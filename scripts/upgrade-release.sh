#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 APPLICATION_VALUES EXECUTION_PROXY_VALUES" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release-preflight.sh
. "${repo_root}/scripts/release-preflight.sh"
application_values="$1"
execution_values="$2"
namespace="${NAMESPACE:-foreman}"
application_release="${APPLICATION_RELEASE:-foreman}"
execution_release="${EXECUTION_RELEASE:-execution}"
compatibility_sets_file="${repo_root}/compatibility/release-sets.json"
compatibility_set="${COMPATIBILITY_SET:-}"
allow_candidate="${ALLOW_CANDIDATE:-0}"
wait_timeout="${UPGRADE_TIMEOUT:-30m}"
preflight_timeout="${PREFLIGHT_TIMEOUT:-10m}"
release_lease_name="${RELEASE_LEASE_NAME:-foreman-kubernetes-release}"
release_holder_id="${RELEASE_HOLDER_ID:-${HOSTNAME:-upgrade-host}-upgrade-$$}"
release_lease_duration_seconds="${RELEASE_LEASE_DURATION_SECONDS:-120}"
release_lease_renew_interval_seconds="${RELEASE_LEASE_RENEW_INTERVAL_SECONDS:-30}"
release_operation_id="${RELEASE_OPERATION_ID:-manual-$(date -u +%Y%m%d%H%M%S)-$$}"
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
trap 'fail "release Lease renewal failed; the upgrade was stopped"' TERM

for command_name in helm jq kubectl grep ruby; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

[[ -f "${application_values}" ]] || fail "application values do not exist: ${application_values}"
[[ -f "${execution_values}" ]] || fail "execution proxy values do not exist: ${execution_values}"

case "${allow_candidate}" in
  0 | 1) ;;
  *) fail 'ALLOW_CANDIDATE must be 0 or 1' ;;
esac
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
  retired)
    fail "compatibility set ${compatibility_set} is retired and cannot be installed"
    ;;
  *) fail "unsupported compatibility-set state: ${release_set_status}" ;;
esac

application_profile="${repo_root}/$(jq --exit-status --raw-output \
  '.applicationProfile' <<<"${release_set}")"
execution_profile="${repo_root}/$(jq --exit-status --raw-output \
  '.executionProxyProfile' <<<"${release_set}")"
[[ -f "${application_profile}" ]] || fail "application profile does not exist: ${application_profile}"
[[ -f "${execution_profile}" ]] || fail "execution profile does not exist: ${execution_profile}"

kubectl get namespace "${namespace}" >/dev/null || \
  fail "namespace ${namespace} does not exist"
acquire_release_lease "${namespace}" "${release_lease_name}" \
  "${release_holder_id}" "${release_lease_duration_seconds}" upgrade \
  "${compatibility_set}" || fail 'another release operation is active or its Lease cannot be claimed safely'
start_release_lease_renewal "${namespace}" "${release_lease_name}" \
  "${release_holder_id}" "${release_lease_duration_seconds}" \
  "${release_lease_renew_interval_seconds}"

application_source_set="$(helm get values "${application_release}" \
  --namespace "${namespace}" --all --output=json | \
  jq --exit-status --raw-output '.platform.compatibilitySet | select(type == "string" and length > 0)')" || \
  fail "cannot determine the installed compatibility set for ${application_release}"
execution_source_set="$(helm get values "${execution_release}" \
  --namespace "${namespace}" --all --output=json | \
  jq --exit-status --raw-output '.compatibilitySet | select(type == "string" and length > 0)')" || \
  fail "cannot determine the installed compatibility set for ${execution_release}"
for source_set in "${application_source_set}" "${execution_source_set}"; do
  jq --exit-status --arg source "${source_set}" \
    '.upgradeFrom | index($source) != null' <<<"${release_set}" >/dev/null || \
    fail "upgrade from ${source_set} to ${compatibility_set} is not allowed"
done

echo "Preflight: checking current ${application_release} and ${execution_release} releases"
helm status "${application_release}" --namespace "${namespace}" >/dev/null
helm status "${execution_release}" --namespace "${namespace}" >/dev/null
kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
  --timeout="${preflight_timeout}"
helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${preflight_timeout}"

echo "Preflight: rendering compatibility set ${compatibility_set}"
helm lint "${repo_root}/charts/foreman-stack" \
  --values "${application_values}" \
  --values "${application_profile}"
