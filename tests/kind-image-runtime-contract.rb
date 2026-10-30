#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

root = File.expand_path('..', __dir__)
checker = File.read(File.join(root, 'tests/kind/image-runtime-contract.rb'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
workflow = File.read(File.join(root, '.github/workflows/integration.yaml'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

%w[foreman pulp-api candlepin foreman-proxy].each do |container|
  abort "runtime image contract omits #{container}" unless checker.include?("container: '#{container}'")
end
%w[FOREMAN_ENABLED_PLUGINS PULP_ENABLED_PLUGINS FOREMAN_PROXY_ENABLED_PLUGINS].each do |variable|
  abort "runtime image contract omits #{variable}" unless checker.include?(variable)
end
%w[runtimeImageId expectedImage packagedPlugins enabledPlugins versions].each do |field|
  abort "runtime image evidence omits #{field}" unless checker.include?("'#{field}'")
end
abort 'runtime image contract does not compare the kubelet image ID with the pinned digest' unless checker.include?('actual_image_id.include?("@#{digest}")')
abort 'runtime image contract uses unsupported MatchData#fetch' if checker.include?('match.fetch(1)')
abort 'runtime image contract does not extract the captured digest' unless checker.include?('match[1]')
abort 'runtime image contract does not accept authenticated local candidate evidence' unless checker.include?("ENV['LOCAL_CANDIDATE_EVIDENCE_FILE']")
abort 'runtime image contract does not bind local candidates to their recorded image ID' unless checker.include?("candidate.fetch('imageId')")
abort 'runtime image contract does not bind imported candidates by rootfs identity' unless checker.include?("candidate.fetch('rootfsDiffIds')")
abort 'runtime image contract does not require the evidenced Kind manifest' unless checker.include?("identity.fetch('repoDigests').include?(actual_image_id)")
abort 'runtime image contract does not reject root containers' unless checker.include?("actual_uid == '0'")
kind_value_precedence = harness.scan(
  /--values "\$\{repo_root\}\/examples\/execution-control-plane-values\.yaml" \\\n+\s+--values "\$\{repo_root\}\/tests\/kind\/values\.yaml"/
)
unless kind_value_precedence.length == 3
  abort 'Kind values must override the narrower execution control-plane plugin list'
end
abort 'Kind harness does not execute the runtime image contract' unless harness.include?('tests/kind/image-runtime-contract.rb')
abort 'promotion evidence does not require the runtime image contract' unless checks.include?('pinned-image-runtime-contract')
abort 'CI does not retain the runtime image report' unless workflow.include?('artifacts/image-runtime-contract.json')

puts 'Full integration verifies exact image digests, identities, executables, and plugin inventories.'
