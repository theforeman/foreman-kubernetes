#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
fake_bin="${temporary_directory}/bin"
tool_log="${temporary_directory}/tools.log"
application_values="${temporary_directory}/application.yaml"
execution_values="${temporary_directory}/execution.yaml"

cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}"
: > "${application_values}"
: > "${execution_values}"
: > "${tool_log}"
export RELEASE_HOLDER_ID=test-holder
export RELEASE_OPERATION_ID=test-operation

cat > "${fake_bin}/helm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ "$1" == template && "$2" == foreman && "$*" == *'releaseOperation.id=test-operation'* ]]; then
  printf '%s\n' \
    'apiVersion: v1' 'kind: ServiceAccount' 'metadata:' '  name: foreman-runtime' \
    '---' 'apiVersion: v1' 'kind: ServiceAccount' 'metadata:' '  name: pulp-runtime' \
    '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: migration-config' \
    '---' 'apiVersion: v1' 'kind: PersistentVolumeClaim' 'metadata:' '  name: shared-tmp' \
    '---' \
    'apiVersion: batch/v1' 'kind: Job' 'metadata:' '  name: dependency-preflight-test-operation' \
    '  annotations:' '    helm.sh/hook: pre-install,pre-upgrade' '  labels:' \
    '    app.kubernetes.io/component: dependency-preflight' '    app.kubernetes.io/instance: foreman' \
    '    platform.theforeman.org/release-operation: test-operation' \
    '    platform.theforeman.org/release-owner: test-operation' 'spec:' '  template:' '    spec:' \
    '      serviceAccountName: pulp-runtime' '---'
  for component in candlepin-migrate pulp-migrate foreman-migrate; do
    printf '%s\n' \
      'apiVersion: batch/v1' 'kind: Job' 'metadata:' "  name: ${component}-test-operation" \
      '  annotations:' '    helm.sh/hook: pre-install,pre-upgrade' '  labels:' \
      "    app.kubernetes.io/component: ${component}" '    app.kubernetes.io/instance: foreman' \
      '    platform.theforeman.org/release-operation: test-operation' \
      '    platform.theforeman.org/release-owner: test-operation' 'spec:' '  template:' '    spec:' \
      '      serviceAccountName: foreman-runtime' '      volumes:' \
      '        - name: config' '          configMap:' '            name: migration-config' \
      '        - name: shared' '          persistentVolumeClaim:' '            claimName: shared-tmp' \
      '---'
  done
  exit 0
fi
if [[ "$1" == list ]]; then
  [[ "${FAKE_HELM_LIST_FAIL:-0}" == 0 ]] || exit 1
  printf '%s\n' "${FAKE_HELM_LIST_JSON:-[]}"
  exit 0
fi
if [[ "$1" == template && "$2" == foreman ]]; then
  printf '%s\n' \
    'apiVersion: apps/v1' \
    'kind: Deployment' \
    'metadata:' \
    '  labels:' \
    '    app.kubernetes.io/component: foreman'
  if [[ "${FAKE_RENDER_SECRET:-0}" == 1 ]]; then
    printf '%s\n' \
      'spec:' \
      '  template:' \
      '    spec:' \
      '      containers:' \
      '        - name: foreman' \
      '          env:' \
      '            - name: PASSWORD' \
      '              valueFrom:' \
      '                secretKeyRef:' \
      '                  name: required-runtime' \
      '                  key: password'
  fi
  if [[ "${FAKE_RENDER_SELECTOR:-0}" == 1 ]]; then
    printf '%s\n' \
      'spec:' \
      '  template:' \
      '    spec:' \
      '      nodeSelector:' \
      '        kubernetes.io/arch: amd64' \
      '        workload: foreman' \
      '      tolerations:' \
      '        - key: dedicated' \
      '          operator: Equal' \
      '          value: foreman' \
      '          effect: NoSchedule' \
      '        - key: maintenance' \
      '          operator: Exists'
  fi
  if [[ "${FAKE_RENDER_EXTERNAL_PVC:-0}" == 1 ]]; then
    printf '%s\n' \
      'spec:' \
      '  template:' \
      '    spec:' \
      '      volumes:' \
      '        - name: imported' \
      '          persistentVolumeClaim:' \
      '            claimName: imported-content'
  fi
  printf '%s\n' \
    '---' 'kind: Job' \
    '---' 'kind: Job' \
    '---' 'kind: Job' \
    '---' 'kind: Job' \
    '---' 'kind: Job'
  if [[ "${FAKE_RENDER_INGRESS:-0}" == 1 ]]; then
    printf '%s\n' \
      '---' \
      'apiVersion: networking.k8s.io/v1' \
      'kind: Ingress' \
      'metadata:' \
      '  annotations:' \
      '    foreman-kubernetes.io/required-ingress-controller: k8s.io/ingress-nginx' \
      'spec:' \
      '  ingressClassName: nginx'
  fi
  if [[ "${FAKE_RENDER_HPA:-0}" == 1 ]]; then
    printf '%s\n' \
      '---' \
      'apiVersion: autoscaling/v2' \
      'kind: HorizontalPodAutoscaler' \
      'metadata:' \
      '  name: foreman' \
      'spec:' \
      '  metrics:' \
      '    - type: Resource' \
      '      resource:' \
      '        name: cpu'
  fi
