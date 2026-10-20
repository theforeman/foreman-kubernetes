#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} STAGED_MANIFEST OPERATION_ID RELEASE NAMESPACE" unless ARGV.length == 4

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
operation_id, release_name, namespace = ARGV.drop(1)
components = %w[candlepin-migrate pulp-migrate foreman-migrate]
jobs = documents.select { |item| item['kind'] == 'Job' }
abort 'manual migration stage must contain exactly three Jobs' unless jobs.length == 3
unless jobs.map { |job| job.dig('metadata', 'labels', 'app.kubernetes.io/component') }.sort == components.sort
  abort 'manual migration stage contains the wrong Jobs'
end
jobs.each do |job|
  abort 'manual migration Job has the wrong operation ID' unless job.dig('metadata', 'labels', 'platform.theforeman.org/release-operation') == operation_id
  abort 'manual migration Job is still a Helm hook' if job.fetch('metadata').fetch('annotations', {}).keys.any? { |key| key.start_with?('helm.sh/hook') }
  abort 'manual migration Job has no bounded post-completion lifetime' unless job.dig('spec', 'ttlSecondsAfterFinished') == 3600
end

allowed = %w[ConfigMap Job PersistentVolumeClaim ServiceAccount]
unexpected = documents.map { |item| item['kind'] }.uniq - allowed
abort "manual migration stage leaked workload kinds: #{unexpected.join(', ')}" unless unexpected.empty?

dependencies = documents.reject { |item| item['kind'] == 'Job' }
dependencies.each do |dependency|
  metadata = dependency.fetch('metadata')
  abort 'migration dependency is not prepared for Helm adoption' unless metadata.dig('labels', 'app.kubernetes.io/managed-by') == 'Helm'
  abort 'migration dependency has the wrong Helm release' unless metadata.dig('annotations', 'meta.helm.sh/release-name') == release_name
  abort 'migration dependency has the wrong Helm namespace' unless metadata.dig('annotations', 'meta.helm.sh/release-namespace') == namespace
end

puts 'Manual release path stages only adoptable dependencies and three bounded migration Jobs.'
