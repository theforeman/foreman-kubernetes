#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'json'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/kubernetes_client').to_s

class FakeRunner
  attr_reader :calls

  def initialize(*responses)
    @responses = responses
    @calls = []
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    raise 'unexpected command' if @responses.empty?

    @responses.shift
  end
end

secret_payload = 'database: secret-value'
runner = FakeRunner.new(
  JSON.generate('items' => [{'metadata' => {'name' => 'foreman'}}]),
  JSON.generate('data' => {'values.yaml' => Base64.strict_encode64(secret_payload)}),
  JSON.generate('metadata' => {'name' => 'foreman'}, 'status' => {'phase' => 'Preflight'})
)
client = ForemanRelease::KubernetesClient.new(runner: runner)

releases = client.releases('platform')
raise 'release list was not decoded' unless releases.dig(0, 'metadata', 'name') == 'foreman'
raise 'values Secret was not decoded' unless client.secret_value('platform', 'foreman-values', 'values.yaml') == secret_payload

resource = {
  'metadata' => {
    'namespace' => 'platform',
    'name' => 'foreman',
    'resourceVersion' => '42'
  }
}
status = {'phase' => 'Preflight', 'observedGeneration' => 3}
client.write_status(resource, status)
patch_command = runner.calls.last.first
patch = JSON.parse(patch_command.fetch(patch_command.index('--patch') + 1))
raise 'status update does not guard resourceVersion' unless patch.first == {
  'op' => 'test', 'path' => '/metadata/resourceVersion', 'value' => '42'
}
raise 'status update does not use the status subresource' unless patch_command.include?('--subresource=status')
raise 'status update contains Secret material' if patch_command.join(' ').include?('secret-value')
raise 'kubectl commands unexpectedly use a shell' unless runner.calls.all? { |call| call.first.first == 'kubectl' }

missing_key = ForemanRelease::KubernetesClient.new(
  runner: FakeRunner.new(JSON.generate('data' => {}))
)
begin
  missing_key.secret_value('platform', 'foreman-values', 'missing')
  raise 'missing Secret key was accepted'
rescue KeyError
  nil
end

resource_runner = FakeRunner.new(
  JSON.generate('items' => [{'metadata' => {'name' => 'migration'}}]),
  JSON.generate('metadata' => {'name' => 'migration'}),
  JSON.generate('metadata' => {'name' => 'smoke'}),
  JSON.generate('metadata' => {'name' => 'runtime-config', 'resourceVersion' => '8'}),
  'job.batch/smoke deleted'
)
resource_client = ForemanRelease::KubernetesClient.new(runner: resource_runner)
listed = resource_client.resources('platform', 'jobs', labels: {'operation' => 'release-1', 'owner' => 'uid-1'})
raise 'generic resource list was not decoded' unless listed.dig(0, 'metadata', 'name') == 'migration'
selector_command = resource_runner.calls.first.first
selector = selector_command.fetch(selector_command.index('--selector') + 1)
raise 'resource labels are not deterministic' unless selector == 'operation=release-1,owner=uid-1'
raise 'single resource was not decoded' unless resource_client.resource('platform', 'job', 'migration').dig('metadata', 'name') == 'migration'
created = resource_client.create('platform', {'apiVersion' => 'batch/v1', 'kind' => 'Job', 'metadata' => {'name' => 'smoke'}})
raise 'created resource was not decoded' unless created.dig('metadata', 'name') == 'smoke'
raise 'resource create did not use stdin' unless resource_runner.calls.last.last.include?('"kind":"Job"')
replaced = resource_client.replace(
  'platform',
  {'apiVersion' => 'v1', 'kind' => 'ConfigMap', 'metadata' => {'name' => 'runtime-config', 'resourceVersion' => '7'}}
)
raise 'replaced resource was not decoded' unless replaced.dig('metadata', 'resourceVersion') == '8'
replace_command = resource_runner.calls.last.first
raise 'resource replace did not use kubectl replace' unless replace_command.include?('replace')
raise 'resource replace did not use stdin' unless resource_runner.calls.last.last.include?('"resourceVersion":"7"')
raise 'resource delete did not succeed' unless resource_client.delete('platform', 'job', 'smoke')
delete_command = resource_runner.calls.last.first
raise 'resource delete can block controller shutdown' unless delete_command.include?('--wait=false')
raise 'resource delete is not idempotent' unless delete_command.include?('--ignore-not-found=true')

finalizer = 'platform.theforeman.org/release-protection'
finalizer_runner = FakeRunner.new(
  JSON.generate('metadata' => {
    'namespace' => 'platform', 'name' => 'foreman', 'resourceVersion' => '43', 'finalizers' => [finalizer]
  }),
  JSON.generate('metadata' => {
    'namespace' => 'platform', 'name' => 'foreman', 'resourceVersion' => '44', 'finalizers' => []
  })
)
finalizer_client = ForemanRelease::KubernetesClient.new(runner: finalizer_runner)
unprotected = {
  'metadata' => {'namespace' => 'platform', 'name' => 'foreman', 'resourceVersion' => '42'}
}
protected = finalizer_client.ensure_finalizer(unprotected, finalizer)
raise 'release finalizer was not persisted' unless protected.dig('metadata', 'finalizers') == [finalizer]
add_patch_command = finalizer_runner.calls.first.first
add_patch = JSON.parse(add_patch_command.fetch(add_patch_command.index('--patch') + 1))
raise 'finalizer add does not guard resourceVersion' unless add_patch.first['value'] == '42'
raise 'finalizer add replaced unrelated metadata' unless add_patch.last == {
  'op' => 'add', 'path' => '/metadata/finalizers', 'value' => [finalizer]
}
removed = finalizer_client.remove_finalizer(protected, finalizer)
raise 'release finalizer was not removed' unless removed.dig('metadata', 'finalizers') == []
remove_patch_command = finalizer_runner.calls.last.first
remove_patch = JSON.parse(remove_patch_command.fetch(remove_patch_command.index('--patch') + 1))
raise 'finalizer removal does not guard the updated resourceVersion' unless remove_patch.first['value'] == '43'
raise 'finalizer removal touched another finalizer' unless remove_patch.last == {
  'op' => 'remove', 'path' => '/metadata/finalizers/0'
}
raise 'metadata patch incorrectly used the status subresource' if finalizer_runner.calls.any? do |call|
  call.first.include?('--subresource=status')
end

cluster_runner = FakeRunner.new(JSON.generate('items' => []))
ForemanRelease::KubernetesClient.new(runner: cluster_runner).resources(nil, 'storageclasses')
raise 'cluster-scoped query included a namespace' if cluster_runner.calls.first.first.include?('--namespace')

puts 'Kubernetes client protects status concurrency and keeps values in same-namespace Secrets.'