fi
if [[ -n "${FAKE_HELM_FAIL_MATCH:-}" && "$*" == *"${FAKE_HELM_FAIL_MATCH}"* ]]; then
  exit 1
fi
SCRIPT

cat > "${fake_bin}/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ -n "${FAKE_KUBECTL_FAIL_MATCH:-}" && "$*" == *"${FAKE_KUBECTL_FAIL_MATCH}"* ]]; then
  exit 1
fi
if [[ "$*" == *'get lease foreman-kubernetes-release --output=jsonpath={.spec.holderIdentity}' ]]; then
  printf '%s' "${FAKE_EXISTING_LEASE_HOLDER:-${RELEASE_HOLDER_ID:-test-holder}}"
fi
if [[ "$*" == *'get lease foreman-kubernetes-release --output=json' ]]; then
  if [[ -n "${FAKE_EXISTING_LEASE_JSON:-}" ]]; then
    printf '%s\n' "${FAKE_EXISTING_LEASE_JSON}"
  else
    printf '%s\n' '{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"name":"foreman-kubernetes-release","namespace":"foreman","resourceVersion":"1"},"spec":{"holderIdentity":"other-install","leaseDurationSeconds":120,"renewTime":"2099-01-01T00:00:00Z"}}'
  fi
fi
if [[ "$*" == *'get secret required-runtime'* ]]; then
  if [[ -z "${FAKE_SECRET_JSON:-}" ]]; then
    exit 1
  fi
  printf '%s\n' "${FAKE_SECRET_JSON}"
fi
if [[ "$*" == 'get storageclass --output=json' ]]; then
  printf '%s\n' '{"items":[{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}'
fi
if [[ "$*" == 'get nodes --output=json' ]]; then
  printf '{"items":[{"metadata":{"labels":{"kubernetes.io/arch":"%s","workload":"%s"}},"spec":{"taints":[{"key":"dedicated","value":"%s","effect":"NoSchedule"},{"key":"maintenance","value":"window","effect":"NoExecute"}]},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\n' \
    "${FAKE_NODE_ARCH:-amd64}" "${FAKE_NODE_WORKLOAD:-foreman}" "${FAKE_NODE_TAINT_VALUE:-foreman}"
fi
if [[ "$*" == '--namespace foreman get persistentvolumeclaim imported-content --output=json' ]]; then
  printf '{"metadata":{"name":"imported-content"},"spec":{"storageClassName":"%s"},"status":{"phase":"%s"}}\n' \
    "${FAKE_PVC_STORAGE_CLASS:-}" "${FAKE_PVC_PHASE:-Bound}"
fi
if [[ "$*" == 'get storageclass zonal-delayed --output=json' ]]; then
  printf '{"metadata":{"name":"zonal-delayed"},"volumeBindingMode":"%s"}\n' \
    "${FAKE_VOLUME_BINDING_MODE:-WaitForFirstConsumer}"
fi
if [[ "$*" == 'get IngressClass nginx --output=json' ]]; then
  printf '{"spec":{"controller":"%s"}}\n' "${FAKE_INGRESS_CONTROLLER:-k8s.io/ingress-nginx}"
