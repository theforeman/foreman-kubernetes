#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find { |item| item['kind'] == 'Deployment' }
policy = documents.find do |item|
  item['kind'] == 'NetworkPolicy' && Array(item.dig('spec', 'policyTypes')).include?('Egress')
end
abort 'operator egress NetworkPolicy is missing' unless policy
unless policy.dig('spec', 'podSelector', 'matchLabels') == deployment.dig('spec', 'selector', 'matchLabels')
  abort 'operator egress policy does not select the controller Pods'
end
abort 'operator egress policy unexpectedly filters ingress' unless policy.dig('spec', 'policyTypes') == ['Egress']

rules = Array(policy.dig('spec', 'egress'))
abort 'operator egress policy must contain only DNS and API rules' unless rules.length == 2
ports_by_cidr = rules.each_with_object({}) do |rule, result|
  cidr = Array(rule['to']).map { |peer| peer.dig('ipBlock', 'cidr') }.compact.first
  result[cidr] = Array(rule['ports']).map { |port| [port['protocol'], port['port']] } if cidr
end
unless ports_by_cidr['192.0.2.20/32'] == [['TCP', 443]]
  abort 'operator egress policy does not restrict the Kubernetes API destination and port'
end
if rules.any? { |rule| Array(rule['to']).any? { |peer| peer.nil? || peer.empty? } }
  abort 'operator egress policy contains an unrestricted destination'
end

puts 'Release operator egress is restricted to DNS and the declared Kubernetes API endpoint.'
