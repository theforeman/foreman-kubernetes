#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 {quiesce|backup|restore|resume} APPLICATION_VALUES EXECUTION_PROXY_VALUES [REQUEST_ID]" >&2
  exit 2
fi

operation="$1"
application_values="$2"
execution_values="$3"
request_id="${4:-}"
case "${operation}" in
  backup | restore)
    [[ -n "${request_id}" ]] || {
      echo "${operation} requires a request ID" >&2
      exit 2
    }
    ;;
  quiesce | resume)
    [[ -z "${request_id}" ]] || {
      echo "${operation} does not accept a request ID" >&2
      exit 2
    }
    ;;
  *)
    echo "unsupported recovery operation: ${operation}" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release-preflight.sh
. "${repo_root}/scripts/release-preflight.sh"
namespace="${NAMESPACE:-foreman}"
application_release="${APPLICATION_RELEASE:-foreman}"
execution_release="${EXECUTION_RELEASE:-execution}"
compatibility_sets_file="${repo_root}/compatibility/release-sets.json"
compatibility_set="${COMPATIBILITY_SET:-}"
allow_candidate="${ALLOW_CANDIDATE:-0}"
application_profile_override="${APPLICATION_PROFILE_OVERRIDE:-}"
execution_profile_override="${EXECUTION_PROXY_PROFILE_OVERRIDE:-}"
recovery_timeout="${RECOVERY_TIMEOUT:-6h}"
resume_timeout="${RESUME_TIMEOUT:-30m}"
smoke_timeout="${SMOKE_TIMEOUT:-10m}"
initialize_repository="${INITIALIZE_REPOSITORY:-0}"
restore_snapshot="${RESTORE_SNAPSHOT:-latest}"
restore_secrets="${RESTORE_SECRETS:-0}"
object_storage_recovery_point="${OBJECT_STORAGE_RECOVERY_POINT:-}"
recovery_from_quiesced="${RECOVERY_FROM_QUIESCED:-0}"
bootstrap_restore="${BOOTSTRAP_RESTORE:-0}"
release_lease_name="${RELEASE_LEASE_NAME:-foreman-kubernetes-release}"
release_holder_id="${RELEASE_HOLDER_ID:-${HOSTNAME:-recovery-host}-${operation}-$$}"
release_lease_duration_seconds="${RELEASE_LEASE_DURATION_SECONDS:-120}"
release_lease_renew_interval_seconds="${RELEASE_LEASE_RENEW_INTERVAL_SECONDS:-30}"
release_lease_acquired=false
release_lease_renewal_pid=''

fail() {
  echo "$1" >&2
  exit 1
}

cleanup() {
  local exit_status=$?

  set +e
  release_operation_lease "${namespace}" "${release_lease_name}" "${release_holder_id}"
  return "${exit_status}"
}
trap cleanup EXIT
trap 'fail "release Lease renewal failed; the recovery operation was stopped"' TERM

for command_name in helm jq kubectl grep ruby; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

[[ -f "${application_values}" ]] || fail "application values do not exist: ${application_values}"
[[ -f "${execution_values}" ]] || fail "execution proxy values do not exist: ${execution_values}"

case "${allow_candidate}" in
  0 | 1) ;;
  *) fail 'ALLOW_CANDIDATE must be 0 or 1' ;;
esac
case "${initialize_repository}" in
  0 | 1) ;;
  *) fail 'INITIALIZE_REPOSITORY must be 0 or 1' ;;
esac
case "${restore_secrets}" in
  0 | 1) ;;
  *) fail 'RESTORE_SECRETS must be 0 or 1' ;;
esac
case "${bootstrap_restore}" in
  0 | 1) ;;
  *) fail 'BOOTSTRAP_RESTORE must be 0 or 1' ;;
esac
case "${recovery_from_quiesced}" in
  0 | 1) ;;
  *) fail 'RECOVERY_FROM_QUIESCED must be 0 or 1' ;;
esac
if [[ "${bootstrap_restore}" == 1 && "${operation}" != restore ]]; then
  fail 'BOOTSTRAP_RESTORE=1 is supported only for restore'
fi
if [[ "${recovery_from_quiesced}" == 1 && "${operation}" != backup && "${operation}" != restore ]]; then
  fail 'RECOVERY_FROM_QUIESCED=1 is supported only for backup or restore'
fi
if [[ -n "${object_storage_recovery_point}" && \
      "${recovery_from_quiesced}" != 1 && "${bootstrap_restore}" != 1 ]]; then
  fail 'OBJECT_STORAGE_RECOVERY_POINT requires RECOVERY_FROM_QUIESCED=1'
fi
if [[ "${bootstrap_restore}" == 1 && "${recovery_from_quiesced}" == 1 ]]; then
  fail 'bootstrap restore cannot continue an existing quiesced release'
