#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

root = File.expand_path('..', __dir__)
drill = File.read(File.join(root, 'tests/kind/operator-release.sh'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
workflow = File.read(File.join(root, '.github/workflows/integration.yaml'))
sanitizer = File.join(root, 'tests/kind/sanitize-operator-values.rb')
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

required = {
  'adopt existing releases' => 'adoptExisting: true',
  'inject a real Candlepin migration failure' => "'operator-wrong-password'",
  'retain application Pods through failure' => 'application_workload_pod_uids',
  'require explicit retry authorization' => 'retryToken":"credentials-restored',
  'replace the active controller leader' => 'wait_for_new_leader',
  'require the replacement leader to finish the retry' => '.spec.holderIdentity == $holder',
  'return adoption flags to their safe default' => 'adoptExisting":false',
  'repair modified stateless resources' => 'app.kubernetes.io/component=operator-drift',
  'repair valid Secret rotations' => 'SecretInputs/application:modified',
  'block modified stateful resources' => 'UnsafeDriftDetected',
  'publish the earliest certificate expiry' => '.status.certificateExpiryTimestamp',
  'persist an operator evidence report' => 'operator-release.json'
}
required.each do |description, contract|
  abort "operator drill does not #{description}" unless drill.include?(contract)
end

abort 'Kind harness does not build the release operator image' unless harness.include?('images/release-operator/Dockerfile')
abort 'Kind harness does not execute the release operator drill' unless harness.include?('tests/kind/operator-release.sh')
abort 'CI does not retain the operator report' unless workflow.include?('artifacts/operator-release.json')
%w[
  operator-blocked-retry
  operator-leader-takeover
  operator-stateless-drift-repair
  operator-secret-rotation-repair
  operator-stateful-drift-block
  operator-certificate-observation
].each do |check|
  abort "promotion evidence does not require #{check}" unless checks.include?(check)
end

Dir.mktmpdir('operator-values-contract') do |directory|
  input = File.join(directory, 'input.yaml')
  output = File.join(directory, 'output.yaml')
  File.write(input, YAML.dump(
    'releaseOperation' => {'skipMigrationJobs' => true},
    'migrations' => {'activeDeadlineSeconds' => 3600},
    'foreman' => {'replicaCount' => 2}
  ))
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, sanitizer, 'application', input, output)
  abort "operator values sanitizer failed: #{stdout}#{stderr}" unless status.success?

  sanitized = YAML.safe_load(File.read(output), permitted_classes: [], permitted_symbols: [], aliases: false)
  abort 'operator values sanitizer retained controller-owned release state' if sanitized.key?('releaseOperation')
  abort 'operator values sanitizer did not bound the failure drill' unless sanitized.dig('migrations', 'activeDeadlineSeconds') == 90
  abort 'operator values sanitizer lost application values' unless sanitized.dig('foreman', 'replicaCount') == 2
end

puts 'Full integration exercises ForemanRelease failure, takeover, drift and Secret repair, and certificate observation.'
