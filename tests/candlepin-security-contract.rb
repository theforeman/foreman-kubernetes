#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
workloads = documents.select do |resource|
  component = resource.dig('metadata', 'labels', 'app.kubernetes.io/component')
  %w[Deployment Job].include?(resource['kind']) &&
    %w[candlepin candlepin-migrate].include?(component)
end
abort 'rendered manifest must contain Candlepin deployment and migration Job' unless workloads.length == 2

workloads.each do |workload|
  name = workload.dig('metadata', 'name')
  pod_spec = workload.dig('spec', 'template', 'spec')
  pod_security = pod_spec.fetch('securityContext')
  abort "#{name} does not enforce a non-root image identity" unless pod_security['runAsNonRoot']
  abort "#{name} duplicates the Candlepin image UID" if pod_security.key?('runAsUser')

  containers = Array(pod_spec['initContainers']) + Array(pod_spec['containers'])
  containers.each do |container|
    security = container.fetch('securityContext')
    abort "#{name}/#{container.fetch('name')} permits privilege escalation" unless security['allowPrivilegeEscalation'] == false
    abort "#{name}/#{container.fetch('name')} duplicates the Candlepin image UID" if security.key?('runAsUser')
  end
end

puts 'Candlepin workloads enforce the numeric non-root identity supplied by the upstream image.'