fi
validate_release_lease_configuration "${release_lease_duration_seconds}" \
  "${release_lease_renew_interval_seconds}" || exit 1

if [[ -z "${compatibility_set}" ]]; then
  compatibility_set="$(jq --exit-status --raw-output '.default' \
    "${compatibility_sets_file}")"
fi
release_set="$(jq --exit-status --compact-output --arg set "${compatibility_set}" \
  '.sets[$set]' "${compatibility_sets_file}")" || \
  fail "unknown compatibility set: ${compatibility_set}"
release_set_status="$(jq --exit-status --raw-output '.status' <<<"${release_set}")"
case "${release_set_status}" in
  supported) ;;
  candidate)
    [[ "${allow_candidate}" == 1 ]] || \
      fail "compatibility set ${compatibility_set} is still a candidate; set ALLOW_CANDIDATE=1 only for qualification"
    ;;
  retired) fail "compatibility set ${compatibility_set} is retired and cannot be recovered" ;;
  *) fail "unsupported compatibility-set state: ${release_set_status}" ;;
esac

if [[ -n "${application_profile_override}" || -n "${execution_profile_override}" ]]; then
  if [[ -z "${application_profile_override}" || -z "${execution_profile_override}" ]]; then
    fail 'APPLICATION_PROFILE_OVERRIDE and EXECUTION_PROXY_PROFILE_OVERRIDE must be supplied together'
  fi
  if [[ "${release_set_status}" != candidate || "${allow_candidate}" != 1 ]]; then
    fail 'recovery profile overrides are allowed only while explicitly qualifying a candidate set'
  fi
  application_profile="${application_profile_override}"
  execution_profile="${execution_profile_override}"
else
  application_profile="${repo_root}/$(jq --exit-status --raw-output \
    '.applicationProfile' <<<"${release_set}")"
  execution_profile="${repo_root}/$(jq --exit-status --raw-output \
    '.executionProxyProfile' <<<"${release_set}")"
fi
[[ -f "${application_profile}" ]] || fail "application profile does not exist: ${application_profile}"
[[ -f "${execution_profile}" ]] || fail "execution profile does not exist: ${execution_profile}"

kubectl get namespace "${namespace}" >/dev/null || fail "namespace ${namespace} does not exist"
acquire_release_lease "${namespace}" "${release_lease_name}" \
  "${release_holder_id}" "${release_lease_duration_seconds}" \
  "recovery-${operation}" "${compatibility_set}" || \
  fail 'another release operation is active or its Lease cannot be claimed safely'
start_release_lease_renewal "${namespace}" "${release_lease_name}" \
  "${release_holder_id}" "${release_lease_duration_seconds}" \
  "${release_lease_renew_interval_seconds}"

declare -a release_install_arguments
release_install_arguments=()
if [[ "${bootstrap_restore}" == 1 ]]; then
  application_exists=0
  execution_exists=0
  if helm status "${application_release}" --namespace "${namespace}" >/dev/null 2>&1; then
    application_exists=1
  fi
  if helm status "${execution_release}" --namespace "${namespace}" >/dev/null 2>&1; then
    execution_exists=1
  fi
  if [[ "${application_exists}" == 1 || "${execution_exists}" == 1 ]]; then
    fail 'bootstrap restore requires both application and execution Helm releases to be absent'
  fi
  release_install_arguments=(--install)
else
  application_installed_values="$(helm get values "${application_release}" \
    --namespace "${namespace}" --all --output=json)" || \
    fail "cannot read the installed values for ${application_release}"
  execution_installed_values="$(helm get values "${execution_release}" \
    --namespace "${namespace}" --all --output=json)" || \
    fail "cannot read the installed values for ${execution_release}"
  application_installed_set="$(jq --exit-status --raw-output \
    '.platform.compatibilitySet | select(type == "string" and length > 0)' \
    <<<"${application_installed_values}")" || \
    fail "cannot determine the installed compatibility set for ${application_release}"
  execution_installed_set="$(jq --exit-status --raw-output \
    '.compatibilitySet | select(type == "string" and length > 0)' \
    <<<"${execution_installed_values}")" || \
    fail "cannot determine the installed compatibility set for ${execution_release}"
  if [[ "${application_installed_set}" != "${compatibility_set}" || \
        "${execution_installed_set}" != "${compatibility_set}" ]]; then
    fail "recovery requires application and execution proxy on ${compatibility_set}; found ${application_installed_set} and ${execution_installed_set}"
  fi

  helm status "${application_release}" --namespace "${namespace}" >/dev/null
  helm status "${execution_release}" --namespace "${namespace}" >/dev/null

  if [[ "${recovery_from_quiesced}" == 1 ]]; then
    jq --exit-status '
      .maintenance.enabled == true and
      .backup.enabled == false and
      .restore.enabled == false
    ' <<<"${application_installed_values}" >/dev/null || \
      fail 'application release is not in guarded maintenance mode'
    jq --exit-status '.maintenance.enabled == true' \
      <<<"${execution_installed_values}" >/dev/null || \
      fail 'execution proxy release is not in guarded maintenance mode'
  fi