application_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}")"
foreman_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --show-only templates/foreman.yaml)"
grep -Fxq 'kind: Deployment' <<<"${foreman_resources}" || \
  fail 'normal upgrade requires the Foreman Deployment; maintenance mode is not supported by this helper'
dynflow_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --show-only templates/dynflow.yaml)"
[[ "$(grep -Fxc 'kind: Deployment' <<<"${dynflow_resources}")" == 3 ]] || \
  fail 'normal upgrade requires all three Dynflow Deployments'
migration_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --show-only templates/migrations.yaml)"
[[ "$(grep -Fxc 'kind: Job' <<<"${migration_resources}")" == 3 ]] || \
  fail 'normal upgrade requires all three chart-owned migration Jobs'
dependency_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --set-string "releaseOperation.id=${release_operation_id}" \
  --set-string "releaseOperation.ownerUid=${release_operation_id}" \
  --show-only templates/dependency-preflight.yaml)"
[[ "$(grep -Fxc 'kind: Job' <<<"${dependency_resources}")" == 1 ]] || \
  fail 'normal upgrade requires the chart-owned dependency preflight Job'
helm lint "${repo_root}/charts/foreman-execution-proxy" \
  --values "${execution_values}" \
  --values "${execution_profile}"
execution_resources="$(helm template "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}")"

combined_resources="$(printf '%s\n---\n%s\n' "${application_resources}" "${execution_resources}")"
check_required_cluster_resources "${combined_resources}" "${namespace}" "${repo_root}"
check_required_secrets "${combined_resources}" "${namespace}" "${repo_root}"
check_server_admission "${combined_resources}" "${namespace}"

operation_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --set-string "releaseOperation.id=${release_operation_id}" \
  --set-string "releaseOperation.ownerUid=${release_operation_id}")"

echo 'Upgrade: checking databases, Valkey, and Pulp object storage before migrations'
dependency_stage="$(printf '%s\n' "${operation_resources}" | \
  ruby "${repo_root}/scripts/render-dependency-preflight-stage.rb" "${application_release}" "${namespace}")"
printf '%s\n' "${dependency_stage}" | kubectl --namespace "${namespace}" apply \
  --filename -
if ! kubectl --namespace "${namespace}" wait \
  --for=condition=complete job \
  --selector="platform.theforeman.org/release-operation=${release_operation_id},app.kubernetes.io/component=dependency-preflight" \
  --timeout="${wait_timeout}"; then
  fail 'dependency preflight failed or timed out; database schemas were not changed'
fi

echo 'Upgrade: applying migration prerequisites and Jobs'
migration_stage="$(printf '%s\n' "${operation_resources}" | \
  ruby "${repo_root}/scripts/render-migration-stage.rb" "${application_release}" "${namespace}")"
printf '%s\n' "${migration_stage}" | kubectl --namespace "${namespace}" apply \
  --filename -
if ! kubectl --namespace "${namespace}" wait \
  --for=condition=complete job \
  --selector="platform.theforeman.org/release-operation=${release_operation_id}" \
  --timeout="${wait_timeout}"; then
  fail 'application migrations failed or timed out; workloads were not upgraded'
fi

echo 'Upgrade: applying the application release after successful migrations'
if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --set releaseOperation.skipMigrationJobs=true \
  --wait \
  --wait-for-jobs \
  --timeout "${wait_timeout}"; then
  fail 'application upgrade failed; inspect migration and workload Jobs before retrying'
fi

if ! helm test "${application_release}" \
  --namespace "${namespace}" \
  --filter 'name=.*-smoke-test$' \
  --logs \
  --timeout "${preflight_timeout}"; then
  fail 'application revision is installed but its smoke test failed; do not roll back automatically after schema migrations'
fi

echo "Upgrade: applying the paired execution-proxy release"
if ! helm upgrade "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  --wait \
  --timeout "${wait_timeout}"; then
  fail 'application upgrade succeeded but execution-proxy upgrade failed; repair or roll the proxy forward without rolling back migrated schemas'
fi

kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
  --timeout="${preflight_timeout}"
helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${preflight_timeout}"
helm test "${execution_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${preflight_timeout}"

echo "Compatibility set ${compatibility_set} is deployed. Run a real Remote Execution workflow before completing the change window."
