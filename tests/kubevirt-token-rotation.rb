#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

root = File.expand_path('..', __dir__)
script = File.join(root, 'scripts/rotate-kubevirt-token.sh')

Dir.mktmpdir('kubevirt-token-rotation') do |directory|
  bin = File.join(directory, 'bin')
  FileUtils.mkdir_p(bin)
  argv_log = File.join(directory, 'curl-argv')
  request_log = File.join(directory, 'request.json')
  curl = File.join(bin, 'curl')
  File.write(curl, <<~'SH')
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$@" >> "${CURL_ARGV_LOG}"
    output=''
    method=GET
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request) method="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "${method}" == PUT ]]; then
      cat > "${REQUEST_LOG}"
      printf '%s\n' '{"id":42,"provider":"Kubevirt"}' > "${output}"
    else
      printf '%s\n' "${CURRENT_RESOURCE_JSON:-{\"id\":42,\"provider\":\"Kubevirt\"}}"
    fi
  SH
  FileUtils.chmod(0o755, curl)

  config = File.join(directory, 'foreman.curlrc')
  token = File.join(directory, 'kubevirt.token')
  File.write(config, "user = \"operator:personal-access-token\"\n")
  File.write(token, "secret-kubevirt-token\n")
  FileUtils.chmod(0o600, [config, token])

  environment = {
    'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
    'FOREMAN_URL' => 'https://foreman.example.test',
    'FOREMAN_CURL_CONFIG' => config,
    'KUBEVIRT_TOKEN_FILE' => token,
    'CURL_ARGV_LOG' => argv_log,
    'REQUEST_LOG' => request_log
  }
  output, status = Open3.capture2e(environment, script, '42')
  raise output unless status.success?
  raise 'rotation did not report success' unless output.include?('Rotated KubeVirt token')

  request = JSON.parse(File.read(request_log))
  unless request == {'compute_resource' => {'password' => 'secret-kubevirt-token'}}
    raise 'rotation payload does not contain exactly the new token'
  end
  raise 'token leaked into the curl argument vector' if File.read(argv_log).include?('secret-kubevirt-token')

  bad_environment = environment.merge('CURRENT_RESOURCE_JSON' => '{"id":42,"provider":"Libvirt"}')
  output, status = Open3.capture2e(bad_environment, script, '42')
  raise 'non-KubeVirt compute resource was accepted' if status.success?
  raise output unless output.include?('is not a KubeVirt provider')
end

puts 'KubeVirt token rotation validates the provider and keeps secrets out of process arguments.'
