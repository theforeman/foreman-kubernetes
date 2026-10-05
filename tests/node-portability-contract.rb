#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} STACK_MANIFEST EXECUTION_MANIFEST OPERATOR_MANIFEST CHART_DIR..." if ARGV.length < 4

manifest_paths = ARGV.shift(3)
chart_directories = ARGV
documents = manifest_paths.flat_map { |path| YAML.load_stream(File.read(path)).compact }

def pod_spec(resource)
  case resource['kind']
  when 'Pod'
    resource['spec']
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job'
    resource.dig('spec', 'template', 'spec')
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

def resource_name(resource)
  [resource['kind'], resource.dig('metadata', 'namespace'), resource.dig('metadata', 'name')]
    .compact.join('/')
end

host_socket_paths = %r{\A/(?:run/(?:containerd|crio|docker|podman|systemd)|var/run/(?:docker|podman))(?:/|\z)}
host_management_paths = %r{\A/(?:var/lib/kubelet|etc/(?:redhat-release|os-release))(?:/|\z)}

documents.each do |resource|
  spec = pod_spec(resource)
  next unless spec

  name = resource_name(resource)
  %w[hostIPC hostNetwork hostPID].each do |setting|
    abort "#{name} enables host namespace #{setting}" if spec[setting] == true
  end

  Array(spec['volumes']).each do |volume|
    abort "#{name} mounts hostPath volume #{volume['name']}" if volume.key?('hostPath')
  end

  containers = Array(spec['initContainers']) + Array(spec['containers'])
  containers.each do |container|
    container_name = "#{name}/#{container['name']}"
    security_context = container.fetch('securityContext', {})
    abort "#{container_name} is privileged" if security_context['privileged'] == true

    Array(container['ports']).each do |port|
      abort "#{container_name} binds hostPort #{port['hostPort']}" if port['hostPort'].to_i.positive?
    end

    Array(container['volumeMounts']).each do |mount|
      path = mount['mountPath'].to_s
      next unless path.match?(host_socket_paths) || path.match?(host_management_paths)

      abort "#{container_name} mounts host integration path #{path}"
    end

    environment_names = Array(container['env']).map { |entry| entry['name'] }
    forbidden_environment = environment_names & %w[CONTAINER_HOST DOCKER_HOST KUBECONFIG]
    unless forbidden_environment.empty?
      abort "#{container_name} receives host control environment #{forbidden_environment.join(', ')}"
    end
  end
end

source_patterns = {
  %r{\b(?:dnf|yum|apt-get|apk)\s+(?:install|remove|upgrade|update)\b} => 'host package manager',
  %r{\brpm\s+-(?:i|U|e|q)\b} => 'host RPM database',
  /\bsystemctl\b/ => 'host systemd',
  %r{/run/(?:containerd|crio|docker|podman|systemd)(?:/|\z)} => 'host runtime socket',
  %r{/var/run/(?:docker|podman)\.sock} => 'host runtime socket',
  %r{/var/lib/kubelet(?:/|\z)} => 'kubelet filesystem',
  %r{/etc/(?:redhat-release|os-release)(?:\z|\s|["'])} => 'node operating-system detection'
}

chart_directories.each do |directory|
  Dir.glob(File.join(directory, '**', '*')).sort.each do |path|
    next unless File.file?(path)
    next unless %w[.json .py .rb .sh .tpl .yaml .yml].include?(File.extname(path))

    content = File.read(path)
    source_patterns.each do |pattern, boundary|
      match = content.match(pattern)
      next unless match

      line = content[0...match.begin(0)].count("\n") + 1
      abort "#{path}:#{line} introduces #{boundary} dependency"
    end
  end
end

puts 'Workloads require no node packages, host services, host namespaces, runtime sockets, or host filesystems.'
