#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman'
end
abort 'Foreman Deployment is missing' unless deployment

container = Array(deployment.dig('spec', 'template', 'spec', 'containers')).find do |candidate|
  candidate['name'] == 'foreman'
end
abort 'Foreman container is missing' unless container

readiness = Array(container.dig('readinessProbe', 'exec', 'command'))
unless readiness == ['ruby', '/opt/foreman-kubernetes/foreman-readiness.rb']
  abort "Foreman readiness does not execute the status validator: #{readiness.inspect}"
end

readiness_host = Array(container['env']).find { |entry| entry['name'] == 'FOREMAN_READINESS_HOST' }
unless readiness_host&.fetch('value', nil) == 'foreman.example.test'
  abort "Foreman readiness does not use the externally allowed hostname: #{readiness_host.inspect}"
end

mount = Array(container['volumeMounts']).find do |candidate|
  candidate['mountPath'] == '/opt/foreman-kubernetes/foreman-readiness.rb'
end
abort 'Foreman readiness validator is not mounted' unless mount&.fetch('readOnly', false)

config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-config')
end
validator = config&.dig('data', 'foreman-readiness.rb').to_s
abort 'Foreman readiness validator does not check the database' unless validator.include?("database == true")
abort 'Foreman readiness validator does not check the cache' unless validator.include?("server['status'] == 'ok'")
abort 'Foreman readiness validator does not check Katello' unless validator.include?("katello_status == 'ok'")
abort 'Foreman readiness request does not set an allowed Host header' unless
  validator.include?("request['Host'] = ENV.fetch('FOREMAN_READINESS_HOST')")
abort 'Foreman readiness request does not preserve the public HTTPS scheme' unless
  validator.include?("request['X-Forwarded-Proto'] = 'https'")

puts 'Foreman readiness uses an allowed Host and parses database, cache, and Katello dependency health.'
