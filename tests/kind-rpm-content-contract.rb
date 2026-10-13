#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rexml/document'
require 'tmpdir'
require 'yaml'

root = File.expand_path('..', __dir__)
values = YAML.safe_load(File.read(File.join(root, 'tests/kind/values.yaml')), aliases: true)
plugins = values.dig('pulp', 'enabledPlugins')
abort 'kind integration profile does not enable pulp_rpm' unless plugins.include?('pulp_rpm')

dependencies = YAML.load_stream(File.read(File.join(root, 'tests/kind/dependencies.yaml'))).compact
fixture = dependencies.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source fixture' unless fixture

rpm_data = fixture.fetch('binaryData', {}).fetch('rpm-squirrel.rpm', nil)
abort 'content source has no embedded RPM fixture' unless rpm_data
rpm_fixture = Base64.strict_decode64(rpm_data)
rpm_checksum = '251768bdd15f13d78487c27638aa6aecd01551e253756093cde1c0ae878a17d2'
abort 'embedded RPM fixture has the wrong checksum' unless Digest::SHA256.hexdigest(rpm_fixture) == rpm_checksum
abort 'embedded RPM fixture has the wrong lead magic' unless rpm_fixture.start_with?("\xed\xab\xee\xdb".b)

deployment = dependencies.find do |resource|
  resource['kind'] == 'Deployment' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source Deployment' unless deployment

pod_spec = deployment.dig('spec', 'template', 'spec')
builder = pod_spec.fetch('initContainers').find { |container| container['name'] == 'build-content-source' }
abort 'content source has no RPM repository builder' unless builder
builder_script = builder.fetch('command').last
required_builder_contracts = %w[
  rpm-squirrel.rpm
  squirrel-0.3-0.8.noarch.rpm
  primary.xml
  filelists.xml
  other.xml
  repodata/repomd.xml
]
required_builder_contracts.each do |contract|
  abort "RPM repository builder is missing #{contract}" unless builder_script.include?(contract)
end

Dir.mktmpdir('foreman-kubernetes-rpm-source') do |directory|
  source = File.join(directory, 'source')
  served = File.join(directory, 'served')
  temporary = File.join(directory, 'tmp')
  FileUtils.mkdir_p([source, served, temporary])
  fixture.fetch('data').each do |name, contents|
    File.binwrite(File.join(source, name), contents)
  end
  fixture.fetch('binaryData', {}).each do |name, contents|
    File.binwrite(File.join(source, name), Base64.strict_decode64(contents))
  end

  test_script = builder_script.gsub('/source', source).gsub('/served', served)
  _stdout, stderr, status = Open3.capture3({'TMPDIR' => temporary}, '/bin/sh', '-ec', test_script)
  abort "RPM fixture builder failed: #{stderr}" unless status.success?

  package = File.join(served, 'rpm/squirrel-0.3-0.8.noarch.rpm')
  abort 'RPM fixture builder did not create its package' unless File.file?(package)
  abort 'served RPM fixture has the wrong checksum' unless Digest::SHA256.file(package).hexdigest == rpm_checksum

  repodata = File.join(served, 'rpm/repodata')
  repomd = File.read(File.join(repodata, 'repomd.xml'))
  REXML::Document.new(repomd)
  {
    'primary' => [
      '<name>squirrel</name>',
      '<version epoch="0" ver="0.3" rel="0.8"/>',
      "<checksum type=\"sha256\" pkgid=\"YES\">#{rpm_checksum}</checksum>",
      '<location href="squirrel-0.3-0.8.noarch.rpm"/>'
    ],
    'filelists' => [
      "pkgid=\"#{rpm_checksum}\" name=\"squirrel\" arch=\"noarch\"",
      '<file>/squirrel.txt</file>'
    ],
    'other' => [
      "pkgid=\"#{rpm_checksum}\" name=\"squirrel\" arch=\"noarch\""
    ]
  }.each do |type, contracts|
    metadata_files = Dir.glob(File.join(repodata, "*-#{type}.xml.gz"))
    abort "RPM fixture has the wrong number of #{type} metadata files" unless metadata_files.length == 1
    metadata_file = metadata_files.first
    metadata, stderr, status = Open3.capture3('gzip', '-dc', metadata_file)
    abort "cannot read RPM #{type} metadata: #{stderr}" unless status.success?
    REXML::Document.new(metadata)
    contracts.each do |contract|
      abort "RPM #{type} metadata is missing #{contract}" unless metadata.include?(contract)
    end

    compressed_checksum = Digest::SHA256.file(metadata_file).hexdigest
    open_checksum = Digest::SHA256.hexdigest(metadata)
    location = "repodata/#{File.basename(metadata_file)}"
    abort "RPM repomd is missing #{type} metadata" unless repomd.include?("<data type=\"#{type}\">")
    abort "RPM repomd has the wrong #{type} checksum" unless repomd.include?(
      "<checksum type=\"sha256\">#{compressed_checksum}</checksum>"
    )
    abort "RPM repomd has the wrong open #{type} checksum" unless repomd.include?(
      "<open-checksum type=\"sha256\">#{open_checksum}</open-checksum>"
    )
    abort "RPM repomd has the wrong #{type} location" unless repomd.include?(
      "<location href=\"#{location}\"/>"
    )
  end
end

lifecycle = File.read(File.join(root, 'tests/kind/content-lifecycle.sh'))
required_lifecycle_contracts = [
  'content_type: "yum"',
  'url: "http://content-source/rpm/"',
  '/packages?per_page=1000',
  'published RPM package checksum',
  'published_rpm_repository_id',
  'restored RPM package checksum'
]
required_lifecycle_contracts.each do |contract|
  abort "kind content lifecycle is missing #{contract}" unless lifecycle.include?(contract)
end

checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')
abort 'promotion evidence does not require the RPM content lifecycle' unless checks.include?('pulp-rpm-lifecycle')

matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
rpm = matrix.fetch('pulp').find { |plugin| plugin.fetch('name') == 'pulp_rpm' }
unless rpm.fetch('status') == 'integration-drill-implemented-unrun'
  abort 'Pulp RPM compatibility status does not reflect the implemented drill'
end

puts 'Kind integration covers RPM synchronization, publication, and restore.'
