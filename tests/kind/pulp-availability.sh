#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 TEMPORARY_DIRECTORY CONTENT_STATE_FILE" >&2
  exit 2
fi

temporary_directory="$1"
state_file="$2"
namespace="${NAMESPACE:-foreman}"
api_deployment="foreman-foreman-stack-pulp-api"
content_deployment="foreman-foreman-stack-pulp-content"
api_selector="app.kubernetes.io/instance=foreman,app.kubernetes.io/component=pulp-api"
content_selector="app.kubernetes.io/instance=foreman,app.kubernetes.io/component=pulp-content"
probe_name="pulp-api-availability"
workers=8
requests_per_worker=80
content_checksum="d527380869e9487a3d860b253a6aa5d454b51c419415264e90f018396e419ac5"
probe_directory="${temporary_directory}/pulp-availability"

mkdir -p "${probe_directory}"

ready_pods() {
  local selector="$1"

  kubectl --namespace "${namespace}" get pods \
    --selector="${selector}" --output=json | jq --raw-output \
      '.items[] |
       select(.status.phase == "Running") |
       select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
       .metadata.name' | sort
}

wait_for_ready_count() {
  local selector="$1"
  local expected="$2"
  local pods

  for _ in $(seq 1 180); do
    pods="$(ready_pods "${selector}")"
    if [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"${pods}")" == "${expected}" ]]; then
      printf '%s\n' "${pods}"
      return
    fi
    sleep 2
  done

  echo "${selector} did not reach ${expected} ready Pods" >&2
  kubectl --namespace "${namespace}" get pods --selector="${selector}" -o wide >&2
  exit 1
}

content_probe_worker() {
  local worker="$1"
  local relative_path="$2"
  local output="${probe_directory}/content-${worker}.log"
  local download="${probe_directory}/content-${worker}.bin"
  local request
  local checksum

  : > "${output}"
  for request in $(seq 1 "${requests_per_worker}"); do
    if ! curl --fail --silent --show-error \
      --connect-timeout 3 \
      --max-time 15 \
      --cacert "${temporary_directory}/ca.crt" \
      --resolve content.test:8443:127.0.0.1 \
      --output "${download}" \
      "https://content.test:8443/pulp/content/${relative_path}/foreman-kubernetes-content.txt" \
      2>>"${output}"; then
      printf 'content worker %s request %s failed\n' "${worker}" "${request}" >>"${output}"
      return 1
    fi
    checksum="$(openssl dgst -sha256 -r "${download}" | awk '{print $1}')"
    if [[ "${checksum}" != "${content_checksum}" ]]; then
      printf 'content worker %s request %s returned checksum %s\n' \
        "${worker}" "${request}" "${checksum}" >>"${output}"
      return 1
    fi
    sleep 0.05
  done
}

