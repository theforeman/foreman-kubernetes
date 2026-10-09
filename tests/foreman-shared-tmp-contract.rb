#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

unless ARGV.length == 2 && %w[true false].include?(ARGV.fetch(1))
  abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECT_PULP_CLAIM(true|false)"
end

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
expect_pulp_claim = ARGV.fetch(1) == 'true'

def pod_template(resource)
  case resource['kind']
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template')
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job'
    resource.dig('spec', 'template')
  end
end

claims = documents.select { |resource| resource['kind'] == 'PersistentVolumeClaim' }
claim_components = claims.to_h do |claim|
  [claim.dig('metadata', 'labels', 'app.kubernetes.io/component'), claim]
end

foreman_claim = claim_components['foreman-tmp']
abort 'Foreman shared tmp claim is missing' unless foreman_claim
abort 'Foreman shared tmp must require ReadWriteMany' unless foreman_claim.dig('spec', 'accessModes') == ['ReadWriteMany']
avatar_claim = claim_components['foreman-avatars']
abort 'Foreman avatar claim is missing' unless avatar_claim
abort 'Foreman avatars must require ReadWriteMany' unless avatar_claim.dig('spec', 'accessModes') == ['ReadWriteMany']

pulp_claim_present = claim_components.key?('pulp')
abort "Pulp claim expectation differs: expected #{expect_pulp_claim}, got #{pulp_claim_present}" unless pulp_claim_present == expect_pulp_claim

expected_claim_name = foreman_claim.dig('metadata', 'name')
expected_avatar_claim_name = avatar_claim.dig('metadata', 'name')
checked = []
avatar_mounts = []

documents.each do |resource|
  template = pod_template(resource)
  next unless template

  pod_spec = template.fetch('spec')
  volumes = Array(pod_spec['volumes']).to_h { |volume| [volume['name'], volume] }
  containers = Array(pod_spec['initContainers']) + Array(pod_spec['containers'])
  containers.each do |container|
    foreman_process = Array(container['env']).any? { |item| item['name'] == 'FOREMAN_ENABLED_PLUGINS' }
    next unless foreman_process

    mount = Array(container['volumeMounts']).find { |item| item['mountPath'] == '/usr/share/foreman/tmp' }
    abort "#{resource.dig('metadata', 'name')}/#{container['name']} lacks shared Foreman tmp" unless mount

    volume = volumes[mount['name']]
    claim_name = volume&.dig('persistentVolumeClaim', 'claimName')
    abort "#{resource.dig('metadata', 'name')}/#{container['name']} uses the wrong tmp claim" unless claim_name == expected_claim_name

    avatar_mount = Array(container['volumeMounts']).find do |item|
      item['mountPath'] == '/usr/share/foreman/public/images/avatars'
    end
    if avatar_mount
      avatar_volume = volumes[avatar_mount['name']]
      avatar_claim_name = avatar_volume&.dig('persistentVolumeClaim', 'claimName')
      unless avatar_claim_name == expected_avatar_claim_name
        abort "#{resource.dig('metadata', 'name')}/#{container['name']} uses the wrong avatar claim"
      end
      avatar_mounts << [resource.dig('metadata', 'name'), container['name']]
    end

    checked << [resource.dig('metadata', 'name'), container['name']]
  end
end

abort 'no Foreman-derived processes were checked' if checked.empty?
expected_avatar_owner = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman'
end
expected_avatar_mount = [expected_avatar_owner&.dig('metadata', 'name'), 'foreman']
abort "avatar claim must be mounted only by Foreman web: #{avatar_mounts.inspect}" unless avatar_mounts == [expected_avatar_mount]

config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-config')
end
abort 'chart still injects an event daemon implementation' if config&.dig('data')&.key?('katello-event-daemon.rb')

puts "Foreman shared tmp covers #{checked.length} rendered process containers."
