#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
crd = documents.find { |item| item['kind'] == 'CustomResourceDefinition' }
abort 'operator chart did not install the ForemanRelease CRD' unless crd&.dig('metadata', 'name') == 'foremanreleases.platform.theforeman.org'
deployment = documents.find { |item| item['kind'] == 'Deployment' }
abort 'operator Deployment is missing' unless deployment
abort 'operator does not publish a warm standby' unless deployment.dig('spec', 'replicas') == 2
abort 'operator cannot roll between elected leaders' unless deployment.dig('spec', 'strategy', 'type') == 'RollingUpdate'
abort 'operator rollout can remove every candidate' unless deployment.dig('spec', 'strategy', 'rollingUpdate', 'maxUnavailable') == 1
abort 'operator requires its Kubernetes API token' unless deployment.dig('spec', 'template', 'spec', 'automountServiceAccountToken') == true
environment = Array(deployment.dig('spec', 'template', 'spec', 'containers', 0, 'env'))
pod_uid = environment.find { |entry| entry['name'] == 'POD_UID' }
abort 'operator leader identity is not sourced from the Pod UID' unless pod_uid&.dig('valueFrom', 'fieldRef', 'fieldPath') == 'metadata.uid'
abort 'operator has no leader Lease name' unless environment.any? { |entry| entry['name'] == 'LEADER_LEASE_NAME' }
abort 'operator has no leader Lease duration' unless environment.any? { |entry| entry['name'] == 'LEADER_LEASE_DURATION_SECONDS' }
command_timeout = environment.find { |entry| entry['name'] == 'COMMAND_TIMEOUT_SECONDS' }
command_grace = environment.find { |entry| entry['name'] == 'COMMAND_TERMINATION_GRACE_SECONDS' }
certificate_validity = environment.find { |entry| entry['name'] == 'CERTIFICATE_MINIMUM_VALIDITY_SECONDS' }
release_lease = environment.find { |entry| entry['name'] == 'RELEASE_LEASE_DURATION_SECONDS' }
abort 'operator commands have no execution deadline' unless command_timeout&.fetch('value') == '60'
abort 'operator commands have no termination grace period' unless command_grace&.fetch('value') == '5'
abort 'operator certificates have no minimum remaining validity' unless certificate_validity&.fetch('value') == '86400'
abort 'operation Lease does not outlive bounded commands' unless release_lease&.fetch('value') == '300'
health_port = environment.find { |entry| entry['name'] == 'HEALTH_PORT' }
readiness_staleness = environment.find { |entry| entry['name'] == 'READINESS_MAX_STALENESS_SECONDS' }
abort 'operator health port is not explicit' unless health_port&.fetch('value') == '9393'
abort 'operator readiness staleness is not explicit' unless readiness_staleness&.fetch('value') == '180'
container = deployment.dig('spec', 'template', 'spec', 'containers', 0)
abort 'operator liveness does not use /livez' unless container.dig('livenessProbe', 'httpGet', 'path') == '/livez'
abort 'operator readiness does not use /readyz' unless container.dig('readinessProbe', 'httpGet', 'path') == '/readyz'

service = documents.find { |item| item['kind'] == 'Service' }
abort 'operator metrics Service is missing' unless service
metrics_port = Array(service.dig('spec', 'ports')).find { |port| port['name'] == 'metrics' }
abort 'operator metrics Service does not target health port' unless metrics_port&.fetch('targetPort') == 'health'

ingress_policy = documents.find do |item|
  item['kind'] == 'NetworkPolicy' && Array(item.dig('spec', 'policyTypes')).include?('Ingress')
end
abort 'operator metrics port has no ingress isolation' unless ingress_policy
unless ingress_policy.dig('spec', 'podSelector', 'matchLabels') == deployment.dig('spec', 'selector', 'matchLabels')
  abort 'operator ingress policy does not select the controller Pods'
end
abort 'operator metrics are admitted without an explicit peer' if ingress_policy.fetch('spec').key?('ingress')

pdb = documents.find { |item| item['kind'] == 'PodDisruptionBudget' }
abort 'operator PodDisruptionBudget is missing' unless pdb
abort 'operator disruption budget can evict every candidate' unless pdb.dig('spec', 'maxUnavailable') == 1

role = documents.find { |item| item['kind'] == 'Role' }
abort 'operator namespaced Role is missing' unless role
release_rule = Array(role['rules']).find do |rule|
  Array(rule['apiGroups']).include?('platform.theforeman.org') && Array(rule['resources']).include?('foremanreleases')
end
abort 'operator cannot manage the release protection finalizer' unless %w[patch update].all? do |verb|
  Array(release_rule&.fetch('verbs', [])).include?(verb)
end
resources = Array(role['rules']).flat_map { |rule| Array(rule['resources']) }
%w[foremanreleases foremanreleases/status leases events jobs deployments secrets].each do |required|
  abort "operator Role is missing #{required}" unless resources.include?(required)
end
%w[nodes namespaces persistentvolumes].each do |forbidden|
  abort "operator Role unexpectedly grants #{forbidden}" if resources.include?(forbidden)
end
edge_resources = %w[dhcp dns tftp smartproxies]
abort 'operator Role grants an edge Smart Proxy capability' unless (resources & edge_resources).empty?

cluster_role = documents.find { |item| item['kind'] == 'ClusterRole' }
abort 'operator cluster preflight role is missing' unless cluster_role
cluster_rules = Array(cluster_role['rules'])
cluster_resources = cluster_rules.flat_map { |rule| Array(rule['resources']) }.sort
expected_cluster_resources = %w[apiservices customresourcedefinitions ingressclasses nodes priorityclasses storageclasses]
abort "unexpected cluster-scoped resources: #{cluster_resources.join(', ')}" unless cluster_resources == expected_cluster_resources
cluster_verbs = cluster_rules.flat_map { |rule| Array(rule['verbs']) }.uniq.sort
abort 'cluster preflight permissions are not read-only' unless cluster_verbs == %w[get list]

puts 'Release operator elects one leader with bounded namespace and read-only cluster RBAC.'
