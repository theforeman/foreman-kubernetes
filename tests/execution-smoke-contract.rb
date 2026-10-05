#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
job = documents.find do |resource|
  resource['kind'] == 'Job' && resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'smoke-test'
end
abort 'execution proxy smoke-test Job is missing' unless job

annotations = job.dig('metadata', 'annotations') || {}
abort 'execution smoke test is not exposed through helm test' unless annotations['helm.sh/hook'] == 'test'

pod = job.dig('spec', 'template', 'spec')
container = Array(pod['containers']).first
script = Array(container['args']).join("\n")
environment = Array(container['env']).to_h { |entry| [entry['name'], entry['value']] }
abort 'execution smoke test does not call the proxy Service DNS name' unless environment['PROXY_FEATURES_URL'] ==
                                                                            'https://execution-foreman-execution-proxy:8443/features'
abort 'execution smoke test does not verify TLS peers' unless script.include?('OpenSSL::SSL::VERIFY_PEER')
abort 'execution smoke test disables hostname verification' if script.include?('verify_hostname = false')
abort 'execution smoke test does not enforce the feature boundary' unless script.include?('expected = %w[ansible dynflow script]')

certificates = Array(pod['volumes']).find { |volume| volume['name'] == 'certificates' }
sources = Array(certificates&.dig('projected', 'sources'))
secrets = sources.each_with_object({}) do |source, result|
  secret = source['secret']
  result[secret['name']] = Array(secret['items']) if secret
end
foreman_keys = Array(secrets['foreman-certificates']).map { |item| item['key'] }
proxy_keys = Array(secrets['foreman-execution-proxy-tls']).map { |item| item['key'] }
abort 'execution smoke test lacks the Foreman client identity' unless foreman_keys.sort == %w[client_cert.pem client_key.pem]
abort 'execution smoke test lacks the Smart Proxy CA' unless proxy_keys == ['ca.crt']

policies = documents.select { |resource| resource['kind'] == 'NetworkPolicy' }
ingress = policies.find { |policy| policy.dig('metadata', 'name') == 'execution-foreman-execution-proxy' }
smoke_peer = Array(ingress&.dig('spec', 'ingress')).flat_map { |rule| Array(rule['from']) }.any? do |peer|
  peer.dig('podSelector', 'matchLabels', 'app.kubernetes.io/instance') == 'execution' &&
    peer.dig('podSelector', 'matchLabels', 'app.kubernetes.io/component') == 'smoke-test'
end
abort 'proxy ingress does not permit its bounded smoke Job' unless smoke_peer
registration_peer = Array(ingress&.dig('spec', 'ingress')).flat_map { |rule| Array(rule['from']) }.any? do |peer|
  expressions = Array(peer.dig('podSelector', 'matchExpressions'))
  expressions.any? do |expression|
    expression['key'] == 'app.kubernetes.io/component' &&
      Array(expression['values']).include?('execution-proxy-registration')
  end
end
abort 'proxy ingress does not permit the bounded Foreman registration Job' unless registration_peer

egress = policies.find { |policy| policy.dig('metadata', 'name') == 'execution-foreman-execution-proxy-smoke-test-egress' }
abort 'execution smoke Job has no bounded egress policy' unless egress
ports = Array(egress.dig('spec', 'egress')).flat_map { |rule| Array(rule['ports']) }.map { |port| port['port'] }
abort 'execution smoke egress lacks DNS or proxy HTTPS' unless [53, 8443].all? { |port| ports.include?(port) }

puts 'Execution smoke test validates mTLS and the exact Smart Proxy feature boundary.'
