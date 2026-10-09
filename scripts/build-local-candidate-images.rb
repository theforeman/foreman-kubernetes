#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'time'

class LocalCandidateImages
  def initialize(root:, upstream_root:, context_root:, engine:, build:, kind_cluster: nil, prepared: nil)
    @root = root
    @upstream_root = upstream_root
    @context_root = context_root
    @engine = engine
    @build = build
    @kind_cluster = kind_cluster
    @prepared = prepared
    @registry = JSON.parse((root / 'compatibility/local-candidate-images.json').read)
    contracts = JSON.parse((root / 'compatibility/upstream-contracts.json').read).fetch('contracts')
    @contracts = contracts.to_h { |contract| [contract.fetch('id'), contract] }
  end

  def call
    validate_registry!
    images = prepared_images || prepare_images
    build_images(images) if build?

    {
      'schemaVersion' => 1,
      'generatedAt' => Time.now.utc.iso8601,
      'platform' => registry.fetch('platform'),
      'mode' => build? ? 'built' : 'prepared',
      'repositoryCommit' => capture!('git', '-C', root.to_s, 'rev-parse', 'HEAD').strip,
      'images' => images
    }
  end

  private

  attr_reader :root, :upstream_root, :context_root, :engine, :registry, :contracts,
              :kind_cluster, :prepared

  def build?
    @build
  end

  def prepare_images
    FileUtils.rm_rf(context_root)
    FileUtils.mkdir_p(context_root)
    registry.fetch('images').map do |name, definition|
      prepare_image(name, definition)
    end
  end

  def prepared_images
    return unless prepared

    document = JSON.parse(prepared.read)
    raise 'prepared candidate evidence is not in prepared mode' unless document.fetch('mode') == 'prepared'
    raise 'prepared candidate platform does not match the registry' unless document.fetch('platform') == registry.fetch('platform')

    images = document.fetch('images')
    expected_components = registry.fetch('images').keys.sort
    unless images.map { |image| image.fetch('component') }.sort == expected_components
      raise 'prepared candidate evidence does not contain the configured components'
    end
    images.each do |image|
      directory = root / image.fetch('contextDirectory')
      raise "prepared context is missing: #{directory}" unless directory.directory?
      unless context_digest(directory) == image.fetch('contextSha256')
        raise "prepared context digest changed for #{image.fetch('component')}"
      end
      definition = registry.fetch('images').fetch(image.fetch('component'))
      unless image.fetch('baseReference') == definition.fetch('baseReference') &&
             image.fetch('localReference') == definition.fetch('localReference')
        raise "prepared references changed for #{image.fetch('component')}"
      end
    end
    images
  end

  def validate_registry!
    raise 'unsupported local candidate image schema' unless registry.fetch('schemaVersion') == 1
    raise 'local candidate images are currently qualified only on linux/amd64' unless registry.fetch('platform') == 'linux/amd64'
    expected = %w[candlepin execution-proxy foreman pulp]
    raise 'candidate image registry must contain foreman, execution-proxy, candlepin, and pulp' unless registry.fetch('images').keys.sort == expected

    referenced = registry.fetch('images').values.flat_map do |definition|
      Array(definition['overlays']).map { |overlay| overlay.fetch('contract') } + Array(definition['contracts'])
    end
    raise 'candidate image contracts must not be duplicated' unless referenced == referenced.uniq

    referenced.each do |contract_id|
      contract = contracts.fetch(contract_id) { raise "unknown upstream contract: #{contract_id}" }
      raise "published contract does not belong in a local candidate image: #{contract_id}" if contract.fetch('state') == 'published'
    end
  end

  def prepare_image(name, definition)
    directory = context_root / name
    FileUtils.mkdir_p(directory)
    contract_ids = []

    Array(definition['overlays']).each do |overlay|
      contract_id = overlay.fetch('contract')
      contract_ids << contract_id
      export_overlay(directory, overlay, contracts.fetch(contract_id))
    end
    contract_ids.concat(Array(definition['contracts']))

    containerfile = containerfile_for(name, definition, contract_ids)
    (directory / 'Containerfile').write(containerfile)
    (directory / 'Containerfile').chmod(0o644)

    source_commits = contract_ids.to_h do |contract_id|
      [contract_id, contracts.fetch(contract_id).fetch('upstream').fetch('commit')]
    end
    {
      'component' => name,
      'baseReference' => definition.fetch('baseReference'),
      'localReference' => definition.fetch('localReference'),
      'contracts' => source_commits,
      'contextSha256' => context_digest(directory),
      'contextDirectory' => directory.relative_path_from(root).to_s
    }
  end

  def export_overlay(directory, overlay, contract)
    upstream = contract.fetch('upstream')
    repository = upstream_root / upstream.fetch('localPath')
    commit = upstream.fetch('commit')
    raise "missing local upstream repository for #{contract.fetch('id')}: #{repository}" unless (repository / '.git').exist?

    resolved = capture!('git', '-C', repository.to_s, 'rev-parse', "#{commit}^{commit}").strip
    raise "upstream commit mismatch for #{contract.fetch('id')}" unless resolved == commit

    branch = capture!('git', '-C', repository.to_s, 'rev-parse', "refs/heads/#{upstream.fetch('branch')}").strip
    raise "local upstream branch is stale for #{contract.fetch('id')}" unless branch == commit

    overlay.fetch('paths').each do |source_path|
      reject_unsafe_path!(source_path)
      mode = capture!('git', '-C', repository.to_s, 'ls-tree', commit, '--', source_path).split.first
      raise "missing #{source_path} in #{contract.fetch('id')}" unless mode

      destination = directory / overlay.fetch('target') / source_path
      FileUtils.mkdir_p(destination.dirname)
      content = capture_binary!('git', '-C', repository.to_s, 'show', "#{commit}:#{source_path}")
      destination.binwrite(content)
      destination.chmod(mode == '100755' ? 0o755 : 0o644)
    end
  end

  def reject_unsafe_path!(source_path)
    pathname = Pathname.new(source_path)
    raise "candidate overlay path must be relative: #{source_path}" if pathname.absolute?
    raise "candidate overlay path escapes its context: #{source_path}" if pathname.each_filename.include?('..')
  end

  def containerfile_for(name, definition, contract_ids)
    contracts_label = contract_ids.join(',')
    base_reference = definition.fetch('baseReference')
    case name
    when 'foreman'
      <<~CONTAINERFILE
        ARG BASE_IMAGE=#{base_reference}
        FROM ${BASE_IMAGE}
        USER 0
        COPY --chown=994:994 foreman/ /usr/share/foreman/
        COPY katello/ /tmp/katello-candidate-overlay/
        RUN set -eu; \
            katello_root="$(ruby -e 'require "rubygems"; print Gem::Specification.find_by_name("katello").full_gem_path')"; \
            cp -a /tmp/katello-candidate-overlay/. "${katello_root}/"; \
            chown -R 994:994 "${katello_root}"; \
            rm -rf /tmp/katello-candidate-overlay
        LABEL org.opencontainers.image.title="Foreman Kubernetes local candidate" \
              org.theforeman.kubernetes.contracts="#{contracts_label}" \
              org.theforeman.kubernetes.unpublished="true"
        USER 994:994
      CONTAINERFILE
    when 'candlepin'
      <<~CONTAINERFILE
        ARG BASE_IMAGE=#{base_reference}
        FROM ${BASE_IMAGE}
        USER 0
        COPY --chmod=0755 candlepin/images/candlepin/assets/candlepin-db-migrate /usr/local/bin/candlepin-db-migrate
        LABEL org.opencontainers.image.title="Candlepin Kubernetes local candidate" \
              org.theforeman.kubernetes.contracts="#{contracts_label}" \
              org.theforeman.kubernetes.unpublished="true"
        USER 53:53
      CONTAINERFILE
    when 'execution-proxy'
      <<~CONTAINERFILE
        ARG BASE_IMAGE=#{base_reference}
        FROM ${BASE_IMAGE}
        USER 0
        COPY smart_proxy_remote_execution_ssh/ /tmp/smart-proxy-rex-candidate-overlay/
        RUN set -eu; \
            plugin_root="$(ruby -e 'require "rubygems"; print Gem::Specification.find_by_name("smart_proxy_remote_execution_ssh").full_gem_path')"; \
            cp -a /tmp/smart-proxy-rex-candidate-overlay/. "${plugin_root}/"; \
            chown -R 0:0 "${plugin_root}"; \
            rm -rf /tmp/smart-proxy-rex-candidate-overlay
        LABEL org.opencontainers.image.title="Foreman execution-proxy Kubernetes local candidate" \
              org.theforeman.kubernetes.contracts="#{contracts_label}" \
              org.theforeman.kubernetes.unpublished="true"
        USER 991:991
      CONTAINERFILE
    when 'pulp'
      requirements = definition.fetch('pythonRequirements')
      (context_root / name / 'requirements.txt').write("#{requirements.join("\n")}\n")
      rpm_packages = definition.fetch('rpmRequirements').join(' ')
      expected_versions = requirements.to_h do |requirement|
        package, remainder = requirement.split('==', 2)
        [package, remainder.split.first]
      end
      <<~CONTAINERFILE
        ARG BASE_IMAGE=#{base_reference}
        FROM ${BASE_IMAGE}
        USER 0
        COPY pulp_smart_proxy/pulp_smart_proxy/ /tmp/pulp-smart-proxy-candidate-overlay/
        COPY requirements.txt /tmp/foreman-kubernetes-requirements.txt
        RUN set -eu; \
            pulp_smart_proxy_root="$(python3 -c 'import inspect, os, pulp_smart_proxy; print(os.path.dirname(inspect.getfile(pulp_smart_proxy)))')"; \
            cp -a /tmp/pulp-smart-proxy-candidate-overlay/. "${pulp_smart_proxy_root}/"; \
            chown -R 700:700 "${pulp_smart_proxy_root}"; \
            rm -rf /tmp/pulp-smart-proxy-candidate-overlay; \
            dnf install --assumeyes --setopt=install_weak_deps=False #{rpm_packages} \
            && python3 -m pip install \
              --break-system-packages \
              --disable-pip-version-check \
              --no-cache-dir \
              --no-deps \
              --require-hashes \
              --requirement /tmp/foreman-kubernetes-requirements.txt \
            && python3 -c 'import importlib.metadata as m; expected=#{JSON.generate(expected_versions)}; assert all(m.version(package) == version for package, version in expected.items()); from storages.backends.s3 import S3Storage; import boto3; assert S3Storage and boto3' \
            && rm -f /tmp/foreman-kubernetes-requirements.txt \
            && dnf clean all \
            && rm -rf /root/.cache /var/cache/dnf
        LABEL org.opencontainers.image.title="Pulp Kubernetes local candidate" \
              org.theforeman.kubernetes.contracts="#{contracts_label}" \
              org.theforeman.kubernetes.unpublished="true"
        USER 700:700
      CONTAINERFILE
    else
      raise "unsupported candidate image component: #{name}"
    end
  end

  def context_digest(directory)
    digest = Digest::SHA256.new
    directory.glob('**/*', File::FNM_DOTMATCH).select(&:file?).sort.each do |entry|
      relative = entry.relative_path_from(directory).to_s
      digest << relative << "\0" << format('%o', entry.stat.mode & 0o777) << "\0"
      digest << entry.binread << "\0"
    end
    digest.hexdigest
  end

  def build_images(images)
    server = capture!(engine, 'version', '--format', '{{.Server.Os}}/{{.Server.Arch}}').strip
    raise "candidate images require a linux/amd64 engine, got #{server}" unless server == 'linux/amd64'

    images.each do |image|
      directory = root / image.fetch('contextDirectory')
      run!(
        engine,
        'build',
        '--platform', registry.fetch('platform'),
        '--file', (directory / 'Containerfile').to_s,
        '--build-arg', "BASE_IMAGE=#{image.fetch('baseReference')}",
        '--tag', image.fetch('localReference'),
        directory.to_s
      )
      inspection = JSON.parse(capture!(engine, 'image', 'inspect', image.fetch('localReference'))).first
      actual_platform = "#{inspection.fetch('Os')}/#{inspection.fetch('Architecture')}"
      raise "built #{image.fetch('component')} for #{actual_platform}" unless actual_platform == registry.fetch('platform')
      labels = inspection.dig('Config', 'Labels') || {}
      raise "#{image.fetch('component')} is missing its unpublished-candidate label" unless labels['org.theforeman.kubernetes.unpublished'] == 'true'

      image['imageId'] = inspection.fetch('Id')
      image['repoDigests'] = Array(inspection['RepoDigests']).sort
      image['rootfsDiffIds'] = inspection.dig('RootFS', 'Layers')
      unless image.fetch('rootfsDiffIds').all? { |digest| digest.match?(/\Asha256:[0-9a-f]{64}\z/) }
        raise "#{image.fetch('component')} has invalid rootfs layer identities"
      end
      image['builtPlatform'] = actual_platform
      if kind_cluster
        load_into_kind(image.fetch('localReference'))
        image['kindRuntime'] = inspect_kind_runtime(image)
      end
    end
  end

  def load_into_kind(reference)
    run!('kind', 'load', 'docker-image', '--name', kind_cluster, reference)
  end

  def inspect_kind_runtime(image)
    node = capture!('kind', 'get', 'nodes', '--name', kind_cluster).lines.map(&:strip)
      .find { |name| name.end_with?('-control-plane') }
    raise "Kind cluster #{kind_cluster} has no control-plane node" unless node

    inspection = JSON.parse(capture!(engine, 'exec', node, 'crictl', 'inspecti', image.fetch('localReference')))
    status = inspection.fetch('status')
    image_spec = inspection.dig('info', 'imageSpec') || {}
    rootfs_diff_ids = image_spec.dig('rootfs', 'diff_ids')
    unless rootfs_diff_ids == image.fetch('rootfsDiffIds')
      raise "Kind changed the rootfs identity for #{image.fetch('component')}"
    end
    labels = image_spec.dig('config', 'Labels') || {}
    unless labels['org.theforeman.kubernetes.unpublished'] == 'true'
      raise "Kind imported #{image.fetch('component')} without its candidate identity"
    end

    {
      'imageId' => status.fetch('id'),
      'repoDigests' => status.fetch('repoDigests').sort,
      'rootfsDiffIds' => rootfs_diff_ids,
      'chainId' => inspection.dig('info', 'chainID')
    }
  end

  def run!(*command)
    stdout, stderr, status = Open3.capture3(*command)
    $stdout.write(stdout)
    $stderr.write(stderr)
    return if status.success?

    raise "command failed (#{status.exitstatus}): #{command.join(' ')}"
  end

  def capture!(*command)
    stdout, stderr, status = Open3.capture3(*command)
    raise "command failed: #{command.join(' ')}\n#{stderr}" unless status.success?

    stdout
  end

  def capture_binary!(*command)
    stdout, stderr, status = Open3.capture3(*command, binmode: true)
    raise "command failed: #{command.join(' ')}\n#{stderr}" unless status.success?

    stdout
  end
