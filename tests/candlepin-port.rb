#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECTED_PORT" unless ARGV.length == 2

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
expected_port = Integer(ARGV.fetch(1), 10)

component = lambda do |resource|
  resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'candlepin'
end

service = documents.find { |resource| resource['kind'] == 'Service' && component.call(resource) }
deployment = documents.find { |resource| resource['kind'] == 'Deployment' && component.call(resource) }
config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-candlepin-config')
end

abort 'rendered Candlepin Service is missing' unless service
abort 'rendered Candlepin Deployment is missing' unless deployment
abort 'rendered Candlepin ConfigMap is missing' unless config

service_port = Array(service.dig('spec', 'ports')).find { |port| port['name'] == 'https' }
container = Array(deployment.dig('spec', 'template', 'spec', 'containers')).find do |candidate|
  candidate['name'] == 'candlepin'
end
container_port = Array(container&.fetch('ports', nil)).find { |port| port['name'] == 'https' }
server_xml = config.dig('data', 'server.xml').to_s

abort "Candlepin Service does not expose #{expected_port}" unless service_port&.fetch('port', nil) == expected_port
abort "Candlepin container does not declare #{expected_port}" unless container_port&.fetch('containerPort', nil) == expected_port
abort "Candlepin Tomcat does not listen on #{expected_port}" unless server_xml.include?(%(Connector port="#{expected_port}"))

puts "Candlepin Service, container, and Tomcat agree on port #{expected_port}."
