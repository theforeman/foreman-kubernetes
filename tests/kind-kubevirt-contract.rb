#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

root = File.expand_path('..', __dir__)
lifecycle = File.read(File.join(root, 'tests/kind/kubevirt-lifecycle.sh'))
run = File.read(File.join(root, 'tests/kind/run.sh'))
values = YAML.safe_load(File.read(File.join(root, 'tests/kind/values.yaml')))

contracts = {
  'read credentials from files' => 'KUBEVIRT_TOKEN_FILE',
  'read the cluster CA from a file' => 'KUBEVIRT_CA_FILE',
  'discover the preferred API version' => '/apis/kubevirt.io',
  'compare Foreman discovery with the cluster' => 'EXPECTED_KUBEVIRT_VERSION',
  'verify the configured storage class' => 'EXPECTED_STORAGE_CLASS',
  'create a stopped qualification VM' => 'start: false',
  'use the pod network without Multus' => 'cni_provider: "pod"',
  'hide provider credentials in API responses' => 'Foreman compute-resource API exposed KubeVirt credentials',
  'delete the external VM and PVC' => 'wait_for_external_deletion',
  'support clean-recovery assertions' => 'assert_lifecycle'
}
contracts.each do |description, contract|
  abort "KubeVirt lifecycle does not #{description}" unless lifecycle.include?(contract)
end

unless values.dig('foreman', 'enabledPlugins').include?('foreman_kubevirt')
  abort 'Kind profile does not enable foreman_kubevirt'
end

unless run.include?('KUBEVIRT_QUALIFY') && run.include?('kubevirt-lifecycle.sh')
  abort 'Kind harness does not expose the opt-in KubeVirt qualification'
end

puts 'KubeVirt qualification covers discovery, credentials, VM/PVC lifecycle, recovery, and cleanup.'
