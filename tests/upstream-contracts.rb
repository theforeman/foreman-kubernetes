#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
manifest = JSON.parse((root / 'compatibility/upstream-contracts.json').read)
release_sets = JSON.parse((root / 'compatibility/release-sets.json').read)
documentation = (root / 'docs/upstream-runtime-readiness.md').read

raise 'unsupported upstream contract schema' unless manifest.fetch('schemaVersion') == 1

profiles = manifest.fetch('profiles')
contracts = manifest.fetch('contracts')
ids = contracts.map { |contract| contract.fetch('id') }
raise 'upstream contract IDs must be unique' unless ids == ids.uniq
raise 'upstream contract registry must not be empty' if contracts.empty?

allowed_states = %w[local-upstream-commit merged-upstream published]
allowed_components = %w[foreman candlepin execution-proxy pulp]
sha_pattern = /\A[0-9a-f]{40}\z/

contracts.each do |contract|
  id = contract.fetch('id')
  raise "invalid upstream contract ID: #{id}" unless id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
  raise "unsupported component for #{id}" unless allowed_components.include?(contract.fetch('component'))
  raise "unsupported state for #{id}" unless allowed_states.include?(contract.fetch('state'))

  contract_profiles = contract.fetch('profiles')
  unless contract_profiles.is_a?(Array) && !contract_profiles.empty? &&
         contract_profiles == contract_profiles.uniq &&
         (contract_profiles - profiles.keys).empty?
    raise "invalid profiles for #{id}"
  end

  available_sets = contract.fetch('availableInReleaseSets')
  unless available_sets.is_a?(Array) && available_sets == available_sets.uniq &&
         (available_sets - release_sets.fetch('sets').keys).empty?
    raise "invalid release-set availability for #{id}"
  end
  if contract.fetch('state') != 'published' && !available_sets.empty?
    raise "unpublished contract claims release-set availability: #{id}"
  end

  upstream = contract.fetch('upstream')
  raise "invalid upstream repository for #{id}" unless upstream.fetch('repository').match?(%r{\Ahttps://github\.com/[^/]+/[^/]+\.git\z})
  raise "invalid upstream commit for #{id}" unless upstream.fetch('commit').match?(sha_pattern)
  raise "invalid upstream pull request for #{id}" unless upstream.fetch('pullRequest').match?(%r{\Ahttps://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*\z})
  raise "missing standalone-default contract for #{id}" if contract.fetch('standaloneDefault').empty?
  raise "missing Kubernetes consumer for #{id}" if contract.fetch('kubernetesConsumers').empty?
  raise "upstream readiness documentation omits #{id}" unless documentation.include?("`#{id}`")
end

release_sets.fetch('sets').each do |set_name, release_set|
  contract_profiles = release_set.fetch('contractProfiles')
  unless contract_profiles.is_a?(Array) && !contract_profiles.empty? &&
         contract_profiles == contract_profiles.uniq &&
         (contract_profiles - profiles.keys).empty?
    raise "invalid contract profiles for release set #{set_name}"
  end

  next unless release_set.fetch('status') == 'supported'

  missing = contracts.select do |contract|
    !(contract.fetch('profiles') & contract_profiles).empty? &&
      (contract.fetch('state') != 'published' ||
       !contract.fetch('availableInReleaseSets').include?(set_name))
  end
  unless missing.empty?
    raise "supported release set #{set_name} is missing upstream contracts: #{missing.map { |contract| contract.fetch('id') }.join(', ')}"
  end
end

upstream_root = root.parent / 'foreman-kubernetes-upstream'
if upstream_root.directory?
  contracts.each do |contract|
    upstream = contract.fetch('upstream')
    repository = upstream_root / upstream.fetch('localPath')
    next unless repository.directory?

    branch_output, branch_status = Open3.capture2('git', '-C', repository.to_s, 'rev-parse', "refs/heads/#{upstream.fetch('branch')}")
    raise "missing local upstream branch for #{contract.fetch('id')}" unless branch_status.success?
    unless branch_output.strip == upstream.fetch('commit')
      raise "local upstream branch is stale for #{contract.fetch('id')}"
    end

    remote_output, remote_status = Open3.capture2('git', '-C', repository.to_s, 'remote', 'get-url', 'origin')
    raise "cannot read local upstream remote for #{contract.fetch('id')}" unless remote_status.success?
    unless remote_output.strip == upstream.fetch('repository')
      raise "local upstream repository mismatch for #{contract.fetch('id')}"
    end
  end
end

puts "Validated #{contracts.length} upstream runtime contracts across #{profiles.length} profile(s)."
