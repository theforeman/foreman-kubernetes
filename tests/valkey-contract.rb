#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

manifest_path, tls_enabled = ARGV
abort 'usage: valkey-contract.rb MANIFEST TLS_ENABLED' unless tls_enabled

resources = YAML.load_stream(File.read(manifest_path)).compact
expect_tls = tls_enabled == 'true'
scheme = expect_tls ? 'rediss://' : 'redis://'

def pod_spec(resource)
  case resource['kind']
  when 'Deployment', 'Job'
    resource.dig('spec', 'template', 'spec')
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

def env_entries(container)
  Array(container['env']).to_h { |entry| [entry['name'], entry] }
end

def has_mount?(container, path)
  Array(container['volumeMounts']).any? do |mount|
    mount['name'] == 'valkey-ca' && mount['mountPath'] == path
  end
end

pod_specs = resources.map { |resource| pod_spec(resource) }.compact
containers = pod_specs.flat_map { |spec| Array(spec['initContainers']) + Array(spec['containers']) }

foreman = containers.select { |container| env_entries(container).key?('DYNFLOW_REDIS_URL') }
abort 'no Foreman Valkey consumers found' if foreman.empty?

foreman.each do |container|
  env = env_entries(container)
  cache_url = env.fetch('FOREMAN_RAILS_CACHE_STORE_URLS').fetch('value')
  dynflow_url = env.fetch('DYNFLOW_REDIS_URL').fetch('value')
  abort "#{container['name']} has the wrong cache scheme" unless cache_url.start_with?(scheme)
  abort "#{container['name']} has the wrong Dynflow scheme" unless dynflow_url.start_with?(scheme)
  abort "#{container['name']} does not use cache URI credentials" unless cache_url.include?('$(VALKEY_FOREMAN_CACHE_URI_AUTH)')
  abort "#{container['name']} does not use Dynflow URI credentials" unless dynflow_url.include?('$(VALKEY_DYNFLOW_URI_AUTH)')

  %w[VALKEY_FOREMAN_CACHE_URI_AUTH VALKEY_DYNFLOW_URI_AUTH].each do |name|
    reference = env.dig(name, 'valueFrom', 'secretKeyRef')
    abort "#{container['name']} does not load #{name} from a Secret" unless reference
  end

  if expect_tls
    abort "#{container['name']} does not configure Dynflow TLS CA" unless \
      env.dig('DYNFLOW_REDIS_SSL_CA_FILE', 'value') == '/etc/foreman/certs/valkey-ca.crt'
    abort "#{container['name']} has no Valkey CA mount" unless has_mount?(container, '/etc/foreman/certs/valkey-ca.crt')
  else
    abort "#{container['name']} unexpectedly configures Dynflow TLS CA" if env.key?('DYNFLOW_REDIS_SSL_CA_FILE')
    abort "#{container['name']} unexpectedly mounts a Valkey CA" if has_mount?(container, '/etc/foreman/certs/valkey-ca.crt')
  end
end

pulp = containers.select { |container| env_entries(container).key?('PULP_REDIS_HOST') }
abort 'no Pulp Valkey consumers found' if pulp.empty?

pulp.each do |container|
  env = env_entries(container)
  %w[PULP_REDIS_HOST PULP_REDIS_PORT PULP_REDIS_DB].each do |name|
    abort "#{container['name']} does not configure #{name}" unless env.dig(name, 'value')
  end
  abort "#{container['name']} does not load the Pulp password from a Secret" unless env.dig('PULP_REDIS_PASSWORD', 'valueFrom', 'secretKeyRef')
  abort "#{container['name']} unexpectedly uses REDIS_URL, which bypasses Pulpcore's CA setting" if env.key?('PULP_REDIS_URL')
  abort "#{container['name']} has the wrong Pulp Redis SSL flag" unless env.dig('PULP_REDIS_SSL', 'value') == expect_tls.to_s

  if expect_tls
    abort "#{container['name']} has no Pulp Valkey CA setting" unless env.dig('PULP_REDIS_SSL_CA_CERTS', 'value') == '/etc/pulp/certs/valkey-ca.crt'
    abort "#{container['name']} has no Pulp Valkey CA mount" unless has_mount?(container, '/etc/pulp/certs/valkey-ca.crt')
  else
    abort "#{container['name']} unexpectedly configures a Pulp Valkey CA" if env.key?('PULP_REDIS_SSL_CA_CERTS')
  end
end

ca_volumes = pod_specs.flat_map { |spec| Array(spec['volumes']) }.select { |volume| volume['name'] == 'valkey-ca' }
if expect_tls
  abort 'no Valkey CA volumes found' if ca_volumes.empty?
  ca_volumes.each do |volume|
    item = Array(volume.dig('secret', 'items')).find { |candidate| candidate['key'] == 'ca.crt' }
    abort 'Valkey CA volume does not require ca.crt' unless item
  end
else
  abort 'Valkey CA volumes rendered while TLS is disabled' unless ca_volumes.empty?
end

config = resources.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name')&.end_with?('-foreman-config')
end
abort 'Foreman runtime ConfigMap not found' unless config

settings = config.dig('data', 'settings.yaml').to_s
if expect_tls
  abort 'Rails cache does not receive Valkey ssl_params' unless settings.include?(':ssl_params:')
else
  abort 'plaintext profile unexpectedly configures Rails cache ssl_params' if settings.include?(':ssl_params:')
end
abort 'chart still injects Dynflow Redis TLS code' if config.dig('data').key?('foreman-kubernetes-valkey-tls.rb')

puts "Valkey contract checks passed for TLS enabled=#{expect_tls}."
