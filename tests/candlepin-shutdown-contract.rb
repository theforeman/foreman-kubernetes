#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'candlepin'
end
config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-candlepin-config')
end
abort 'Candlepin Deployment is missing' unless deployment
abort 'Candlepin ConfigMap is missing' unless config

pod_spec = deployment.dig('spec', 'template', 'spec')
container = Array(pod_spec['containers']).find { |candidate| candidate['name'] == 'candlepin' }
abort 'Candlepin container is missing' unless container
unless pod_spec['terminationGracePeriodSeconds'] == 1230
  abort 'Candlepin termination window does not cover both asynchronous job pools'
end
unless container.dig('lifecycle', 'preStop', 'exec', 'command') == ['/usr/bin/sleep', '10']
  abort 'Candlepin does not drain Service endpoints before Tomcat shutdown'
end
unless config.dig('data', 'candlepin.conf').to_s.include?('candlepin.async.thread.shutdown.timeout=600')
  abort 'Candlepin asynchronous job shutdown timeout is not explicit'
end

puts 'Candlepin Pod lifetime covers endpoint drain and asynchronous job shutdown.'
