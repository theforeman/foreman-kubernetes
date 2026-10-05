#!/bin/sh

set -eu
# shellcheck source=recovery-common.sh
. /opt/foreman-recovery/recovery-common.sh

for command in cmp jq kubectl pg_restore restic sha256sum; do
  require_command "${command}"
done

if [ "${RESTORE_CONFIRMATION}" != RESTORE ]; then
  log "Restore confirmation is missing" >&2
  exit 1
fi

if [ "${PULP_STORAGE_BACKEND}" = s3 ] && [ -z "${PULP_OBJECT_STORAGE_RECOVERY_POINT}" ]; then
  log "The exact restored object-storage recovery point is required before restoring the Pulp database" >&2
  exit 1
fi

wait_for_quiescence
prepare_work_directory

snapshot_id="$(resolve_snapshot)"
log "Validated recovery snapshot ${snapshot_id}"

require_snapshot_path() {
  required_path="$1"
  listing_file=/work/metadata/snapshot-path.jsonl

  if ! restic ls --json "${snapshot_id}" "${required_path}" > "${listing_file}"; then
    log "Unable to inspect recovery snapshot path: ${required_path}" >&2
    exit 1
  fi

  if ! jq -e --arg required_path "${required_path}" '
    select(
      (.message_type // .struct_type) == "node" and
      .path == $required_path
    )
  ' "${listing_file}" >/dev/null; then
    log "Recovery snapshot is incomplete: ${required_path} is missing" >&2
    exit 1
  fi
}

restic restore "${snapshot_id}" \
  --target / \
  --include '/work/**'

for required_file in \
  /work/metadata/manifest.json \
  /work/metadata/checksums.sha256 \
  /work/databases/foreman.dump \
  /work/databases/candlepin.dump \
  /work/databases/pulp.dump; do
  if [ ! -s "${required_file}" ]; then
    log "Recovery snapshot is incomplete: ${required_file} is missing" >&2
    exit 1
  fi
  require_snapshot_path "${required_file}"
done

jq -e \
  --arg release "${HELM_RELEASE}" \
  --arg namespace "${POD_NAMESPACE}" \
  --arg compatibility_set "${COMPATIBILITY_SET}" \
  --arg pulp_storage_backend "${PULP_STORAGE_BACKEND}" \
  --arg pulp_object_storage_recovery_point "${PULP_OBJECT_STORAGE_RECOVERY_POINT}" \
  --argjson execution_proxy_enabled "${EXECUTION_PROXY_RECOVERY_ENABLED}" \
  --arg execution_proxy_release "${EXECUTION_PROXY_RELEASE:-}" \
  '((.schema_version == "6" and
      .pulp_storage_backend == $pulp_storage_backend and
      .object_storage.backend == $pulp_storage_backend and
      (if $pulp_storage_backend == "s3" then
         .object_storage.recovery_point == $pulp_object_storage_recovery_point
       else
         .object_storage.recovery_point == null
       end)) or
     (.schema_version == "5" and
      $pulp_storage_backend == "filesystem" and
      (.pulp_storage_backend // (if .includes_pulp_filesystem then "filesystem" else "unknown" end)) == "filesystem")) and
   (.request_id |
     type == "string" and
     length > 0 and length <= 16 and
     test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")) and
   .helm_release == $release and
   .namespace == $namespace and
   .compatibility_set == $compatibility_set and
   (.databases | sort) == ["candlepin", "foreman", "pulp"] and
   (.secret_names | type == "array" and length > 0 and length == (unique | length)) and
   all(.secret_names[]; test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")) and
   .integrity == {algorithm: "sha256", manifest: "/work/metadata/checksums.sha256"} and
   .includes_foreman_avatars == true and
   (if $pulp_storage_backend == "filesystem" then .includes_pulp_filesystem == true else true end) and
   .execution_proxy.enabled == $execution_proxy_enabled and
   (if $execution_proxy_enabled then
      .execution_proxy.release == $execution_proxy_release and
      .execution_proxy.includes_state == true and
      .execution_proxy.includes_ansible_content == true
    else true end)' \
  /work/metadata/manifest.json >/dev/null

manifest_request_id="$(jq -er '.request_id' /work/metadata/manifest.json)"
restic snapshots --json "${snapshot_id}" |
  jq -e --arg request_tag "request-${manifest_request_id}" '
    length == 1 and (.[0].tags | index($request_tag)) != null
  ' >/dev/null

require_snapshot_path /var/lib/foreman/avatars
if [ "${PULP_STORAGE_BACKEND}" = filesystem ]; then
  require_snapshot_path /var/lib/pulp
fi
if [ "${EXECUTION_PROXY_RECOVERY_ENABLED}" = true ]; then
  require_snapshot_path /var/lib/foreman-execution-proxy/state
  require_snapshot_path /var/lib/foreman-execution-proxy/ansible
fi

if [ "${RESTORE_SECRETS}" = true ]; then
  for secret_name in ${BACKUP_SECRET_NAMES}; do
    secret_file="/work/secrets/${secret_name}.json"
    if ! jq -e --arg secret_name "${secret_name}" \
      '.secret_names | index($secret_name) != null' \
      /work/metadata/manifest.json >/dev/null; then
      log "Secret escrow manifest is incomplete: ${secret_name} is missing" >&2
      exit 1
    fi
    if [ ! -s "${secret_file}" ]; then
      log "Secret escrow is incomplete: ${secret_name} is missing" >&2
      exit 1
    fi
    require_snapshot_path "${secret_file}"
  done
fi

verify_recovery_integrity

validate_database_dump Foreman /work/databases/foreman.dump
validate_database_dump Candlepin /work/databases/candlepin.dump
validate_database_dump Pulp /work/databases/pulp.dump

log "Snapshot validation completed; starting destructive restore"

log "Replacing Foreman LDAP avatars from the selected recovery snapshot"
find /var/lib/foreman/avatars -mindepth 1 -maxdepth 1 -exec rm -rf {} +
restic restore "${snapshot_id}" \
  --target / \
  --include '/var/lib/foreman/avatars/**'
chmod -R u+rwX,g+rwX /var/lib/foreman/avatars

if [ "${PULP_STORAGE_BACKEND}" = filesystem ]; then
  log "Replacing Pulp filesystem from the selected recovery snapshot"
  find /var/lib/pulp -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  restic restore "${snapshot_id}" \
    --target / \
    --include '/var/lib/pulp/**'
  chmod -R u+rwX,g+rwX /var/lib/pulp
else
  log "Pulp objects were restored from coordinated recovery point ${PULP_OBJECT_STORAGE_RECOVERY_POINT}"
fi

if [ "${EXECUTION_PROXY_RECOVERY_ENABLED}" = true ]; then
  log "Replacing execution proxy state and Ansible content from the selected recovery snapshot"
  find /var/lib/foreman-execution-proxy/state -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  find /var/lib/foreman-execution-proxy/ansible -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  restic restore "${snapshot_id}" \
    --target / \
    --include '/var/lib/foreman-execution-proxy/state/**' \
    --include '/var/lib/foreman-execution-proxy/ansible/**'
  chmod -R u+rwX,g+rwX \
    /var/lib/foreman-execution-proxy/state \
    /var/lib/foreman-execution-proxy/ansible
fi

restore_database Foreman /work/databases/foreman.dump \
  --dbname "${FOREMAN_DATABASE_URL}"

PGPASSWORD="${CANDLEPIN_DATABASE_PASSWORD}" \
PGSSLMODE="${CANDLEPIN_DATABASE_SSLMODE}" \
PGSSLROOTCERT="${CANDLEPIN_DATABASE_SSLROOTCERT:-}" \
  restore_database Candlepin /work/databases/candlepin.dump \
    --host "${CANDLEPIN_DATABASE_HOST}" \
    --port "${CANDLEPIN_DATABASE_PORT}" \
    --username "${CANDLEPIN_DATABASE_USER}" \
    --dbname "${CANDLEPIN_DATABASE_NAME}"

PGPASSWORD="${PULP_DATABASE_PASSWORD}" \
PGSSLMODE="${PULP_DATABASE_SSLMODE}" \
PGSSLROOTCERT="${PULP_DATABASE_SSLROOTCERT:-}" \
  restore_database Pulp /work/databases/pulp.dump \
    --host "${PULP_DATABASE_HOST}" \
    --port "${PULP_DATABASE_PORT}" \
    --username "${PULP_DATABASE_USER}" \
    --dbname "${PULP_DATABASE_NAME}"

if [ "${RESTORE_SECRETS}" = true ]; then
  log "Restoring application Secrets"
  for secret_name in ${BACKUP_SECRET_NAMES}; do
    secret_file="/work/secrets/${secret_name}.json"
    kubectl apply \
      --namespace "${POD_NAMESPACE}" \
      --server-side \
      --force-conflicts \
      --field-manager foreman-stack-recovery \
      --filename "${secret_file}"
  done
else
  log "Secret escrow was not applied; restore required application encryption and signing keys before leaving maintenance mode"
fi

log "Restore completed; leave maintenance mode to run migrations and restart workloads"
