#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

manifest, expected_mode = ARGV
abort "usage: #{$PROGRAM_NAME} MANIFEST EXPECTED_MODE" unless expected_mode

expected_components = %w[
  foreman
  candlepin
  dynflow-orchestrator
  dynflow-worker
  dynflow-worker-hosts-queue
  pulp-api
  pulp-content
  pulp-control-proxy
  pulp-worker
].freeze
expected_keys = %w[topology.kubernetes.io/zone kubernetes.io/hostname].freeze
seen = []

YAML.load_stream(File.read(manifest)).compact.each do |resource|
  next unless resource['kind'] == 'Deployment'

  component = resource.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component')
  next unless expected_components.include?(component)

  constraints = Array(resource.dig('spec', 'template', 'spec', 'topologySpreadConstraints'))
  actual_keys = constraints.map { |constraint| constraint['topologyKey'] }
  abort "#{component} has incomplete failure-domain spread: #{actual_keys.inspect}" unless actual_keys == expected_keys

  constraints.each do |constraint|
    abort "#{component} has an invalid maxSkew" unless constraint['maxSkew'] == 1
    abort "#{component} uses the wrong scheduling mode" unless constraint['whenUnsatisfiable'] == expected_mode
    selector = constraint.dig('labelSelector', 'matchLabels')
    abort "#{component} spread selector can mix components" unless selector&.fetch('app.kubernetes.io/component', nil) == component
  end
  seen << component
end

missing = expected_components - seen
abort "topology spread contract did not cover: #{missing.join(', ')}" unless missing.empty?

puts "All application Deployments spread across zone and node failure domains using #{expected_mode}."
