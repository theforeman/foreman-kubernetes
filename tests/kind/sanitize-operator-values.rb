#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort 'usage: sanitize-operator-values.rb MODE INPUT OUTPUT' unless ARGV.length == 3

mode, input, output = ARGV
abort "unsupported values mode: #{mode}" unless %w[application execution].include?(mode)

values = YAML.safe_load(
  File.read(input),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
)
abort 'Helm values must contain a YAML mapping' unless values.is_a?(Hash)

# A release operation is controller-owned state, never an input copied from a
# previously deployed Helm revision.
values.delete('releaseOperation')
if mode == 'application'
  values['migrations'] ||= {}
  values['migrations']['activeDeadlineSeconds'] = 90
end

File.write(output, YAML.dump(values))
