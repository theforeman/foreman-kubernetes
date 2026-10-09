#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

root = File.expand_path('..', __dir__)
values = YAML.safe_load(File.read(File.join(root, 'tests/kind/values.yaml')), aliases: true)
plugins = values.dig('pulp', 'enabledPlugins')
abort 'kind integration profile does not enable pulp_deb' unless plugins.include?('pulp_deb')

dependencies = YAML.load_stream(File.read(File.join(root, 'tests/kind/dependencies.yaml'))).compact
fixture = dependencies.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source fixture' unless fixture

deployment = dependencies.find do |resource|
  resource['kind'] == 'Deployment' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source Deployment' unless deployment

pod_spec = deployment.dig('spec', 'template', 'spec')
builder = pod_spec.fetch('initContainers').find { |container| container['name'] == 'build-content-source' }
abort 'content source has no Debian repository builder' unless builder
builder_script = builder.fetch('command').last
required_builder_contracts = %w[
  debian-binary
  control.tar.gz
  data.tar.gz
  foreman-kubernetes-deb_1.0.0_all.deb
  dists/stable/main/binary-amd64/Packages
  dists/stable/Release
]
required_builder_contracts.each do |contract|
  abort "Debian repository builder is missing #{contract}" unless builder_script.include?(contract)
end

Dir.mktmpdir('foreman-kubernetes-debian-source') do |directory|
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
  abort "Debian fixture builder failed: #{stderr}" unless status.success?

  archive = File.join(
    served,
    'debian/pool/main/f/foreman-kubernetes-deb/foreman-kubernetes-deb_1.0.0_all.deb'
  )
  abort 'Debian fixture builder did not create its package' unless File.file?(archive)

  archive_data = File.binread(archive)
  abort 'generated Debian package has no ar signature' unless archive_data.start_with?("!<arch>\n")
  archive_members = {}
  offset = 8
  while offset < archive_data.bytesize
    header = archive_data.byteslice(offset, 60)
    abort 'generated Debian package has a truncated member header' unless header&.bytesize == 60
    abort 'generated Debian package has an invalid member header' unless header.end_with?("`\n")

    name = header.byteslice(0, 16).strip.sub(%r{/\z}, '')
    size = Integer(header.byteslice(48, 10).strip, 10)
    offset += 60
    member = archive_data.byteslice(offset, size)
    abort "generated Debian package has a truncated #{name} member" unless member&.bytesize == size
    archive_members[name] = member
    offset += size
    offset += 1 if size.odd?
  end

  missing_members = %w[debian-binary control.tar.gz data.tar.gz] - archive_members.keys
  unless missing_members.empty?
    abort "generated Debian package is missing #{missing_members.join(', ')}; found #{archive_members.keys.inspect}"
  end
  abort 'generated Debian package has the wrong format version' unless archive_members['debian-binary'] == "2.0\n"

  control_archive = File.join(directory, 'control.tar.gz')
  File.binwrite(control_archive, archive_members.fetch('control.tar.gz'))
  control, stderr, status = Open3.capture3('tar', '-xOzf', control_archive, './control')
  abort "cannot read generated Debian control metadata: #{stderr}" unless status.success?
  {
    'Package' => 'foreman-kubernetes-deb',
    'Version' => '1.0.0',
    'Architecture' => 'all'
  }.each do |field, expected|
    abort "generated Debian package has the wrong #{field}" unless control.include?("#{field}: #{expected}\n")
  end

  data_archive = File.join(directory, 'data.tar.gz')
  File.binwrite(data_archive, archive_members.fetch('data.tar.gz'))
  payload, stderr, status = Open3.capture3('tar', '-xOzf', data_archive,
                                           './usr/share/foreman-kubernetes/debian-fixture')
  abort "cannot read generated Debian package payload: #{stderr}" unless status.success?
  abort 'generated Debian package has the wrong payload' unless payload == "foreman-kubernetes-debian-fixture\n"

  packages_path = File.join(served, 'debian/dists/stable/main/binary-amd64/Packages')
  packages = File.read(packages_path)
  expected_package_fields = {
    'Package' => 'foreman-kubernetes-deb',
    'Version' => '1.0.0',
    'Architecture' => 'all',
    'Filename' => 'pool/main/f/foreman-kubernetes-deb/foreman-kubernetes-deb_1.0.0_all.deb',
    'Size' => File.size(archive).to_s,
    'SHA256' => Digest::SHA256.file(archive).hexdigest
  }
  expected_package_fields.each do |field, expected|
    abort "Debian Packages metadata has the wrong #{field}" unless packages.include?("#{field}: #{expected}\n")
  end

  compressed_packages = File.join(served, 'debian/dists/stable/main/binary-amd64/Packages.gz')
  decompressed, stderr, status = Open3.capture3('gzip', '-dc', compressed_packages)
  abort "cannot read compressed Debian Packages metadata: #{stderr}" unless status.success?
  abort 'compressed Debian Packages metadata differs from the source' unless decompressed == packages

  release = File.read(File.join(served, 'debian/dists/stable/Release'))
  {
    'main/binary-amd64/Packages' => packages_path,
    'main/binary-amd64/Packages.gz' => compressed_packages
  }.each do |relative_path, path|
    checksum_line = " #{Digest::SHA256.file(path).hexdigest} #{File.size(path)} #{relative_path}\n"
    abort "Debian Release metadata has the wrong checksum for #{relative_path}" unless release.include?(checksum_line)
  end
end

lifecycle = File.read(File.join(root, 'tests/kind/content-lifecycle.sh'))
required_lifecycle_contracts = [
  'content_type: "deb"',
  'deb_releases: "stable"',
  'deb_components: "main"',
  'deb_architectures: "amd64"',
  '/debs?per_page=1000',
  'published Debian package checksum',
  'published_deb_repository_id',
  'restored Debian package checksum'
]
required_lifecycle_contracts.each do |contract|
  abort "kind content lifecycle is missing #{contract}" unless lifecycle.include?(contract)
end

checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')
abort 'promotion evidence does not require the Debian content lifecycle' unless checks.include?('pulp-debian-lifecycle')

matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
debian = matrix.fetch('pulp').find { |plugin| plugin.fetch('name') == 'pulp_deb' }
unless debian.fetch('status') == 'integration-drill-implemented-unrun'
  abort 'Pulp Debian compatibility status does not reflect the implemented drill'
end

puts 'Kind integration covers Debian synchronization, publication, and restore.'
