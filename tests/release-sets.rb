#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'time'
require 'yaml'

default_root = File.expand_path('..', __dir__)
root = Pathname.new(File.expand_path(ENV.fetch('FOREMAN_KUBERNETES_ROOT', default_root)))
manifest = JSON.parse((root / 'compatibility/release-sets.json').read)
sets = manifest.fetch('sets')
default_set = manifest.fetch('default')
checks_path = root / 'compatibility/required-integration-checks.json'
upstream_contracts_path = root / 'compatibility/upstream-contracts.json'
cluster_platforms_path = root / 'compatibility/cluster-platforms.json'
checks_contract = JSON.parse(checks_path.read)
upstream_contracts = JSON.parse(upstream_contracts_path.read)
cluster_platforms = JSON.parse(cluster_platforms_path.read)
required_checks = checks_contract.fetch('checks')
compatibility_documentation = (root / 'docs/compatibility.md').read

raise 'unsupported release-set schema' unless manifest.fetch('schemaVersion') == 2
raise 'unsupported integration checks schema' unless checks_contract.fetch('schemaVersion') == 1
raise 'unsupported upstream contracts schema' unless upstream_contracts.fetch('schemaVersion') == 1
raise 'unsupported cluster-platform schema' unless cluster_platforms.fetch('schemaVersion') == 1
raise 'integration checks must be unique non-empty strings' unless required_checks == required_checks.uniq && required_checks.all? { |check| check.is_a?(String) && !check.empty? }
raise "default release set #{default_set} does not exist" unless sets.key?(default_set)
environment_values_position = compatibility_documentation.index('--values /secure/path/production-values.yaml')
profile_position = compatibility_documentation.index('--values profiles/nightly-candidate-2026-09-23.yaml')
unless environment_values_position && profile_position && environment_values_position < profile_position
  raise 'compatibility documentation allows environment values to override pinned images'
end

def profile_path(root, relative_path)
  path = root.join(relative_path).cleanpath
  raise "profile escapes the repository: #{relative_path}" unless path.to_s.start_with?("#{root}/")
  raise "profile does not exist: #{relative_path}" unless path.file?

  path
end

def digest_pinned!(set_name, component, image)
  reference = "#{image.fetch('repository')}:#{image.fetch('tag')}"
  return if reference.match?(/@sha256:[0-9a-f]{64}\z/)

  raise "#{set_name} #{component} image is not digest-pinned: #{reference}"
end