fi
if [[ "$*" == 'get apiservice v1beta1.metrics.k8s.io --output=json' ]]; then
  [[ "${FAKE_METRICS_API_EXISTS:-1}" == 1 ]] || exit 1
  printf '{"status":{"conditions":[{"type":"Available","status":"%s"}]}}\n' \
    "${FAKE_METRICS_API_STATUS:-True}"
fi
SCRIPT

chmod +x "${fake_bin}/helm" "${fake_bin}/kubectl"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'candidate compatibility set was accepted without explicit qualification opt-in' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'candidate gate invoked cluster tools before rejecting the release set' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='create --filename -' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation continued while another holder owned the release Lease' >&2
  exit 1
fi
if grep -Fq 'helm ' "${tool_log}"; then
  echo 'Helm was invoked before the release Lease was acquired' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_LIST_FAIL=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation treated a Helm release-list failure as an empty namespace' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Helm release discovery failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_LIST_JSON='[{"name":"foreman"}]' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an existing application release' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation overwrote an existing release' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null

application_install="helm upgrade --install foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --set releaseOperation.skipMigrationJobs=true --wait --wait-for-jobs --timeout 30m"
execution_install="helm upgrade --install execution ${repo_root}/charts/foreman-execution-proxy --namespace foreman --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml --wait --timeout 30m"

grep -Fqx "${application_install}" "${tool_log}"
grep -Fqx "${execution_install}" "${tool_log}"

stage_render="helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --set-string releaseOperation.id=test-operation --set-string releaseOperation.ownerUid=test-operation"
grep -Fqx "${stage_render}" "${tool_log}"
grep -Fqx 'kubectl --namespace foreman apply --dry-run=server --filename -' "${tool_log}"
grep -Fqx 'kubectl --namespace foreman apply --filename -' "${tool_log}"
grep -Fqx 'kubectl --namespace foreman wait --for=condition=complete job --selector=platform.theforeman.org/release-operation=test-operation --timeout=30m' "${tool_log}"

application_line="$(grep -Fn "${application_install}" "${tool_log}" | cut -d: -f1)"
first_smoke_line="$(grep -Fn 'helm test foreman --namespace foreman --filter name=.*-smoke-test$ --logs --timeout 10m' "${tool_log}" | head -n 1 | cut -d: -f1)"
execution_line="$(grep -Fn "${execution_install}" "${tool_log}" | cut -d: -f1)"
if ! (( application_line < first_smoke_line && first_smoke_line < execution_line )); then
  echo 'execution proxy was installed before the application smoke gate' >&2
  exit 1
fi
grep -Fqx 'helm test execution --namespace foreman --logs --timeout 10m' "${tool_log}"

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='wait --for=condition=complete job' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed migration stage unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install foreman ' "${tool_log}"; then
  echo 'application workloads were installed after migration failure' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_FAIL_MATCH='test foreman ' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed application smoke test unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install execution ' "${tool_log}"; then
  echo 'execution proxy was installed after the application smoke test failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SECRET=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted a missing externally managed Secret' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Secret preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SECRET=1 \
  FAKE_SECRET_JSON='{"data":{"username":"dXNlcg=="}}' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an externally managed Secret without its required key' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Secret key preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_INGRESS=1 \
  FAKE_INGRESS_CONTROLLER=example.invalid/controller \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an incompatible ingress implementation' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after ingress implementation preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_HPA=1 \
  FAKE_METRICS_API_STATUS=False \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted autoscaling without an available resource Metrics API' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Metrics API preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SELECTOR=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SELECTOR=1 \
  FAKE_NODE_TAINT_VALUE=other \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted workloads without a tolerable node taint' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after node scheduling preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_EXTERNAL_PVC=1 \
  FAKE_PVC_PHASE=Pending \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an unbound external PersistentVolumeClaim' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after external PersistentVolumeClaim preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_EXTERNAL_PVC=1 \
  FAKE_PVC_PHASE=Pending \
  FAKE_PVC_STORAGE_CLASS=zonal-delayed \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='apply --dry-run=server' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted a server-side admission rejection' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after admission preflight failed' >&2
  exit 1
fi

if grep -Fq -- '--atomic' "${repo_root}/scripts/install-release.sh"; then
  echo 'install helper must not automatically roll back migrated schemas' >&2
  exit 1
fi

echo 'Install release sequencing checks passed.'
