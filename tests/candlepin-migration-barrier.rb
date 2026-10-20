#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECT_BARRIER(true|false)" unless ARGV.length == 2

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'candlepin'
end
abort 'Candlepin Deployment is missing' unless deployment

barrier = Array(deployment.dig('spec', 'template', 'spec', 'initContainers')).find do |container|
  container['name'] == 'ensure-candlepin-migrations'
end
expected = ARGV.fetch(1) == 'true'
abort "Candlepin migration barrier expectation differs" unless !barrier.nil? == expected

if barrier
  command = Array(barrier['command'])
  unless command == ['/usr/local/bin/candlepin-db-migrate']
    abort "Candlepin barrier does not use the upstream migration entrypoint: #{command.inspect}"
  end

  env = Array(barrier['env']).to_h { |entry| [entry['name'], entry] }
  abort 'Candlepin barrier lacks LIQUIBASE_COMMAND_PASSWORD' unless env.key?('LIQUIBASE_COMMAND_PASSWORD')
  args = Array(barrier['args'])
  abort 'Candlepin barrier lacks the JDBC URL' unless args.any? { |arg| arg.start_with?('--url=jdbc:postgresql://') }
  abort 'Candlepin barrier lacks the database user' unless args.any? { |arg| arg.start_with?('--username=') }
end

puts "Candlepin migration init barrier enabled=#{expected}."
