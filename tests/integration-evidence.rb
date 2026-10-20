#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'pathname'
require 'rbconfig'
require 'tmpdir'

root = Pathname.new(File.expand_path('..', __dir__))
release_sets = JSON.parse((root / 'compatibility/release-sets.json').read)
set_name = release_sets.fetch('default')
release_set = release_sets.fetch('sets').fetch(set_name)
cluster_platforms = JSON.parse((root / 'compatibility/cluster-platforms.json').read)
cluster_platform_id = release_set.fetch('qualificationTargets').first
cluster_platform = cluster_platforms.fetch('platforms').fetch(cluster_platform_id)
node_image = cluster_platform.dig('kubernetes', 'nodeImage')
application_profile = root / release_set.fetch('applicationProfile')
execution_profile = root / release_set.fetch('executionProxyProfile')
writer = root / 'scripts/write-integration-evidence.rb'
promoter = root / 'scripts/promote-release-set.rb'
validator = root / 'tests/release-sets.rb'
git_commit = `git -C #{root} rev-parse HEAD`.strip

def run_command(*command, env: {})
  stdout, stderr, status = Open3.capture3(env, *command)
  [stdout, stderr, status]
end

Dir.mktmpdir('foreman-kubernetes-evidence') do |directory|
  work = Pathname.new(directory)
  generated_evidence = work / 'generated.json'
  stdout, stderr, status = run_command(
    RbConfig.ruby,
    writer.to_s,
    generated_evidence.to_s,
    set_name,
    application_profile.to_s,
    execution_profile.to_s,
    'passed',
    cluster_platform_id,
    node_image
  )
  abort stderr unless status.success?
  abort 'evidence writer did not report its output' unless stdout.include?(set_name)

  evidence = JSON.parse(generated_evidence.read)
  required_checks = JSON.parse((root / 'compatibility/required-integration-checks.json').read).fetch('checks')
  abort 'local evidence must not be promotable' unless evidence.fetch('eligibleForPromotion') == false
  abort 'evidence did not record the exact compatibility set' unless evidence.fetch('compatibilitySet') == set_name
  abort 'evidence did not record the cluster platform' unless evidence.fetch('clusterPlatform') == cluster_platform_id
  abort 'evidence did not record the cluster node image' unless evidence.dig('clusterRuntime', 'nodeImage') == node_image
  abort 'evidence omitted required integration checks' unless (required_checks - evidence.fetch('checks')).empty?
  expected_contracts_digest = Digest::SHA256.file(root / 'compatibility/upstream-contracts.json').hexdigest
  unless evidence.dig('inputs', 'upstreamContractsSha256') == expected_contracts_digest
    abort 'evidence omitted the upstream contract registry digest'
  end
  expected_platforms_digest = Digest::SHA256.file(root / 'compatibility/cluster-platforms.json').hexdigest
  unless evidence.dig('inputs', 'clusterPlatformsSha256') == expected_platforms_digest
    abort 'evidence omitted the cluster-platform registry digest'
  end

  partial_generated_evidence = work / 'generated-partial.json'
  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    writer.to_s,
    partial_generated_evidence.to_s,
    set_name,
    application_profile.to_s,
    execution_profile.to_s,
    'partial',
    cluster_platform_id,
    node_image
  )
  abort stderr unless status.success?
  partial_generated = JSON.parse(partial_generated_evidence.read)
  abort 'partial evidence was marked promotable' unless partial_generated.fetch('eligibleForPromotion') == false
  abort 'partial evidence retained the skipped recovery check' if partial_generated.fetch('checks').include?('clean-namespace-recovery')
  if partial_generated.fetch('checks').include?('foreman-webhooks-clean-recovery')
    abort 'partial evidence retained the skipped webhook recovery check'
  end
  if partial_generated.fetch('checks').include?('virt-who-configuration-clean-recovery')
    abort 'partial evidence retained the skipped virt-who configuration recovery check'
  end

  undeclared_profile = work / 'undeclared-profile.yaml'
  FileUtils.cp(application_profile, undeclared_profile)
  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    writer.to_s,
    (work / 'undeclared.json').to_s,
    set_name,
    undeclared_profile.to_s,
    execution_profile.to_s,
    'passed',
    cluster_platform_id,
    node_image
  )
  abort 'evidence writer accepted an undeclared profile path' if status.success?
  abort 'undeclared profile failure was not explicit' unless stderr.include?('does not match the declared compatibility set')

  github_evidence_path = work / 'github.json'
  github_environment = {
    'GITHUB_ACTIONS' => 'true',
    'GITHUB_SHA' => git_commit,
    'GITHUB_REPOSITORY' => 'example/foreman-kubernetes',
    'GITHUB_RUN_ID' => '123456789',
    'GITHUB_RUN_ATTEMPT' => '1',
    'GITHUB_SERVER_URL' => 'https://github.com',
    'GITHUB_WORKFLOW' => 'Full integration',
    'GITHUB_EVENT_NAME' => 'workflow_dispatch',
    'GITHUB_JOB' => 'kind'
  }
  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    writer.to_s,
    github_evidence_path.to_s,
    set_name,
    application_profile.to_s,
    execution_profile.to_s,
    'passed',
    cluster_platform_id,
    node_image,
    env: github_environment
  )
  abort stderr unless status.success?
  github_evidence = JSON.parse(github_evidence_path.read)
  abort 'writer omitted GitHub workflow provenance' unless github_evidence.dig('provenance', 'workflow') == 'Full integration'

  custom_node_evidence_path = work / 'custom-node.json'
  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    writer.to_s,
    custom_node_evidence_path.to_s,
    set_name,
    application_profile.to_s,
    execution_profile.to_s,
    'passed',
    cluster_platform_id,
    'kindest/node:v1.34.11@sha256:' + ('0' * 64),
    env: github_environment
  )
  abort stderr unless status.success?
  custom_node_evidence = JSON.parse(custom_node_evidence_path.read)
  abort 'writer promoted an undeclared node image' unless custom_node_evidence.fetch('eligibleForPromotion') == false

  temporary_root = work / 'repository'
  FileUtils.mkdir_p(temporary_root)
  FileUtils.cp_r((root / 'compatibility').to_s, temporary_root.to_s)
  FileUtils.cp_r((root / 'profiles').to_s, temporary_root.to_s)
  FileUtils.mkdir_p(temporary_root / 'docs')
  FileUtils.cp(root / 'docs/compatibility.md', temporary_root / 'docs/compatibility.md')

  evidence['eligibleForPromotion'] = true
  evidence['runnerPlatform'] = 'linux/amd64'
  evidence['gitCommit'] = git_commit
  evidence['provenance'] = {
    'provider' => 'github-actions',
    'workflow' => 'Full integration',
    'event' => 'workflow_dispatch',
    'job' => 'kind',
    'runId' => '123456789',
    'runAttempt' => '1',
    'runUrl' => 'https://github.com/example/foreman-kubernetes/actions/runs/123456789'
  }
  promotable_evidence = work / 'promotable.json'
  promotable_evidence.write("#{JSON.pretty_generate(evidence)}\n")

  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    promoter.to_s,
    set_name,
    promotable_evidence.to_s,
    env: {'FOREMAN_KUBERNETES_ROOT' => temporary_root.to_s, 'GITHUB_SHA' => git_commit}
  )
  abort 'promotion accepted a release set with unpublished upstream contracts' if status.success?
  unless stderr.include?('missing published upstream contracts')
    abort 'unpublished upstream contract failure was not explicit'
  end

  temporary_contracts_path = temporary_root / 'compatibility/upstream-contracts.json'
  temporary_contracts = JSON.parse(temporary_contracts_path.read)
  required_profiles = release_set.fetch('contractProfiles')
  temporary_contracts.fetch('contracts').each do |contract|
    next if (contract.fetch('profiles') & required_profiles).empty?

    contract['state'] = 'published'
    contract['availableInReleaseSets'] = [set_name]
  end
  temporary_contracts_path.write("#{JSON.pretty_generate(temporary_contracts)}\n")

  evidence.fetch('inputs')['upstreamContractsSha256'] = Digest::SHA256.file(temporary_contracts_path).hexdigest
  promotable_evidence.write("#{JSON.pretty_generate(evidence)}\n")

  stale_evidence = JSON.parse(promotable_evidence.read)
  stale_evidence.fetch('inputs')['applicationProfileSha256'] = '0' * 64
  stale_evidence_path = work / 'stale.json'
  stale_evidence_path.write("#{JSON.pretty_generate(stale_evidence)}\n")
  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    promoter.to_s,
    set_name,
    stale_evidence_path.to_s,
    env: {'FOREMAN_KUBERNETES_ROOT' => temporary_root.to_s, 'GITHUB_SHA' => git_commit}
  )
  abort 'promotion accepted stale profile evidence' if status.success?
  abort 'stale evidence failure did not identify the changed input' unless stderr.include?('integration input changed')

  partial_evidence = JSON.parse(promotable_evidence.read)
  partial_evidence['result'] = 'partial'
  partial_evidence['eligibleForPromotion'] = false
  partial_evidence_path = work / 'partial.json'
  partial_evidence_path.write("#{JSON.pretty_generate(partial_evidence)}\n")
  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    promoter.to_s,
    set_name,
    partial_evidence_path.to_s,
    env: {'FOREMAN_KUBERNETES_ROOT' => temporary_root.to_s, 'GITHUB_SHA' => git_commit}
  )
  abort 'promotion accepted a partial integration run' if status.success?
  abort 'partial evidence failure was not explicit' unless stderr.include?('not a complete passing run')

  stdout, stderr, status = run_command(
    RbConfig.ruby,
    promoter.to_s,
    set_name,
    promotable_evidence.to_s,
    env: {'FOREMAN_KUBERNETES_ROOT' => temporary_root.to_s, 'GITHUB_SHA' => git_commit}
  )
  abort stderr unless status.success?
  abort 'promotion did not report the supported set' unless stdout.include?(set_name)

  promoted_manifest = JSON.parse((temporary_root / 'compatibility/release-sets.json').read)
  promoted_set = promoted_manifest.fetch('sets').fetch(set_name)
  abort 'promotion did not change the set status' unless promoted_set.fetch('status') == 'supported'
  stored_evidence = temporary_root / promoted_set.dig('evidence', 'file')
  abort 'promotion did not retain the evidence' unless stored_evidence.file?

  _stdout, stderr, status = run_command(
    RbConfig.ruby,
    validator.to_s,
    env: {'FOREMAN_KUBERNETES_ROOT' => temporary_root.to_s}
  )
  abort stderr unless status.success?
end

puts 'Integration evidence and release-set promotion checks passed.'
