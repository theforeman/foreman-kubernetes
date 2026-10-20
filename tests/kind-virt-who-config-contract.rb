#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

root = File.expand_path('..', __dir__)
values = YAML.safe_load(File.read(File.join(root, 'tests/kind/values.yaml')))
lifecycle = File.read(File.join(root, 'tests/kind/virt-who-config-lifecycle.sh'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
checks = JSON.parse(
  File.read(File.join(root, 'compatibility/required-integration-checks.json'))
).fetch('checks')

unless values.dig('foreman', 'enabledPlugins').include?('foreman_virt_who_configure')
  abort 'Kind profile does not enable foreman_virt_who_configure'
end

required_lifecycle_contracts = {
  'reject an invalid KubeVirt configuration' => 'invalid KubeVirt configuration returned',
  'exercise the plugin API' => '/foreman_virt_who_configure/api/v2/configs',
  'avoid exposing a password in the normal API' => 'has("hypervisor_password")',
  'verify encrypted service credentials at rest' => 'encrypted_password_in_db',
  'require the hidden authentication source' => 'AuthSourceHiddenWithAuthentication',
  'require the reporting role' => 'Virt-who Reporter',
  'move report state to ok' => 'config.virt_who_touch!',
  'validate the external systemd contract' => 'systemctl restart virt-who',
  'regenerate the script after an endpoint update' => 'updated deploy script retained',
  'verify clean recovery' => 'restored virt-who configuration differs',
  'remove the service identity with the final config' => 'Service identity survived deletion'
}
required_lifecycle_contracts.each do |description, contract|
  abort "virt-who configuration lifecycle does not #{description}" unless lifecycle.include?(contract)
end

unless harness.include?('seed "${temporary_directory}" "${content_lifecycle_state}"')
  abort 'Kind harness does not seed the virt-who lifecycle'
end
unless harness.include?('assert "${temporary_directory}" "${content_lifecycle_state}"')
  abort 'Kind harness does not verify the restored virt-who lifecycle'
end
unless harness.include?('cleanup "${temporary_directory}" "${content_lifecycle_state}"')
  abort 'partial Kind runs do not clean up the virt-who configuration'
end

plugin = matrix.fetch('foreman').find do |entry|
  entry.fetch('name') == 'foreman_virt_who_configure'
end
abort 'foreman_virt_who_configure matrix entry is missing' unless plugin
unless plugin.fetch('status') == 'integration-drill-implemented-unrun'
  abort 'foreman_virt_who_configure matrix overstates or understates the prepared drill'
end
unless plugin.fetch('placement') == 'application-plus-external-service'
  abort 'foreman_virt_who_configure lost its external-service placement boundary'
end
unless checks.include?('virt-who-configuration-script-lifecycle')
  abort 'promotion evidence does not require the virt-who configuration lifecycle'
end
unless checks.include?('virt-who-configuration-clean-recovery')
  abort 'promotion evidence does not require virt-who configuration recovery'
end

puts 'Virt-who integration covers configuration, script generation, report state, identity cleanup, and recovery.'
