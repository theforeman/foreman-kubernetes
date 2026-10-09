#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'json'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV[0])).compact
enabled_plugin_values = documents.each_with_object([]) do |resource, values|
  pod_spec = resource.dig('spec', 'template', 'spec')
  next unless pod_spec

  value = Array(pod_spec['containers']).flat_map { |container| Array(container['env']) }
    .find { |env| env['name'] == 'PULP_ENABLED_PLUGINS' }
    &.fetch('value', nil)
  values << value if value
end
abort 'PULP_ENABLED_PLUGINS is missing from Pulp workloads' if enabled_plugin_values.empty?
abort 'Pulp workloads disagree on enabled plugins' unless enabled_plugin_values.uniq.one?

enabled_plugins = JSON.parse(enabled_plugin_values.first)
pulp_ingresses = documents.select do |resource|
  resource['kind'] == 'Ingress' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-content-edge'
end
abort 'Pulp ingresses are missing' if pulp_ingresses.empty?

paths = pulp_ingresses.flat_map do |ingress|
  Array(ingress.dig('spec', 'rules')).flat_map do |rule|
    Array(rule.dig('http', 'paths'))
  end
end
path_map = paths.each_with_object({}) do |path, result|
  result[path['path']] = path.dig('backend', 'service', 'name')
end
ingress_by_path = pulp_ingresses.each_with_object({}) do |ingress, result|
  Array(ingress.dig('spec', 'rules')).each do |rule|
    Array(rule.dig('http', 'paths')).each { |path| result[path['path']] = ingress }
  end
end
content_service = documents.find do |resource|
  resource['kind'] == 'Service' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-content'
end
abort 'Pulp content Service is missing' unless content_service

content_service_name = content_service.dig('metadata', 'name')
api_service = documents.find do |resource|
  resource['kind'] == 'Service' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-api'
end
abort 'Pulp API Service is missing' unless api_service

api_service_name = api_service.dig('metadata', 'name')
required_routes = {
  '/pulp/content' => content_service_name,
  '/pulp/isos(/|$)(.*)' => content_service_name,
  '/pulp/assets' => api_service_name
}
plugin_routes = {
  'pulp_container' => {
    '/pulp/container' => content_service_name,
    '/v2' => api_service_name
  },
  'pulp_deb' => {'/pulp/deb' => content_service_name},
  'pulp_ansible' => {'/pulp_ansible/galaxy' => api_service_name},
  'pulp_python' => {'/pypi' => api_service_name}
}

required_routes.each do |path, service|
  abort "#{path} is not routed to #{service}" unless path_map[path] == service
end
plugin_routes.each do |plugin, routes|
  routes.each do |path, service|
    if enabled_plugins.include?(plugin)
      abort "#{path} is missing for enabled #{plugin}" unless path_map[path] == service
    elsif path_map.key?(path)
      abort "#{path} is public although #{plugin} is disabled"
    end
  end
end

abort 'Pulp administrative API must not be public' if path_map.keys.any? { |path| path.start_with?('/pulp/api') }
abort 'Katello registry control route must not be public' if path_map.keys.any? { |path| path.start_with?('/pulpcore_registry') }

if enabled_plugins.include?('pulp_container')
  public_registry_ingress = ingress_by_path.fetch('/v2')
  public_registry_annotations = public_registry_ingress.dig('metadata', 'annotations') || {}
  abort 'public OCI Registry API must not inherit the Katello prefix rewrite' if \
    public_registry_annotations.key?('nginx.ingress.kubernetes.io/rewrite-target')
end

puts "Pulp public routes match enabled plugins: #{enabled_plugins.sort.join(', ')}."
