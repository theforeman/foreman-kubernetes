#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
dockerfile = (root / 'images/recovery-toolbox/Dockerfile').read
workflow = (root / '.github/workflows/recovery-image.yaml').read

unless dockerfile.match?(/^FROM alpine:3\.23\.6@sha256:[0-9a-f]{64}$/)
  abort 'recovery toolbox base image is not pinned to the reviewed Alpine manifest'
end

%w[ca-certificates jq kubectl postgresql18-client restic].each do |package|
  abort "recovery toolbox is missing #{package}" unless dockerfile.match?(/^\s+#{Regexp.escape(package)}(?:\s|\\|$)/)
end

abort 'recovery image workflow cannot publish packages' unless workflow.include?('packages: write')
abort 'recovery image workflow does not publish amd64 and arm64' unless workflow.include?('platforms: linux/amd64,linux/arm64')
%w[linux/amd64 linux/arm64].each do |platform|
  abort "recovery image workflow does not verify #{platform}" unless workflow.include?("platform: #{platform}")
end
abort 'recovery image workflow does not install emulation before cross-platform verification' unless workflow.include?('docker/setup-qemu-action@')
abort 'recovery image publication is not gated by platform verification' unless workflow.match?(/publish:\n(?:.|\n)*?needs: verify/)
abort 'recovery image workflow does not emit provenance' unless workflow.include?('provenance: mode=max')
abort 'recovery image workflow does not emit an SBOM' unless workflow.include?('sbom: true')
abort 'recovery image workflow does not report the immutable digest' unless workflow.include?('steps.publish.outputs.digest')
abort 'recovery toolbox image does not run as the recovery UID' unless dockerfile.include?("\nUSER 700:700\n")

%w[cmp jq kubectl pg_dump pg_restore restic sha256sum].each do |command|
  abort "recovery image workflow does not verify #{command}" unless workflow.include?(command)
end

puts 'Recovery toolbox build and publication contract passed.'
