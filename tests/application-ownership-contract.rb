#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} STACK_MANIFEST EXECUTION_MANIFEST" unless ARGV.length == 2

documents = ARGV.flat_map { |path| YAML.load_stream(File.read(path)).compact }
allowed_scripts = %w[
  backup.sh
  check-features.rb
  foreman-readiness.rb
  pulp-app-readiness.py
  pulp-readiness.py
  recovery-common.sh
  restore.sh
]
required_probes = %w[
  check-features.rb
  foreman-readiness.rb
  pulp-app-readiness.py
  pulp-readiness.py
]

script_keys = documents.select { |resource| resource['kind'] == 'ConfigMap' }.flat_map do |resource|
  Array(resource['data']&.keys).grep(/\.(?:rb|py|sh|jar|class)\z/)
end.uniq.sort
unexpected_scripts = script_keys - allowed_scripts
abort "chart injects application code: #{unexpected_scripts.join(', ')}" unless unexpected_scripts.empty?

missing_probes = required_probes - script_keys
abort "chart-owned probe is missing: #{missing_probes.join(', ')}" unless missing_probes.empty?

def pod_spec(resource)
  case resource['kind']
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job'
    resource.dig('spec', 'template', 'spec')
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

containers = documents.map { |resource| pod_spec(resource) }.compact.flat_map do |spec|
  Array(spec['initContainers']) + Array(spec['containers'])
end

injection_environment = %w[
  BUNDLE_GEMFILE
  JAVA_TOOL_OPTIONS
  LD_PRELOAD
  PYTHONPATH
  RUBYLIB
  RUBYOPT
]
containers.each do |container|
  environment_names = Array(container['env']).map { |entry| entry['name'] }.compact
  injected_environment = environment_names & injection_environment
  unless injected_environment.empty?
    abort "#{container['name']} injects application runtime code through #{injected_environment.join(', ')}"
  end

  Array(container['volumeMounts']).each do |mount|
    path = mount['mountPath'].to_s
    code_path = path.match?(%r{/(?:config/initializers|site-packages)(?:/|\z)}) ||
      path.match?(%r{/usr/share/foreman/lib(?:/|\z)})
    next unless code_path

    abort "#{container['name']} mounts chart content into application code path #{path}"
  end
end

puts 'Chart-owned executables are limited to probes and recovery orchestration.'
