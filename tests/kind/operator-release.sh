#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workdir="${1:?usage: operator-release.sh WORKDIR}"
namespace="${NAMESPACE:-foreman}"
application_release="${APPLICATION_RELEASE:-foreman}"
execution_release="${EXECUTION_RELEASE:-execution}"
compatibility_set="${COMPATIBILITY_SET:?COMPATIBILITY_SET is required}"
output_file="${OPERATOR_RELEASE_EVIDENCE_FILE:-artifacts/operator-release.json}"
release_name=foreman
values_secret=foreman-release-values
leader_lease=foreman-release-controller-leader
candlepin_password_backup=""

cleanup() {
  local exit_status=$?

  if [[ -n "${candlepin_password_backup}" ]] && \
    kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl --namespace "${namespace}" patch secret candlepin-runtime \
      --type=merge \
      --patch "$(jq --compact-output --null-input \
        --arg password "${candlepin_password_backup}" \
        '{data: {"database-password": $password}}')" >/dev/null || true
  fi
  exit "${exit_status}"
}
trap cleanup EXIT

application_workload_pod_uids() {
  kubectl --namespace "${namespace}" get pods \
    --selector="app.kubernetes.io/instance=${application_release}" \
    --output=json | jq --raw-output '
      [.items[] |
       select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet")) |
       [.metadata.labels["app.kubernetes.io/component"], .metadata.uid]] |
      sort_by(.[0], .[1])[] |
      @tsv'
}

execution_pod_uids() {
  kubectl --namespace "${namespace}" get pods \
    --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
    --output=json | jq --raw-output '.items[].metadata.uid' | sort
}

helm_revision() {
  helm status "$1" --namespace "${namespace}" --output=json | jq --raw-output '.version'
}

wait_for_release_phase() {
  local expected_phase="$1"
  local expected_generation="$2"
  local timeout_seconds="$3"
  local deadline=$((SECONDS + timeout_seconds))
  local resource
  local phase

  while ((SECONDS < deadline)); do
    resource="$(kubectl --namespace "${namespace}" get foremanrelease "${release_name}" \
      --output=json 2>/dev/null || true)"
    if [[ -n "${resource}" ]]; then
      phase="$(jq --raw-output '.status.phase // "Pending"' <<<"${resource}")"
      if [[ "${phase}" == "${expected_phase}" ]] && \
        [[ "$(jq --raw-output '.status.observedGeneration // 0' <<<"${resource}")" == "${expected_generation}" ]]; then
        printf '%s\n' "${resource}"
        return 0
      fi
      if [[ "${phase}" == Blocked && "${expected_phase}" != Blocked ]]; then
        echo "ForemanRelease entered Blocked while waiting for ${expected_phase}" >&2
        jq '.status' <<<"${resource}" >&2
        return 1
      fi
    fi
    sleep 2
  done

  echo "ForemanRelease did not reach ${expected_phase} at generation ${expected_generation}" >&2
  kubectl --namespace "${namespace}" get foremanrelease "${release_name}" \
    --output=yaml >&2 || true
  return 1
}

wait_for_new_leader() {
  local previous_holder="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  local holder
  local pods

  while ((SECONDS < deadline)); do
    holder="$(kubectl --namespace "${namespace}" get lease "${leader_lease}" \
      --output=jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
    pods="$(kubectl --namespace "${namespace}" get pods \
      --selector=app.kubernetes.io/name=foreman-release-operator \
      --output=json 2>/dev/null || true)"
    if [[ -n "${holder}" && "${holder}" != "${previous_holder}" ]] && \
      jq --exit-status --arg holder "${holder}" \
        'any(.items[]; .metadata.uid == $holder and .status.phase == "Running")' \
        <<<"${pods}" >/dev/null; then
      printf '%s\n' "${holder}"
      return 0
    fi
    sleep 2
  done

  echo 'The standby release controller did not take leadership' >&2
  return 1
}

