#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

root = File.expand_path('..', __dir__)
resources = YAML.load_stream(File.read(File.join(root, 'examples/kubevirt-rbac.yaml'))).compact

def resource!(resources, kind, name)
  resources.find do |resource|
    resource['kind'] == kind && resource.dig('metadata', 'name') == name
  end || abort("#{kind}/#{name} is missing from KubeVirt RBAC")
end

role = resource!(resources, 'Role', 'foreman-kubevirt')
cluster_role = resource!(resources, 'ClusterRole', 'foreman-kubevirt-discovery')
service_account = resource!(resources, 'ServiceAccount', 'foreman-kubevirt')
role_binding = resource!(resources, 'RoleBinding', 'foreman-kubevirt')
cluster_role_binding = resource!(resources, 'ClusterRoleBinding', 'foreman-kubevirt-discovery')

unless service_account.dig('metadata', 'namespace') == 'foreman-managed-vms' &&
       service_account['automountServiceAccountToken'] == false
  abort 'KubeVirt service account is not bound to the dedicated namespace without automatic token mounting'
end

[role, cluster_role].each do |rbac|
  rbac.fetch('rules').each do |rule|
    abort "#{rbac['kind']} contains a wildcard API group" if rule.fetch('apiGroups').include?('*')
    abort "#{rbac['kind']} contains a wildcard resource" if rule.fetch('resources').include?('*')
    abort "#{rbac['kind']} contains a wildcard verb" if rule.fetch('verbs').include?('*')
    abort "#{rbac['kind']} grants node access" if rule.fetch('resources').include?('nodes')
  end
end

role_resources = role.fetch('rules').to_h do |rule|
  [
    [rule.fetch('apiGroups').first, rule.fetch('resources').first],
    rule.fetch('verbs').sort
  ]
end
expected_role_resources = {
  ['kubevirt.io', 'virtualmachines'] => %w[create delete get list patch update watch].sort,
  ['kubevirt.io', 'virtualmachineinstances'] => %w[get list watch].sort,
  ['subresources.kubevirt.io', 'virtualmachineinstances/vnc'] => %w[get],
  ['', 'persistentvolumeclaims'] => %w[create delete get list watch].sort,
  ['', 'secrets'] => %w[create delete get list patch update].sort,
  ['k8s.cni.cncf.io', 'network-attachment-definitions'] => %w[get list watch].sort
}
abort 'KubeVirt namespaced RBAC differs from the reviewed client operations' unless role_resources == expected_role_resources

namespace_rule = cluster_role.fetch('rules').find { |rule| rule.fetch('resources') == ['namespaces'] }
unless namespace_rule&.fetch('resourceNames') == ['foreman-managed-vms'] && namespace_rule.fetch('verbs') == ['get']
  abort 'KubeVirt namespace discovery is broader than the managed namespace'
end
storage_rule = cluster_role.fetch('rules').find { |rule| rule.fetch('resources') == ['storageclasses'] }
unless storage_rule&.fetch('verbs')&.sort == %w[get list]
  abort 'KubeVirt StorageClass discovery permissions changed'
end

unless role_binding.dig('roleRef', 'kind') == 'Role' &&
       role_binding.dig('roleRef', 'name') == 'foreman-kubevirt' &&
       role_binding.fetch('subjects').one? { |subject| subject['name'] == 'foreman-kubevirt' }
  abort 'KubeVirt RoleBinding does not bind the dedicated service account'
end
unless cluster_role_binding.dig('roleRef', 'kind') == 'ClusterRole' &&
       cluster_role_binding.dig('roleRef', 'name') == 'foreman-kubevirt-discovery' &&
       cluster_role_binding.fetch('subjects').one? { |subject| subject['name'] == 'foreman-kubevirt' }
  abort 'KubeVirt ClusterRoleBinding does not bind the discovery role'
end

puts 'KubeVirt RBAC is namespace-scoped and contains no wildcard or node access.'
