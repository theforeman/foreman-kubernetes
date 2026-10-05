#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployments = documents.select do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component').to_s.start_with?('dynflow-')
end
abort "expected three Dynflow Deployments, got #{deployments.length}" unless deployments.length == 3

deployments.each do |deployment|
  component = deployment.dig('metadata', 'labels', 'app.kubernetes.io/component')
  expected_strategy = component == 'dynflow-orchestrator' ? 'Recreate' : 'RollingUpdate'
  actual_strategy = deployment.dig('spec', 'strategy', 'type')
  unless actual_strategy == expected_strategy
    abort "#{component} has unexpected rollout strategy #{actual_strategy.inspect}"
  end

  pod_spec = deployment.dig('spec', 'template', 'spec')
  abort "#{component} has the wrong shutdown grace" unless pod_spec['terminationGracePeriodSeconds'] == 330
  container = Array(pod_spec['containers']).find { |candidate| candidate['name'] == 'dynflow' }
  abort "#{component} container is missing" unless container
  args = Array(container['args'])
  timeout_index = args.index('-t')
  abort "#{component} lacks the Sidekiq shutdown timeout" unless timeout_index && args[timeout_index + 1] == '300'

  env = Array(container['env']).to_h { |entry| [entry['name'], entry['value']] }
  abort "#{component} must use the upstream lifecycle hooks" if env.key?('RUBYOPT')
  marker = env['DYNFLOW_READINESS_FILE']
  abort "#{component} has no readiness marker" if marker.to_s.empty?

  %w[startupProbe readinessProbe].each do |probe|
    command = Array(container.dig(probe, 'exec', 'command')).join(' ')
    abort "#{component} #{probe} ignores lifecycle readiness" unless command.include?('DYNFLOW_READINESS_FILE')
  end
end

puts 'Dynflow rollouts wait for initialization and allow graceful Sidekiq shutdown.'
