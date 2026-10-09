#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

abort "usage: #{$PROGRAM_NAME} DEFAULT_RENDER MONITORING_RENDER" unless ARGV.length == 2

default_documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
monitoring_documents = YAML.load_stream(File.read(ARGV.fetch(1))).compact

service = default_documents.find { |item| item['kind'] == 'Service' }
abort 'operator metrics Service is missing' unless service
abort 'NotReady controller metrics disappear from discovery' unless service.dig('spec', 'publishNotReadyAddresses') == true
abort 'PrometheusRule was enabled without an explicit dependency' if default_documents.any? { |item| item['kind'] == 'PrometheusRule' }
abort 'ServiceMonitor was enabled without an explicit dependency' if default_documents.any? { |item| item['kind'] == 'ServiceMonitor' }
abort 'Grafana dashboard was enabled without an explicit dependency' if default_documents.any? do |item|
  item['kind'] == 'ConfigMap' && item.dig('metadata', 'name').to_s.end_with?('-dashboard')
end

monitor = monitoring_documents.find { |item| item['kind'] == 'ServiceMonitor' }
abort 'enabled ServiceMonitor is missing' unless monitor
abort 'ServiceMonitor discovery label is missing' unless monitor.dig('metadata', 'labels', 'release') == 'platform-monitoring'
unless monitor.dig('spec', 'selector', 'matchLabels') == service.dig('spec', 'selector')
  abort 'ServiceMonitor does not select the operator metrics Service'
end
endpoint = Array(monitor.dig('spec', 'endpoints')).first
unless endpoint == {
  'port' => 'metrics',
  'path' => '/metrics',
  'scheme' => 'http',
  'interval' => '30s',
  'scrapeTimeout' => '10s',
  'honorLabels' => false
}
  abort 'ServiceMonitor endpoint does not preserve the bounded metrics scrape contract'
end

rule = monitoring_documents.find { |item| item['kind'] == 'PrometheusRule' }
abort 'enabled PrometheusRule is missing' unless rule
rules = Array(rule.dig('spec', 'groups')).flat_map { |group| Array(group['rules']) }
expected = %w[
  ForemanReleaseControllerMetricsMissing
  ForemanReleaseControllerNotReady
  ForemanReleaseControllerLeaderUnavailable
  ForemanReleaseControllerCycleFailures
  ForemanReleaseBlocked
  ForemanReleaseGenerationStalled
  ForemanReleaseDriftAuditFailed
  ForemanReleaseCertificateExpiring
  ForemanReleaseCertificateExpiryCritical
]
names = rules.map { |item| item['alert'] }
abort "unexpected operator alerts: #{names.join(', ')}" unless names.sort == expected.sort
expressions = rules.map { |item| item['expr'].to_s }.join('\n')
%w[
  foreman_release_controller_running
  foreman_release_controller_ready
  foreman_release_controller_leader
  foreman_release_controller_cycles_total
  foreman_release_status
  foreman_release_metadata_generation
  foreman_release_observed_generation
  foreman_release_drift_check_healthy
  foreman_release_certificate_expiry_timestamp_seconds
].each do |metric|
  abort "alerts do not consume #{metric}" unless expressions.include?(metric)
end

dashboard = monitoring_documents.find do |item|
  item['kind'] == 'ConfigMap' && item.dig('metadata', 'name').to_s.end_with?('-dashboard')
end
abort 'enabled Grafana dashboard is missing' unless dashboard
abort 'Grafana sidecar discovery label is missing' unless dashboard.dig('metadata', 'labels', 'grafana_dashboard') == '1'

ingress_policy = monitoring_documents.find do |item|
  item['kind'] == 'NetworkPolicy' && Array(item.dig('spec', 'policyTypes')).include?('Ingress')
end
abort 'operator metrics ingress policy is missing' unless ingress_policy
unless ingress_policy.dig('spec', 'podSelector', 'matchLabels') == service.dig('spec', 'selector')
  abort 'operator metrics ingress policy does not select the controller'
end
ingress_rule = Array(ingress_policy.dig('spec', 'ingress')).first
prometheus_peer = Array(ingress_rule&.fetch('from', nil)).first
unless prometheus_peer&.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name') == 'monitoring' &&
    prometheus_peer&.dig('podSelector', 'matchLabels', 'app.kubernetes.io/name') == 'prometheus'
  abort 'operator metrics ingress is not restricted to the declared Prometheus peer'
end
unless Array(ingress_rule['ports']) == [{ 'protocol' => 'TCP', 'port' => 9393 }]
  abort 'operator metrics ingress exposes an unexpected port'
end

dashboard_json = dashboard.dig('data', 'foreman-release-operator.json')
abort 'Grafana dashboard payload is missing' if dashboard_json.to_s.empty?
parsed_dashboard = JSON.parse(dashboard_json)
abort 'Grafana dashboard has an unstable identity' unless parsed_dashboard['uid'] == 'foreman-release-controller'
dashboard_expressions = parsed_dashboard.fetch('panels').flat_map do |panel|
  Array(panel['targets']).map { |target| target['expr'].to_s }
end.join('\n')
%w[
  foreman_release_controller_ready
  foreman_release_controller_leader
  foreman_release_controller_cycles_total
  foreman_release_status
  foreman_release_metadata_generation
  foreman_release_observed_generation
  foreman_release_drift_check_healthy
  foreman_release_certificate_expiry_timestamp_seconds
].each do |metric|
  abort "dashboard does not consume #{metric}" unless dashboard_expressions.include?(metric)
end

puts 'Operator monitoring packages discovery, nine alerts, and one opt-in Grafana dashboard.'
