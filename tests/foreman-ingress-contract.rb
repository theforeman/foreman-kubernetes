#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
foreman_ingress = documents.find do |resource|
  resource['kind'] == 'Ingress' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman-edge'
end
abort 'Foreman Ingress is missing' unless foreman_ingress

annotations = foreman_ingress.dig('metadata', 'annotations') || {}
abort 'Foreman Ingress does not require optional verified client certificates' unless \
  annotations['nginx.ingress.kubernetes.io/auth-tls-verify-client'] == 'optional'
abort 'Foreman Ingress does not pass client certificates upstream' unless \
  annotations['nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream'] == 'true'

header_reference = annotations['nginx.ingress.kubernetes.io/proxy-set-headers'].to_s
header_name = header_reference.split('/', 2).last
headers = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name') == header_name
end
abort 'Foreman trusted client-header ConfigMap is missing' unless headers

expected_headers = {
  'SSL-CLIENT-CERT' => '$ssl_client_escaped_cert',
  'SSL-CLIENT-S-DN' => '$ssl_client_s_dn',
  'SSL-CLIENT-VERIFY' => '$ssl_client_verify'
}
abort "unexpected Foreman client headers: #{headers['data'].inspect}" unless headers['data'] == expected_headers

config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman-config'
end
abort 'Foreman runtime ConfigMap is missing' unless config

settings = config.dig('data', 'settings.yaml').to_s
%w[
  :ssl_client_cert_env:\ HTTP_SSL_CLIENT_CERT
  :ssl_client_dn_env:\ HTTP_SSL_CLIENT_S_DN
  :ssl_client_verify_env:\ HTTP_SSL_CLIENT_VERIFY
].each do |setting|
  abort "Foreman client-certificate setting is missing: #{setting}" unless settings.include?(setting)
end

abort 'chart still injects client-certificate parsing code' if \
  config.dig('data').key?('foreman-kubernetes-client-certificate.rb')

foreman = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman'
end
mounts = Array(foreman&.dig('spec', 'template', 'spec', 'containers', 0, 'volumeMounts'))
abort 'chart still mounts client-certificate parsing code' if mounts.any? do |mount|
  mount['mountPath'].to_s.include?('foreman_kubernetes_client_certificate')
end

puts 'Foreman ingress client-certificate forwarding contract passed.'
