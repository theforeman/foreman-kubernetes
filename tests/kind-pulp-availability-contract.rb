#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

root = File.expand_path('..', __dir__)
drill = File.read(File.join(root, 'tests/kind/pulp-availability.sh'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

required = {
  'scale the API and content independently' => ['api_deployment', 'content_deployment', '--replicas=2'],
  'probe the internal API Service' => ['STDOUT.sync = true', 'foreman-foreman-stack-pulp-api:24817', 'online_workers', 'online_content_apps'],
  'probe already published public content' => ['published_relative_path', 'foreman-kubernetes-content.txt', 'content_checksum'],
  'send concurrent API and content requests' => ['Thread.new', 'content_probe_worker "${worker}" "${relative_path}" &'],
  'replace an API and content Pod together' => ['api_pod_to_delete', 'content_pod_to_delete', 'delete pod'],
  'restore both declared replica counts' => ['api_deployment}" --replicas=1', 'content_deployment}" --replicas=1']
}
required.each do |description, contracts|
  missing = contracts.reject { |contract| drill.include?(contract) }
  abort "Pulp availability drill does not #{description}: #{missing.join(', ')}" unless missing.empty?
end

unless harness.include?('tests/kind/pulp-availability.sh')
  abort 'Kind harness does not execute the Pulp availability drill'
end
unless checks.include?('pulp-api-content-request-continuity')
  abort 'promotion evidence does not require Pulp request continuity'
end

puts 'Pulp integration requires API and content continuity through one Pod replacement each.'
