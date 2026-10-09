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

pod_spec = deployment.dig('spec', 'template', 'spec')
container = Array(pod_spec['containers']).find { |candidate| candidate['name'] == 'foreman' }
abort 'Foreman web container is missing' unless container

startup = Array(container['args']).join("\n")
unless container['command'] == ['/bin/sh', '-ec'] &&
       startup.include?('exec /usr/share/foreman/bin/rails server --environment production --pid /tmp/rails.pid')
  abort 'Foreman startup wrapper does not replace itself with Rails as PID 1'
end

unless pod_spec['terminationGracePeriodSeconds'] == 150
  abort 'Foreman has insufficient time to drain active web requests'
end

pre_stop = Array(container.dig('lifecycle', 'preStop', 'exec', 'command'))
unless pre_stop == ['/usr/bin/sleep', '10']
  abort 'Foreman does not drain Service endpoints before Puma shutdown'
end

puts 'Foreman web lifecycle sends signals directly to Puma and drains requests.'
