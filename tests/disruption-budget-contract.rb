#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

budgets = YAML.load_stream(File.read(ARGV.fetch(0))).compact.select do |resource|
  resource['kind'] == 'PodDisruptionBudget'
end
abort 'expected at least one PodDisruptionBudget' if budgets.empty?

budgets.each do |budget|
  name = budget.dig('metadata', 'name')
  abort "#{name} must not use a weak fixed minAvailable" if budget.dig('spec').key?('minAvailable')
  abort "#{name} must allow at most one unavailable replica" unless budget.dig('spec', 'maxUnavailable').to_i == 1
end

puts "All #{budgets.length} disruption budgets preserve all but one replica."
