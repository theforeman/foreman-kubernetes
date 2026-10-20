#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

root = File.expand_path('..', __dir__)
values = YAML.safe_load(File.read(File.join(root, 'tests/kind/values.yaml')))
lifecycle = File.read(File.join(root, 'tests/kind/webhook-lifecycle.sh'))
receiver = File.read(File.join(root, 'tests/kind/webhook-receiver.rb'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

unless values.dig('foreman', 'enabledPlugins').include?('foreman_webhooks')
  abort 'Kind profile does not enable foreman_webhooks'
end

required_lifecycle_contracts = {
  'create a payload template through the public API' => 'POST /api/webhook_templates',
  'create an event webhook through the public API' => 'POST /api/webhooks',
  'use a real domain event' => 'event: "domain_created"',
  'create domains through the public API' => 'POST /api/domains',
  'surface destination failure' => '/failure',
  'require the HTTP 503 result' => '"path":"/failure","status":503',
  'replace the receiver Pod' => 'delete pod',
  'reject a retained Pod UID' => 'webhook receiver Pod was not replaced',
  'verify restored webhook state through the public API' => 'GET "/api/webhooks/${webhook_id}"',
  'exercise post-restore delivery' => 'recovery_domain'
}
required_lifecycle_contracts.each do |description, contract|
  abort "webhook lifecycle does not #{description}" unless lifecycle.include?(contract)
end

abort 'receiver does not emit a controlled HTTP failure' unless receiver.include?("path == '/failure' ? 503 : 204")
abort 'receiver does not record request bodies' unless receiver.include?('body: body')
abort 'Kind harness does not seed the webhook lifecycle' unless harness.include?('seed "${temporary_directory}" "${webhook_lifecycle_state}"')
abort 'Kind harness does not verify recovered webhooks' unless harness.include?('assert "${temporary_directory}" "${webhook_lifecycle_state}"')
abort 'partial Kind runs do not clean up the webhook receiver' unless harness.include?('cleanup "${temporary_directory}" "${webhook_lifecycle_state}"')

webhooks = matrix.fetch('foreman').find { |plugin| plugin.fetch('name') == 'foreman_webhooks' }
abort 'Foreman Webhooks matrix entry is missing' unless webhooks
unless webhooks.fetch('status') == 'integration-drill-implemented-unrun'
  abort 'Foreman Webhooks matrix overstates or understates the prepared drill'
end
abort 'promotion evidence does not require webhook delivery and restart' unless checks.include?('foreman-webhooks-delivery-failure-restart')
abort 'promotion evidence does not require webhook recovery' unless checks.include?('foreman-webhooks-clean-recovery')

puts 'Foreman Webhooks integration covers delivery, visible failure, receiver replacement, and clean recovery.'
