#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} STAGED_MANIFEST OPERATION_ID RELEASE NAMESPACE" unless ARGV.length == 4

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
operation_id, release_name, namespace = ARGV.drop(1)
jobs = documents.select { |item| item['kind'] == 'Job' }
abort 'manual dependency preflight stage must contain exactly one Job' unless jobs.length == 1

job = jobs.first
abort 'manual stage contains the wrong Job' unless job.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'dependency-preflight'
abort 'manual preflight Job has the wrong operation ID' unless job.dig('metadata', 'labels', 'platform.theforeman.org/release-operation') == operation_id
abort 'manual preflight Job is still a Helm hook' if job.fetch('metadata').fetch('annotations', {}).keys.any? { |key| key.start_with?('helm.sh/hook') }
abort 'manual preflight Job has no bounded post-completion lifetime' unless job.dig('spec', 'ttlSecondsAfterFinished') == 3600

allowed = %w[Job ServiceAccount]
unexpected = documents.map { |item| item['kind'] }.uniq - allowed
abort "manual dependency preflight leaked workload kinds: #{unexpected.join(', ')}" unless unexpected.empty?

documents.reject { |item| item['kind'] == 'Job' }.each do |dependency|
  metadata = dependency.fetch('metadata')
  abort 'preflight dependency is not prepared for Helm adoption' unless metadata.dig('labels', 'app.kubernetes.io/managed-by') == 'Helm'
  abort 'preflight dependency has the wrong Helm release' unless metadata.dig('annotations', 'meta.helm.sh/release-name') == release_name
  abort 'preflight dependency has the wrong Helm namespace' unless metadata.dig('annotations', 'meta.helm.sh/release-namespace') == namespace
end

puts 'Manual release path stages one bounded dependency preflight Job before migrations.'
