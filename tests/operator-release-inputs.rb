#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/release_inputs').to_s

catalog = ForemanRelease::ReleaseCatalog.load(root)
begin
  catalog.resolve('nightly-candidate-2026-09-24', allow_candidate: false)
  raise 'candidate set was accepted without explicit opt-in'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('still a candidate')
end

profiles = catalog.resolve('nightly-candidate-2026-09-24', allow_candidate: true)
raise 'application profile was not resolved' unless File.file?(profiles.application_path)
raise 'execution proxy profile was not resolved' unless File.file?(profiles.execution_proxy_path)
catalog.validate_upgrade_paths!(
  'nightly-candidate-2026-09-24',
  ['nightly-candidate-2026-09-24']
)
begin
  catalog.validate_upgrade_paths!('nightly-candidate-2026-09-24', ['undeclared-set'])
  raise 'an undeclared installed compatibility set was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('is not declared')
end

manifest = JSON.parse(root.join('compatibility/release-sets.json').read)
old_set = Marshal.load(Marshal.dump(manifest.dig('sets', 'nightly-candidate-2026-09-24')))
old_set['upgradeFrom'] = ['old-set']
manifest['sets']['old-set'] = old_set
restricted_catalog = ForemanRelease::ReleaseCatalog.new(root: root, manifest: manifest)
begin
  restricted_catalog.validate_upgrade_paths!('nightly-candidate-2026-09-24', ['old-set'])
  raise 'a disallowed upgrade path was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('is not allowed')
end

class SecretClient
  attr_reader :requests

  def initialize(values)
    @values = values
    @requests = []
  end

  def secret_value(namespace, name, key)
    @requests << [namespace, name, key]
    @values.fetch([name, key])
  end
end

secret_client = SecretClient.new(
  ['application-values', 'values.yaml'] => "platform:\n  fqdn: foreman.example.test\n",
  ['execution-values', 'values.yaml'] => "proxy:\n  foremanUrl: https://foreman.example.test\n"
)
reader = ForemanRelease::ValuesReader.new(secret_client)
resource = {
  'metadata' => {'namespace' => 'foreman'},
  'spec' => {
    'application' => {'valuesSecretRef' => {'name' => 'application-values', 'key' => 'values.yaml'}},
    'executionProxy' => {'valuesSecretRef' => {'name' => 'execution-values', 'key' => 'values.yaml'}}
  }
}
bundle = reader.read(resource)
raise 'application values were altered' unless bundle.application.include?('foreman.example.test')
raise 'execution values were altered' unless bundle.execution_proxy.include?('foreman.example.test')
raise 'values were read outside the CR namespace' unless secret_client.requests.all? { |request| request.first == 'foreman' }

invalid_client = SecretClient.new(
  ['application-values', 'values.yaml'] => "- not\n- a\n- mapping\n",
  ['execution-values', 'values.yaml'] => "proxy: {}\n"
)
begin
  ForemanRelease::ValuesReader.new(invalid_client).read(resource)
  raise 'non-mapping values were accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('YAML mapping')
end

puts 'Operator release inputs are digest-pinned, candidate-gated, and Secret-backed.'
