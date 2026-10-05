#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/manifest_requirements').to_s

documents = YAML.load_stream($stdin.read).compact
ForemanRelease::ManifestRequirements.new(documents).cluster_resources.each do |requirement|
  puts requirement.join("\t")
end