wait_for_operation_change() {
  local previous_operation="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  local resource
  local operation

  while ((SECONDS < deadline)); do
    resource="$(kubectl --namespace "${namespace}" get foremanrelease "${release_name}" \
      --output=json 2>/dev/null || true)"
    if [[ -n "${resource}" ]]; then
      operation="$(jq --raw-output '.status.operation.id // ""' <<<"${resource}")"
      if [[ -n "${operation}" && "${operation}" != "${previous_operation}" ]]; then
        printf '%s\n' "${resource}"
        return 0
      fi
      if [[ "$(jq --raw-output '.status.phase // "Pending"' <<<"${resource}")" == Blocked ]]; then
        echo 'ForemanRelease blocked while waiting for a drift repair operation' >&2
        jq '.status' <<<"${resource}" >&2
        return 1
      fi
    fi
    sleep 2
  done

  echo 'ForemanRelease did not start a new drift repair operation' >&2
  return 1
}

wait_for_certificate_expiry() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  local resource

  while ((SECONDS < deadline)); do
    resource="$(kubectl --namespace "${namespace}" get foremanrelease "${release_name}" \
      --output=json 2>/dev/null || true)"
    if jq --exit-status '.status.certificateExpiryTimestamp | strings | length > 0' \
      <<<"${resource}" >/dev/null 2>&1; then
      printf '%s\n' "${resource}"
      return 0
    fi
    sleep 2
  done

  echo 'ForemanRelease did not publish certificate expiry after a Ready audit' >&2
  return 1
}

mkdir -p "${workdir}"
helm get values "${application_release}" --namespace "${namespace}" --output=yaml \
  >"${workdir}/application-live.yaml"
helm get values "${execution_release}" --namespace "${namespace}" --output=yaml \
  >"${workdir}/execution-live.yaml"
ruby "${repo_root}/tests/kind/sanitize-operator-values.rb" application \
  "${workdir}/application-live.yaml" "${workdir}/application.yaml"
ruby "${repo_root}/tests/kind/sanitize-operator-values.rb" execution \
  "${workdir}/execution-live.yaml" "${workdir}/execution-proxy.yaml"

kubectl --namespace "${namespace}" create secret generic "${values_secret}" \
  --from-file=application.yaml="${workdir}/application.yaml" \
  --from-file=execution-proxy.yaml="${workdir}/execution-proxy.yaml" \
  --dry-run=client --output=yaml | \
  kubectl --namespace "${namespace}" apply --filename=- >/dev/null

helm upgrade --install foreman-release-operator \
  "${repo_root}/charts/foreman-release-operator" \
  --namespace "${namespace}" \
  --set-string image.repository=foreman-release-operator \
  --set-string image.tag=test \
  --set image.pullPolicy=Never \
  --set controller.pollSeconds=2 \
  --wait \
  --timeout=10m >/dev/null

operator_deployment="$(kubectl --namespace "${namespace}" get deployment \
  --selector=app.kubernetes.io/name=foreman-release-operator \
  --output=jsonpath='{.items[0].metadata.name}')"
kubectl --namespace "${namespace}" rollout status \
  "deployment/${operator_deployment}" --timeout=10m >/dev/null

application_uids_before="$(application_workload_pod_uids)"
execution_uids_before="$(execution_pod_uids)"
application_revision_before="$(helm_revision "${application_release}")"
execution_revision_before="$(helm_revision "${execution_release}")"

candlepin_password_backup="$(kubectl --namespace "${namespace}" get secret \
  candlepin-runtime --output=jsonpath='{.data.database-password}')"
wrong_password="$(printf '%s' 'operator-wrong-password' | openssl base64 -A)"
kubectl --namespace "${namespace}" patch secret candlepin-runtime \
  --type=merge \
  --patch "$(jq --compact-output --null-input \
    --arg password "${wrong_password}" \
    '{data: {"database-password": $password}}')" >/dev/null

