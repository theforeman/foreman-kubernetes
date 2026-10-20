#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
namespace="${NAMESPACE:-foreman}"
compatibility_set="${COMPATIBILITY_SET:?COMPATIBILITY_SET is required}"
image_profile="${IMAGE_PROFILE:?IMAGE_PROFILE is required}"
output_file="${PULP_OBJECT_STORAGE_EVIDENCE_FILE:-artifacts/pulp-object-storage.json}"
job_name=foreman-foreman-stack-pulp-object-storage-test
secret_name=pulp-object-storage-probe
last_probe_logs=""
last_probe_result=""

apply_probe_credentials() {
  local access_key="$1"
  local secret_key="$2"

  kubectl --namespace "${namespace}" create secret generic "${secret_name}" \
    --from-literal=access-key-id="${access_key}" \
    --from-literal=secret-access-key="${secret_key}" \
    --dry-run=client --output=yaml | \
    kubectl --namespace "${namespace}" apply --filename=- >/dev/null
}

start_probe() {
  kubectl --namespace "${namespace}" delete job "${job_name}" \
    --ignore-not-found --wait=true >/dev/null
  kubectl --namespace "${namespace}" apply --filename="${manifest}" >/dev/null
}

wait_for_probe_terminal() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  local job

  while ((SECONDS < deadline)); do
    job="$(kubectl --namespace "${namespace}" get job "${job_name}" --output=json)"
    if jq --exit-status \
      'any(.status.conditions[]?; .type == "Complete" and .status == "True")' \
      <<<"${job}" >/dev/null; then
      echo complete
      return 0
    fi
    if jq --exit-status \
      'any(.status.conditions[]?; .type == "Failed" and .status == "True")' \
      <<<"${job}" >/dev/null; then
      echo failed
      return 0
    fi
    sleep 2
  done

  echo timeout
}

run_successful_probe() {
  local outcome

  start_probe
  outcome="$(wait_for_probe_terminal 600)"
  if [[ "${outcome}" != complete ]]; then
    echo "Object-storage probe ended with ${outcome}, expected complete" >&2
    kubectl --namespace "${namespace}" logs "job/${job_name}" >&2 || true
    kubectl --namespace "${namespace}" describe "job/${job_name}" >&2 || true
    return 1
  fi

  last_probe_logs="$(kubectl --namespace "${namespace}" logs "job/${job_name}")"
  last_probe_result="$(jq --raw-input --slurp '
    [split("\n")[] | fromjson? | select(type == "object" and has("backend"))] | last
  ' <<<"${last_probe_logs}")"
  jq --exit-status '
    .backend == "S3Storage" and
    .bucket == "foreman-pulp-probe" and
    .location == "qualification" and
    .bytes == 9437185 and
    .directDownload == true and
    .objectVersions >= 2 and
    .deleteMarkers >= 1 and
    (.recoveredFromVersion | type == "string" and length > 0) and
    .versionRecoverySha256 == .sha256
  ' <<<"${last_probe_result}" >/dev/null
}

require_old_credentials_rejected() {
  local outcome

  start_probe
  outcome="$(wait_for_probe_terminal 180)"
  if [[ "${outcome}" == complete ]]; then
    echo 'The retired object-storage credentials still completed a write' >&2
    return 1
  fi
  if [[ "${outcome}" != failed ]]; then
    echo "Old-credential probe ended with ${outcome}, expected failed" >&2
    return 1
  fi
  old_credential_logs="$(kubectl --namespace "${namespace}" logs "job/${job_name}")"
  if ! grep -Eiq 'InvalidAccessKeyId|SignatureDoesNotMatch|AccessDenied' \
    <<<"${old_credential_logs}"; then
    echo 'The old-credential probe failed without an S3 authentication error' >&2
    printf '%s\n' "${old_credential_logs}" >&2
    return 1
  fi
}

kind_node="${KIND_CLUSTER_NAME:-foreman-stack-e2e}-control-plane"
docker exec "${kind_node}" \
  install -d -m 0770 -o 1000 -g 1000 /var/local/foreman-kind-object-storage
kubectl apply --filename="${repo_root}/tests/kind/object-storage.yaml" >/dev/null
kubectl --namespace "${namespace}" rollout status \
  deployment/object-storage --timeout=10m >/dev/null

apply_probe_credentials foreman-pulp-test foreman-pulp-secret-test

manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT
helm template foreman "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${image_profile}" \
  --set pulp.storage.backend=s3 \
  --set-string pulp.storage.existingClaim= \
  --set-string pulp.storage.s3.bucket=foreman-pulp-probe \
  --set-string pulp.storage.s3.location=qualification \
  --set-string pulp.storage.s3.region=us-east-1 \
  --set-string pulp.storage.s3.endpointUrl=http://object-storage:8333 \
  --set-string pulp.storage.s3.addressingStyle=path \
  --set pulp.storage.s3.redirectToObjectStorage=true \
  --set-string pulp.storage.s3.existingSecret="${secret_name}" \
  --show-only templates/tests/pulp-object-storage.yaml \
  >"${manifest}"

run_successful_probe
initial_result="${last_probe_result}"
printf '%s\n' "${last_probe_logs}"

kubectl --namespace "${namespace}" set env deployment/object-storage \
  AWS_ACCESS_KEY_ID=foreman-pulp-rotated \
  AWS_SECRET_ACCESS_KEY=foreman-pulp-secret-rotated >/dev/null
kubectl --namespace "${namespace}" rollout status \
  deployment/object-storage --timeout=10m >/dev/null
require_old_credentials_rejected

apply_probe_credentials foreman-pulp-rotated foreman-pulp-secret-rotated
run_successful_probe
rotated_result="${last_probe_result}"
printf '%s\n' "${last_probe_logs}"

mkdir -p "$(dirname "${output_file}")"
jq --null-input \
  --arg compatibility_set "${compatibility_set}" \
  --arg emulator_image "chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882" \
  --argjson initial "${initial_result}" \
  --argjson rotated "${rotated_result}" \
  '{
    compatibilitySet: $compatibility_set,
    emulatorImage: $emulator_image,
    oldCredentialsRejected: true,
    initial: $initial,
    rotated: $rotated
  }' >"${output_file}"

echo 'Pulp completed direct versioned multipart transfers and exact-version recovery before and after credential rotation.'
