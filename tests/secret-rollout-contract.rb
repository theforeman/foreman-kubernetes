#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} BASE_MANIFEST ROTATED_MANIFEST" unless ARGV.length == 2

def pod_templates(path)
  YAML.load_stream(File.read(path)).compact.each_with_object({}) do |resource, result|
    template = case resource['kind']
               when 'Deployment'
                 resource.dig('spec', 'template')
               when 'CronJob'
                 resource.dig('spec', 'jobTemplate', 'spec', 'template')
               end
    next unless template

    result[[resource['kind'], resource.dig('metadata', 'name')]] = template
  end
end

base = pod_templates(ARGV[0])
rotated = pod_templates(ARGV[1])
abort 'secret rotation changed the long-running workload set' unless base.keys.sort == rotated.keys.sort
abort 'no long-running workloads were checked' if base.empty?

base.each do |identity, template|
  original = template.dig('metadata', 'annotations', 'checksum/secrets')
  replacement = rotated.dig(identity, 'metadata', 'annotations', 'checksum/secrets')
  abort "#{identity.join('/')} has no Secret rollout annotation" if original.to_s.empty? || replacement.to_s.empty?
  abort "#{identity.join('/')} did not roll for a new Secret token" if original == replacement
end

puts "Secret rotation changes #{base.length} workload templates."
