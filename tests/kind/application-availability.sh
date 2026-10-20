#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 TEMPORARY_DIRECTORY" >&2
  exit 2
fi

temporary_directory="$1"
namespace="${NAMESPACE:-foreman}"
deployment="foreman-foreman-stack-foreman"
selector="app.kubernetes.io/instance=foreman,app.kubernetes.io/component=foreman"
workers=8
requests_per_worker=80
probe_directory="${temporary_directory}/foreman-availability"
original_replicas="$(
  kubectl --namespace "${namespace}" get deployment/"${deployment}" \
    --output=jsonpath='{.spec.replicas}'
)"

mkdir -p "${probe_directory}"

restore_replicas() {
  kubectl --namespace "${namespace}" scale deployment/"${deployment}" \
    --replicas="${original_replicas}" >/dev/null
  kubectl --namespace "${namespace}" rollout status deployment/"${deployment}" \
    --timeout=10m >/dev/null
}

trap restore_replicas EXIT

pod_uids() {
  kubectl --namespace "${namespace}" get pods \
    --selector="${selector}" --output=json | jq --raw-output \
      '.items[] | select(.status.phase == "Running") | .metadata.uid' | sort
}

ready_pod_names() {
  kubectl --namespace "${namespace}" get pods \
    --selector="${selector}" --output=json | jq --raw-output \
      '.items[] |
       select(.status.phase == "Running") |
       select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
       .metadata.name' | sort
}

wait_for_ready_count() {
  local expected="$1"
  local pods

  for _ in $(seq 1 180); do
    pods="$(ready_pod_names)"
    if [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"${pods}")" == "${expected}" ]]; then
      printf '%s\n' "${pods}"
      return
    fi
    sleep 2
  done

  echo "Foreman web did not reach ${expected} ready Pods" >&2
  kubectl --namespace "${namespace}" get pods --selector="${selector}" -o wide >&2
  exit 1
}

probe_worker() {
  local worker="$1"
  local output="${probe_directory}/worker-${worker}.log"
  local body
  local request
  local response
  local status

  : > "${output}"
  for request in $(seq 1 "${requests_per_worker}"); do
    if ! response="$(curl --silent --show-error \
      --connect-timeout 3 \
      --max-time 15 \
      --cacert "${temporary_directory}/ca.crt" \
      --resolve foreman.test:8443:127.0.0.1 \
      --write-out $'\n%{http_code}' \
      https://foreman.test:8443/api/v2/ping 2>>"${output}")"; then
      printf 'worker %s request %s failed to connect\n' "${worker}" "${request}" >>"${output}"
      return 1
    fi
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ "${status}" != 200 ]] || ! jq --exit-status \
      '.results.foreman.database.active == true and .results.katello.status == "ok"' \
      <<<"${body}" >/dev/null 2>>"${output}"; then
      printf 'worker %s request %s returned HTTP %s: %s\n' \
        "${worker}" "${request}" "${status}" "${body}" >>"${output}"
      return 1
    fi
    sleep 0.05
  done
}

kubectl --namespace "${namespace}" scale deployment/"${deployment}" --replicas=2
kubectl --namespace "${namespace}" rollout status deployment/"${deployment}" --timeout=10m
wait_for_ready_count 2 >/dev/null

uids_before="$(pod_uids)"
pod_to_delete="$(ready_pod_names | head -n 1)"

pids=()
for worker in $(seq 1 "${workers}"); do
  probe_worker "${worker}" &
  pids+=("$!")
done

sleep 1
kubectl --namespace "${namespace}" delete pod "${pod_to_delete}" --wait=true
kubectl --namespace "${namespace}" rollout status deployment/"${deployment}" --timeout=10m
wait_for_ready_count 2 >/dev/null

failed=0
for pid in "${pids[@]}"; do
  wait "${pid}" || failed=1
done
if [[ "${failed}" == 1 ]]; then
  echo 'Foreman returned an invalid response while one web Pod was replaced' >&2
  grep --with-filename --no-messages '.' "${probe_directory}"/*.log >&2 || true
  exit 1
fi

uids_after="$(pod_uids)"
if [[ "${uids_before}" == "${uids_after}" ]]; then
  echo 'Foreman web Pod set did not change during the availability drill' >&2
  exit 1
fi

kubectl --namespace "${namespace}" scale deployment/"${deployment}" \
  --replicas="${original_replicas}"
kubectl --namespace "${namespace}" rollout status deployment/"${deployment}" --timeout=10m
wait_for_ready_count "${original_replicas}" >/dev/null

trap - EXIT

echo "$((workers * requests_per_worker)) Foreman requests survived one web Pod replacement."