deploy_api_probe() {
  local foreman_image="$1"

  kubectl --namespace "${namespace}" delete pod/"${probe_name}" \
    --ignore-not-found=true --wait=true
  kubectl apply --filename=- <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${probe_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/instance: foreman
    app.kubernetes.io/component: smoke-test
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 994
    runAsGroup: 994
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ${foreman_image}
      imagePullPolicy: IfNotPresent
      command: [ruby, -rjson, -rnet/http, -ruri, -e]
      args:
        - |
          STDOUT.sync = true
          url = URI('http://foreman-foreman-stack-pulp-api:24817/pulp/api/v3/status/')
          puts 'READY'
          threads = 8.times.map do
            Thread.new do
              80.times do
                response = Net::HTTP.start(url.host, url.port, open_timeout: 3, read_timeout: 15) do |http|
                  http.get(url.request_uri)
                end
                abort "Pulp API returned #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
                status = JSON.parse(response.body)
                abort 'Pulp database is disconnected' if status.dig('database_connection', 'connected') == false
                abort 'Pulp cache is disconnected' if status.dig('redis_connection', 'connected') == false
                abort 'Pulp workers disappeared' if Array(status['online_workers']).empty?
                abort 'Pulp content apps disappeared' if Array(status['online_content_apps']).empty?
                sleep 0.05
              end
            end
          end
          threads.each(&:value)
          puts 'API_OK'
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        readOnlyRootFilesystem: true
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 128Mi
EOF
}

wait_for_probe_marker() {
  local marker="$1"

  for _ in $(seq 1 120); do
    if kubectl --namespace "${namespace}" logs pod/"${probe_name}" 2>/dev/null | \
      grep --fixed-strings --quiet "${marker}"; then
      return
    fi
    if [[ "$(kubectl --namespace "${namespace}" get pod/"${probe_name}" \
      --output=jsonpath='{.status.phase}' 2>/dev/null || true)" == Failed ]]; then
      kubectl --namespace "${namespace}" logs pod/"${probe_name}" >&2 || true
      exit 1
    fi
    sleep 1
  done

  echo "Pulp API probe did not report ${marker}" >&2
  kubectl --namespace "${namespace}" logs pod/"${probe_name}" >&2 || true
  exit 1
}

relative_path="$(jq --exit-status --raw-output '.published_relative_path' "${state_file}")"
relative_path="${relative_path#/}"
relative_path="${relative_path%/}"
foreman_image="$(kubectl --namespace "${namespace}" get \
  deployment/foreman-foreman-stack-foreman \
  --output=jsonpath='{.spec.template.spec.containers[0].image}')"

kubectl --namespace "${namespace}" scale deployment/"${api_deployment}" --replicas=2
kubectl --namespace "${namespace}" scale deployment/"${content_deployment}" --replicas=2
kubectl --namespace "${namespace}" rollout status deployment/"${api_deployment}" --timeout=10m
kubectl --namespace "${namespace}" rollout status deployment/"${content_deployment}" --timeout=10m
wait_for_ready_count "${api_selector}" 2 >/dev/null
wait_for_ready_count "${content_selector}" 2 >/dev/null

api_pod_to_delete="$(ready_pods "${api_selector}" | head -n 1)"
content_pod_to_delete="$(ready_pods "${content_selector}" | head -n 1)"
deploy_api_probe "${foreman_image}"
wait_for_probe_marker READY

pids=()
for worker in $(seq 1 "${workers}"); do
  content_probe_worker "${worker}" "${relative_path}" &
  pids+=("$!")
done

sleep 1
kubectl --namespace "${namespace}" delete pod \
  "${api_pod_to_delete}" "${content_pod_to_delete}" --wait=true
kubectl --namespace "${namespace}" rollout status deployment/"${api_deployment}" --timeout=10m
kubectl --namespace "${namespace}" rollout status deployment/"${content_deployment}" --timeout=10m
wait_for_ready_count "${api_selector}" 2 >/dev/null
wait_for_ready_count "${content_selector}" 2 >/dev/null

failed=0
for pid in "${pids[@]}"; do
  wait "${pid}" || failed=1
done
wait_for_probe_marker API_OK
if [[ "${failed}" == 1 ]]; then
  echo 'Pulp content returned an invalid response while one content Pod was replaced' >&2
  grep --with-filename --no-messages '.' "${probe_directory}"/*.log >&2 || true
  exit 1
fi

kubectl --namespace "${namespace}" delete pod/"${probe_name}" --wait=true
kubectl --namespace "${namespace}" scale deployment/"${api_deployment}" --replicas=1
kubectl --namespace "${namespace}" scale deployment/"${content_deployment}" --replicas=1
kubectl --namespace "${namespace}" rollout status deployment/"${api_deployment}" --timeout=10m
kubectl --namespace "${namespace}" rollout status deployment/"${content_deployment}" --timeout=10m
wait_for_ready_count "${api_selector}" 1 >/dev/null
wait_for_ready_count "${content_selector}" 1 >/dev/null

echo 'Pulp API and public content requests survived one Pod replacement each.'
