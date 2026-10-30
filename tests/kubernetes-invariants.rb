#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST [...]" if ARGV.empty?

documents = ARGV.flat_map { |path| YAML.load_stream(File.read(path)).compact }
errors = []

def namespace(resource)
  resource.dig('metadata', 'namespace') || 'default'
end

def identity(resource)
  [namespace(resource), resource.fetch('kind'), resource.dig('metadata', 'name')]
end

def pod_template(resource)
  case resource.fetch('kind')
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template')
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job'
    resource.dig('spec', 'template')
  end
end

def labels_match?(selector, labels)
  selector.all? { |key, value| labels[key] == value }
end

documents.group_by { |resource| identity(resource) }.each do |resource_identity, matches|
  errors << "duplicate resource #{resource_identity.join('/')}" if matches.length > 1
end

workloads = documents.select { |resource| pod_template(resource) }
maintenance_render = workloads.any? do |workload|
  pod_template(workload).dig('metadata', 'labels', 'app.kubernetes.io/component').to_s.start_with?('recovery-')
end
workloads.each do |workload|
  template = pod_template(workload)
  pod_spec = template.fetch('spec')
  workload_name = identity(workload).join('/')
  selector = workload.dig('spec', 'selector', 'matchLabels')
  labels = template.dig('metadata', 'labels') || {}
  recovery_workload = labels.fetch('app.kubernetes.io/component', '').start_with?('recovery-')
  kubernetes_api_client = labels.fetch('app.kubernetes.io/component', '') == 'release-controller'
  compatibility_label = 'platform.theforeman.org/compatibility-set'
  workload_compatibility_set = workload.dig('metadata', 'labels', compatibility_label)
  pod_compatibility_set = labels[compatibility_label]

  if workload_compatibility_set.to_s.empty?
    errors << "#{workload_name} has no compatibility-set label"
  elsif pod_compatibility_set != workload_compatibility_set
    errors << "#{workload_name} pod compatibility set does not match its workload"
  end

  if selector && !labels_match?(selector, labels)
    errors << "#{workload_name} selector does not match its pod template"
  end

  if pod_spec['automountServiceAccountToken'] != false && !recovery_workload && !kubernetes_api_client
    errors << "#{workload_name} must disable the Kubernetes API token"
  end

  pod_security = pod_spec.fetch('securityContext', {})
  unless pod_security.dig('seccompProfile', 'type') == 'RuntimeDefault'
    errors << "#{workload_name} must use the RuntimeDefault seccomp profile"
  end

  volume_names = Array(pod_spec['volumes']).map { |volume| volume.fetch('name') }
  containers = Array(pod_spec['initContainers']) + Array(pod_spec['containers'])
  containers.each do |container|
    container_name = "#{workload_name}/#{container.fetch('name')}"
    security = container.fetch('securityContext', {})
    effective_non_root = security.fetch('runAsNonRoot', pod_security['runAsNonRoot'])
    errors << "#{container_name} may run as root" unless effective_non_root == true
    errors << "#{container_name} permits privilege escalation" unless security['allowPrivilegeEscalation'] == false
    errors << "#{container_name} does not drop all capabilities" unless Array(security.dig('capabilities', 'drop')).include?('ALL')
    resources = container.fetch('resources', {})
    errors << "#{container_name} has no CPU request" unless resources.dig('requests', 'cpu')
    errors << "#{container_name} has no memory request" unless resources.dig('requests', 'memory')
    errors << "#{container_name} has no memory limit" unless resources.dig('limits', 'memory')

    Array(container['volumeMounts']).each do |mount|
      next if volume_names.include?(mount.fetch('name'))

      errors << "#{container_name} mounts missing volume #{mount.fetch('name')}"
    end
  end
end

