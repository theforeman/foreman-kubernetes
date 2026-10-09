#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
components = %w[pulp-api pulp-content pulp-worker pulp-migrate foreman-migrate]
workloads = documents.select do |resource|
  %w[Deployment Job].include?(resource['kind']) &&
    components.include?(resource.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
abort 'rendered manifest does not contain every Pulp runtime and migration workload' unless workloads.length == 5

workloads.each do |workload|
  name = workload.dig('metadata', 'name')
  component = workload.dig('metadata', 'labels', 'app.kubernetes.io/component')
  pod_spec = workload.dig('spec', 'template', 'spec')
  volume = Array(pod_spec['volumes']).find { |candidate| candidate['name'] == 'pulp-tmp' }
  unless volume&.key?('emptyDir') && volume.dig('emptyDir', 'sizeLimit')
    abort "#{name} does not provide bounded ephemeral Pulp scratch storage"
  end

  pulp_containers = (Array(pod_spec['initContainers']) + Array(pod_spec['containers'])).select do |container|
    container['name'].start_with?('pulp-') || container['name'] == 'wait-for-pulp-migrations' ||
      (component == 'pulp-migrate' && container['name'] == 'migrate')
  end
  pulp_containers.each do |container|
    mount = Array(container['volumeMounts']).find { |candidate| candidate['name'] == 'pulp-tmp' }
    unless mount&.fetch('mountPath', nil) == '/var/lib/pulp/tmp'
      abort "#{name}/#{container.fetch('name')} does not mount Pulp scratch storage"
    end
  end
end

puts 'Every Pulp runtime and migration workload mounts bounded ephemeral scratch storage.'
