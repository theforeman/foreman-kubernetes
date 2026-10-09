#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'open3'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/certificate_validator').to_s

NOW = Time.utc(2026, 9, 25, 12, 0, 0)

def issue_certificate(common_name:, key:, not_before:, not_after:, issuer_certificate: nil, issuer_key: nil, ca: false,
                      dns_names: [])
  certificate = OpenSSL::X509::Certificate.new
  certificate.version = 2
  certificate.serial = rand(1..1_000_000)
  certificate.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
  certificate.issuer = issuer_certificate ? issuer_certificate.subject : certificate.subject
  certificate.public_key = key.public_key
  certificate.not_before = not_before
  certificate.not_after = not_after

  extensions = OpenSSL::X509::ExtensionFactory.new
  extensions.subject_certificate = certificate
  extensions.issuer_certificate = issuer_certificate || certificate
  certificate.add_extension(extensions.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
  certificate.add_extension(
    extensions.create_extension('keyUsage', ca ? 'keyCertSign,cRLSign' : 'digitalSignature,keyEncipherment', true)
  )
  certificate.add_extension(extensions.create_extension('subjectKeyIdentifier', 'hash'))
  certificate.add_extension(extensions.create_extension('authorityKeyIdentifier', 'keyid:always'))
  unless dns_names.empty?
    certificate.add_extension(extensions.create_extension('subjectAltName', dns_names.map { |name| "DNS:#{name}" }.join(',')))
  end
  certificate.sign(issuer_key || key, OpenSSL::Digest::SHA256.new)
  certificate
end

def encoded_secret(data)
  {'data' => data.transform_values { |value| Base64.strict_encode64(value) }}
end

def expect_invalid(fragment)
  yield
  raise "expected certificate validation failure containing #{fragment.inspect}"
rescue ForemanRelease::InvalidRelease => error
  raise "unexpected certificate validation error: #{error.message}" unless error.message.include?(fragment)
end

ca_key = OpenSSL::PKey::RSA.new(2048)
ca_certificate = issue_certificate(
  common_name: 'platform CA',
  key: ca_key,
  not_before: NOW - 3600,
  not_after: NOW + (365 * 86_400),
  ca: true
)
leaf_key = OpenSSL::PKey::RSA.new(2048)
leaf_certificate = issue_certificate(
  common_name: 'foreman.example.test',
  key: leaf_key,
  not_before: NOW - 3600,
  not_after: NOW + (30 * 86_400),
  issuer_certificate: ca_certificate,
  issuer_key: ca_key
)
validator = ForemanRelease::CertificateValidator.new(clock: -> { NOW })
valid_secret = encoded_secret(
  'tls.crt' => leaf_certificate.to_pem,
  'tls.key' => leaf_key.to_pem,
  'ca.crt' => ca_certificate.to_pem,
  'password' => 'not a certificate'
)
required_keys = %w[tls.crt tls.key ca.crt password]
valid_expiry = validator.validate_secret!('platform', 'tls', valid_secret, required_keys)
raise 'valid certificate Secret returned the wrong earliest expiry' unless valid_expiry == leaf_certificate.not_after

ingress_certificate = issue_certificate(
  common_name: 'unused.example.test',
  key: leaf_key,
  not_before: NOW - 3600,
  not_after: NOW + (30 * 86_400),
  issuer_certificate: ca_certificate,
  issuer_key: ca_key,
  dns_names: %w[foreman.example.test *.content.example.test]
)
ingress_secret = encoded_secret(
  'tls.crt' => ingress_certificate.to_pem,
  'tls.key' => leaf_key.to_pem,
  'ca.crt' => ca_certificate.to_pem
)
validator.validate_secret!(
  'platform', 'ingress', ingress_secret, required_keys,
  required_identities: {'tls.crt' => %w[foreman.example.test rpm.content.example.test]}
)
expect_invalid('does not cover DNS name unrelated.example.test') do
  validator.validate_secret!(
    'platform', 'ingress', ingress_secret, required_keys,
    required_identities: {'tls.crt' => ['unrelated.example.test']}
  )
end
validator.validate_secret!(
  'platform', 'candlepin',
  encoded_secret('tomcat.crt' => ingress_certificate.to_pem, 'tomcat.key' => leaf_key.to_pem),
  %w[tomcat.crt tomcat.key],
  required_identities: {'tomcat.crt' => ['foreman.example.test']}
)

soon_certificate = issue_certificate(
  common_name: 'foreman.example.test',
  key: leaf_key,
  not_before: NOW - 3600,
  not_after: NOW + 3600,
  issuer_certificate: ca_certificate,
  issuer_key: ca_key
)
expect_invalid('before the 86400-second safety window') do
  validator.validate_secret!(
    'platform', 'tls',
    encoded_secret('tls.crt' => soon_certificate.to_pem, 'tls.key' => leaf_key.to_pem),
    %w[tls.crt tls.key]
  )
end

future_certificate = issue_certificate(
  common_name: 'future.example.test',
  key: leaf_key,
  not_before: NOW + 3600,
  not_after: NOW + (30 * 86_400),
  issuer_certificate: ca_certificate,
  issuer_key: ca_key
)
expect_invalid('is not valid before') do
  validator.validate_secret!(
    'platform', 'tls',
    encoded_secret('tls.crt' => future_certificate.to_pem, 'tls.key' => leaf_key.to_pem),
    %w[tls.crt tls.key]
  )
end

other_key = OpenSSL::PKey::RSA.new(2048)
expect_invalid('do not match') do
  validator.validate_secret!(
    'platform', 'tls',
    encoded_secret('tls.crt' => leaf_certificate.to_pem, 'tls.key' => other_key.to_pem),
    %w[tls.crt tls.key]
  )
end

other_ca_key = OpenSSL::PKey::RSA.new(2048)
other_ca_certificate = issue_certificate(
  common_name: 'other CA',
  key: other_ca_key,
  not_before: NOW - 3600,
  not_after: NOW + (365 * 86_400),
  ca: true
)
expect_invalid('is not trusted by ca.crt') do
  validator.validate_secret!(
    'platform', 'tls',
    encoded_secret(
      'tls.crt' => leaf_certificate.to_pem,
      'tls.key' => leaf_key.to_pem,
      'ca.crt' => other_ca_certificate.to_pem
    ),
    %w[tls.crt tls.key ca.crt]
  )
end

expired_ca_key = OpenSSL::PKey::RSA.new(2048)
expired_ca_certificate = issue_certificate(
  common_name: 'retired CA',
  key: expired_ca_key,
  not_before: NOW - (365 * 86_400),
  not_after: NOW - 3600,
  ca: true
)
rotating_ca_secret = encoded_secret('ca.crt' => expired_ca_certificate.to_pem + ca_certificate.to_pem)
rotating_expiry = validator.validate_secret!('platform', 'ca-bundle', rotating_ca_secret, ['ca.crt'])
raise 'a CA rotation bundle returned the retired anchor expiry' unless rotating_expiry == ca_certificate.not_after

short_ca_key = OpenSSL::PKey::RSA.new(2048)
short_ca_certificate = issue_certificate(
  common_name: 'short-lived active CA',
  key: short_ca_key,
  not_before: NOW - 3600,
  not_after: NOW + (10 * 86_400),
  ca: true
)
short_ca_leaf = issue_certificate(
  common_name: 'short-chain.example.test',
  key: leaf_key,
  not_before: NOW - 3600,
  not_after: NOW + (30 * 86_400),
  issuer_certificate: short_ca_certificate,
  issuer_key: short_ca_key
)
chain_expiry = validator.validate_secret!(
  'platform', 'tls',
  encoded_secret(
    'tls.crt' => short_ca_leaf.to_pem,
    'tls.key' => leaf_key.to_pem,
    'ca.crt' => short_ca_certificate.to_pem + ca_certificate.to_pem
  ),
  %w[tls.crt tls.key ca.crt]
)
raise 'expiry did not follow the CA that signs the leaf' unless chain_expiry == short_ca_certificate.not_after

expiring_ca_key = OpenSSL::PKey::RSA.new(2048)
expiring_ca_certificate = issue_certificate(
  common_name: 'expiring active CA',
  key: expiring_ca_key,
  not_before: NOW - 3600,
  not_after: NOW + 3600,
  ca: true
)
expiring_ca_leaf = issue_certificate(
  common_name: 'expiring-chain.example.test',
  key: leaf_key,
  not_before: NOW - 3600,
  not_after: NOW + (30 * 86_400),
  issuer_certificate: expiring_ca_certificate,
  issuer_key: expiring_ca_key
)
expect_invalid('will not remain trusted by ca.crt through the 86400-second safety window') do
  validator.validate_secret!(
    'platform', 'tls',
    encoded_secret(
      'tls.crt' => expiring_ca_leaf.to_pem,
      'tls.key' => leaf_key.to_pem,
      'ca.crt' => expiring_ca_certificate.to_pem + ca_certificate.to_pem
    ),
    %w[tls.crt tls.key ca.crt]
  )
end

expect_invalid('has no certificate valid through the 86400-second safety window') do
  validator.validate_secret!(
    'platform', 'ca-bundle', encoded_secret('ca.crt' => expired_ca_certificate.to_pem), ['ca.crt']
  )
end

expect_invalid('contains no PEM certificate') do
  validator.validate_secret!(
    'platform', 'tls', encoded_secret('tls.crt' => 'plain text'), ['tls.crt']
  )
end

expect_invalid('is not valid base64') do
  validator.validate_secret!('platform', 'tls', {'data' => {'tls.crt' => '**invalid**'}}, ['tls.crt'])
end

expect_invalid('contains an invalid private key') do
  validator.validate_secret!(
    'platform', 'tls',
    encoded_secret('tls.crt' => leaf_certificate.to_pem, 'tls.key' => 'plain text'),
    %w[tls.crt tls.key]
  )
end

unless validator.validate_secret!('platform', 'database', encoded_secret('password' => 'secret'), ['password']).nil?
  raise 'non-certificate Secret returned a certificate expiry'
end

cli_now = Time.now.utc
cli_key = OpenSSL::PKey::RSA.new(2048)
cli_certificate = issue_certificate(
  common_name: 'candlepin',
  key: cli_key,
  not_before: cli_now - 3600,
  not_after: cli_now + (30 * 86_400),
  dns_names: ['candlepin']
)
cli_secret = JSON.generate(
  encoded_secret('tomcat.crt' => cli_certificate.to_pem, 'tomcat.key' => cli_key.to_pem)
)
validation_script = root.join('scripts/validate-secret-certificates.rb').to_s
_output, error, status = Open3.capture3(
  'ruby', validation_script, 'platform', 'candlepin', 'tomcat.crt,tomcat.key', '86400',
  JSON.generate('tomcat.crt' => ['candlepin']),
  stdin_data: cli_secret
)
raise "manual certificate validation rejected a matching identity: #{error}" unless status.success?

_output, error, status = Open3.capture3(
  'ruby', validation_script, 'platform', 'candlepin', 'tomcat.crt,tomcat.key', '86400',
  JSON.generate('tomcat.crt' => ['wrong-service']),
  stdin_data: cli_secret
)
if status.success? || !error.include?('does not cover DNS name wrong-service')
  raise "manual certificate validation accepted the wrong identity: #{error}"
end

puts 'Certificate validator rejects unusable TLS identities before a release.'
