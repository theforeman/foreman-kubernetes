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
abort 'kind integration profile does not enable pulp_python' unless plugins.include?('pulp_python')

dependencies = YAML.load_stream(File.read(File.join(root, 'tests/kind/dependencies.yaml'))).compact
fixture = dependencies.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source fixture' unless fixture

required_fixture_keys = %w[
  PULP_MANIFEST
  foreman-kubernetes-content.txt
  python-PKG-INFO
  python-setup.py
  python-module.py
  nginx.conf
]
missing_fixture_keys = required_fixture_keys - fixture.fetch('data').keys
abort "Python content source is missing #{missing_fixture_keys.join(', ')}" unless missing_fixture_keys.empty?

deployment = dependencies.find do |resource|
  resource['kind'] == 'Deployment' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source Deployment' unless deployment

pod_spec = deployment.dig('spec', 'template', 'spec')
builder = pod_spec.fetch('initContainers').find { |container| container['name'] == 'build-content-source' }
abort 'content source has no Python package builder' unless builder
builder_script = builder.fetch('command').last
%w[PKG-INFO setup.py sha256sum simple/foreman-kubernetes-pkg pypi/foreman-kubernetes-pkg/json].each do |contract|
  abort "Python package builder is missing #{contract}" unless builder_script.include?(contract)
end

volumes = pod_spec.fetch('volumes').to_h { |volume| [volume.fetch('name'), volume] }
abort 'content source does not mount its fixture ConfigMap separately' unless volumes.dig('source', 'configMap', 'name') == 'content-source'
abort 'content source generated content is not ephemeral' unless volumes.dig('content', 'emptyDir') == {}
server = pod_spec.fetch('containers').find { |container| container['name'] == 'nginx' }
server_mounts = server.fetch('volumeMounts').to_h { |mount| [mount.fetch('mountPath'), mount] }
unless server_mounts.dig('/etc/nginx/conf.d/default.conf', 'subPath') == 'nginx.conf'
  abort 'content source does not mount its PyPI-aware Nginx configuration'
end
unless fixture.dig('data', 'nginx.conf').include?('default_type application/json')
  abort 'content source does not identify PyPI JSON metadata correctly'
end

Dir.mktmpdir('foreman-kubernetes-python-source') do |directory|
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
  abort "Python fixture builder failed: #{stderr}" unless status.success?

  archive = File.join(served, 'packages', 'foreman_kubernetes_pkg-1.0.0.tar.gz')
  metadata = JSON.parse(File.read(File.join(served, 'pypi', 'foreman-kubernetes-pkg', 'json')))
  abort 'generated PyPI metadata has the wrong package name' unless metadata.dig('info', 'name') == 'foreman-kubernetes-pkg'
  release = metadata.dig('releases', '1.0.0', 0)
  abort 'generated PyPI metadata has the wrong filename' unless release['filename'] == File.basename(archive)
  unless release.dig('digests', 'sha256') == Digest::SHA256.file(archive).hexdigest
    abort 'generated PyPI metadata checksum does not match its package'
  end

  _stdout, stderr, status = Open3.capture3('tar', '-tzf', archive)
  abort "generated Python source distribution is unreadable: #{stderr}" unless status.success?
end

lifecycle = File.read(File.join(root, 'tests/kind/content-lifecycle.sh'))
required_lifecycle_contracts = [
  'content_type: "python"',
  '/python_packages?per_page=1000',
  '/pypi/${normalized_path}/simple/${python_package_name}/',
  'published Python package checksum',
  'published_python_repository_id',
  'restored Python package checksum metadata'
]
required_lifecycle_contracts.each do |contract|
  abort "kind content lifecycle is missing #{contract}" unless lifecycle.include?(contract)
end

checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')
abort 'promotion evidence does not require the Python content lifecycle' unless checks.include?('pulp-python-lifecycle')

matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
python = matrix.fetch('pulp').find { |plugin| plugin.fetch('name') == 'pulp_python' }
unless python.fetch('status') == 'integration-drill-implemented-unrun'
  abort 'Pulp Python compatibility status does not reflect the implemented drill'
end

puts 'Kind integration covers Python synchronization, publication, download, and restore.'
