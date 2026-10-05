#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

manifest_path, expected_secret = ARGV
abort 'usage: image-pull-secrets-contract.rb MANIFEST SECRET_NAME' unless expected_secret

def pod_spec(document)
  case document['kind']
  when 'Pod'
    document['spec']
  when 'Deployment', 'DaemonSet', 'ReplicaSet', 'StatefulSet', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

checked = 0
YAML.load_stream(File.read(manifest_path)).compact.each do |document|
  next unless document.is_a?(Hash)

  spec = pod_spec(document)
  next unless spec.is_a?(Hash)

  checked += 1
  names = Array(spec['imagePullSecrets']).map { |secret| secret['name'] }
  next if names.include?(expected_secret)

  abort "#{document['kind']}/#{document.dig('metadata', 'name')} cannot pull from the configured private registry"
end

abort 'no Pod templates were found' if checked.zero?

puts "Global image pull credentials cover #{checked} Pod templates."
