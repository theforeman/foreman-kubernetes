#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'yaml'

repo_root = File.expand_path('..', __dir__)
renderer = File.join(repo_root, 'scripts/render-migration-stage.rb')

job = lambda do |component|
  {
    'apiVersion' => 'batch/v1',
    'kind' => 'Job',
    'metadata' => {
      'name' => component,
      'annotations' => {'helm.sh/hook' => 'pre-install'},
      'labels' => {'app.kubernetes.io/component' => component},
    },
    'spec' => {
      'template' => {
        'spec' => {
          'serviceAccountName' => 'external-runtime',
          'volumes' => [
            {'name' => 'config', 'configMap' => {'name' => 'migration-config'}},
            {'name' => 'shared', 'persistentVolumeClaim' => {'claimName' => 'external-shared'}},
          ],
        },
      },
    },
  }
end

documents = [
  {
    'apiVersion' => 'v1',
    'kind' => 'ConfigMap',
    'metadata' => {'name' => 'migration-config'},
  },
  *%w[candlepin-migrate pulp-migrate foreman-migrate].map(&job),
]
manifest = documents.map { |document| YAML.dump(document) }.join

output, error, status = Open3.capture3(
  'ruby', renderer, 'foreman', 'foreman', stdin_data: manifest
)
abort error unless status.success?

staged = YAML.load_stream(output).compact
unless staged.count { |item| item['kind'] == 'Job' } == 3
  abort 'renderer did not preserve all migration Jobs'
end
unless staged.any? { |item| item['kind'] == 'ConfigMap' && item.dig('metadata', 'name') == 'migration-config' }
  abort 'renderer omitted a chart-managed migration ConfigMap'
end
if staged.any? { |item| %w[PersistentVolumeClaim ServiceAccount].include?(item['kind']) }
  abort 'renderer attempted to adopt externally managed dependencies'
end

missing_config_manifest = documents.reject { |item| item['kind'] == 'ConfigMap' }
  .map { |document| YAML.dump(document) }.join
_output, error, status = Open3.capture3(
  'ruby', renderer, 'foreman', 'foreman', stdin_data: missing_config_manifest
)
if status.success? || !error.include?('migration render is missing ConfigMap: migration-config')
  abort 'renderer accepted a missing chart-managed migration ConfigMap'
end

puts 'Migration staging accepts external PVCs and ServiceAccounts but requires chart ConfigMaps.'
