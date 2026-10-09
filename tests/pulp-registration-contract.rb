#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
job = documents.find do |resource|
  resource['kind'] == 'Job' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-registration'
end
abort 'Pulp Smart Proxy registration Job is missing' unless job

container = Array(job.dig('spec', 'template', 'spec', 'containers')).find do |candidate|
  candidate['name'] == 'register'
end
abort 'Pulp Smart Proxy registration container is missing' unless container

script = Array(container['command']).join("\n")
abort 'Pulp registration does not run as Foreman system administrator' unless
  script.include?('User.as_anonymous_admin do')
abort 'Pulp registration is not idempotent by both URL and name' unless
  script.include?('by_url || by_name || SmartProxy.new')
abort 'Pulp registration does not reject split name/URL ownership' unless
  script.include?('by_url.id != by_name.id')
abort 'Pulp registration does not require the Pulpcore feature' unless
  script.include?('proxy.has_feature?("Pulpcore")')

puts 'Pulp Smart Proxy registration is authorized, idempotent, and feature-gated.'
