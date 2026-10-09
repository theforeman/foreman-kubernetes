#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

resources = YAML.load_stream(File.read(ARGV.fetch(0))).compact

config = resources.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name')&.end_with?('-foreman-config')
end
abort 'Foreman ConfigMap is missing' unless config

database_config = config.dig('data', 'database.yml').to_s
abort 'database.yml does not use DATABASE_URL' unless database_config.include?("ENV.fetch('DATABASE_URL')")
abort 'database.yml does not enforce FOREMAN_DATABASE_POOL' unless database_config.include?("ENV.fetch('FOREMAN_DATABASE_POOL')")

pod_template_for = lambda do |resource|
  case resource['kind']
  when 'Deployment', 'Job'
    resource.dig('spec', 'template')
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template')
  end
end

expected = {
  'foreman' => 5,
  'dynflow-orchestrator' => 5,
  'dynflow-worker' => 10,
  'dynflow-worker-hosts-queue' => 5,
  'foreman-cron' => 5,
  'foreman-migrate' => 5,
  'pulp-registration' => 5,
}.freeze

seen = Hash.new(0)
resources.each do |resource|
  template = pod_template_for.call(resource)
  next unless template

  component = template.dig('metadata', 'labels', 'app.kubernetes.io/component')
  next unless expected.key?(component)

  containers = Array(template.dig('spec', 'initContainers')) + Array(template.dig('spec', 'containers'))
  containers.each do |container|
    next unless Array(container['env']).any? { |entry| entry['name'] == 'DATABASE_URL' }

    pool = Array(container['env']).find { |entry| entry['name'] == 'FOREMAN_DATABASE_POOL' }
    abort "#{resource.dig('metadata', 'name')} has no FOREMAN_DATABASE_POOL" unless pool
    expected_pool = container['name'] == 'wait-for-foreman-migrations' ? 5 : expected.fetch(component)
    abort "#{resource.dig('metadata', 'name')}/#{container['name']} expected pool #{expected_pool}, got #{pool['value']}" unless pool['value'].to_i == expected_pool

    mount = Array(container['volumeMounts']).find do |entry|
      entry['mountPath'] == '/usr/share/foreman/config/database.yml' && entry['subPath'] == 'database.yml'
    end
    abort "#{resource.dig('metadata', 'name')} does not mount generated database.yml" unless mount

    seen[component] += 1 unless container['name'] == 'wait-for-foreman-migrations'
  end
end

missing = expected.keys.reject { |component| seen[component].positive? }
abort "database-pool contract did not cover: #{missing.join(', ')}" unless missing.empty?

puts "Foreman database pools are explicit for #{seen.values.sum} process templates."
