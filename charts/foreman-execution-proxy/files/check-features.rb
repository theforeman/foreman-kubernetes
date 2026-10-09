# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

port = Integer(ENV.fetch('FOREMAN_PROXY_HTTPS_PORT', '8443'), 10)
uri = URI("https://127.0.0.1:#{port}/features")
http = Net::HTTP.new(uri.host, uri.port)
http.open_timeout = 2
http.read_timeout = 3
http.use_ssl = true

# This is a loopback-only readiness request. Verify the local server
# certificate against its configured CA, while skipping only the hostname
# check because the certificate is issued for the Service DNS name rather than
# 127.0.0.1.
http.ca_file = '/etc/foreman-proxy/ssl_ca.pem'
http.verify_mode = OpenSSL::SSL::VERIFY_PEER
http.verify_hostname = false
http.cert = OpenSSL::X509::Certificate.new(File.read('/etc/foreman-proxy/foreman_ssl_cert.pem'))
http.key = OpenSSL::PKey.read(File.read('/etc/foreman-proxy/foreman_ssl_key.pem'))

response = http.request(Net::HTTP::Get.new(uri))
abort "feature endpoint returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

features = JSON.parse(response.body).sort
expected = %w[ansible dynflow script]
abort "unexpected Smart Proxy features: #{features.inspect}" unless features == expected
