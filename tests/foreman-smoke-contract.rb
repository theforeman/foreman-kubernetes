#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
job = documents.find do |resource|
  resource['kind'] == 'Job' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'smoke-test'
end
abort 'Foreman smoke-test Job is missing' unless job

container = Array(job.dig('spec', 'template', 'spec', 'containers')).find do |candidate|
  candidate['name'] == 'smoke-test'
end
abort 'Foreman smoke-test container is missing' unless container

environment = Array(container['env']).to_h { |entry| [entry['name'], entry['value']] }
unless environment['FOREMAN_REQUEST_HOST'] == 'foreman.example.test'
  abort "Foreman smoke test does not use the externally allowed hostname: #{environment.inspect}"
end

script = Array(container['args']).join("\n")
unless script.include?("'Host' => ENV.fetch('FOREMAN_REQUEST_HOST')")
  abort 'Foreman smoke request does not set an allowed Host header'
end
unless script.include?("'X-Forwarded-Proto' => 'https'")
  abort 'Foreman smoke request does not preserve the public HTTPS scheme'
end
unless script.include?("if name == 'Foreman'")
  abort 'Foreman-only proxy headers are not scoped to the Rails health request'
end

puts 'Foreman smoke test preserves the allowed public host and scheme.'
