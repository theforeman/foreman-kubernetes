#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST RELEASE_INSTANCE" unless ARGV.length == 2

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
instance = ARGV.fetch(1)

def pod_template(resource)
  case resource['kind']
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template')
  when 'Deployment', 'Job', 'StatefulSet', 'DaemonSet'
    resource.dig('spec', 'template')
  end
end

def selector_matches?(selector, labels)
  match_labels = selector.fetch('matchLabels', {})
  return false unless match_labels.all? { |key, value| labels[key] == value }

  Array(selector['matchExpressions']).all? do |expression|
    value = labels[expression.fetch('key')]
    case expression.fetch('operator')
    when 'In'
      expression.fetch('values').include?(value)
    when 'NotIn'
      value && !expression.fetch('values').include?(value)
    when 'Exists'
      !value.nil?
    when 'DoesNotExist'
      value.nil?
    else
      false
    end
  end
end

workloads = documents.each_with_object([]) do |resource, selected|
  template = pod_template(resource)
  next unless template
  next unless template.dig('metadata', 'labels', 'app.kubernetes.io/instance') == instance

  selected << [resource, template]
end
ingress_policies = documents.select do |resource|
  resource['kind'] == 'NetworkPolicy' && Array(resource.dig('spec', 'policyTypes')).include?('Ingress')
end

default_deny = ingress_policies.find do |policy|
  policy.dig('spec', 'podSelector', 'matchLabels') == { 'app.kubernetes.io/instance' => instance } &&
    !policy.fetch('spec').key?('ingress')
end
abort "missing release-wide default-deny ingress policy for #{instance}" unless default_deny

unselected = workloads.each_with_object([]) do |(resource, template), names|
  labels = template.dig('metadata', 'labels') || {}
  next if ingress_policies.any? { |policy| selector_matches?(policy.dig('spec', 'podSelector') || {}, labels) }

  names << "#{resource['kind']}/#{resource.dig('metadata', 'name')}"
end
abort "workloads remain ingress-open: #{unselected.join(', ')}" unless unselected.empty?

puts "Default-deny ingress covers all #{workloads.length} #{instance} workload templates."
