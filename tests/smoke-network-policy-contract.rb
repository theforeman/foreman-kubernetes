# frozen_string_literal: true

require 'yaml'

manifest, expected_foreman_port = ARGV
abort "usage: #{$PROGRAM_NAME} MANIFEST FOREMAN_PORT" unless manifest && expected_foreman_port

documents = YAML.load_stream(File.read(manifest)).compact
policies = documents.select { |resource| resource['kind'] == 'NetworkPolicy' }

foreman_service = documents.find do |resource|
  resource['kind'] == 'Service' && resource.dig('metadata', 'name').to_s.end_with?('-foreman')
end
abort 'Foreman Service is missing' unless foreman_service

service_ports = Array(foreman_service.dig('spec', 'ports')).map { |entry| entry['port'] }
unless service_ports == [expected_foreman_port.to_i]
  abort "Foreman Service has ports #{service_ports.inspect}, expected #{expected_foreman_port}"
end

foreman_policy = policies.find do |policy|
  policy.dig('metadata', 'name').to_s.end_with?('-foreman')
end
abort 'Foreman ingress NetworkPolicy is missing' unless foreman_policy

foreman_ports = Array(foreman_policy.dig('spec', 'ingress')).flat_map do |rule|
  Array(rule['ports']).map { |entry| entry['port'] }
end
unless foreman_ports == ['http']
  abort "Foreman ingress NetworkPolicy has ports #{foreman_ports.inspect}, expected the named pod port http"
end

smoke_policy = policies.find do |policy|
  policy.dig('metadata', 'name').to_s.end_with?('-smoke-test-egress')
end

if smoke_policy
  selector = smoke_policy.dig('spec', 'podSelector', 'matchLabels') || {}
  abort 'smoke egress policy does not select the smoke test' unless selector['app.kubernetes.io/component'] == 'smoke-test'

  permitted = Array(smoke_policy.dig('spec', 'egress')).each_with_object({}) do |rule, result|
    peer = Array(rule['to']).find { |candidate| candidate.key?('podSelector') }
    component = peer&.dig('podSelector', 'matchLabels', 'app.kubernetes.io/component')
    next unless component

    result[component] = Array(rule['ports']).map { |entry| entry['port'] }
  end

  expected = {
    'foreman' => ['http'],
    'candlepin' => Array(documents.find do |resource|
      resource['kind'] == 'Service' && resource.dig('spec', 'selector', 'app.kubernetes.io/component') == 'candlepin'
    end&.dig('spec', 'ports')).map { |entry| entry['port'] },
    'pulp-api' => Array(documents.find do |resource|
      resource['kind'] == 'Service' && resource.dig('spec', 'selector', 'app.kubernetes.io/component') == 'pulp-api'
    end&.dig('spec', 'ports')).map { |entry| entry['port'] },
    'pulp-control-proxy' => Array(documents.find do |resource|
      resource['kind'] == 'Deployment' &&
        resource.dig('spec', 'selector', 'matchLabels', 'app.kubernetes.io/component') == 'pulp-control-proxy'
    end&.dig('spec', 'template', 'spec', 'containers', 0, 'ports')).map { |entry| entry['containerPort'] },
  }
  abort "smoke egress destinations are #{permitted.inspect}, expected #{expected.inspect}" unless permitted == expected

  unbounded = Array(smoke_policy.dig('spec', 'egress')).any? do |rule|
    Array(rule['to']).any? { |peer| peer.nil? || peer.empty? }
  end
  abort 'smoke egress contains an unrestricted destination' if unbounded
end

puts "Smoke-test network contract passed for Foreman port #{expected_foreman_port}."
