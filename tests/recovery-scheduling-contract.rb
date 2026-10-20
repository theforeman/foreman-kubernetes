# frozen_string_literal: true

require 'yaml'

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
job = documents.find do |document|
  document['kind'] == 'Job' &&
    document.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'recovery-backup'
end
abort 'recovery backup Job is missing' unless job

spec = job.dig('spec', 'template', 'spec')
expected_node_selector = {'platform.theforeman.org/pool' => 'foreman'}
expected_toleration = {
  'key' => 'platform.theforeman.org/dedicated',
  'operator' => 'Equal',
  'value' => 'foreman',
  'effect' => 'NoSchedule',
}

abort 'recovery Job did not inherit the execution PriorityClass' unless
  spec['priorityClassName'] == 'foreman-platform-critical'
abort 'recovery Job did not inherit the execution node selector' unless
  spec['nodeSelector'] == expected_node_selector
abort 'recovery Job did not inherit the execution toleration' unless
  Array(spec['tolerations']).include?(expected_toleration)

puts 'Recovery Job inherited execution scheduling.'