kubectl --namespace "${namespace}" apply --filename=- >/dev/null <<YAML
apiVersion: platform.theforeman.org/v1beta1
kind: ForemanRelease
metadata:
  name: ${release_name}
spec:
  compatibilitySet: ${compatibility_set}
  allowCandidate: true
  retryToken: initial
  reconcileToken: initial
  driftCheckSeconds: 60
  operationHistoryLimit: 3
  timeouts:
    preflightSeconds: 300
    leaseSeconds: 900
    migrationSeconds: 300
    applicationRolloutSeconds: 1800
    verificationSeconds: 600
    proxyRolloutSeconds: 900
  failurePolicy:
    afterMigration: Halt
  application:
    releaseName: ${application_release}
    adoptExisting: true
    valuesSecretRef:
      name: ${values_secret}
      key: application.yaml
  executionProxy:
    releaseName: ${execution_release}
    adoptExisting: true
    valuesSecretRef:
      name: ${values_secret}
      key: execution-proxy.yaml
YAML

blocked="$(wait_for_release_phase Blocked 1 600)"
jq --exit-status '
  .status.observedRetryToken == "initial" and
  any(.status.conditions[]?;
      .type == "Degraded" and .status == "True" and .reason == "MigrationsFailed")' \
  <<<"${blocked}" >/dev/null
release_uid="$(jq --raw-output '.metadata.uid' <<<"${blocked}")"
failed_job="$(kubectl --namespace "${namespace}" get jobs \
  --selector="platform.theforeman.org/release-owner=${release_uid},app.kubernetes.io/component=candlepin-migrate" \
  --output=json | jq --exit-status --raw-output '
    [.items[] |
     select(any(.status.conditions[]?; .type == "Failed" and .status == "True"))] |
    sort_by(.metadata.creationTimestamp) |
    last.metadata.name')"

[[ "$(helm_revision "${application_release}")" == "${application_revision_before}" ]]
[[ "$(helm_revision "${execution_release}")" == "${execution_revision_before}" ]]
[[ "$(application_workload_pod_uids)" == "${application_uids_before}" ]]
[[ "$(execution_pod_uids)" == "${execution_uids_before}" ]]

blocked_operation="$(jq --raw-output '.status.operation.id' <<<"${blocked}")"
sleep 5
still_blocked="$(kubectl --namespace "${namespace}" get foremanrelease "${release_name}" --output=json)"
[[ "$(jq --raw-output '.status.phase' <<<"${still_blocked}")" == Blocked ]]
[[ "$(jq --raw-output '.status.operation.id' <<<"${still_blocked}")" == "${blocked_operation}" ]]

leader_before="$(kubectl --namespace "${namespace}" get lease "${leader_lease}" \
  --output=jsonpath='{.spec.holderIdentity}')"
leader_pod="$(kubectl --namespace "${namespace}" get pods \
  --selector=app.kubernetes.io/name=foreman-release-operator \
  --output=json | jq --exit-status --arg holder "${leader_before}" --raw-output \
    '.items[] | select(.metadata.uid == $holder) | .metadata.name')"
kubectl --namespace "${namespace}" delete pod "${leader_pod}" \
  --wait=true --timeout=5m >/dev/null
kubectl --namespace "${namespace}" rollout status \
  "deployment/${operator_deployment}" --timeout=10m >/dev/null
leader_after="$(wait_for_new_leader "${leader_before}" 180)"

kubectl --namespace "${namespace}" patch secret candlepin-runtime \
  --type=merge \
  --patch "$(jq --compact-output --null-input \
    --arg password "${candlepin_password_backup}" \
    '{data: {"database-password": $password}}')" >/dev/null
candlepin_password_backup=""

retry_resource="$(kubectl --namespace "${namespace}" patch foremanrelease "${release_name}" \
  --type=merge --patch='{"spec":{"retryToken":"credentials-restored"}}' --output=json)"
