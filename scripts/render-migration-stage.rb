#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require_relative 'release-job-stage'

abort "usage: #{$PROGRAM_NAME} RELEASE_NAME RELEASE_NAMESPACE" unless ARGV.length == 2

release_name, release_namespace = ARGV
documents = YAML.load_stream($stdin.read).compact
stage = ReleaseJobStage.render(
  documents: documents,
  components: %w[candlepin-migrate pulp-migrate foreman-migrate],
  expected_count: 3,
  stage_name: 'migration',
  release_name: release_name,
  release_namespace: release_namespace
)
puts stage.map { |document| YAML.dump(document) }.join
