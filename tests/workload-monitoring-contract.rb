#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} STACK_DEFAULT STACK_MONITORED STACK_MAINTENANCE PROXY_DEFAULT PROXY_MONITORED PROXY_MAINTENANCE" unless ARGV.length == 6

stack_default, stack_monitored, stack_maintenance, proxy_default, proxy_monitored, proxy_maintenance = ARGV.map do |path|
  YAML.load_stream(File.read(path)).compact
end

if stack_default.any? { |item| item['kind'] == 'PrometheusRule' }
  abort 'Foreman stack PrometheusRule was enabled without an explicit dependency'
end
if proxy_default.any? { |item| item['kind'] == 'PrometheusRule' }
  abort 'execution proxy PrometheusRule was enabled without an explicit dependency'
end
if stack_maintenance.any? { |item| item['kind'] == 'PrometheusRule' }
  abort 'Foreman stack alerts remain active during intentional maintenance'
end
if proxy_maintenance.any? { |item| item['kind'] == 'PrometheusRule' }
  abort 'execution proxy alerts remain active during intentional maintenance'
end

def validate_rule(documents, expected_names, required_metrics, discovery_label)
  rule = documents.find { |item| item['kind'] == 'PrometheusRule' }
  abort 'enabled PrometheusRule is missing' unless rule
  unless rule.dig('metadata', 'labels', 'release') == discovery_label
    abort 'PrometheusRule discovery label is missing'
  end

  rules = Array(rule.dig('spec', 'groups')).flat_map { |group| Array(group['rules']) }
  names = rules.map { |item| item['alert'] }
  abort "unexpected workload alerts: #{names.join(', ')}" unless names.sort == expected_names.sort
  expressions = rules.map { |item| item['expr'].to_s }.join("\n")
  required_metrics.each do |metric|
    abort "workload alerts do not consume #{metric}" unless expressions.include?(metric)
  end
end

validate_rule(
  stack_monitored,
  %w[
    ForemanStackMetricsMissing
    ForemanStackDeploymentUnavailable
    ForemanStackPodCrashLooping
    ForemanStackJobFailed
    ForemanStackPersistentVolumeClaimPending
  ],
  %w[
    kube_deployment_spec_replicas
    kube_deployment_status_replicas_available
    kube_pod_container_status_waiting_reason
    kube_job_status_failed
    kube_persistentvolumeclaim_status_phase
  ],
  'platform-monitoring'
)

validate_rule(
  proxy_monitored,
  %w[
    ForemanExecutionProxyMetricsMissing
    ForemanExecutionProxyUnavailable
    ForemanExecutionProxyCrashLooping
    ForemanExecutionProxyPersistentVolumeClaimPending
  ],
  %w[
    kube_deployment_spec_replicas
    kube_deployment_status_replicas_available
    kube_pod_container_status_waiting_reason
    kube_persistentvolumeclaim_status_phase
  ],
  'platform-monitoring'
)

puts 'Application and execution-proxy workload alerts are opt-in and maintenance-aware.'
