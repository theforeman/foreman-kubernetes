#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

unless ARGV.length == 3 && ARGV.drop(1).all? { |value| %w[true false].include?(value) }
  abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECT_PULP_FILESYSTEM(true|false) EXPECT_EXECUTION_PROXY(true|false)"
end

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
expect_pulp = ARGV.fetch(1) == 'true'
expect_execution = ARGV.fetch(2) == 'true'

job = documents.find do |resource|
  resource['kind'] == 'Job' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component').to_s.start_with?('recovery-')
end
abort 'recovery Job is missing' unless job

pod_spec = job.dig('spec', 'template', 'spec')
container = Array(pod_spec&.fetch('containers', nil)).first
environment = Array(container&.fetch('env', nil)).to_h { |entry| [entry['name'], entry] }
volumes = Array(pod_spec&.fetch('volumes', nil)).to_h { |volume| [volume['name'], volume] }
mounts = Array(container&.fetch('volumeMounts', nil)).to_h { |mount| [mount['name'], mount] }

avatar_mount = mounts['foreman-avatars']
avatar_volume = volumes['foreman-avatars']
abort 'recovery Job does not mount Foreman avatars' unless avatar_mount&.fetch('mountPath', nil) == '/var/lib/foreman/avatars'
abort 'Foreman avatar recovery volume is not a PVC' unless avatar_volume&.dig('persistentVolumeClaim', 'claimName')
abort 'recovery Job does not receive the coordinated object-storage point' unless
  environment.key?('PULP_OBJECT_STORAGE_RECOVERY_POINT')
abort 'recovery Job does not require its unprivileged Pod identity' unless
  pod_spec.dig('securityContext', 'runAsNonRoot') == true &&
  pod_spec.dig('securityContext', 'runAsUser') == 700 &&
  container.dig('securityContext', 'runAsNonRoot') == true &&
  container.dig('securityContext', 'runAsUser') == 700

pulp_mounted = mounts.key?('pulp-data') && volumes.dig('pulp-data', 'persistentVolumeClaim', 'claimName')
abort "Pulp recovery volume expectation differs: expected #{expect_pulp}, got #{!!pulp_mounted}" unless !!pulp_mounted == expect_pulp

execution_state_mounted = mounts.dig('execution-proxy-state', 'mountPath') == '/var/lib/foreman-execution-proxy/state' &&
                          volumes.dig('execution-proxy-state', 'persistentVolumeClaim', 'claimName') == 'execution-state'
execution_ansible_mounted = mounts.dig('execution-proxy-ansible', 'mountPath') == '/var/lib/foreman-execution-proxy/ansible' &&
                            volumes.dig('execution-proxy-ansible', 'persistentVolumeClaim', 'claimName') == 'execution-ansible'
unless execution_state_mounted == expect_execution && execution_ansible_mounted == expect_execution
  abort "execution recovery volume expectation differs: expected #{expect_execution}"
end

role = documents.find { |resource| resource['kind'] == 'Role' && resource.dig('metadata', 'name').to_s.end_with?('-recovery') }
secret_names = Array(role&.dig('rules'))
  .select { |rule| Array(rule['resources']).include?('secrets') }
  .flat_map { |rule| Array(rule['resourceNames']) }
if expect_execution && !%w[execution-ssh execution-tls].all? { |name| secret_names.include?(name) }
  abort 'execution proxy Secrets are missing from encrypted escrow RBAC'
end

scripts = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-recovery-scripts')
end
backup = scripts&.dig('data', 'backup.sh').to_s
restore = scripts&.dig('data', 'restore.sh').to_s
common = scripts&.dig('data', 'recovery-common.sh').to_s

abort 'backup manifest does not record Foreman avatars' unless backup.include?('includes_foreman_avatars: true')
abort 'backup does not include Foreman avatars' unless backup.include?('set -- /work /var/lib/foreman/avatars')
abort 'backup manifest does not record the compatibility set' unless backup.include?('compatibility_set: $compatibility_set')
abort 'backup manifest does not record its request ID' unless backup.include?('request_id: $request_id')
abort 'backup manifest does not bind an external object-storage recovery point' unless
  backup.include?('recovery_point: (if $pulp_storage_backend == "s3" then $pulp_object_storage_recovery_point else null end)')
abort 'backup does not create an integrity manifest' unless backup.include?('write_recovery_integrity')
abort 'backup does not verify its recovery set before upload' unless backup.index('verify_recovery_integrity') <
                                                                  backup.index('restic backup --json')
abort 'backup does not capture Restic JSON output' unless backup.include?('restic backup --json')
abort 'backup does not extract the created snapshot ID' unless backup.include?('.snapshot_id')
abort 'backup does not verify the request-specific snapshot tag' unless backup.include?('(.[0].tags | index($request_tag)) != null')
abort 'backup does not inspect the created snapshot contents' unless backup.include?('restic ls --json "${snapshot_id}"')
abort 'backup does not verify all three database dumps' unless backup.include?('/work/databases/foreman.dump') &&
                                                         backup.include?('/work/databases/candlepin.dump') &&
                                                         backup.include?('/work/databases/pulp.dump')
