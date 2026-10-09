#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECTED" unless ARGV.length == 2

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
cron_jobs = documents.select { |resource| resource['kind'] == 'CronJob' }
abort 'expected four recurring Foreman CronJobs' unless cron_jobs.length == 4

expected = ARGV.fetch(1) == 'true'
cron_jobs.each do |cron_job|
  abort 'recurring task time zone is implicit' unless cron_job.dig('spec', 'timeZone') == 'Etc/UTC'
  abort 'recurring task missed-run deadline is absent' unless cron_job.dig('spec', 'startingDeadlineSeconds') == 1800
  unless cron_job.dig('spec', 'jobTemplate', 'spec', 'activeDeadlineSeconds') == 21_600
    abort 'recurring task has no bounded runtime'
  end
  init_names = Array(cron_job.dig('spec', 'jobTemplate', 'spec', 'template', 'spec', 'initContainers'))
    .map { |container| container['name'] }
  present = init_names.include?('wait-for-foreman-migrations')
  abort "unexpected migration barrier state for #{cron_job.dig('metadata', 'name')}" unless present == expected
end

puts "Recurring task schedule and migration barrier enabled=#{expected} are bounded."
