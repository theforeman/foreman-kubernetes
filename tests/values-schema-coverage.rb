#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

root = File.expand_path('..', __dir__)

def resolve(reference, root)
  return reference unless reference.is_a?(Hash) && reference['$ref']&.start_with?('#/')

  reference['$ref'].delete_prefix('#/').split('/').reduce(root) { |item, key| item.fetch(key) }
end

def uncovered_paths(value, reference, root, path = [])
  reference = resolve(reference, root)
  if value.is_a?(Hash)
    properties = reference.fetch('properties', {})
    free_form = properties.empty? && reference.fetch('additionalProperties', true) != false
    return [] if free_form

    value.flat_map do |key, child|
      child_reference = properties[key]
      child_reference ||= reference['additionalProperties'] if reference['additionalProperties'].is_a?(Hash)
      if child_reference
        uncovered_paths(child, child_reference, root, path + [key])
      else
        [(path + [key]).join('.')]
      end
    end
  elsif value.is_a?(Array) && reference['items']
    value.each_with_index.flat_map do |child, index|
      uncovered_paths(child, reference['items'], root, path + [index.to_s])
    end
  else
    []
  end
end

charts = %w[foreman-stack foreman-execution-proxy foreman-release-operator]
charts.each do |chart|
  chart_root = File.join(root, 'charts', chart)
  values = YAML.safe_load(File.read(File.join(chart_root, 'values.yaml')))
  schema = JSON.parse(File.read(File.join(chart_root, 'values.schema.json')))
  missing = uncovered_paths(values, schema, schema)
  next if missing.empty?

  abort "#{chart}/values.schema.json does not cover defaults:\n#{missing.join("\n")}"
end

puts 'Every default chart value is covered by values.schema.json.'
