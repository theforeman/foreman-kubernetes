#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

source = File.read(File.expand_path('kind/run.sh', __dir__))
checks = JSON.parse(File.read(File.expand_path('../compatibility/required-integration-checks.json', __dir__))).fetch('checks')

required = [
  'scripts/render-dependency-preflight-stage.rb',
  'scripts/render-migration-stage.rb',
  'wait_for_operation_jobs',
  'wait_for_migration_jobs',
  "Migration ',app.kubernetes.io/component!=dependency-preflight'",
  '.type == "Failed" and .status == "True"',
  '--set releaseOperation.skipMigrationJobs=true',
  'assert_pods_unchanged',
  'assert_application_workloads_unchanged',
  'restore_candlepin_database_password',
  'candlepin_java_xms=544m',
  '.info.status == "deployed" and .version == $revision'
]
required.each do |contract|
  abort "kind release drill is missing #{contract}" unless source.include?(contract)
end

normal_path = source.match(/operation_id="kind-.*?^}/m)&.to_s
abort 'cannot identify the normal kind release path' unless normal_path
dependency_stage = normal_path.index('scripts/render-dependency-preflight-stage.rb')
dependency_wait = normal_path.index('Dependency preflight')
stage = normal_path.index('scripts/render-migration-stage.rb')
wait = normal_path.index('wait_for_migration_jobs')
rollout = normal_path.index('helm upgrade --install', stage)
unless dependency_stage && dependency_wait && stage && wait && rollout &&
  dependency_stage < dependency_wait && dependency_wait < stage && stage < wait && wait < rollout
  abort 'kind release drill does not finish dependency preflight and migrations before submitting workloads'
end

foreman_failure = source.index("wrong_database_url=\"")
candlepin_failure = source.index("wrong_database_password=\"")
roll_forward = source.index('helm_apply --set foreman.dynflow.workerConcurrency=4')
unless foreman_failure && candlepin_failure && roll_forward &&
  foreman_failure < candlepin_failure && candlepin_failure < roll_forward
  abort 'kind release drill does not gate one roll-forward on both migration failures'
end

%w[candlepin-failed-migration-roll-forward candlepin-recreate-upgrade].each do |check|
  abort "integration evidence does not require #{check}" unless checks.include?(check)
end

puts 'Kind release drill preserves old Pods until dependency preflight and staged migrations succeed.'
