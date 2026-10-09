#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} DEFAULT_MANIFEST S3_MANIFEST" unless ARGV.length == 2

def resources(path)
  YAML.load_stream(File.read(path)).compact
end

def component_jobs(documents, component)
  documents.select do |resource|
    resource['kind'] == 'Job' &&
      resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
  end
end

default = resources(ARGV.fetch(0))
s3 = resources(ARGV.fetch(1))
preflights = component_jobs(default, 'dependency-preflight')
abort 'chart must render exactly one dependency preflight Job' unless preflights.length == 1

job = preflights.first
annotations = job.dig('metadata', 'annotations') || {}
abort 'dependency preflight must be controlled by a release operation, not Helm hooks' if annotations.keys.any? { |key| key.start_with?('helm.sh/hook') }
abort 'dependency preflight has no release-operation label' if job.dig('metadata', 'labels', 'platform.theforeman.org/release-operation').to_s.empty?

pod_spec = job.dig('spec', 'template', 'spec')
containers = Array(pod_spec['containers']).to_h { |container| [container.fetch('name'), container] }
abort 'dependency preflight must isolate Foreman, Pulp, and Candlepin checks' unless containers.keys.sort == %w[candlepin foreman pulp]
abort 'dependency preflight does not use the Pulp service account for workload identity' unless pod_spec['serviceAccountName']&.end_with?('-pulp')
abort 'dependency preflight unexpectedly mounts a Kubernetes API token' unless pod_spec['automountServiceAccountToken'] == false

foreman_script = Array(containers.fetch('foreman')['command']).join("\n")
abort 'Foreman dependency preflight must use the packaged Ruby runtime directly' unless foreman_script.include?("ruby <<'RUBY'") && !foreman_script.include?('bundle exec')
abort 'Foreman dependency preflight does not execute a read-only database query' unless foreman_script.include?("exec('SELECT 1')")
abort 'Foreman dependency preflight does not authenticate both Valkey clients' unless foreman_script.include?('FOREMAN_RAILS_CACHE_STORE_URLS') && foreman_script.include?('DYNFLOW_REDIS_URL') && foreman_script.include?('.ping')
abort 'Foreman dependency preflight contains a schema mutation' if foreman_script.match?(/db:migrate|db:seed|\bINSERT\b|\bUPDATE\b|\bDELETE\b/)

pulp_script = Array(containers.fetch('pulp')['command']).join("\n")
abort 'Pulp dependency preflight does not execute a read-only database query' unless pulp_script.include?('cursor.execute("SELECT 1")')
abort 'Pulp dependency preflight does not authenticate Valkey' unless pulp_script.include?('redis.Redis(**cache_options).ping()')
abort 'Pulp dependency preflight contains a schema mutation' if pulp_script.match?(/pulpcore-manager migrate|\bINSERT\b|\bUPDATE\b|\bDELETE\b/)

candlepin = containers.fetch('candlepin')
candlepin_args = Array(candlepin['args'])
abort 'Candlepin dependency preflight must use Liquibase status' unless candlepin_args.include?('status') && candlepin_args.include?('--verbose')
abort 'Candlepin dependency preflight unexpectedly mutates its schema' if candlepin_args.include?('update')
abort 'Candlepin dependency preflight does not load its password from a Secret' unless Array(candlepin['env']).any? { |entry| entry['name'] == 'LIQUIBASE_COMMAND_PASSWORD' && entry.dig('valueFrom', 'secretKeyRef') }

migrations = component_jobs(default, 'candlepin-migrate') +
  component_jobs(default, 'pulp-migrate') + component_jobs(default, 'foreman-migrate')
abort 'chart must retain all three migration Jobs' unless migrations.length == 3
migrations.each do |migration|
  migration_annotations = migration.dig('metadata', 'annotations') || {}
  abort 'migrations must be controlled by the release operation, not Helm hooks' if migration_annotations.keys.any? { |key| key.start_with?('helm.sh/hook') }
end

s3_job = component_jobs(s3, 'dependency-preflight')
abort 'S3 profile must render exactly one dependency preflight Job' unless s3_job.length == 1
s3_pod = s3_job.first.dig('spec', 'template', 'spec')
s3_pulp = Array(s3_pod['containers']).find { |container| container['name'] == 'pulp' }
s3_script = Array(s3_pulp['command']).join("\n")
abort 'S3 dependency preflight does not perform an authenticated read/list request' unless s3_script.include?('client.list_objects_v2(')
abort 'S3 dependency preflight does not cap its listing' unless s3_script.include?('MaxKeys=1')

puts 'Dependency preflight is read-only, authenticated, and owned by the guarded release operation.'
