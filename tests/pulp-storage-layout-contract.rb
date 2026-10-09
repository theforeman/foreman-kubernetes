#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} FILESYSTEM_MANIFEST OBJECT_STORAGE_MANIFEST" unless ARGV.length == 2

def pulp_deployments(path)
  YAML.load_stream(File.read(path)).compact.select do |resource|
    resource['kind'] == 'Deployment' &&
      %w[pulp-api pulp-content pulp-worker].include?(
        resource.dig('metadata', 'labels', 'app.kubernetes.io/component')
      )
  end
end

filesystem = pulp_deployments(ARGV.fetch(0))
abort "expected three filesystem Pulp Deployments, got #{filesystem.length}" unless filesystem.length == 3

filesystem.each do |deployment|
  component = deployment.dig('metadata', 'labels', 'app.kubernetes.io/component')
  prepare = Array(deployment.dig('spec', 'template', 'spec', 'initContainers')).find do |container|
    container['name'] == 'prepare-pulp-storage'
  end
  abort "#{component} does not prepare filesystem storage" unless prepare
  unless Array(prepare['command']) == ['/usr/bin/mkdir', '-p', '/var/lib/pulp/media']
    abort "#{component} does not create Pulp's configured media directory"
  end
  mount = Array(prepare['volumeMounts']).find { |candidate| candidate['name'] == 'pulp-data' }
  abort "#{component} storage preparation does not mount the Pulp PVC" unless
    mount&.fetch('mountPath', nil) == '/var/lib/pulp'
end

object_storage = pulp_deployments(ARGV.fetch(1))
abort "expected three object-storage Pulp Deployments, got #{object_storage.length}" unless object_storage.length == 3
object_storage.each do |deployment|
  component = deployment.dig('metadata', 'labels', 'app.kubernetes.io/component')
  init_names = Array(deployment.dig('spec', 'template', 'spec', 'initContainers')).map { |container| container['name'] }
  abort "#{component} prepares a nonexistent filesystem PVC for object storage" if
    init_names.include?('prepare-pulp-storage')
end

puts 'Pulp filesystem workloads create the media directory without imposing a PVC on object storage.'
