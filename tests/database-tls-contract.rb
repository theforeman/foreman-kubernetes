#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

manifest_path, expected_mode, ca_enabled = ARGV
abort 'usage: database-tls-contract.rb MANIFEST MODE CA_ENABLED' unless ca_enabled

resources = YAML.load_stream(File.read(manifest_path)).compact
expect_ca = ca_enabled == 'true'

def pod_spec(resource)
  case resource['kind']
  when 'Deployment', 'Job'
    resource.dig('spec', 'template', 'spec')
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

def environment(container)
  Array(container['env']).to_h { |entry| [entry['name'], entry['value']] }
end

def mount?(container, name, path)
  Array(container['volumeMounts']).any? do |mount|
    mount['name'] == name && mount['mountPath'] == path
  end
end

pod_specs = resources.map { |resource| pod_spec(resource) }.compact
containers = pod_specs.flat_map { |spec| Array(spec['initContainers']) + Array(spec['containers']) }

foreman_consumers = containers.select do |container|
  names = Array(container['env']).map { |entry| entry['name'] }
  names.include?('DATABASE_URL') || names.include?('FOREMAN_DATABASE_URL')
end
abort 'no Foreman database consumers found' if foreman_consumers.empty?

foreman_consumers.each do |container|
  env = environment(container)
  abort "#{container['name']} has the wrong PGSSLMODE" unless env['PGSSLMODE'] == expected_mode
  if expect_ca
    abort "#{container['name']} has no Foreman sslrootcert" unless env['PGSSLROOTCERT']&.end_with?('/foreman/db-ca.crt') || env['PGSSLROOTCERT'] == '/etc/foreman/certs/db-ca.crt'
    abort "#{container['name']} has no Foreman database CA mount" unless mount?(container, 'foreman-database-ca', env['PGSSLROOTCERT']) || mount?(container, 'foreman-database-ca', '/etc/recovery/database-ca/foreman')
  else
    abort "#{container['name']} unexpectedly has a Foreman sslrootcert" if env.key?('PGSSLROOTCERT')
  end
end

pulp_consumers = containers.select do |container|
  names = Array(container['env']).map { |entry| entry['name'] }
  names.include?('PULP_DATABASES__default__HOST') || names.include?('PULP_DATABASE_HOST')
end
abort 'no Pulp database consumers found' if pulp_consumers.empty?

pulp_consumers.each do |container|
  env = environment(container)
  mode = env['PULP_DATABASES__default__OPTIONS__sslmode'] || env['PULP_DATABASE_SSLMODE']
  root = env['PULP_DATABASES__default__OPTIONS__sslrootcert'] || env['PULP_DATABASE_SSLROOTCERT']
  abort "#{container['name']} has the wrong Pulp sslmode" unless mode == expected_mode
  if expect_ca
    abort "#{container['name']} has no Pulp sslrootcert" unless root&.end_with?('/pulp/db-ca.crt') || root == '/etc/pulp/certs/db-ca.crt'
    abort "#{container['name']} has no Pulp database CA mount" unless mount?(container, 'pulp-database-ca', root) || mount?(container, 'pulp-database-ca', '/etc/recovery/database-ca/pulp')
  else
    abort "#{container['name']} unexpectedly has a Pulp sslrootcert" if root
  end
end

candlepin_consumers = containers.select do |container|
  names = Array(container['env']).map { |entry| entry['name'] }
  names.include?('CANDLEPIN_DATABASE_URL') ||
    names.include?('CANDLEPIN_DATABASE_SSLMODE') ||
    names.include?('JPA_CONFIG_HIBERNATE_CONNECTION_PASSWORD')
end
abort 'no Candlepin database consumers found' if candlepin_consumers.empty?

candlepin_consumers.each do |container|
  env = environment(container)
  url = env['CANDLEPIN_DATABASE_URL']
  mode = env['CANDLEPIN_DATABASE_SSLMODE']
  abort "#{container['name']} has the wrong Candlepin sslmode" if mode && mode != expected_mode
  abort "#{container['name']} has the wrong Candlepin JDBC sslmode" if url && !url.include?("sslmode=#{expected_mode}")
  if expect_ca
    root = env['CANDLEPIN_DATABASE_SSLROOTCERT']
    abort "#{container['name']} has no Candlepin JDBC sslrootcert" if url && !url.include?('sslrootcert=/etc/candlepin/certs/db-ca.crt')
    expected_path = root || '/etc/candlepin/certs/db-ca.crt'
    abort "#{container['name']} has no Candlepin database CA mount" unless mount?(container, 'candlepin-database-ca', expected_path) || mount?(container, 'candlepin-database-ca', '/etc/recovery/database-ca/candlepin')
  else
    abort "#{container['name']} unexpectedly has a Candlepin sslrootcert" if url&.include?('sslrootcert=') || env.key?('CANDLEPIN_DATABASE_SSLROOTCERT')
  end
end

ca_volumes = pod_specs.flat_map { |spec| Array(spec['volumes']) }.select do |volume|
  volume['name']&.end_with?('-database-ca')
end

if expect_ca
  expected_secrets = %w[foreman-database-ca candlepin-database-ca pulp-database-ca]
  actual_secrets = ca_volumes.map { |volume| volume.dig('secret', 'secretName') }.compact.uniq
  missing = expected_secrets - actual_secrets
  abort "missing database CA Secrets: #{missing.join(', ')}" unless missing.empty?

  ca_volumes.each do |volume|
    keys = Array(volume.dig('secret', 'items')).map { |item| item['key'] }
    abort "#{volume['name']} does not require db-ca.crt" unless keys.include?('db-ca.crt')
  end
else
  abort 'database CA volumes rendered while TLS verification is disabled' unless ca_volumes.empty?
end

puts "Database TLS contract checks passed for #{expected_mode}."