end

options = { build: true }
OptionParser.new do |parser|
  parser.banner = 'Usage: build-local-candidate-images.rb [--prepare-only | --build-prepared FILE] [--kind CLUSTER] [OUTPUT_JSON]'
  parser.on('--prepare-only', 'Prepare deterministic build contexts without building images') { options[:build] = false }
  parser.on('--build-prepared FILE', 'Build previously prepared and transferred contexts') do |file|
    options[:prepared] = Pathname.new(file).expand_path
  end
  parser.on('--kind CLUSTER', 'Load built images into an existing kind cluster') { |cluster| options[:kind_cluster] = cluster }
end.parse!

if !options.fetch(:build) && options[:prepared]
  abort '--prepare-only and --build-prepared cannot be used together'
end

root = Pathname.new(File.expand_path('..', __dir__))
upstream_root = Pathname.new(ENV.fetch('UPSTREAM_ROOT', (root.parent / 'foreman-kubernetes-upstream').to_s)).expand_path
context_root = Pathname.new(ENV.fetch('CANDIDATE_CONTEXT_DIR', (root / 'artifacts/local-candidate-contexts').to_s)).expand_path
output = Pathname.new(ARGV.fetch(0, (root / 'artifacts/local-candidate-images.json').to_s)).expand_path

result = LocalCandidateImages.new(
  root: root,
  upstream_root: upstream_root,
  context_root: context_root,
  engine: ENV.fetch('CONTAINER_ENGINE', 'docker'),
  build: options.fetch(:build),
  kind_cluster: options[:kind_cluster],
  prepared: options[:prepared]
).call

FileUtils.mkdir_p(output.dirname)
temporary = Pathname.new("#{output}.tmp")
temporary.write("#{JSON.pretty_generate(result)}\n")
FileUtils.mv(temporary, output)
puts "Wrote #{result.fetch('mode')} candidate image evidence to #{output}"
