#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

manifest, recovery_manifest = ARGV
abort "usage: #{$PROGRAM_NAME} MANIFEST RECOVERY_MANIFEST" unless manifest && recovery_manifest

documents = YAML.load_stream(File.read(manifest)).compact
recovery_documents = YAML.load_stream(File.read(recovery_manifest)).compact
proxy_variables = {
  'HTTP_PROXY' => 'http-proxy',
  'HTTPS_PROXY' => 'https-proxy',
  'NO_PROXY' => 'no-proxy',
  'http_proxy' => 'http-proxy',
  'https_proxy' => 'https-proxy',
  'no_proxy' => 'no-proxy'
}.freeze

def pod_spec(document)
  case document['kind']
  when 'Deployment', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

def containers(document)
  spec = pod_spec(document)
  return [] unless spec

  Array(spec['initContainers']) + Array(spec['containers'])
end

def assert_proxy_env(container, variables)
  env = Array(container['env']).to_h { |entry| [entry['name'], entry] }
  variables.each do |name, key|
    reference = env.dig(name, 'valueFrom', 'secretKeyRef')
    expected = {'name' => 'foreman-outbound-proxy', 'key' => key}
    abort "#{container['name']} has an invalid #{name} reference" unless reference == expected
  end
end

rails = []
pulp = []
documents.each do |document|
  containers(document).each do |container|
    names = Array(container['env']).map { |entry| entry['name'] }
    rails << container if names.include?('RAILS_ENV')
    pulp << container if names.include?('PULP_DATABASES__default__NAME')
  end
end
abort 'proxy contract did not cover any Foreman/Katello process' if rails.empty?
abort 'proxy contract did not cover any Pulp process' if pulp.empty?
(rails + pulp).each { |container| assert_proxy_env(container, proxy_variables) }

candlepin_documents = documents.select do |document|
  document.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component').to_s.start_with?('candlepin')
end
candlepin_documents.flat_map { |document| containers(document) }.each do |container|
  names = Array(container['env']).map { |entry| entry['name'] }
  leaked = names & proxy_variables.keys
  abort "#{container['name']} unexpectedly received HTTP proxy variables" unless leaked.empty?
end

%w[foreman-egress pulp-egress].each do |suffix|
  policy = documents.find do |resource|
    resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'name').to_s.end_with?("-#{suffix}")
  end
  proxy_rule = Array(policy&.dig('spec', 'egress')).find do |rule|
    Array(rule['to']).any? { |peer| peer.dig('ipBlock', 'cidr') == '192.0.2.30/32' }
  end
  ports = Array(proxy_rule&.fetch('ports', nil)).map { |port| port['port'] }
  abort "#{suffix} does not permit only the declared proxy port" unless ports == [3128]
end

recovery_job = recovery_documents.find { |resource| resource['kind'] == 'Job' }
recovery_container = recovery_job&.dig('spec', 'template', 'spec', 'containers', 0)
abort 'recovery Job is missing' unless recovery_container
assert_proxy_env(recovery_container, proxy_variables)

recovery_policy = recovery_documents.find do |resource|
  resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'name').to_s.end_with?('-recovery-egress')
end
proxy_rule = Array(recovery_policy&.dig('spec', 'egress')).find do |rule|
  Array(rule['to']).any? { |peer| peer.dig('ipBlock', 'cidr') == '192.0.2.30/32' }
end
unless Array(proxy_rule&.fetch('ports', nil)).map { |port| port['port'] } == [3128]
  abort 'recovery egress does not permit only the declared proxy port'
end

role = recovery_documents.find do |resource|
  resource['kind'] == 'Role' && resource.dig('metadata', 'name').to_s.end_with?('-recovery')
end
secret_rule = Array(role&.fetch('rules', nil)).find { |rule| Array(rule['resources']).include?('secrets') }
unless Array(secret_rule&.fetch('resourceNames', nil)).include?('foreman-outbound-proxy')
  abort 'recovery escrow cannot read the outbound proxy Secret'
end

backup_names = Array(recovery_container['env']).find { |entry| entry['name'] == 'BACKUP_SECRET_NAMES' }
unless backup_names&.fetch('value', '').split.include?('foreman-outbound-proxy')
  abort 'recovery escrow does not list the outbound proxy Secret'
end

puts "Outbound proxy reaches #{rails.length} Rails and #{pulp.length} Pulp containers through one declared endpoint."
