#!/bin/sh

set -eu
# shellcheck source=recovery-common.sh
. /opt/foreman-recovery/recovery-common.sh

for command in cmp jq kubectl pg_dump restic sha256sum; do
  require_command "${command}"
done

wait_for_quiescence
prepare_work_directory

if [ "${PULP_STORAGE_BACKEND}" = s3 ] && [ -z "${PULP_OBJECT_STORAGE_RECOVERY_POINT}" ]; then
  log "An exact object-storage recovery point is required for an S3 backup" >&2
  exit 1
fi

dump_databases

log "Exporting application Secrets to the encrypted recovery set"
for secret_name in ${BACKUP_SECRET_NAMES}; do
  kubectl get secret \
    --namespace "${POD_NAMESPACE}" \
    "${secret_name}" \
    --output json |
    jq '{
      apiVersion,
      kind,
      metadata: {name: .metadata.name},
      type,
      data,
      immutable
    } | del(.immutable | nulls)' \
      > "/work/secrets/${secret_name}.json"
done

includes_pulp_filesystem=false
if [ "${PULP_STORAGE_BACKEND}" = filesystem ]; then
  includes_pulp_filesystem=true
fi
includes_execution_proxy=false
if [ "${EXECUTION_PROXY_RECOVERY_ENABLED}" = true ]; then
  includes_execution_proxy=true
fi

jq -n \
  --arg schema_version "6" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg request_id "${BACKUP_REQUEST_ID}" \
  --arg chart_version "${CHART_VERSION}" \
  --arg compatibility_set "${COMPATIBILITY_SET}" \
  --arg release "${HELM_RELEASE}" \
  --arg namespace "${POD_NAMESPACE}" \
  --arg pulp_storage_backend "${PULP_STORAGE_BACKEND}" \
  --arg pulp_object_storage_recovery_point "${PULP_OBJECT_STORAGE_RECOVERY_POINT}" \
  --argjson includes_pulp_filesystem "${includes_pulp_filesystem}" \
  --argjson includes_execution_proxy "${includes_execution_proxy}" \
  --arg execution_proxy_release "${EXECUTION_PROXY_RELEASE:-}" \
  --arg secret_names "${BACKUP_SECRET_NAMES}" \
  '{
    schema_version: $schema_version,
    created_at: $created_at,
    request_id: $request_id,
    chart_version: $chart_version,
    compatibility_set: $compatibility_set,
    helm_release: $release,
    namespace: $namespace,
    databases: ["foreman", "candlepin", "pulp"],
    includes_foreman_avatars: true,
    pulp_storage_backend: $pulp_storage_backend,
    object_storage: {
      backend: $pulp_storage_backend,
      recovery_point: (if $pulp_storage_backend == "s3" then $pulp_object_storage_recovery_point else null end)
    },
    includes_pulp_filesystem: $includes_pulp_filesystem,
    execution_proxy: {
      enabled: $includes_execution_proxy,
      release: (if $includes_execution_proxy then $execution_proxy_release else null end),
      includes_state: $includes_execution_proxy,
      includes_ansible_content: $includes_execution_proxy
    },
    secret_names: ($secret_names | split(" ") | map(select(length > 0))),
    integrity: {
      algorithm: "sha256",
      manifest: "/work/metadata/checksums.sha256"
    }
  }' > /work/metadata/manifest.json

write_recovery_integrity
verify_recovery_integrity

if ! restic cat config >/dev/null 2>&1; then
  if [ "${INITIALIZE_REPOSITORY}" != true ]; then
    log "Restic repository is unavailable or uninitialized; set backup.initializeRepository=true only for its first use" >&2
    exit 1
  fi
  log "Initializing Restic repository"
  restic init
fi

log "Creating encrypted recovery snapshot"
set -- /work /var/lib/foreman/avatars
if [ "${PULP_STORAGE_BACKEND}" = filesystem ]; then
  set -- "$@" /var/lib/pulp
else
  log "Pulp objects are external; the bucket must use an independently protected, coordinated recovery point"
