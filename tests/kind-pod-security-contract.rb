#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

root = File.expand_path('..', __dir__)
harness = File.read(File.join(root, 'tests/kind/run.sh'))
object_storage_drill = File.read(File.join(root, 'tests/kind/object-storage.sh'))
ssh_target_image = File.read(File.join(root, 'images/ssh-target/Dockerfile'))
ssh_target_entrypoint = File.read(File.join(root, 'images/ssh-target/entrypoint.sh'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')
cluster_platforms = JSON.parse(File.read(File.join(root, 'compatibility/cluster-platforms.json')))
default_cluster_platform = cluster_platforms.fetch('platforms').fetch(cluster_platforms.fetch('default'))
pod_security_version = default_cluster_platform.dig('podSecurity', 'version')

def resources(path)
  YAML.load_stream(File.read(path)).compact
end

def deployment(path, name)
  resources(path).find do |resource|
    resource['kind'] == 'Deployment' && resource.dig('metadata', 'name') == name
  end || abort("missing Deployment/#{name}")
end

def assert_restricted(resource)
  name = resource.dig('metadata', 'name')
  pod = resource.dig('spec', 'template', 'spec')
  pod_security = pod.fetch('securityContext', {})
  abort "#{name} does not require a non-root Pod" unless pod_security['runAsNonRoot'] == true
  abort "#{name} does not use RuntimeDefault seccomp" unless pod_security.dig('seccompProfile', 'type') == 'RuntimeDefault'
  abort "#{name} enables a host namespace" if %w[hostIPC hostNetwork hostPID].any? { |key| pod[key] == true }
  abort "#{name} mounts a hostPath directly" if Array(pod['volumes']).any? { |volume| volume.key?('hostPath') }

  containers = Array(pod['initContainers']) + Array(pod['containers'])
  abort "#{name} has no containers" if containers.empty?
  containers.each do |container|
    security = container.fetch('securityContext', {})
    container_name = "#{name}/#{container.fetch('name')}"
    abort "#{container_name} allows privilege escalation" unless security['allowPrivilegeEscalation'] == false
    abort "#{container_name} does not drop all capabilities" unless Array(security.dig('capabilities', 'drop')).include?('ALL')
    effective_non_root = security.fetch('runAsNonRoot', pod_security['runAsNonRoot'])
    abort "#{container_name} does not require a non-root identity" unless effective_non_root == true
  end
end

assert_restricted(deployment(File.join(root, 'tests/kind/object-storage.yaml'), 'object-storage'))
execution_target = deployment(File.join(root, 'tests/kind/execution-target.yaml'), 'execution-target')
assert_restricted(execution_target)
abort 'execution target does not listen on an unprivileged container port' unless
  execution_target.dig('spec', 'template', 'spec', 'containers', 0, 'ports', 0, 'containerPort') == 2222

%w[USER\ 1000:1000 passwd\ -d\ foreman Port\ 2222 AuthorizedKeysFile\ /keys/authorized_key StrictModes\ no EXPOSE\ 2222].each do |contract|
  abort "SSH target image omits #{contract}" unless ssh_target_image.include?(contract)
end
abort 'SSH target settings are appended after distribution defaults' if
  ssh_target_image.include?('>> /etc/ssh/sshd_config')
abort 'SSH target still mutates host identity at runtime' if ssh_target_entrypoint.include?('ssh-keygen')

labels = %w[enforce audit warn].flat_map do |mode|
  [
    "pod-security.kubernetes.io/#{mode}=restricted",
    "pod-security.kubernetes.io/#{mode}-version=\"${pod_security_version}\""
  ]
end
labels.each do |label|
  abort "Kind harness omits namespace label #{label}" unless harness.include?(label)
end
abort 'Kind harness does not read the declared Pod Security version' unless
  harness.include?(".podSecurity.version") && pod_security_version.match?(/\Av\d+\.\d+\z/)

abort 'Pod Security is not enabled before Helm creates application workloads' unless
  harness.include?("\ninstall_dependencies\n\nhelm_apply\n")
abort 'execution target is not recreated under restricted Pod Security' unless
  harness.include?("rollout restart \\\n    deployment/execution-target")
abort 'object-storage host data is not prepared for its non-root process' unless
  object_storage_drill.include?('install -d -m 0770 -o 1000 -g 1000 /var/local/foreman-kind-object-storage')
{
  700 => %w[/var/local/foreman-kind-pulp /var/local/foreman-kind-recovery],
  994 => %w[/var/local/foreman-kind-tmp /var/local/foreman-kind-avatars]
}.each do |identity, paths|
  paths.each do |path|
    contract = "-m 2770 -o #{identity} -g #{identity}"
    abort "Kind harness does not prepare #{path} for UID/GID #{identity}" unless
      harness.include?(contract) && harness.include?(path)
  end
end
abort 'promotion evidence does not require restricted Pod Security admission' unless
  checks.include?('restricted-pod-security-admission')

puts 'Kind integration enforces restricted Pod Security for application lifecycle operations.'
