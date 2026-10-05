#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} NORMAL_RENDER MAINTENANCE_RENDER" unless ARGV.length == 2

normal, maintenance = ARGV.map { |path| YAML.load_stream(File.read(path)).compact }

def resources(documents, kind)
  documents.select { |item| item['kind'] == kind }
end

abort 'normal execution release has no Deployment' unless resources(normal, 'Deployment').length == 1
abort 'normal execution release has no smoke-test Job' unless resources(normal, 'Job').length == 1
abort 'maintenance release still contains the execution Deployment' unless resources(maintenance, 'Deployment').empty?
abort 'maintenance release still contains an execution smoke-test Job' unless resources(maintenance, 'Job').empty?
abort 'maintenance release still emits unavailable-workload alerts' unless resources(maintenance, 'PrometheusRule').empty?

%w[Service ConfigMap ServiceAccount].each do |kind|
  abort "maintenance release removed #{kind}" if resources(maintenance, kind).empty?
end

normal_claims = resources(normal, 'PersistentVolumeClaim').map { |item| item.dig('metadata', 'name') }.sort
maintenance_claims = resources(maintenance, 'PersistentVolumeClaim').map { |item| item.dig('metadata', 'name') }.sort
abort 'normal execution release does not declare both persistent claims' unless normal_claims.length == 2
abort 'maintenance release changed or removed persistent claims' unless maintenance_claims == normal_claims

policies = resources(maintenance, 'NetworkPolicy')
abort 'maintenance release removed execution network isolation' if policies.empty?
abort 'maintenance release has no default-deny ingress policy' unless policies.any? do |item|
  item.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'default-deny-ingress' &&
    Array(item.dig('spec', 'policyTypes')).include?('Ingress') &&
    !item.fetch('spec').key?('ingress')
end

puts 'Execution maintenance removes runtime writers while retaining identity, storage, and isolation.'