retry_generation="$(jq --raw-output '.metadata.generation' <<<"${retry_resource}")"
ready="$(wait_for_release_phase Ready "${retry_generation}" 1800)"
jq --exit-status --arg holder "${leader_after}" \
  '.spec.holderIdentity == $holder' \
  < <(kubectl --namespace "${namespace}" get lease "${leader_lease}" --output=json) \
  >/dev/null
jq --exit-status --arg set "${compatibility_set}" '
  .status.currentSet == $set and
  .status.observedRetryToken == "credentials-restored" and
  (.status.operation.applicationRevision | tonumber) > 0 and
  (.status.operation.executionProxyRevision | tonumber) > 0 and
  any(.status.conditions[]?; .type == "Available" and .status == "True")' \
  <<<"${ready}" >/dev/null

application_owner="$(kubectl --namespace "${namespace}" get \
  deployment/foreman-foreman-stack-foreman \
  --output=jsonpath='{.metadata.labels.platform\.theforeman\.org/release-owner}')"
execution_owner="$(kubectl --namespace "${namespace}" get \
  deployment/execution-foreman-execution-proxy \
  --output=jsonpath='{.metadata.labels.platform\.theforeman\.org/release-owner}')"
[[ "${application_owner}" == "${release_uid}" ]]
[[ "${execution_owner}" == "${release_uid}" ]]

adopted_resource="$(kubectl --namespace "${namespace}" patch foremanrelease "${release_name}" \
  --type=merge \
  --patch='{"spec":{"application":{"adoptExisting":false},"executionProxy":{"adoptExisting":false}}}' \
  --output=json)"
adopted_generation="$(jq --raw-output '.metadata.generation' <<<"${adopted_resource}")"
ready="$(wait_for_release_phase Ready "${adopted_generation}" 180)"

ready_operation="$(jq --raw-output '.status.operation.id' <<<"${ready}")"
configmap_name="$(kubectl --namespace "${namespace}" get configmaps \
  --selector="app.kubernetes.io/instance=${application_release},app.kubernetes.io/component=foreman-config" \
  --output=json | jq --exit-status --raw-output '.items[0].metadata.name')"
configmap_component="$(kubectl --namespace "${namespace}" get configmap "${configmap_name}" \
  --output=jsonpath='{.metadata.labels.app\.kubernetes\.io/component}')"
kubectl --namespace "${namespace}" label configmap "${configmap_name}" \
  app.kubernetes.io/component=operator-drift --overwrite >/dev/null
repair_started="$(wait_for_operation_change "${ready_operation}" 180)"
repair_operation="$(jq --raw-output '.status.operation.id' <<<"${repair_started}")"
drift_repaired="$(wait_for_release_phase Ready "${adopted_generation}" 1800)"
jq --exit-status --arg operation "${repair_operation}" '
  .status.operation.id == $operation and
  .status.operation.type == "Repair" and
  any(.status.operation.driftedResources[]?; contains("ConfigMap/") and endswith(":modified"))' \
  <<<"${drift_repaired}" >/dev/null
[[ "$(kubectl --namespace "${namespace}" get configmap "${configmap_name}" \
  --output=jsonpath='{.metadata.labels.app\.kubernetes\.io/component}')" == "${configmap_component}" ]]

secret_rotation_operation="$(jq --raw-output '.status.operation.id' <<<"${drift_repaired}")"
secret_rotation_application_uids_before="$(application_workload_pod_uids)"
secret_rotation_execution_uids_before="$(execution_pod_uids)"
kubectl --namespace "${namespace}" annotate secret foreman-runtime \
  "foreman-kubernetes.io/operator-rotation-test=${secret_rotation_operation}" \
  --overwrite >/dev/null
