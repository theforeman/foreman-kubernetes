#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST OPERATION_ID OWNER_UID" unless ARGV.length == 3

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
operation_id = ARGV.fetch(1)
owner_uid = ARGV.fetch(2)
deployment = documents.find { |resource| resource['kind'] == 'Deployment' }
abort 'execution proxy Deployment is missing' unless deployment
abort 'execution proxy Deployment has no bounded progress deadline' unless deployment.dig('spec', 'progressDeadlineSeconds').to_i.positive?

labels = deployment.dig('metadata', 'labels') || {}
pod_labels = deployment.dig('spec', 'template', 'metadata', 'labels') || {}
selector = deployment.dig('spec', 'selector', 'matchLabels') || {}

abort 'proxy Deployment has the wrong operation label' unless labels['platform.theforeman.org/release-operation'] == operation_id
abort 'proxy Deployment has the wrong owner label' unless labels['platform.theforeman.org/release-owner'] == owner_uid
abort 'proxy Pod has the wrong operation label' unless pod_labels['platform.theforeman.org/release-operation'] == operation_id
abort 'proxy Pod has the wrong owner label' unless pod_labels['platform.theforeman.org/release-owner'] == owner_uid
abort 'operation identity leaked into the immutable Deployment selector' if selector.key?('platform.theforeman.org/release-operation') ||
                                                                        selector.key?('platform.theforeman.org/release-owner')

puts "Execution proxy rollout belongs to release operation #{operation_id}."
