#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman'
end
abort 'Foreman Deployment is missing' unless deployment

pod = deployment.dig('spec', 'template', 'spec')
volumes = Array(pod['volumes']).to_h { |volume| [volume['name'], volume] }
runtime = volumes['foreman-puma-runtime']
unless runtime&.dig('emptyDir', 'sizeLimit') == '1Mi'
  abort 'Foreman Puma runtime is not a bounded per-Pod emptyDir'
end

container = Array(pod['containers']).find { |candidate| candidate['name'] == 'foreman' }
abort 'Foreman web container is missing' unless container
mounts = Array(container['volumeMounts']).to_h { |mount| [mount['mountPath'], mount] }
run_dir = Array(container['env']).find { |entry| entry['name'] == 'FOREMAN_RUN_DIR' }
abort 'Foreman does not select the isolated Puma runtime directory' unless run_dir&.fetch('value', nil) == '/run/foreman-puma'

runtime_mount = mounts['/run/foreman-puma']
unless runtime_mount&.fetch('name', nil) == 'foreman-puma-runtime' && !runtime_mount.key?('subPath')
  abort 'Foreman Puma runtime directory is not isolated per Pod'
end

shared_tmp = mounts['/usr/share/foreman/tmp']
unless shared_tmp && volumes.dig(shared_tmp['name'], 'persistentVolumeClaim', 'claimName')
  abort 'Foreman web no longer retains the shared Katello hand-off volume'
end
abort 'Foreman shared tmp aliases the Puma runtime directory' if shared_tmp['mountPath'] == run_dir.fetch('value')

unless container['command'] == ['/bin/sh', '-ec'] &&
       Array(container['args']).join("\n").include?('mkdir -p "${FOREMAN_RUN_DIR}/sockets"') &&
       Array(container['args']).join("\n").include?('exec /usr/share/foreman/bin/rails server')
  abort 'Foreman does not create its isolated Puma socket directory before startup'
end

puts 'Foreman uses its upstream runtime-directory contract while retaining shared Katello tmp.'
