#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST OPERATION_ID OWNER_UID" unless ARGV.length == 3

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
operation_id = ARGV.fetch(1)
owner_uid = ARGV.fetch(2)
components = %w[dependency-preflight candlepin-migrate pulp-migrate foreman-migrate pulp-registration]

jobs = documents.select do |resource|
  resource['kind'] == 'Job' && components.include?(resource.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
abort "expected five operation Jobs, got #{jobs.length}" unless jobs.length == 5

jobs.each do |job|
  name = job.dig('metadata', 'name')
  labels = job.dig('metadata', 'labels') || {}
  pod_labels = job.dig('spec', 'template', 'metadata', 'labels') || {}
  abort "operation Job name does not contain its stable ID: #{name}" unless name.end_with?(operation_id)
  abort "operation Job name is too long: #{name}" if name.length > 63
  abort "operation Job #{name} has the wrong operation label" unless labels['platform.theforeman.org/release-operation'] == operation_id
  abort "operation Job #{name} has the wrong owner label" unless labels['platform.theforeman.org/release-owner'] == owner_uid
  abort "operation Pod #{name} has the wrong operation label" unless pod_labels['platform.theforeman.org/release-operation'] == operation_id
  abort "operation Pod #{name} has the wrong owner label" unless pod_labels['platform.theforeman.org/release-owner'] == owner_uid
  abort "operation Job #{name} can expire before the controller adopts it" if job.dig('spec').key?('ttlSecondsAfterFinished')
end

abort 'operation Job names are not unique' unless jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == jobs.length

puts "Release operation #{operation_id} owns five adoptable Jobs."