fi
if [ "${EXECUTION_PROXY_RECOVERY_ENABLED}" = true ]; then
  set -- "$@" \
    /var/lib/foreman-execution-proxy/state \
    /var/lib/foreman-execution-proxy/ansible
fi
backup_output=/tmp/restic-backup.jsonl
restic backup --json \
  --host "${HELM_RELEASE}" \
  --tag foreman-stack \
  --tag "request-${BACKUP_REQUEST_ID}" \
  "$@" > "${backup_output}"

snapshot_id="$(
  jq -ers '
    [
      .[]
      | select(.message_type == "summary")
      | .snapshot_id
      | select(type == "string" and length > 0)
    ] as $snapshot_ids
    | if ($snapshot_ids | length) == 1 then
        $snapshot_ids[0]
      else
        error("backup did not report exactly one snapshot ID")
      end
  ' "${backup_output}"
)"
jq -c 'select(.message_type == "summary")' "${backup_output}"

snapshot_json="$(restic snapshots --json "${snapshot_id}")"
printf '%s' "${snapshot_json}" | jq -e \
  --arg snapshot_id "${snapshot_id}" \
  --arg release "${HELM_RELEASE}" \
  --arg request_tag "request-${BACKUP_REQUEST_ID}" \
  --argjson includes_execution_proxy "${includes_execution_proxy}" '
    length == 1 and
    .[0].id == $snapshot_id and
    .[0].hostname == $release and
    (.[0].tags | index("foreman-stack")) != null and
    (.[0].tags | index($request_tag)) != null and
    (.[0].paths | index("/work")) != null and
    (.[0].paths | index("/var/lib/foreman/avatars")) != null and
    (if $includes_execution_proxy then
      (.[0].paths | index("/var/lib/foreman-execution-proxy/state")) != null and
      (.[0].paths | index("/var/lib/foreman-execution-proxy/ansible")) != null
    else true end)
  ' >/dev/null

require_created_snapshot_path() {
  required_path="$1"
  listing_file=/tmp/restic-created-snapshot-path.jsonl

  restic ls --json "${snapshot_id}" "${required_path}" > "${listing_file}"
  jq -e --arg required_path "${required_path}" '
    select(
      (.message_type // .struct_type) == "node" and
      .path == $required_path
    )
  ' "${listing_file}" >/dev/null
}

for required_file in \
  /work/metadata/manifest.json \
  /work/metadata/checksums.sha256 \
  /work/databases/foreman.dump \
  /work/databases/candlepin.dump \
  /work/databases/pulp.dump; do
  require_created_snapshot_path "${required_file}"
done
require_created_snapshot_path /var/lib/foreman/avatars
for secret_name in ${BACKUP_SECRET_NAMES}; do
  require_created_snapshot_path "/work/secrets/${secret_name}.json"
done
if [ "${PULP_STORAGE_BACKEND}" = filesystem ]; then
  printf '%s' "${snapshot_json}" |
    jq -e '.[0].paths | index("/var/lib/pulp") != null' >/dev/null
  require_created_snapshot_path /var/lib/pulp
fi
if [ "${EXECUTION_PROXY_RECOVERY_ENABLED}" = true ]; then
  require_created_snapshot_path /var/lib/foreman-execution-proxy/state
  require_created_snapshot_path /var/lib/foreman-execution-proxy/ansible
fi

log "Validated encrypted recovery snapshot ${snapshot_id}"
if [ "${PULP_STORAGE_BACKEND}" = s3 ]; then
  log "Retain object-storage recovery point with this snapshot: ${PULP_OBJECT_STORAGE_RECOVERY_POINT}"
fi

if [ "${RETENTION_ENABLED}" = true ]; then
  set -- \
    --host "${HELM_RELEASE}" \
    --tag foreman-stack \
    --keep-daily "${RETENTION_KEEP_DAILY}" \
    --keep-weekly "${RETENTION_KEEP_WEEKLY}" \
    --keep-monthly "${RETENTION_KEEP_MONTHLY}"
  if [ "${RETENTION_PRUNE}" = true ]; then
    set -- "$@" --prune
  fi
  log "Applying Restic retention policy"
  restic forget "$@"
fi

log "Recovery snapshot completed: ${snapshot_id}"
