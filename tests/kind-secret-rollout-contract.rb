#!/usr/bin/env ruby
# frozen_string_literal: true

run_script = File.read(File.expand_path('kind/run.sh', __dir__))

unless run_script.include?('jq --compact-output --sort-keys') &&
       run_script.include?("'{name: .metadata.name, data: .data}'")
  abort 'Kind secret rollout digest does not hash Secret names and data deterministically'
end
unless run_script.include?('application_secret_rollout_token="$(secret_rollout_digest')
  abort 'Kind application rollout token is not derived from the generated Secrets'
end
unless run_script.include?('execution_secret_rollout_token="$(secret_rollout_digest')
  abort 'Kind execution rollout token is not derived from the generated Secrets'
end

apply_secrets = run_script.index('"${repo_root}/tests/kind/apply-secrets.sh"')
application_digest = run_script.index('application_secret_rollout_token="$(secret_rollout_digest', apply_secrets)
execution_digest = run_script.index('execution_secret_rollout_token="$(secret_rollout_digest', apply_secrets)
unless apply_secrets && application_digest && execution_digest &&
       apply_secrets < application_digest && apply_secrets < execution_digest
  abort 'Kind rollout digests are not refreshed after Secret generation'
end

%w[
  foreman-certificates
  candlepin-certificates
  pulp-control-proxy-certificates
  foreman-execution-proxy-tls
  foreman-execution-proxy-foreman-client
  foreman-execution-proxy-ssh
].each do |secret|
  abort "Kind rollout digest omits #{secret}" unless run_script.include?(secret)
end

smoke_test = run_script[/assert_application_smoke_test\(\) \{.*?^\}/m].to_s
abort 'Kind smoke test still relies on Helm Pod-name log lookup' if smoke_test.include?('--logs')
unless smoke_test.include?('app.kubernetes.io/component=smoke-test') && smoke_test.include?('--all-containers=true')
  abort 'Kind smoke test does not collect failed hook logs by label selector'
end

puts 'Kind reuses regenerate deterministic Secret rollout tokens and collect failed hook logs by selector.'
