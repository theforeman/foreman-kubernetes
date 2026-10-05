#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort 'usage: compute-provider-egress-contract.rb MANIFEST' unless ARGV.length == 1

resources = YAML.load_stream(File.read(ARGV.fetch(0))).compact
policy = resources.find do |resource|
  resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'name')&.end_with?('-foreman-egress')
end
abort 'Foreman egress policy is missing' unless policy

rule = policy.dig('spec', 'egress').find do |entry|
  entry.fetch('to', []).any? { |peer| peer.dig('ipBlock', 'cidr') == '192.0.2.50/32' }
end
abort 'Compute-provider destination CIDR is missing' unless rule

ports = rule.fetch('ports').map { |port| port.fetch('port') }
abort "Compute-provider egress ports are #{ports.inspect}, expected [443, 6443]" unless ports == [443, 6443]

puts 'Compute-provider egress is limited to the declared destination and ports.'