fi

declare -a recovery_arguments application_maintenance_arguments
declare -a application_normal_arguments execution_maintenance_arguments
declare -a execution_normal_arguments
recovery_arguments=()
application_maintenance_arguments=(
  --set maintenance.enabled=true
  --set backup.enabled=false
  --set restore.enabled=false
)
application_normal_arguments=(
  --set maintenance.enabled=false
  --set backup.enabled=false
  --set restore.enabled=false
)
execution_maintenance_arguments=(
  --set maintenance.enabled=true
  --set smokeTest.enabled=false
)
execution_normal_arguments=(--set maintenance.enabled=false)

if [[ "${bootstrap_restore}" != 1 && \
      ("${operation}" == quiesce || \
       ("${operation}" != resume && "${recovery_from_quiesced}" != 1)) ]]; then
  kubectl --namespace "${namespace}" wait \
    --for=condition=Ready pod \
    --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
    --timeout="${smoke_timeout}"
  helm test "${application_release}" \
    --namespace "${namespace}" \
    --logs \
    --timeout "${smoke_timeout}"
  helm test "${execution_release}" \
    --namespace "${namespace}" \
    --logs \
    --timeout "${smoke_timeout}"

fi

if [[ "${operation}" == backup || "${operation}" == restore ]]; then
  recovery_arguments+=(
    --set maintenance.enabled=true
    --set backup.enabled=false
    --set restore.enabled=false
    --set "${operation}.enabled=true"
    --set-string "${operation}.requestId=${request_id}"
  )
  if [[ "${operation}" == backup ]]; then
    recovery_arguments+=(
      --set "backup.initializeRepository=$([[ "${initialize_repository}" == 1 ]] && echo true || echo false)"
    )
    if [[ -n "${object_storage_recovery_point}" ]]; then
      recovery_arguments+=(--set-string "backup.objectStorageRecoveryPoint=${object_storage_recovery_point}")
    fi
  else
    recovery_arguments+=(
      --set-string "restore.snapshot=${restore_snapshot}"
      --set restore.confirmation=RESTORE
      --set "restore.secrets=$([[ "${restore_secrets}" == 1 ]] && echo true || echo false)"
    )
    if [[ -n "${object_storage_recovery_point}" ]]; then
      recovery_arguments+=(--set-string "restore.objectStorageRecoveryPoint=${object_storage_recovery_point}")
    fi
  fi
fi

echo "Preflight: rendering ${operation} for compatibility set ${compatibility_set}"
helm lint "${repo_root}/charts/foreman-stack" \
  --values "${application_values}" \
  --values "${application_profile}" \
  "${application_normal_arguments[@]}"
application_normal_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  "${application_normal_arguments[@]}")"
helm lint "${repo_root}/charts/foreman-execution-proxy" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  "${execution_normal_arguments[@]}"
execution_normal_resources="$(helm template "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  "${execution_normal_arguments[@]}")"
if [[ "${operation}" == backup || "${operation}" == restore ]]; then
  execution_recovery_inputs="$(ruby "${repo_root}/scripts/execution-recovery-inputs.rb" \
    <<<"${execution_normal_resources}")" || \
    fail 'cannot derive execution proxy recovery inputs from its rendered release'
  recovery_arguments+=(
    --set recovery.executionProxy.enabled=true
    --set-string "recovery.executionProxy.release=${execution_release}"
    --set-string "recovery.executionProxy.stateClaim=$(jq --exit-status --raw-output '.stateClaim' <<<"${execution_recovery_inputs}")"
    --set-string "recovery.executionProxy.ansibleClaim=$(jq --exit-status --raw-output '.ansibleClaim' <<<"${execution_recovery_inputs}")"
    --set-json "recovery.executionProxy.secretNames=$(jq --compact-output '.secretNames' <<<"${execution_recovery_inputs}")"
    --set-json "recovery.scheduling=$(jq --compact-output '.scheduling' <<<"${execution_recovery_inputs}")"
  )
fi
normal_resources="$(printf '%s\n---\n%s\n' \
  "${application_normal_resources}" "${execution_normal_resources}")"

if [[ "${operation}" == resume ]]; then
  all_resources="${normal_resources}"
  check_required_cluster_resources "${all_resources}" "${namespace}" "${repo_root}"
  check_required_secrets "${all_resources}" "${namespace}" "${repo_root}"
  check_server_admission "${normal_resources}" "${namespace}"
