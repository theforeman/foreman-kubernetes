#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'yaml'

unless ARGV.length == 4
  abort 'usage: verify-release-image-platforms.rb OUTPUT SET APPLICATION_PROFILE EXECUTION_PROFILE'
end

root = Pathname.new(File.expand_path('..', __dir__))
output = Pathname.new(File.expand_path(ARGV.fetch(0)))
set_name = ARGV.fetch(1)
application_profile_path = Pathname.new(File.expand_path(ARGV.fetch(2)))
execution_profile_path = Pathname.new(File.expand_path(ARGV.fetch(3)))
release_sets = JSON.parse((root / 'compatibility/release-sets.json').read)
release_set = release_sets.fetch('sets').fetch(set_name)
expected_platform = release_set.fetch('platform')
application_profile = YAML.safe_load(application_profile_path.read)
execution_profile = YAML.safe_load(execution_profile_path.read)
inspector = ENV.fetch('IMAGE_INSPECTOR', 'docker')
local_candidate_file = ENV['LOCAL_CANDIDATE_EVIDENCE_FILE']
local_candidate = if local_candidate_file
                    JSON.parse(Pathname.new(File.expand_path(local_candidate_file)).read)
                  end

images = %w[foreman candlepin pulp].map do |component|
  [component, application_profile.fetch(component).fetch('image')]
end
images << ['execution-proxy', execution_profile.fetch('image')]

verified = images.map do |component, image|
  reference = "#{image.fetch('repository')}:#{image.fetch('tag')}"
  immutable = reference.match?(/@sha256:[0-9a-f]{64}\z/)
  if immutable
    stdout, stderr, status = Open3.capture3(
      inspector,
      'buildx',
      'imagetools',
      'inspect',
      '--format',
      '{{.Image.OS}}/{{.Image.Architecture}}',
      reference
    )
    unless status.success?
      abort "unable to inspect #{component} image #{reference}: #{stderr.strip}"
    end
    actual_platform = stdout.strip
    source = 'registry-manifest'
    image_id = nil
  else
    abort "#{component} image is not digest-pinned: #{reference}" unless local_candidate
    abort 'local candidate evidence must describe built images' unless local_candidate.fetch('mode') == 'built'
    candidate = local_candidate.fetch('images').find do |entry|
      entry.fetch('component') == component && entry.fetch('localReference') == reference
    end
    abort "local candidate evidence does not cover #{component} image #{reference}" unless candidate

    stdout, stderr, status = Open3.capture3(inspector, 'image', 'inspect', reference)
    abort "unable to inspect local #{component} image #{reference}: #{stderr.strip}" unless status.success?
    inspection = JSON.parse(stdout).first
    actual_platform = "#{inspection.fetch('Os')}/#{inspection.fetch('Architecture')}"
    image_id = inspection.fetch('Id')
    abort "local #{component} image ID differs from its evidence" unless image_id == candidate.fetch('imageId')
    labels = inspection.dig('Config', 'Labels') || {}
    unless labels['org.theforeman.kubernetes.unpublished'] == 'true'
      abort "local #{component} image is missing its unpublished-candidate label"
    end
    source = 'local-candidate'
  end
  unless actual_platform == expected_platform
    abort "#{component} image platform is #{actual_platform.inspect}, expected #{expected_platform}"
  end

  {
    'component' => component,
    'reference' => reference,
    'platform' => actual_platform,
    'source' => source,
    'imageId' => image_id
  }
end

report = {
  'schemaVersion' => 1,
  'compatibilitySet' => set_name,
  'expectedPlatform' => expected_platform,
  'qualificationEligible' => verified.all? { |image| image.fetch('source') == 'registry-manifest' },
  'images' => verified
}

FileUtils.mkdir_p(output.dirname)
temporary_output = Pathname.new("#{output}.tmp.#{Process.pid}")
begin
  temporary_output.write("#{JSON.pretty_generate(report)}\n")
  File.rename(temporary_output, output)
ensure
  temporary_output.delete if temporary_output.exist?
end

puts "Verified #{verified.length} image manifests for #{expected_platform}."
