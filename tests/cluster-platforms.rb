#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
manifest = JSON.parse((root / 'compatibility/cluster-platforms.json').read)
release_sets = JSON.parse((root / 'compatibility/release-sets.json').read)
documentation = (root / 'docs/compatibility.md').read

raise 'unsupported cluster-platform schema' unless manifest.fetch('schemaVersion') == 1

platforms = manifest.fetch('platforms')
default_platform = manifest.fetch('default')
raise 'cluster-platform registry must not be empty' if platforms.empty?
raise "default cluster platform #{default_platform} does not exist" unless platforms.key?(default_platform)

allowed_harness_states = %w[implemented-unrun verified]
platform_pattern = %r{\Alinux/(?:amd64|arm64)\z}
digest_pattern = /@sha256:[0-9a-f]{64}\z/
semver_pattern = /\A\d+\.\d+\.\d+\z/

platforms.each do |platform_id, platform|
  raise "invalid cluster-platform ID: #{platform_id}" unless platform_id.match?(/\A[a-z0-9][a-z0-9.-]*\z/)
  unless allowed_harness_states.include?(platform.fetch('harnessState'))
    raise "unsupported harness state for #{platform_id}"
  end

  %w[harness workflow].each do |path_key|
    path = root / platform.fetch(path_key)
    raise "#{platform_id} #{path_key} does not exist" unless path.file?
  end

  %w[workloadPlatform runnerPlatform].each do |platform_key|
    unless platform.fetch(platform_key).match?(platform_pattern)
      raise "invalid #{platform_key} for #{platform_id}"
    end
  end

  kubernetes = platform.fetch('kubernetes')
  raise "unsupported Kubernetes distribution for #{platform_id}" unless kubernetes.fetch('distribution') == 'kind'
  raise "invalid Kubernetes version for #{platform_id}" unless kubernetes.fetch('version').match?(semver_pattern)
  unless kubernetes.fetch('nodeImage').match?(digest_pattern)
    raise "cluster node image is not digest-pinned for #{platform_id}"
  end
  unless kubernetes.fetch('nodeImage').include?(":v#{kubernetes.fetch('version')}@")
    raise "cluster node image version mismatch for #{platform_id}"
  end
  raise "missing container runtime for #{platform_id}" if kubernetes.fetch('containerRuntime').empty?

  ingress = platform.fetch('ingress')
  raise "unsupported ingress controller for #{platform_id}" unless ingress.fetch('controller') == 'k8s.io/ingress-nginx'
  raise "invalid ingress chart version for #{platform_id}" unless ingress.fetch('chartVersion').match?(semver_pattern)

  pod_security = platform.fetch('podSecurity')
  raise "unsupported Pod Security profile for #{platform_id}" unless pod_security.fetch('profile') == 'restricted'
  unless pod_security.fetch('version') == "v#{kubernetes.fetch('version').split('.').first(2).join('.')}"
    raise "Pod Security version mismatch for #{platform_id}"
  end

  host_contract = platform.fetch('hostContract')
  raise "unsupported node kernel for #{platform_id}" unless host_contract.fetch('nodeKernel') == 'linux'
  raise "#{platform_id} requires application packages on the node" unless host_contract.fetch('applicationPackagesRequired') == false
  %w[hostServicesRequired hostRuntimeSocketsRequired hostFilesystemMountsRequired].each do |key|
    raise "#{platform_id} declares host coupling in #{key}" unless host_contract.fetch(key) == []
  end

  if platform.fetch('harnessState') == 'verified'
    evidence = platform.fetch('evidence')
    evidence_path = root / evidence.fetch('file')
    raise "verified cluster platform #{platform_id} has no retained evidence" unless evidence_path.file?
  elsif platform.key?('evidence')
    raise "unverified cluster platform #{platform_id} carries evidence"
  end

  raise "compatibility documentation omits #{platform_id}" unless documentation.include?("`#{platform_id}`")
end

release_sets.fetch('sets').each do |set_name, release_set|
  qualification_targets = release_set.fetch('qualificationTargets')
  unless qualification_targets.is_a?(Array) && !qualification_targets.empty? &&
         qualification_targets == qualification_targets.uniq &&
         (qualification_targets - platforms.keys).empty?
    raise "invalid cluster qualification targets for #{set_name}"
  end
  qualification_targets.each do |platform_id|
    platform = platforms.fetch(platform_id)
    unless platform.fetch('workloadPlatform') == release_set.fetch('platform')
      raise "release-set platform mismatch for #{set_name} and #{platform_id}"
    end
  end
end

default = platforms.fetch(default_platform)
harness = (root / default.fetch('harness')).read
workflow = (root / default.fetch('workflow')).read
raise 'kind harness does not resolve the cluster-platform registry' unless harness.include?('compatibility/cluster-platforms.json')
raise 'kind harness does not use the declared node image' unless harness.include?('declared_kind_node_image')
raise 'kind harness does not use the declared ingress chart version' unless harness.include?('ingress_chart_version')
raise 'kind harness does not validate the live cluster platform' unless harness.include?('assert_cluster_platform')
unless harness.include?("'.sets[$set].qualificationTargets[0]'")
  raise 'kind harness does not derive its default target from the selected release set'
end
unless harness.include?('expected_runner_architecture')
  raise 'kind harness does not enforce the selected target runner architecture'
end
if harness.include?('images are currently linux/amd64 only')
  raise 'kind harness still hard-codes the current candidate architecture'
end
raise 'full integration workflow no longer uses the expected amd64 runner' unless workflow.include?('runs-on: ubuntu-24.04')

puts "Validated #{platforms.length} cluster platform contract(s); default is #{default_platform}."