abort 'backup reports completion before validation' unless backup.index('Validated encrypted recovery snapshot') <
                                                           backup.index('Recovery snapshot completed:')
abort 'backup does not report the bound object-storage point for the recovery record' unless
  backup.include?('Retain object-storage recovery point with this snapshot:')
abort 'restore does not require the release-aware schema' unless restore.include?('.schema_version == "6"')
abort 'restore drops supported schema 5 filesystem recovery sets' unless
  restore.include?('.schema_version == "5"') &&
  restore.include?('$pulp_storage_backend == "filesystem"')
abort 'restore accepts a snapshot from another release set' unless restore.include?('.compatibility_set == $compatibility_set')
abort 'restore accepts a different object-storage recovery point' unless
  restore.include?('.object_storage.recovery_point == $pulp_object_storage_recovery_point')
abort 'restore does not bind the manifest request ID to the Restic tag' unless restore.include?('request-${manifest_request_id}')
abort 'restore does not replace Foreman avatars' unless restore.include?("--include '/var/lib/foreman/avatars/**'")
abort 'restore does not make cross-UID volume data group-accessible' unless
  restore.include?('chmod -R u+rwX,g+rwX /var/lib/foreman/avatars') &&
  restore.include?('chmod -R u+rwX,g+rwX /var/lib/pulp') &&
  restore.include?('/var/lib/foreman-execution-proxy/ansible')
abort 'backup does not include execution state' unless backup.include?('/var/lib/foreman-execution-proxy/state')
abort 'backup does not include execution Ansible content' unless backup.include?('/var/lib/foreman-execution-proxy/ansible')
abort 'restore does not validate execution release identity' unless restore.include?('.execution_proxy.release == $execution_proxy_release')
abort 'restore does not replace execution state' unless restore.include?("--include '/var/lib/foreman-execution-proxy/state/**'")
abort 'restore does not replace execution Ansible content' unless restore.include?("--include '/var/lib/foreman-execution-proxy/ansible/**'")
abort 'restore does not inspect snapshot contents' unless restore.include?('restic ls --json')
validation_boundary = restore.index('Snapshot validation completed; starting destructive restore')
avatar_deletion = restore.index('find /var/lib/foreman/avatars')
pulp_deletion = restore.index('find /var/lib/pulp')
abort 'restore is missing the destructive validation boundary' unless validation_boundary
abort 'restore validates the snapshot after deleting avatars' unless avatar_deletion && validation_boundary < avatar_deletion
abort 'restore validates the snapshot after deleting Pulp data' unless pulp_deletion && validation_boundary < pulp_deletion
execution_deletion = restore.index('find /var/lib/foreman-execution-proxy/state')
abort 'restore validates the snapshot after deleting execution state' unless execution_deletion && validation_boundary < execution_deletion
secret_validation = restore.index('Secret escrow manifest is incomplete')
abort 'restore validates Secret escrow after destructive changes' unless secret_validation && secret_validation < validation_boundary
integrity_validation = restore.index('verify_recovery_integrity')
abort 'restore verifies recovery integrity after destructive changes' unless integrity_validation && integrity_validation < validation_boundary
abort 'restore integrity verification precedes Secret validation' unless secret_validation < integrity_validation
%w[Foreman Candlepin Pulp].each do |database|
  validation = restore.index("validate_database_dump #{database}")
  abort "restore does not validate the #{database} archive before destructive changes" unless
    validation && validation < validation_boundary
end
abort 'recovery helper does not define exact integrity paths' unless common.include?('recovery_integrity_paths()')
abort 'database restore does not validate custom archives with pg_restore' unless
  common.include?('pg_restore --list "${dump}"')
abort 'database restore can leave a partially applied database' unless
  common.include?('--single-transaction')
abort 'recovery helper accepts unlisted files in the integrity manifest' unless common.include?('does not describe the exact recovery set')
%w[candlepin-migrate execution-proxy-registration pulp-object-storage-test].each do |component|
  abort "recovery quiescence omits #{component}" unless common.include?(%($component == "#{component}"))
end
abort 'recovery ignores terminating writers' if common.include?('.metadata.deletionTimestamp == null')
abort 'recovery does not ignore successful Jobs' unless common.include?('(.status.phase // "") != "Succeeded"')
abort 'recovery does not ignore failed Jobs' unless common.include?('(.status.phase // "") != "Failed"')

puts "Recovery storage includes avatars; Pulp filesystem mounted=#{expect_pulp}; execution proxy mounted=#{expect_execution}."
