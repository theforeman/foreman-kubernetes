#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'open3'

abort 'usage: pulp-object-storage-test-contract.rb DEFAULT S3 S3_EGRESS' unless ARGV.length == 3

load_resources = lambda do |path|
  YAML.load_stream(File.read(path)).compact
end

default, s3, s3_egress = ARGV.map { |path| load_resources.call(path) }
component = 'pulp-object-storage-test'
jobs = s3.select do |resource|
  resource['kind'] == 'Job' && resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
end
abort 'S3 profile must render exactly one Pulp object-storage test' unless jobs.length == 1
abort 'filesystem profile must not render the Pulp object-storage test' if default.any? do |resource|
  resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
end

job = jobs.first
abort 'object-storage probe is not a Helm test' unless job.dig('metadata', 'annotations', 'helm.sh/hook') == 'test'
pod = job.dig('spec', 'template', 'spec')
abort 'object-storage probe does not use the isolated Pulp identity' unless pod['serviceAccountName'] == 'test-foreman-stack-pulp'
abort 'object-storage probe mounts a service-account token' unless pod['automountServiceAccountToken'] == false
container = pod.fetch('containers').fetch(0)
script = container.fetch('args').join("\n")
%w[versioning.enable payload_size default_storage.save default_storage.open default_storage.url urllib.request.urlopen default_storage.delete list_object_versions copy_object delete_objects].each do |contract|
  abort "object-storage probe does not exercise #{contract}" unless script.include?(contract)
end
abort 'object-storage probe does not cross the multipart threshold' unless script.include?('9 * 1024 * 1024')
_stdout, stderr, status = Open3.capture3(
  'python3', '-c', 'import sys; compile(sys.stdin.read(), "pulp-object-storage-test", "exec")',
  stdin_data: script
)
abort "object-storage probe contains invalid Python: #{stderr}" unless status.success?

env = container.fetch('env').to_h { |entry| [entry.fetch('name'), entry] }
abort 'object-storage probe does not configure the S3 backend' unless env.dig('PULP_STORAGES__default__BACKEND', 'value') == 'storages.backends.s3.S3Storage'
abort 'object-storage probe lacks Secret-backed access credentials' unless env.dig('PULP_STORAGES__default__OPTIONS__access_key', 'valueFrom', 'secretKeyRef', 'name') == 'pulp-object-storage'
abort 'object-storage probe has no bounded local scratch volume' unless pod.fetch('volumes').any? do |volume|
  volume['name'] == 'pulp-tmp' && volume.dig('emptyDir', 'sizeLimit') == '20Gi'
end

policy = s3_egress.find do |resource|
  resource['kind'] == 'NetworkPolicy' &&
    resource.dig('spec', 'podSelector', 'matchLabels', 'app.kubernetes.io/component') == component
end
abort 'restricted egress does not select the object-storage probe' unless policy
ports = policy.dig('spec', 'egress').flat_map { |rule| Array(rule['ports']) }.map { |port| port['port'] }
abort 'object-storage probe egress does not permit the declared S3 port' unless ports.include?(443)

puts 'Pulp S3 Helm test covers versioning, multipart round trip, exact-version recovery, and cleanup.'
