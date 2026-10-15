# frozen_string_literal: true

require 'yaml'
require 'digest'

abort "usage: #{$PROGRAM_NAME} RENDER" unless ARGV.length == 1

def pulp_checksums(path)
  YAML.load_stream(File.read(path)).compact.each_with_object({}) do |document, checksums|
    next unless document['kind'] == 'Deployment'

    component = document.dig('metadata', 'labels', 'app.kubernetes.io/component')
    next unless %w[pulp-api pulp-content pulp-worker].include?(component)

    checksums[component] = document.dig('spec', 'template', 'metadata', 'annotations', 'checksum/health')
  end
end

files = File.expand_path('../charts/foreman-stack/files', __dir__)
expected = {
  'pulp-api' => Digest::SHA256.hexdigest(File.binread(File.join(files, 'pulp-readiness.py'))),
  'pulp-content' => Digest::SHA256.hexdigest(File.binread(File.join(files, 'pulp-app-readiness.py'))),
  'pulp-worker' => Digest::SHA256.hexdigest(File.binread(File.join(files, 'pulp-app-readiness.py'))),
}
actual = pulp_checksums(ARGV.fetch(0))
abort "Pulp health-script coverage is incomplete: #{actual.keys.sort.join(', ')}" unless actual.keys.sort == expected.keys.sort

wrong = expected.keys.select { |component| actual[component] != expected[component] }
abort "Pulp health-script checksum is stale for: #{wrong.join(', ')}" unless wrong.empty?

puts 'Pulp readiness script changes replace exactly the affected long-running pods.'
