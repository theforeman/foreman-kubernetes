#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

deployments = YAML.load_stream(File.read(ARGV.fetch(0))).compact.select do |resource|
  resource['kind'] == 'Deployment'
end

recreate = %w[candlepin dynflow-orchestrator].freeze
zero_downtime = %w[foreman pulp-api pulp-content pulp-control-proxy].freeze
bounded_worker_loss = %w[dynflow-worker dynflow-worker-hosts-queue pulp-worker].freeze
expected = recreate + zero_downtime + bounded_worker_loss
seen = []

deployments.each do |deployment|
  component = deployment.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component')
  next unless expected.include?(component)

  deadline = deployment.dig('spec', 'progressDeadlineSeconds').to_i
  abort "#{component} has no bounded progress deadline" unless deadline.positive?
  strategy = deployment.dig('spec', 'strategy') || {}
  if recreate.include?(component)
    abort "#{component} must use Recreate" unless strategy['type'] == 'Recreate'
  else
    abort "#{component} must use RollingUpdate" unless strategy['type'] == 'RollingUpdate'
    abort "#{component} must limit rollout surge to one Pod" unless strategy.dig('rollingUpdate', 'maxSurge').to_i == 1

    unavailable = strategy.dig('rollingUpdate', 'maxUnavailable').to_i
    expected_unavailable = zero_downtime.include?(component) ? 0 : 1
    abort "#{component} expected maxUnavailable #{expected_unavailable}, got #{unavailable}" unless unavailable == expected_unavailable
  end
  seen << component
end

missing = expected - seen
abort "rollout strategy contract did not cover: #{missing.join(', ')}" unless missing.empty?

puts 'All application Deployments have explicit availability and surge limits.'
