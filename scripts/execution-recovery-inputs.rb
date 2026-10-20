#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/manifest_requirements').to_s

documents = YAML.load_stream($stdin.read).compact
deployment = documents.find do |document|
  document['kind'] == 'Deployment' &&
    document.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'execution-proxy'
end
abort 'rendered execution proxy Deployment is missing' unless deployment

volumes = Array(deployment.dig('spec', 'template', 'spec', 'volumes')).to_h do |volume|
  [volume['name'], volume]
end
state_claim = volumes.dig('state', 'persistentVolumeClaim', 'claimName').to_s
ansible_claim = volumes.dig('ansible-content', 'persistentVolumeClaim', 'claimName').to_s
abort 'rendered execution proxy state claim is missing' if state_claim.empty?
abort 'rendered execution proxy Ansible content claim is missing' if ansible_claim.empty?
abort 'execution proxy state and Ansible content must use distinct claims' if state_claim == ansible_claim

secret_names = ForemanRelease::ManifestRequirements.new(documents).secrets.keys
abort 'rendered execution proxy has no external Secret references' if secret_names.empty?

pod_spec = deployment.dig('spec', 'template', 'spec')
scheduling = {
  priorityClassName: pod_spec.fetch('priorityClassName', '').to_s,
  nodeSelector: pod_spec.fetch('nodeSelector', {}),
  tolerations: Array(pod_spec['tolerations']),
}

puts JSON.generate(
  stateClaim: state_claim,
  ansibleClaim: ansible_claim,
  secretNames: secret_names.sort,
  scheduling: scheduling
)
