#!/usr/bin/env ruby

require 'yaml'

manifest, remote_repository = ARGV
abort "usage: #{$PROGRAM_NAME} MANIFEST REMOTE_REPOSITORY" unless manifest && remote_repository

documents = YAML.load_stream(File.read(manifest)).compact
policy = documents.find do |resource|
  resource['kind'] == 'NetworkPolicy' &&
    resource.dig('metadata', 'name').to_s.end_with?('-recovery-egress')
end
abort 'recovery egress NetworkPolicy is missing' unless policy

component_selector = Array(policy.dig('spec', 'podSelector', 'matchExpressions')).find do |expression|
  expression['key'] == 'app.kubernetes.io/component'
end
expected_components = %w[recovery-backup recovery-restore]
unless Array(component_selector&.fetch('values', nil)).sort == expected_components.sort
  abort 'recovery egress policy does not select backup and restore Jobs'
end

rules = Array(policy.dig('spec', 'egress'))
destinations = rules.flat_map do |rule|
  Array(rule['to']).map { |peer| peer.dig('ipBlock', 'cidr') }.compact
end
ports = rules.map do |rule|
  cidr = Array(rule['to']).map { |peer| peer.dig('ipBlock', 'cidr') }.compact.first
  [cidr, Array(rule['ports']).map { |port| port['port'] }.sort] if cidr
end.compact.to_h

abort 'recovery cannot reach PostgreSQL' unless ports['192.0.2.10/32'] == [5432]
abort 'recovery cannot reach the Kubernetes API' unless ports['192.0.2.20/32'] == [6443]

if remote_repository == 'true'
  abort 'recovery cannot reach its remote Restic repository' unless ports['192.0.2.21/32'] == [22, 443]
else
  abort 'PVC-backed recovery unexpectedly permits the remote repository' if destinations.include?('192.0.2.21/32')
end

if rules.any? { |rule| Array(rule['to']).any?(&:empty?) }
  abort 'recovery egress contains an unrestricted destination'
end

puts "Recovery egress contract passed for remote repository=#{remote_repository}."
