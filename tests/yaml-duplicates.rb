#!/usr/bin/env ruby
# frozen_string_literal: true

require 'psych'

root = File.expand_path('..', __dir__)
files = Dir.glob(File.join(root, '**', '*.{yaml,yml}')).reject do |path|
  path.match?(%r{/charts/[^/]+/templates/})
end
errors = []

def check_node(node, file, path, errors)
  case node
  when Psych::Nodes::Mapping
    seen = {}
    node.children.each_slice(2) do |key, value|
      key_name = key.value if key.is_a?(Psych::Nodes::Scalar)
      key_path = key_name ? path + [key_name] : path
      if key_name && seen.key?(key_name)
        errors << "#{file}:#{key.start_line + 1}: duplicate key #{key_path.join('.')} " \
                  "(first declared on line #{seen.fetch(key_name)})"
      elsif key_name
        seen[key_name] = key.start_line + 1
      end
      check_node(value, file, key_path, errors)
    end
  when Psych::Nodes::Sequence, Psych::Nodes::Stream, Psych::Nodes::Document
    node.children.each { |child| check_node(child, file, path, errors) }
  end
end

files.each do |file|
  check_node(Psych.parse_stream(File.read(file), filename: file), file, [], errors)
rescue Psych::SyntaxError => e
  errors << e.message
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "No duplicate keys in #{files.length} YAML files."
