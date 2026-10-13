#!/usr/bin/env ruby
# frozen_string_literal: true

notes = File.read(ARGV.fetch(0))

expected = [
  'Foreman PostgreSQL steady-state connection ceiling for this profile: 255',
  'web: 100; Dynflow workers: 120; hosts queue: 30; orchestrator and one-shot utilities: 5',
  'simultaneous rolling-update ceiling: 280'
]

missing = expected.reject { |line| notes.include?(line) }
abort "capacity notes do not use every HPA maximum: #{missing.join('; ')}" unless missing.empty?

puts 'Helm notes size Foreman PostgreSQL from static or HPA-maximum replicas.'
