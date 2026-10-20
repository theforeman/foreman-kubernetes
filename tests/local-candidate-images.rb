#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
registry = JSON.parse((root / 'compatibility/local-candidate-images.json').read)
contracts = JSON.parse((root / 'compatibility/upstream-contracts.json').read)
  .fetch('contracts').to_h { |contract| [contract.fetch('id'), contract] }
profile = YAML.safe_load((root / 'profiles/local-amd64-candidate.yaml').read)
release_profile = YAML.safe_load((root / 'profiles/nightly-candidate-2026-09-23.yaml').read)
execution_profile = YAML.safe_load((root / 'profiles/execution-proxy-local-amd64-candidate.yaml').read)
execution_release_profile = YAML.safe_load((root / 'profiles/execution-proxy-nightly-candidate-2026-09-24.yaml').read)

abort 'unsupported local candidate schema' unless registry.fetch('schemaVersion') == 1
abort 'local candidate pipeline must be native amd64' unless registry.fetch('platform') == 'linux/amd64'
expected_components = %w[candlepin execution-proxy foreman pulp]
abort 'local candidate pipeline must cover every runtime image' unless registry.fetch('images').keys.sort == expected_components

seen_contracts = []
registry.fetch('images').each do |component, image|
  base = image.fetch('baseReference')
  abort "#{component} local candidate base is not digest-pinned" unless base.match?(/@sha256:[0-9a-f]{64}\z/)
  release_image = if component == 'execution-proxy'
                    execution_release_profile.fetch('image')
                  else
                    release_profile.fetch(component).fetch('image')
                  end
  expected_base = "#{release_image.fetch('repository')}:#{release_image.fetch('tag')}"
  abort "#{component} local candidate base differs from the release profile" unless base == expected_base

  local = image.fetch('localReference')
  local_image = component == 'execution-proxy' ? execution_profile.fetch('image') : profile.fetch(component).fetch('image')
  expected_local = "#{local_image.fetch('repository')}:#{local_image.fetch('tag')}"
  abort "#{component} profile differs from the build registry" unless local == expected_local
  abort "#{component} local candidate must not pull from a registry" unless local_image.fetch('pullPolicy') == 'Never'

  overlays = Array(image['overlays'])
  ids = overlays.map { |overlay| overlay.fetch('contract') } + Array(image['contracts'])
  ids.each do |id|
    contract = contracts.fetch(id) { abort "unknown local candidate contract: #{id}" }
    abort "published contract is unexpectedly overlaid: #{id}" if contract.fetch('state') == 'published'
    seen_contracts << id
  end
  overlays.each do |overlay|
    allowed_targets = %w[foreman katello candlepin pulp_smart_proxy smart_proxy_remote_execution_ssh]
    abort 'unsupported overlay target' unless allowed_targets.include?(overlay.fetch('target'))
    overlay.fetch('paths').each do |source_path|
      path = Pathname.new(source_path)
      abort "unsafe overlay path: #{source_path}" if path.absolute? || path.each_filename.include?('..')
      abort "test-only path leaked into a runtime image: #{source_path}" if source_path.start_with?('test/', 'tests/', '.github/')
    end
  end
end

abort 'local candidate contracts are duplicated' unless seen_contracts == seen_contracts.uniq
required = contracts.values.select { |contract| !(contract.fetch('profiles') & %w[default object-storage]).empty? }
  .map { |contract| contract.fetch('id') }
missing = required - seen_contracts
abort "local candidate pipeline omits required contracts: #{missing.join(', ')}" unless missing.empty?

pulp_requirements = registry.dig('images', 'pulp', 'pythonRequirements')
expected_python_packages = %w[boto3 botocore django-storages jmespath s3transfer]
actual_python_packages = pulp_requirements.map { |requirement| requirement.split('==', 2).first }.sort
abort 'Pulp candidate does not pin the complete S3 client chain' unless actual_python_packages == expected_python_packages
unless pulp_requirements.all? { |requirement| requirement.match?(/ --hash=sha256:[0-9a-f]{64}\z/) }
  abort 'Pulp candidate contains an unhashed Python requirement'
end

node_selector = profile.dig('scheduling', 'nodeSelector')
abort 'local candidate profile does not require amd64 nodes' unless node_selector == {'kubernetes.io/arch' => 'amd64'}
execution_node_selector = execution_profile.dig('scheduling', 'nodeSelector')
abort 'local execution-proxy profile does not require amd64 nodes' unless execution_node_selector == {'kubernetes.io/arch' => 'amd64'}
builder = (root / 'scripts/build-local-candidate-images.rb').read
unless builder.include?("'--file', (directory / 'Containerfile').to_s")
  abort 'candidate builder does not explicitly select the generated Containerfile'
end
unless builder.include?("image['rootfsDiffIds']") && builder.include?("image['kindRuntime']")
  abort 'candidate builder does not retain portable and Kind runtime image identities'
end

puts "Local candidate images cover #{seen_contracts.length} unpublished runtime contracts."
