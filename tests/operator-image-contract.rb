#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
dockerfile = root.join('images/release-operator/Dockerfile').read
workflow = root.join('.github/workflows/operator-image.yaml').read

unless dockerfile.match?(/^FROM alpine:3\.23\.6@sha256:[0-9a-f]{64}$/)
  abort 'release operator base image is not pinned to the reviewed Alpine manifest'
end
%w[ca-certificates helm kubectl ruby].each do |package|
  abort "release operator image is missing #{package}" unless dockerfile.match?(/^\s+#{package}(?:\s|\\|$)/)
end
%w[charts compatibility operator profiles].each do |directory|
  abort "release operator image does not include #{directory}" unless dockerfile.include?("COPY --chown=1000:1000 #{directory} ")
end
abort 'release operator image does not run as the unprivileged UID' unless dockerfile.include?("\nUSER 1000:1000\n")
abort 'release operator image has the wrong entry point' unless dockerfile.include?('operator/bin/foreman-release-controller"]')

abort 'operator workflow cannot publish packages' unless workflow.include?('packages: write')
abort 'operator workflow does not publish amd64 and arm64' unless workflow.include?('platforms: linux/amd64,linux/arm64')
%w[linux/amd64 linux/arm64].each do |platform|
  abort "operator workflow does not verify #{platform}" unless workflow.include?("platform: #{platform}")
end
abort 'operator workflow does not install emulation before cross-platform verification' unless workflow.include?('docker/setup-qemu-action@')
abort 'operator image publication is not gated by platform verification' unless workflow.match?(/publish:\n(?:.|\n)*?needs: verify/)
abort 'operator workflow does not emit provenance' unless workflow.include?('provenance: mode=max')
abort 'operator workflow does not emit an SBOM' unless workflow.include?('sbom: true')
abort 'operator workflow does not report the immutable digest' unless workflow.include?('steps.publish.outputs.digest')
%w[ruby helm kubectl].each do |command|
  abort "operator workflow does not verify #{command}" unless workflow.include?(command)
end

puts 'Release operator image build and publication contract passed.'
