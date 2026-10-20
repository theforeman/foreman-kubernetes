#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployments = documents.select { |resource| resource['kind'] == 'Deployment' }

pulp = deployments.find do |resource|
  resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-api'
end
abort 'Pulp API Deployment is missing' unless pulp
pulp_container = Array(pulp.dig('spec', 'template', 'spec', 'containers')).find do |container|
  container['name'] == 'pulp-api'
end
pulp_command = Array(pulp_container&.dig('readinessProbe', 'exec', 'command'))
unless pulp_command == ['python3', '/opt/foreman-kubernetes/pulp-readiness.py']
  abort "Pulp API readiness does not parse status: #{pulp_command.inspect}"
end
pulp_mount = Array(pulp_container['volumeMounts']).find do |mount|
  mount['mountPath'] == '/opt/foreman-kubernetes/pulp-readiness.py'
end
abort 'Pulp readiness validator is not mounted read-only' unless pulp_mount&.fetch('readOnly', false)

candlepin = deployments.find do |resource|
  resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'candlepin'
end
abort 'Candlepin Deployment is missing' unless candlepin
candlepin_container = Array(candlepin.dig('spec', 'template', 'spec', 'containers')).find do |container|
  container['name'] == 'candlepin'
end
candlepin_command = Array(candlepin_container&.dig('readinessProbe', 'exec', 'command')).join("\n")
abort 'Candlepin readiness does not verify TLS' unless candlepin_command.include?('-verify_return_error')
abort 'Candlepin readiness does not require normal mode' unless candlepin_command.include?('"NORMAL"')
abort 'Candlepin readiness does not inspect HTTP status' unless candlepin_command.include?('HTTP/1')

puts 'Pulp and Candlepin readiness parse backend health payloads.'
