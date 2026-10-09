#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
migration = documents.find do |resource|
  resource['kind'] == 'Job' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-migrate'
end
abort 'Pulp migration Job is missing' unless migration

containers = migration.dig('spec', 'template', 'spec', 'containers') || []
command = containers.find { |container| container['name'] == 'migrate' }&.fetch('command', [])
script = command.last.to_s
abort 'Pulp migration Job does not migrate the database first' unless \
  script.index('pulpcore-manager migrate --noinput') == 0
abort 'Pulp migration Job does not create the remote-authentication identity' unless \
  script.include?('pulpcore-manager reset-admin-password --random')
abort 'Pulp migration Job exposes a reusable administrator password' if \
  script.match?(/reset-admin-password\s+(?!--random)/)

puts 'Pulp migrations create the passwordless remote administrator identity.'
