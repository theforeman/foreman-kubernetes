#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

abort 'usage: image-platform-scheduling-contract.rb APPLICATION_RENDER EXECUTION_RENDER' unless ARGV.length == 2

root = Pathname.new(File.expand_path('..', __dir__))
release_sets = JSON.parse((root / 'compatibility/release-sets.json').read)

def pod_spec(document)
  case document['kind']
  when 'Pod'
    document['spec']
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

release_sets.fetch('sets').each do |set_name, release_set|
  operating_system, architecture = release_set.fetch('platform').split('/', 2)
  raise "unsupported workload operating system for #{set_name}" unless operating_system == 'linux'
  raise "missing workload architecture for #{set_name}" if architecture.nil? || architecture.empty?

  %w[applicationProfile executionProxyProfile].each do |profile_key|
    profile = YAML.safe_load((root / release_set.fetch(profile_key)).read)
    selector = profile.dig('scheduling', 'nodeSelector')
    unless selector == {'kubernetes.io/arch' => architecture}
      raise "#{set_name} #{profile_key} does not enforce its image architecture"
    end
  end
end

set_name = release_sets.fetch('default')
expected_architecture = release_sets.dig('sets', set_name, 'platform').split('/', 2).last

ARGV.each do |render_path|
  workloads = YAML.load_stream(File.read(render_path)).compact.each_with_object([]) do |document, found|
    spec = pod_spec(document)
    found << [document.fetch('kind'), document.dig('metadata', 'name'), spec] if spec
  end
  abort "#{render_path}: no pod-producing workload was rendered" if workloads.empty?

  workloads.each do |kind, name, spec|
    actual_architecture = spec.dig('nodeSelector', 'kubernetes.io/arch')
    unless actual_architecture == expected_architecture
      abort "#{render_path}: #{kind}/#{name} is not pinned to #{expected_architecture} nodes"
    end
  end
end

puts "Release workloads are pinned to the #{expected_architecture} image architecture."