sets.each do |set_name, release_set|
  status = release_set.fetch('status')
  raise "unsupported status for #{set_name}" unless %w[candidate supported retired].include?(status)
  unless %w[linux/amd64 linux/arm64].include?(release_set.fetch('platform'))
    raise "unsupported platform for #{set_name}"
  end
  upgrade_sources = release_set.fetch('upgradeFrom')
  unless upgrade_sources.is_a?(Array) && !upgrade_sources.empty? &&
         upgrade_sources == upgrade_sources.uniq &&
         upgrade_sources.all? { |source| source.is_a?(String) && sets.key?(source) }
    raise "invalid upgrade sources for #{set_name}"
  end
  raise "same-set reconciliation is not allowed for #{set_name}" unless upgrade_sources.include?(set_name)

  contract_profiles = release_set.fetch('contractProfiles')
  known_contract_profiles = upstream_contracts.fetch('profiles').keys
  unless contract_profiles.is_a?(Array) && !contract_profiles.empty? &&
         contract_profiles == contract_profiles.uniq &&
         (contract_profiles - known_contract_profiles).empty?
    raise "invalid upstream contract profiles for #{set_name}"
  end
  qualification_targets = release_set.fetch('qualificationTargets')
  known_cluster_platforms = cluster_platforms.fetch('platforms').keys
  unless qualification_targets.is_a?(Array) && !qualification_targets.empty? &&
         qualification_targets == qualification_targets.uniq &&
         (qualification_targets - known_cluster_platforms).empty?
    raise "invalid cluster qualification targets for #{set_name}"
  end
  qualification_targets.each do |platform_id|
    unless cluster_platforms.dig('platforms', platform_id, 'workloadPlatform') == release_set.fetch('platform')
      raise "cluster qualification target platform mismatch for #{set_name}: #{platform_id}"
    end
  end

  application_profile_path = profile_path(root, release_set.fetch('applicationProfile'))
  execution_profile_path = profile_path(root, release_set.fetch('executionProxyProfile'))
  application_profile = YAML.safe_load(application_profile_path.read)
  execution_profile = YAML.safe_load(execution_profile_path.read)
  workload_architecture = release_set.fetch('platform').split('/', 2).last

  raise "application profile identity mismatch for #{set_name}" unless \
    application_profile.dig('platform', 'compatibilitySet') == set_name
  raise "execution profile identity mismatch for #{set_name}" unless \
    execution_profile.fetch('compatibilitySet') == set_name
  [application_profile, execution_profile].each do |profile|
    unless profile.dig('scheduling', 'nodeSelector', 'kubernetes.io/arch') == workload_architecture
      raise "image architecture is not enforced by both profiles for #{set_name}"
    end
  end

  %w[foreman candlepin pulp].each do |component|
    digest_pinned!(set_name, component, application_profile.fetch(component).fetch('image'))
  end
  digest_pinned!(set_name, 'execution proxy', execution_profile.fetch('image'))

  if status == 'candidate' && release_set.key?('evidence')
    raise "candidate #{set_name} must not carry supported evidence"
  end
  next unless status == 'supported'

  missing_contracts = upstream_contracts.fetch('contracts').select do |contract|
    !(contract.fetch('profiles') & contract_profiles).empty? &&
      (contract.fetch('state') != 'published' ||
       !contract.fetch('availableInReleaseSets').include?(set_name))
  end
  unless missing_contracts.empty?
    raise "supported release set #{set_name} is missing upstream contracts: #{missing_contracts.map { |contract| contract.fetch('id') }.join(', ')}"
  end

  evidence_reference = release_set.fetch('evidence')
  evidence_path = profile_path(root, evidence_reference.fetch('file'))
  evidence_digest = Digest::SHA256.file(evidence_path).hexdigest
  raise "stored evidence digest mismatch for #{set_name}" unless evidence_reference.fetch('sha256') == evidence_digest

  evidence = JSON.parse(evidence_path.read)
  raise "unsupported evidence schema for #{set_name}" unless evidence.fetch('schemaVersion') == 2
  raise "stored evidence belongs to another set: #{set_name}" unless evidence.fetch('compatibilitySet') == set_name
  cluster_platform_id = evidence.fetch('clusterPlatform')
  unless qualification_targets.include?(cluster_platform_id)
    raise "stored evidence used an undeclared cluster platform for #{set_name}"
  end
  cluster_platform = cluster_platforms.fetch('platforms').fetch(cluster_platform_id)
  cluster_runtime = evidence.fetch('clusterRuntime')
  expected_cluster_runtime = {
    'kubernetesVersion' => cluster_platform.dig('kubernetes', 'version'),
    'nodeImage' => cluster_platform.dig('kubernetes', 'nodeImage'),
    'containerRuntime' => cluster_platform.dig('kubernetes', 'containerRuntime'),
    'ingressChartVersion' => cluster_platform.dig('ingress', 'chartVersion'),
    'podSecurityVersion' => cluster_platform.dig('podSecurity', 'version')
  }
  raise "stored evidence cluster runtime mismatch for #{set_name}" unless cluster_runtime == expected_cluster_runtime
  raise "stored evidence did not pass for #{set_name}" unless evidence.fetch('result') == 'passed' && evidence.fetch('eligibleForPromotion') == true
  raise "stored evidence used another target for #{set_name}" unless evidence.fetch('targetPlatform') == release_set.fetch('platform')
  unless evidence.fetch('runnerPlatform') == cluster_platform.fetch('runnerPlatform')
    raise "stored evidence did not run on the declared runner for #{set_name}"
  end
  raise "stored evidence commit mismatch for #{set_name}" unless evidence_reference.fetch('testedCommit') == evidence.fetch('gitCommit')
  raise "stored evidence timestamp mismatch for #{set_name}" unless evidence_reference.fetch('completedAt') == evidence.fetch('completedAt')
  raise "stored evidence workflow mismatch for #{set_name}" unless evidence_reference.fetch('workflowRun') == evidence.dig('provenance', 'runUrl')
  raise "invalid stored evidence commit for #{set_name}" unless evidence.fetch('gitCommit').match?(/\A[0-9a-f]{40}\z/)
  raise "invalid stored evidence timestamp for #{set_name}" unless Time.iso8601(evidence.fetch('completedAt')).utc.iso8601 == evidence.fetch('completedAt')

  provenance = evidence.fetch('provenance')
  raise "unsupported evidence provider for #{set_name}" unless provenance.fetch('provider') == 'github-actions'
  raise "unexpected evidence workflow for #{set_name}" unless provenance.fetch('workflow') == 'Full integration'
  raise "unexpected evidence event for #{set_name}" unless provenance.fetch('event') == 'workflow_dispatch'
  raise "unexpected evidence job for #{set_name}" unless provenance.fetch('job') == 'kind'
  raise "invalid evidence workflow URL for #{set_name}" unless provenance.fetch('runUrl').match?(%r{\Ahttps://github\.com/[^/]+/[^/]+/actions/runs/\d+\z})

  missing_checks = required_checks - evidence.fetch('checks')
  raise "stored evidence is missing checks for #{set_name}: #{missing_checks.join(', ')}" unless missing_checks.empty?

  evidence_inputs = evidence.fetch('inputs')
  expected_inputs = {
    'applicationProfileSha256' => Digest::SHA256.file(application_profile_path).hexdigest,
    'executionProfileSha256' => Digest::SHA256.file(execution_profile_path).hexdigest,
    'checksSha256' => Digest::SHA256.file(checks_path).hexdigest,
    'upstreamContractsSha256' => Digest::SHA256.file(upstream_contracts_path).hexdigest,
    'clusterPlatformsSha256' => Digest::SHA256.file(cluster_platforms_path).hexdigest
  }
  expected_inputs.each do |key, expected_digest|
    raise "stored evidence input mismatch for #{set_name}: #{key}" unless evidence_inputs.fetch(key) == expected_digest
  end
end

puts "Validated #{sets.length} digest-pinned release set(s); default is #{default_set}."
