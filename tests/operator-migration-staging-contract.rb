#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} MIGRATION_RENDER APPLICATION_RENDER" unless ARGV.length == 2

migration_documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
application_documents = YAML.load_stream(File.read(ARGV.fetch(1))).compact
migration_components = %w[candlepin-migrate pulp-migrate foreman-migrate]
migration_jobs = migration_documents.select do |item|
  item['kind'] == 'Job' && migration_components.include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
abort 'migration render does not contain exactly three migration Jobs' unless migration_jobs.length == 3

application_migrations = application_documents.select do |item|
  item['kind'] == 'Job' && migration_components.include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
abort 'application-stage render retained migration Jobs' unless application_migrations.empty?
abort 'application-stage render omitted Deployments' unless application_documents.any? { |item| item['kind'] == 'Deployment' }

config_map_names = migration_jobs.flat_map do |job|
  Array(job.dig('spec', 'template', 'spec', 'volumes')).map { |volume| volume.dig('configMap', 'name') }.compact
end.uniq
abort 'migration Jobs have no rendered configuration dependencies' if config_map_names.empty?

migration_config_maps = migration_documents.select do |item|
  item['kind'] == 'ConfigMap' && config_map_names.include?(item.dig('metadata', 'name'))
end
unless migration_config_maps.map { |item| item.dig('metadata', 'name') }.sort == config_map_names.sort
  abort 'a migration ConfigMap dependency is not part of the Helm release'
end

# The controller replaces desired migration ConfigMaps before starting Jobs.
# Every running workload must use subPath so an existing Pod retains the old
# inode until the post-migration rollout replaces it.
migration_documents.select { |item| item['kind'] == 'Deployment' }.each do |deployment|
  volumes = Array(deployment.dig('spec', 'template', 'spec', 'volumes')).to_h do |volume|
    [volume.fetch('name'), volume.dig('configMap', 'name')]
  end
  Array(deployment.dig('spec', 'template', 'spec', 'containers')).each do |container|
    Array(container['volumeMounts']).each do |mount|
      next unless config_map_names.include?(volumes[mount.fetch('name')])

      if mount['subPath'].to_s.empty?
        abort "#{deployment.dig('metadata', 'name')} sees migration ConfigMap updates before rollout"
      end
    end
  end
end

puts 'Controller stages migration Jobs and immutable running-Pod configuration before application rollout.'