services = documents.select { |resource| resource['kind'] == 'Service' }
services.each do |service|
  selector = service.dig('spec', 'selector') || {}
  next if selector.empty?

  service_name = identity(service).join('/')
  selected_workloads = workloads.select do |workload|
    namespace(workload) == namespace(service) &&
      labels_match?(selector, pod_template(workload).dig('metadata', 'labels') || {})
  end
  if selected_workloads.empty?
    errors << "#{service_name} does not select a rendered workload" unless maintenance_render
    next
  end

  available_ports = selected_workloads.flat_map do |workload|
    Array(pod_template(workload).dig('spec', 'containers')).flat_map do |container|
      Array(container['ports']).flat_map { |port| [port['name'], port['containerPort']] }.compact
    end
  end
  Array(service.dig('spec', 'ports')).each do |port|
    target = port['targetPort'] || port.fetch('port')
    errors << "#{service_name} targets missing container port #{target}" unless available_ports.include?(target)
  end
end

documents.select { |resource| resource['kind'] == 'NetworkPolicy' }.each do |policy|
  policy_name = identity(policy).join('/')
  Array(policy.dig('spec', 'ingress')).each do |rule|
    Array(rule['from']).each do |peer|
      unbounded = peer.nil? || peer.empty? ||
        (peer.keys == ['podSelector'] && (peer['podSelector'].nil? || peer['podSelector'].empty?)) ||
        (peer.keys == ['namespaceSelector'] && (peer['namespaceSelector'].nil? || peer['namespaceSelector'].empty?))
      errors << "#{policy_name} contains an unbounded ingress peer" if unbounded
    end
  end
  Array(policy.dig('spec', 'egress')).each do |rule|
    Array(rule['to']).each do |peer|
      unbounded = peer.nil? || peer.empty? ||
        (peer.keys == ['podSelector'] && (peer['podSelector'].nil? || peer['podSelector'].empty?)) ||
        (peer.keys == ['namespaceSelector'] && (peer['namespaceSelector'].nil? || peer['namespaceSelector'].empty?))
      errors << "#{policy_name} contains an unbounded egress peer" if unbounded
    end
  end

  next unless Array(policy.dig('spec', 'policyTypes')).include?('Ingress')

  selector = policy.dig('spec', 'podSelector', 'matchLabels') || {}
  selected_workloads = workloads.select do |workload|
    namespace(workload) == namespace(policy) &&
      labels_match?(selector, pod_template(workload).dig('metadata', 'labels') || {})
  end
  next if selected_workloads.empty?

  available_ports = selected_workloads.flat_map do |workload|
    Array(pod_template(workload).dig('spec', 'containers')).flat_map do |container|
      Array(container['ports']).flat_map { |port| [port['name'], port['containerPort']] }.compact
    end
  end
  Array(policy.dig('spec', 'ingress')).flat_map { |rule| Array(rule['ports']) }.each do |port|
    target = port['port']
    next if available_ports.include?(target)

    errors << "#{policy_name} permits missing container port #{target}"
  end
end

documents.select { |resource| resource['kind'] == 'Ingress' }.each do |ingress|
  ingress_name = identity(ingress).join('/')
  Array(ingress.dig('spec', 'rules')).each do |rule|
    Array(rule.dig('http', 'paths')).each do |path|
      backend = path.dig('backend', 'service')
      next unless backend

      service = services.find do |candidate|
        namespace(candidate) == namespace(ingress) && candidate.dig('metadata', 'name') == backend['name']
      end
      unless service
        errors << "#{ingress_name} targets missing Service #{backend['name']}"
        next
      end

      backend_port = backend.fetch('port')
      service_ports = Array(service.dig('spec', 'ports'))
      port_exists = if backend_port['name']
                      service_ports.any? { |port| port['name'] == backend_port['name'] }
                    else
                      service_ports.any? { |port| port['port'] == backend_port['number'] }
                    end
      errors << "#{ingress_name} targets a missing port on Service #{backend['name']}" unless port_exists
    end
  end
end

documents.select { |resource| resource['kind'] == 'PodDisruptionBudget' }.each do |budget|
  selector = budget.dig('spec', 'selector', 'matchLabels') || {}
  next if workloads.any? do |workload|
    namespace(workload) == namespace(budget) &&
      labels_match?(selector, pod_template(workload).dig('metadata', 'labels') || {})
  end

  errors << "#{identity(budget).join('/')} does not select a rendered workload"
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "Kubernetes invariants passed for #{documents.length} rendered resources."
