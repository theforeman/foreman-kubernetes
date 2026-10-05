#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
maintenance_documents = YAML.load_stream(File.read(ARGV.fetch(1))).compact

autoscalers = documents.select { |resource| resource['kind'] == 'HorizontalPodAutoscaler' }
dynflow_autoscalers = autoscalers.select do |resource|
  resource.dig('metadata', 'name').include?('-dynflow-')
end
expected = {
  'worker' => {:min => 2, :max => 8, :cpu => 65},
  'worker-hosts-queue' => {:min => 2, :max => 4, :cpu => 60}
}

abort 'Dynflow orchestrator must not have an autoscaler' if dynflow_autoscalers.any? do |resource|
  resource.dig('metadata', 'name').end_with?('-orchestrator')
end
abort 'expected exactly two Dynflow autoscalers' unless dynflow_autoscalers.length == expected.length

expected.each do |name, values|
  autoscaler = dynflow_autoscalers.find { |resource| resource.dig('metadata', 'name').end_with?("-dynflow-#{name}") }
  abort "missing Dynflow #{name} autoscaler" unless autoscaler
  abort "Dynflow #{name} targets the wrong Deployment" unless
    autoscaler.dig('spec', 'scaleTargetRef', 'name').end_with?("-dynflow-#{name}")
  abort "Dynflow #{name} minimum changed" unless autoscaler.dig('spec', 'minReplicas') == values.fetch(:min)
  abort "Dynflow #{name} maximum changed" unless autoscaler.dig('spec', 'maxReplicas') == values.fetch(:max)
  abort "Dynflow #{name} CPU target changed" unless
    autoscaler.dig('spec', 'metrics', 0, 'resource', 'target', 'averageUtilization') == values.fetch(:cpu)
  abort "Dynflow #{name} scale-down stabilization changed" unless
    autoscaler.dig('spec', 'behavior', 'scaleDown', 'stabilizationWindowSeconds') == 600

  deployment = documents.find do |resource|
    resource['kind'] == 'Deployment' && resource.dig('metadata', 'name').end_with?("-dynflow-#{name}")
  end
  abort "missing Dynflow #{name} Deployment" unless deployment
  abort "Dynflow #{name} Deployment competes with its HPA" if deployment.fetch('spec').key?('replicas')

  budget = documents.find do |resource|
    resource['kind'] == 'PodDisruptionBudget' && resource.dig('metadata', 'name').end_with?("-dynflow-#{name}")
  end
  abort "Dynflow #{name} minimum replicas lack a disruption budget" unless budget
  abort "Dynflow #{name} disruption budget is weaker than one unavailable" unless
    budget.dig('spec', 'maxUnavailable') == 1
end

orchestrator = documents.find do |resource|
  resource['kind'] == 'Deployment' && resource.dig('metadata', 'name').end_with?('-dynflow-orchestrator')
end
abort 'Dynflow orchestrator is no longer a singleton' unless orchestrator&.dig('spec', 'replicas') == 1

if maintenance_documents.any? { |resource| resource.dig('metadata', 'name').to_s.include?('-dynflow-') }
  abort 'maintenance mode retained a Dynflow Deployment, HPA, or disruption budget'
end

puts 'Dynflow workers autoscale independently while the orchestrator remains a singleton.'