secret_repair_started="$(wait_for_operation_change "${secret_rotation_operation}" 180)"
secret_repair_operation="$(jq --raw-output '.status.operation.id' <<<"${secret_repair_started}")"
secret_repaired="$(wait_for_release_phase Ready "${adopted_generation}" 1800)"
jq --exit-status --arg operation "${secret_repair_operation}" '
  .status.operation.id == $operation and
  .status.operation.type == "Repair" and
  (.status.operation.applicationSecretsSha256 | test("^[0-9a-f]{64}$")) and
  (.status.operation.executionProxySecretsSha256 | test("^[0-9a-f]{64}$")) and
  any(.status.operation.driftedResources[]?; . == "SecretInputs/application:modified")' \
  <<<"${secret_repaired}" >/dev/null
[[ "$(application_workload_pod_uids)" != "${secret_rotation_application_uids_before}" ]]
[[ "$(execution_pod_uids)" != "${secret_rotation_execution_uids_before}" ]]

pvc_name="$(kubectl --namespace "${namespace}" get persistentvolumeclaims \
  --selector="app.kubernetes.io/instance=${application_release}" \
  --output=json | jq --exit-status --raw-output '.items[0].metadata.name')"
pvc_component="$(kubectl --namespace "${namespace}" get persistentvolumeclaim "${pvc_name}" \
  --output=jsonpath='{.metadata.labels.app\.kubernetes\.io/component}')"
kubectl --namespace "${namespace}" label persistentvolumeclaim "${pvc_name}" \
  app.kubernetes.io/component=operator-drift --overwrite >/dev/null
stateful_blocked="$(wait_for_release_phase Blocked "${adopted_generation}" 180)"
jq --exit-status --arg resource "PersistentVolumeClaim/${pvc_name}:modified" '
  any(.status.operation.driftedResources[]?; . == $resource) and
  any(.status.conditions[]?;
      .type == "Degraded" and .status == "True" and .reason == "UnsafeDriftDetected")' \
  <<<"${stateful_blocked}" >/dev/null
kubectl --namespace "${namespace}" label persistentvolumeclaim "${pvc_name}" \
  "app.kubernetes.io/component=${pvc_component}" --overwrite >/dev/null
stateful_retry="$(kubectl --namespace "${namespace}" patch foremanrelease "${release_name}" \
  --type=merge --patch='{"spec":{"retryToken":"stateful-drift-restored"}}' --output=json)"
stateful_retry_generation="$(jq --raw-output '.metadata.generation' <<<"${stateful_retry}")"
ready="$(wait_for_release_phase Ready "${stateful_retry_generation}" 1800)"
ready="$(wait_for_certificate_expiry 180)"
jq --exit-status '
  .status.observedRetryToken == "stateful-drift-restored" and
  (.status.certificateExpiryTimestamp | fromdateiso8601) > now' \
  <<<"${ready}" >/dev/null

mkdir -p "$(dirname "${output_file}")"
jq --null-input \
  --argjson blocked "${blocked}" \
  --argjson drift_repaired "${drift_repaired}" \
  --argjson secret_repaired "${secret_repaired}" \
  --argjson stateful_blocked "${stateful_blocked}" \
  --argjson ready "${ready}" \
  --arg failed_job "${failed_job}" \
  --arg leader_before "${leader_before}" \
  --arg leader_after "${leader_after}" \
  --arg application_revision_before "${application_revision_before}" \
  --arg execution_revision_before "${execution_revision_before}" \
  '{
    blockedStatus: $blocked.status,
    driftRepairStatus: $drift_repaired.status,
    secretRotationStatus: $secret_repaired.status,
    statefulDriftStatus: $stateful_blocked.status,
    readyStatus: $ready.status,
    failedMigrationJob: $failed_job,
    leaderTakeover: {before: $leader_before, after: $leader_after},
    revisionsBeforeRetry: {
      application: ($application_revision_before | tonumber),
      executionProxy: ($execution_revision_before | tonumber)
    }
  }' >"${output_file}"

echo 'ForemanRelease handled migration failure, leader takeover, stateless and Secret repair, stateful drift, and certificate observation.'
