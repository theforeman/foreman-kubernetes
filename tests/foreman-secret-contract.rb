#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

manifest_path, secret_name, database_key, encryption_key, secret_key_base, seed_user_key, seed_password_key = ARGV
abort 'usage: foreman-secret-contract.rb MANIFEST SECRET DATABASE_KEY ENCRYPTION_KEY SECRET_KEY_BASE SEED_USER_KEY SEED_PASSWORD_KEY' unless seed_password_key

def pod_spec(document)
  case document['kind']
  when 'Pod'
    document['spec']
  when 'Deployment', 'DaemonSet', 'ReplicaSet', 'StatefulSet', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

def secret_reference(environment)
  reference = environment.dig('valueFrom', 'secretKeyRef')
  [reference && reference['name'], reference && reference['key']]
end

rails_containers = 0
seed_containers = []

YAML.load_stream(File.read(manifest_path)).compact.each do |document|
  next unless document.is_a?(Hash)

  spec = pod_spec(document)
  next unless spec.is_a?(Hash)

  component = document.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component') ||
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component')

  %w[initContainers containers].each do |container_type|
    Array(spec[container_type]).each do |container|
      environment = Array(container['env'])
      next unless environment.any? { |entry| entry['name'] == 'RAILS_ENV' }

      rails_containers += 1
      env_by_name = environment.to_h { |entry| [entry['name'], entry] }
      expected_runtime = {
        'DATABASE_URL' => database_key,
        'ENCRYPTION_KEY' => encryption_key,
        'SECRET_KEY_BASE' => secret_key_base
      }
      expected_runtime.each do |name, key|
        actual = secret_reference(env_by_name.fetch(name, {}))
        abort "#{component}/#{container['name']} has invalid #{name} reference: #{actual.inspect}" unless actual == [secret_name, key]
      end

      Array(container['envFrom']).each do |source|
        abort "#{component}/#{container['name']} imports the complete Foreman runtime Secret" if source.dig('secretRef', 'name') == secret_name
      end

      seed_names = %w[SEED_ADMIN_USER SEED_ADMIN_PASSWORD]
      next unless seed_names.any? { |name| env_by_name.key?(name) }

      seed_containers << [component, container['name']]
      expected_seed = {
        'SEED_ADMIN_USER' => seed_user_key,
        'SEED_ADMIN_PASSWORD' => seed_password_key
      }
      expected_seed.each do |name, key|
        actual = secret_reference(env_by_name.fetch(name, {}))
        abort "#{component}/#{container['name']} has invalid #{name} reference: #{actual.inspect}" unless actual == [secret_name, key]
      end
    end
  end
end

abort 'no Foreman Rails containers were found' if rails_containers.zero?
abort "seed credentials must be limited to the migration container: #{seed_containers.inspect}" unless seed_containers == [['foreman-migrate', 'migrate']]

puts "Foreman runtime keys are explicit in #{rails_containers} Rails containers; seed keys are migration-only."
