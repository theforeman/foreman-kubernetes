#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} OPERATOR_RENDER MANAGED_RENDER..." unless ARGV.length >= 2

operator_documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
managed_documents = ARGV.drop(1).flat_map { |path| YAML.load_stream(File.read(path)).compact }
role = operator_documents.find { |item| item['kind'] == 'Role' }
abort 'operator Role is missing' unless role

resource_names = {
  ['', 'ConfigMap'] => 'configmaps',
  ['', 'PersistentVolumeClaim'] => 'persistentvolumeclaims',
  ['', 'Secret'] => 'secrets',
  ['', 'Service'] => 'services',
  ['', 'ServiceAccount'] => 'serviceaccounts',
  ['apps', 'Deployment'] => 'deployments',
  ['autoscaling', 'HorizontalPodAutoscaler'] => 'horizontalpodautoscalers',
  ['batch', 'CronJob'] => 'cronjobs',
  ['batch', 'Job'] => 'jobs',
  ['networking.k8s.io', 'Ingress'] => 'ingresses',
  ['networking.k8s.io', 'NetworkPolicy'] => 'networkpolicies',
  ['monitoring.coreos.com', 'PrometheusRule'] => 'prometheusrules',
  ['policy', 'PodDisruptionBudget'] => 'poddisruptionbudgets'
}.freeze

def api_group(document)
  version = document.fetch('apiVersion')
  version.include?('/') ? version.split('/', 2).first : ''
end

def rule_for(role, group, resource)
  Array(role['rules']).find do |rule|
    Array(rule['apiGroups']).include?(group) && Array(rule['resources']).include?(resource)
  end
end

required_verbs = %w[get list create update patch delete]
managed_documents.map { |document| [api_group(document), document.fetch('kind')] }.uniq.each do |identity|
  resource = resource_names[identity]
  abort "RBAC coverage does not classify #{identity.join('/')}" unless resource

  rule = rule_for(role, identity.first, resource)
  abort "operator Role cannot manage #{identity.join('/')}" unless rule
  missing = required_verbs - Array(rule['verbs'])
  abort "operator Role cannot #{missing.join(', ')} #{resource}" unless missing.empty?
end

special = {
  ['', 'secrets'] => required_verbs,
  ['', 'pods'] => %w[get list],
  ['coordination.k8s.io', 'leases'] => %w[get list create update patch],
  ['events.k8s.io', 'events'] => %w[create],
  ['platform.theforeman.org', 'foremanreleases'] => %w[get list watch patch update],
  ['platform.theforeman.org', 'foremanreleases/status'] => %w[get patch update]
}
special.each do |(group, resource), verbs|
  rule = rule_for(role, group, resource)
  abort "operator Role is missing special access to #{resource}" unless rule
  missing = verbs - Array(rule['verbs'])
  abort "operator Role cannot #{missing.join(', ')} #{resource}" unless missing.empty?
end

puts "Operator RBAC covers #{managed_documents.map { |item| item['kind'] }.uniq.length} managed kinds and all control resources."
