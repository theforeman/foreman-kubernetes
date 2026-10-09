#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECTED_PVC [...]" if ARGV.length < 2

documents = YAML.load_stream(File.read(ARGV.shift)).compact
expected_names = ARGV.sort
claims = documents.select { |resource| resource['kind'] == 'PersistentVolumeClaim' }
actual_names = claims.map { |claim| claim.dig('metadata', 'name') }.sort

abort "unexpected chart-owned PVCs: #{actual_names.join(', ')}" unless actual_names == expected_names

unretained = claims.each_with_object([]) do |claim, names|
  next if claim.dig('metadata', 'annotations', 'helm.sh/resource-policy') == 'keep'

  names << claim.dig('metadata', 'name')
end
abort "PVCs can be deleted with the Helm release: #{unretained.join(', ')}" unless unretained.empty?

puts "Helm release deletion retains all #{claims.length} chart-owned PVCs."