else
  helm lint "${repo_root}/charts/foreman-stack" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${application_maintenance_arguments[@]}"
  application_maintenance_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${application_maintenance_arguments[@]}")"
  helm lint "${repo_root}/charts/foreman-execution-proxy" \
    --values "${execution_values}" \
    --values "${execution_profile}" \
    "${execution_maintenance_arguments[@]}"
  execution_maintenance_resources="$(helm template "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
    --namespace "${namespace}" \
    --values "${execution_values}" \
    --values "${execution_profile}" \
    "${execution_maintenance_arguments[@]}")"
  maintenance_resources="$(printf '%s\n---\n%s\n' \
    "${application_maintenance_resources}" "${execution_maintenance_resources}")"
  if [[ "${operation}" == quiesce ]]; then
    all_resources="$(printf '%s\n---\n%s\n' "${normal_resources}" "${maintenance_resources}")"
    check_required_cluster_resources "${all_resources}" "${namespace}" "${repo_root}"
    check_required_secrets "${all_resources}" "${namespace}" "${repo_root}"
    check_server_admission "${maintenance_resources}" "${namespace}"
    check_server_admission "${normal_resources}" "${namespace}"
  else
    helm lint "${repo_root}/charts/foreman-stack" \
      --values "${application_values}" \
      --values "${application_profile}" \
      "${recovery_arguments[@]}"
    application_recovery_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
      --namespace "${namespace}" \
      --values "${application_values}" \
      --values "${application_profile}" \
      "${recovery_arguments[@]}")"
    if [[ "$(grep -Fxc 'kind: Job' <<<"${application_recovery_resources}")" != 1 ]]; then
      fail "${operation} must render exactly one recovery Job"
    fi

    recovery_resources="$(printf '%s\n---\n%s\n' \
      "${application_recovery_resources}" "${execution_maintenance_resources}")"
    all_resources="$(printf '%s\n---\n%s\n' "${normal_resources}" "${recovery_resources}")"
    check_required_cluster_resources "${all_resources}" "${namespace}" "${repo_root}"
    check_required_secrets "${all_resources}" "${namespace}" "${repo_root}"
    check_server_admission "${maintenance_resources}" "${namespace}"
    check_server_admission "${recovery_resources}" "${namespace}"
    check_server_admission "${normal_resources}" "${namespace}"
  fi
fi

if [[ "${operation}" == quiesce || \
      ("${operation}" != resume && "${recovery_from_quiesced}" != 1) ]]; then
  echo 'Recovery: stopping application writers'
  if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
    "${release_install_arguments[@]}" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${application_maintenance_arguments[@]}" \
    --wait \
    --wait-for-jobs \
    --timeout "${resume_timeout}"; then
    fail 'application maintenance mode did not become ready; inspect the release before retrying'
  fi

  echo 'Recovery: stopping the execution proxy'
  if ! helm upgrade "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
    "${release_install_arguments[@]}" \
    --namespace "${namespace}" \
    --values "${execution_values}" \
    --values "${execution_profile}" \
    "${execution_maintenance_arguments[@]}" \
    --wait \
    --timeout "${resume_timeout}"; then
    fail 'the execution proxy did not enter maintenance; the application remains stopped'
  fi
  kubectl --namespace "${namespace}" wait \
    --for=delete pod \
    --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
    --timeout="${resume_timeout}" || \
    fail 'the execution proxy Pod did not terminate; both releases remain in maintenance mode'

fi

if [[ "${operation}" == quiesce ]]; then
  echo 'Recovery: releases are quiesced; capture or restore the external object-storage recovery point now'
  exit 0
fi

if [[ "${operation}" == backup || "${operation}" == restore ]]; then
  echo "Recovery: running ${operation} ${request_id}"
  if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
    "${release_install_arguments[@]}" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${recovery_arguments[@]}" \
    --wait \
    --wait-for-jobs \
    --timeout "${recovery_timeout}"; then
    fail "${operation} failed; the application and execution proxy remain in maintenance mode for inspection or a guarded retry"
  fi
fi

echo 'Recovery: restoring the normal application release'
if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
  "${release_install_arguments[@]}" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  "${application_normal_arguments[@]}" \
  --wait \
  --wait-for-jobs \
  --timeout "${resume_timeout}"; then
  fail 'the recovery action completed, but the normal application release did not become ready'
fi

echo 'Recovery: restoring the execution proxy'
if ! helm upgrade "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  "${release_install_arguments[@]}" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  "${execution_normal_arguments[@]}" \
  --wait \
  --timeout "${resume_timeout}"; then
  fail 'the application is ready, but the execution proxy did not leave maintenance mode'
fi

kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
  --timeout="${smoke_timeout}"
helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${smoke_timeout}"
helm test "${execution_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${smoke_timeout}"

echo "Recovery operation ${operation} completed with compatibility set ${compatibility_set}."
