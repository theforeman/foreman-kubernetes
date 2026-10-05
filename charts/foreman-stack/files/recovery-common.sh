#!/bin/sh

set -eu
umask 077

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Required command is unavailable: $1" >&2
    exit 1
  }
}

wait_for_quiescence() {
  started_at="$(date +%s)"

  while :; do
    active_pods="$(
      kubectl get pods --namespace "${POD_NAMESPACE}" \
        --selector "app.kubernetes.io/instance=${HELM_RELEASE}" \
        --output json |
        jq -r '
          .items[]
          | select(
              (.status.phase // "") != "Succeeded" and
              (.status.phase // "") != "Failed"
            )
          | .metadata.labels["app.kubernetes.io/component"] as $component
          | select(
              $component == "foreman" or
              $component == "candlepin" or
              $component == "pulp-api" or
              $component == "pulp-content" or
              $component == "pulp-worker" or
              $component == "foreman-cron" or
              $component == "candlepin-migrate" or
              $component == "foreman-migrate" or
              $component == "pulp-migrate" or
              $component == "pulp-registration" or
              $component == "execution-proxy-registration" or
              $component == "pulp-object-storage-test" or
              ($component | startswith("dynflow-"))
            )
          | .metadata.name
        '
    )"

    if [ -z "${active_pods}" ]; then
      log "All database-writing workloads are quiescent"
      return
    fi

    now="$(date +%s)"
    if [ "$((now - started_at))" -ge "${QUIESCENCE_TIMEOUT_SECONDS}" ]; then
      log "Timed out waiting for database-writing pods to stop:" >&2
      printf '%s\n' "${active_pods}" >&2
      exit 1
    fi

    log "Waiting for database-writing pods to stop"
    sleep 5
  done
}

prepare_work_directory() {
  find /work -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir -p /work/databases /work/metadata /work/secrets
}

recovery_integrity_paths() {
  work_root="${RECOVERY_WORK_ROOT:-/work}"
  manifest_file="${work_root}/metadata/manifest.json"

  printf '%s\n' \
    "${work_root}/databases/foreman.dump" \
    "${work_root}/databases/candlepin.dump" \
    "${work_root}/databases/pulp.dump" \
    "${manifest_file}"
  jq -r '.secret_names[]' "${manifest_file}" |
    while IFS= read -r secret_name; do
      printf '%s/secrets/%s.json\n' "${work_root}" "${secret_name}"
    done
}

write_recovery_integrity() {
  work_root="${RECOVERY_WORK_ROOT:-/work}"
  integrity_file="${work_root}/metadata/checksums.sha256"
  integrity_tmp="${integrity_file}.tmp"

  : > "${integrity_tmp}"
  recovery_integrity_paths |
    while IFS= read -r recovery_file; do
      if [ ! -s "${recovery_file}" ]; then
        log "Recovery set file is missing or empty: ${recovery_file}" >&2
        exit 1
      fi
      sha256sum "${recovery_file}"
    done > "${integrity_tmp}"
  mv "${integrity_tmp}" "${integrity_file}"
}

verify_recovery_integrity() {
  work_root="${RECOVERY_WORK_ROOT:-/work}"
  integrity_file="${work_root}/metadata/checksums.sha256"
  expected_paths="/tmp/recovery-integrity-expected.$$"
  recorded_paths="/tmp/recovery-integrity-recorded.$$"
  recorded_paths_unsorted="${recorded_paths}.unsorted"

  if [ ! -s "${integrity_file}" ]; then
    log "Recovery integrity manifest is missing or empty" >&2
    return 1
  fi

  recovery_integrity_paths > "${expected_paths}"
  LC_ALL=C sort "${expected_paths}" -o "${expected_paths}"
  if ! awk '
      NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ { exit 1 }
      { print $2 }
    ' "${integrity_file}" > "${recorded_paths_unsorted}"; then
    rm -f "${expected_paths}" "${recorded_paths}" "${recorded_paths_unsorted}"
    log "Recovery integrity manifest has an invalid entry" >&2
    return 1
  fi
  LC_ALL=C sort "${recorded_paths_unsorted}" > "${recorded_paths}"

  if ! cmp -s "${expected_paths}" "${recorded_paths}"; then
    rm -f "${expected_paths}" "${recorded_paths}" "${recorded_paths_unsorted}"
    log "Recovery integrity manifest does not describe the exact recovery set" >&2
    return 1
  fi
  rm -f "${expected_paths}" "${recorded_paths}" "${recorded_paths_unsorted}"

  if ! sha256sum -c "${integrity_file}"; then
    log "Recovery set integrity verification failed" >&2
    return 1
  fi
  log "Verified recovery set integrity"
}

dump_databases() {
  log "Dumping Foreman database"
  pg_dump \
    --format=custom \
    --no-owner \
    --no-acl \
    --file=/work/databases/foreman.dump \
    "${FOREMAN_DATABASE_URL}"

  log "Dumping Candlepin database"
  PGPASSWORD="${CANDLEPIN_DATABASE_PASSWORD}" \
  PGSSLMODE="${CANDLEPIN_DATABASE_SSLMODE}" \
  PGSSLROOTCERT="${CANDLEPIN_DATABASE_SSLROOTCERT:-}" \
    pg_dump \
      --host "${CANDLEPIN_DATABASE_HOST}" \
      --port "${CANDLEPIN_DATABASE_PORT}" \
      --username "${CANDLEPIN_DATABASE_USER}" \
      --dbname "${CANDLEPIN_DATABASE_NAME}" \
      --format=custom \
      --no-owner \
      --no-acl \
      --file=/work/databases/candlepin.dump

  log "Dumping Pulp database"
  PGPASSWORD="${PULP_DATABASE_PASSWORD}" \
  PGSSLMODE="${PULP_DATABASE_SSLMODE}" \
  PGSSLROOTCERT="${PULP_DATABASE_SSLROOTCERT:-}" \
    pg_dump \
      --host "${PULP_DATABASE_HOST}" \
      --port "${PULP_DATABASE_PORT}" \
      --username "${PULP_DATABASE_USER}" \
      --dbname "${PULP_DATABASE_NAME}" \
      --format=custom \
      --no-owner \
      --no-acl \
      --file=/work/databases/pulp.dump
}

restore_database() {
  name="$1"
  dump="$2"
  shift 2

  log "Restoring ${name} database"
  pg_restore \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --exit-on-error \
    --single-transaction \
    "$@" \
    "${dump}"
}

validate_database_dump() {
  name="$1"
  dump="$2"

  if ! pg_restore --list "${dump}" >/dev/null; then
    log "${name} database archive cannot be read by pg_restore: ${dump}" >&2
    return 1
  fi
  log "Validated ${name} database archive"
}

resolve_snapshot() {
  if [ "${RESTORE_SNAPSHOT}" = latest ]; then
    snapshot_json="$(
      restic snapshots \
        --json \
        --latest 1 \
        --host "${HELM_RELEASE}" \
        --tag foreman-stack
    )"
  else
    snapshot_json="$(restic snapshots --json "${RESTORE_SNAPSHOT}")"
  fi

  snapshot_id="$(
    printf '%s' "${snapshot_json}" |
      jq -er --arg release "${HELM_RELEASE}" '
        if length != 1 then
          error("expected exactly one recovery snapshot")
        elif .[0].hostname != $release then
          error("snapshot belongs to a different Helm release")
        elif (.[0].tags | index("foreman-stack")) == null then
          error("snapshot is missing the foreman-stack tag")
        else
          .[0].id
        end
      '
  )"

  printf '%s\n' "${snapshot_id}"
}
