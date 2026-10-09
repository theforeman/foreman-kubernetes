#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'rbconfig'
require 'shellwords'
require 'time'

unless ARGV.length == 7
  abort 'usage: write-integration-evidence.rb OUTPUT SET APPLICATION_PROFILE EXECUTION_PROFILE RESULT CLUSTER_PLATFORM NODE_IMAGE'
end

root = Pathname.new(File.expand_path('..', __dir__))
output = Pathname.new(File.expand_path(ARGV.fetch(0)))
set_name = ARGV.fetch(1)
application_profile = Pathname.new(File.expand_path(ARGV.fetch(2)))
execution_profile = Pathname.new(File.expand_path(ARGV.fetch(3)))
result = ARGV.fetch(4)
cluster_platform_id = ARGV.fetch(5)
node_image = ARGV.fetch(6)
abort "unsupported integration result: #{result}" unless %w[passed partial].include?(result)

release_sets_path = root / 'compatibility/release-sets.json'
cluster_platforms_path = root / 'compatibility/cluster-platforms.json'
checks_path = root / 'compatibility/required-integration-checks.json'
upstream_contracts_path = root / 'compatibility/upstream-contracts.json'
release_sets = JSON.parse(release_sets_path.read)
release_set = release_sets.fetch('sets').fetch(set_name)
cluster_platforms = JSON.parse(cluster_platforms_path.read)
abort 'unsupported cluster-platform schema' unless cluster_platforms.fetch('schemaVersion') == 1
cluster_platform = cluster_platforms.fetch('platforms').fetch(cluster_platform_id)
unless release_set.fetch('qualificationTargets').include?(cluster_platform_id)
  abort "cluster platform #{cluster_platform_id} is not a qualification target for #{set_name}"
end
declared_application_profile = root / release_set.fetch('applicationProfile')
declared_execution_profile = root / release_set.fetch('executionProxyProfile')

unless application_profile.realpath == declared_application_profile.realpath
  abort 'tested application profile does not match the declared compatibility set'
end
unless execution_profile.realpath == declared_execution_profile.realpath
  abort 'tested execution profile does not match the declared compatibility set'
end

checks_contract = JSON.parse(checks_path.read)
abort 'unsupported integration checks schema' unless checks_contract.fetch('schemaVersion') == 1

checks = checks_contract.fetch('checks')
if result == 'partial'
  checks -= %w[
    clean-namespace-recovery
    foreman-webhooks-clean-recovery
    virt-who-configuration-clean-recovery
  ]
end

host_os = RbConfig::CONFIG.fetch('host_os')
operating_system = if host_os.include?('linux')
                     'linux'
                   elsif host_os.include?('darwin')
                     'darwin'
                   else
                     host_os.split(/\d/).first
                   end
architecture = `uname -m`.strip
architecture = 'amd64' if %w[amd64 x86_64].include?(architecture)
architecture = 'arm64' if %w[aarch64 arm64 arm64e].include?(architecture)
runner_platform = "#{operating_system}/#{architecture}"

git_commit = ENV['GITHUB_SHA'] || `git -C #{root.to_s.shellescape} rev-parse HEAD`.strip
abort 'integration evidence requires a full Git commit SHA' unless git_commit.match?(/\A[0-9a-f]{40}\z/)

github_actions = ENV['GITHUB_ACTIONS'] == 'true'
provenance = if github_actions
               repository = ENV.fetch('GITHUB_REPOSITORY')
               run_id = ENV.fetch('GITHUB_RUN_ID')
               run_attempt = ENV.fetch('GITHUB_RUN_ATTEMPT')
               server_url = ENV.fetch('GITHUB_SERVER_URL')
               {
                 'provider' => 'github-actions',
                 'workflow' => ENV.fetch('GITHUB_WORKFLOW'),
                 'event' => ENV.fetch('GITHUB_EVENT_NAME'),
                 'job' => ENV.fetch('GITHUB_JOB'),
                 'runId' => run_id,
                 'runAttempt' => run_attempt,
                 'runUrl' => "#{server_url}/#{repository}/actions/runs/#{run_id}"
               }
             else
               {'provider' => 'local'}
             end

platform_matches = cluster_platform.fetch('workloadPlatform') == release_set.fetch('platform')
node_image_matches = node_image == cluster_platform.dig('kubernetes', 'nodeImage')

evidence = {
  'schemaVersion' => 2,
  'compatibilitySet' => set_name,
  'clusterPlatform' => cluster_platform_id,
  'clusterRuntime' => {
    'kubernetesVersion' => cluster_platform.dig('kubernetes', 'version'),
    'nodeImage' => node_image,
    'containerRuntime' => cluster_platform.dig('kubernetes', 'containerRuntime'),
    'ingressChartVersion' => cluster_platform.dig('ingress', 'chartVersion'),
    'podSecurityVersion' => cluster_platform.dig('podSecurity', 'version')
  },
  'result' => result,
  'eligibleForPromotion' => result == 'passed' &&
    platform_matches && node_image_matches &&
    runner_platform == cluster_platform.fetch('runnerPlatform') && github_actions,
  'targetPlatform' => release_set.fetch('platform'),
  'runnerPlatform' => runner_platform,
  'gitCommit' => git_commit,
  'completedAt' => Time.now.utc.iso8601,
  'provenance' => provenance,
  'inputs' => {
    'releaseSetsSha256' => Digest::SHA256.file(release_sets_path).hexdigest,
    'applicationProfileSha256' => Digest::SHA256.file(application_profile).hexdigest,
    'executionProfileSha256' => Digest::SHA256.file(execution_profile).hexdigest,
    'checksSha256' => Digest::SHA256.file(checks_path).hexdigest,
    'upstreamContractsSha256' => Digest::SHA256.file(upstream_contracts_path).hexdigest,
    'clusterPlatformsSha256' => Digest::SHA256.file(cluster_platforms_path).hexdigest
  },
  'checks' => checks
}

FileUtils.mkdir_p(output.dirname)
temporary_output = Pathname.new("#{output}.tmp.#{Process.pid}")
begin
  temporary_output.write("#{JSON.pretty_generate(evidence)}\n")
  File.rename(temporary_output, output)
ensure
  temporary_output.delete if temporary_output.exist?
end

puts "Wrote #{result} integration evidence for #{set_name} to #{output}"
