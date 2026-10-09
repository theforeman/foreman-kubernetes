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
export RELEASE_HOLDER_ID=test-holder
export RELEASE_OPERATION_ID=test-operation

cat > "${fake_bin}/helm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ "$1" == template && "$2" == foreman && "$*" == *'releaseOperation.id=test-operation'* && "$*" != *'--show-only'* ]]; then
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
if [[ -n "${FAKE_HELM_FAIL_MATCH:-}" && "$*" == *"${FAKE_HELM_FAIL_MATCH}"* ]]; then
  match_count=1
  if [[ -n "${FAKE_HELM_MATCH_COUNT_FILE:-}" ]]; then
    if [[ -s "${FAKE_HELM_MATCH_COUNT_FILE}" ]]; then
      match_count="$(<"${FAKE_HELM_MATCH_COUNT_FILE}")"
      match_count=$((match_count + 1))
    fi
    printf '%s\n' "${match_count}" > "${FAKE_HELM_MATCH_COUNT_FILE}"
  fi
  if [[ "${match_count}" == "${FAKE_HELM_FAIL_ON_MATCH:-1}" ]]; then
    exit 1
  fi
fi
case "$*" in
  'get values foreman --namespace foreman --all --output=json')
    printf '{"platform":{"compatibilitySet":"%s"}}\n' "${FAKE_APPLICATION_SET:-nightly-candidate-2026-09-24}"
    ;;
  'get values execution --namespace foreman --all --output=json')
    printf '{"compatibilitySet":"%s"}\n' "${FAKE_EXECUTION_SET:-nightly-candidate-2026-09-24}"
    ;;
  *'--show-only templates/foreman.yaml'*)
    printf '%s\n' 'kind: Service'
    if [[ "${FAKE_FOREMAN_DEPLOYMENT:-1}" == 1 ]]; then
      printf '%s\n' '---' 'kind: Deployment'
    fi
    ;;
  *'--show-only templates/dynflow.yaml'*)
    printf '%s\n' 'kind: Deployment' '---' 'kind: Deployment' '---' 'kind: Deployment'
    ;;
  *'--show-only templates/migrations.yaml'*)
    printf '%s\n' 'kind: Job' '---' 'kind: Job' '---' 'kind: Job'
    ;;
  *'--show-only templates/dependency-preflight.yaml'*)
    printf '%s\n' 'kind: Job'
    ;;
esac
if [[ "$1" == template && "$2" == foreman && "$*" != *'--show-only'* ]]; then
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
    printf '%s\n' '{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"name":"foreman-kubernetes-release","namespace":"foreman","resourceVersion":"1"},"spec":{"holderIdentity":"other-upgrade","leaseDurationSeconds":120,"renewTime":"2099-01-01T00:00:00Z"}}'
  fi
fi
if [[ "$*" == *'get secret required-runtime'* ]]; then
  if [[ -z "${FAKE_SECRET_JSON:-}" ]]; then
    exit 1
  fi
  printf '%s\n' "${FAKE_SECRET_JSON}"
fi
SCRIPT

chmod +x "${fake_bin}/helm" "${fake_bin}/kubectl"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  "${repo_root}/scripts/upgrade-release.sh" \
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
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'upgrade continued while another holder owned the namespace lock' >&2
  exit 1
fi
if grep -Fq 'helm ' "${tool_log}"; then
  echo 'Helm was invoked before the namespace lock was acquired' >&2
  exit 1
fi

: > "${tool_log}"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_APPLICATION_SET='undeclared-set' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'upgrade from an undeclared compatibility set was accepted' >&2
  exit 1
fi
if grep -Fq 'helm status ' "${tool_log}" || grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'release preflight or mutation started after upgrade-path rejection' >&2
  exit 1
fi

: > "${tool_log}"

PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='create --filename -' \
  FAKE_EXISTING_LEASE_JSON='{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"name":"foreman-kubernetes-release","namespace":"foreman","resourceVersion":"7"},"spec":{"holderIdentity":"dead-upgrade","leaseDurationSeconds":30,"renewTime":"2000-01-01T00:00:00Z"}}' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null
if ! grep -Fq 'kubectl --namespace foreman replace --filename -' "${tool_log}"; then
  echo 'expired release Lease was not claimed with an optimistic replace' >&2
  exit 1
fi

: > "${tool_log}"

PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null

cat > "${temporary_directory}/expected.log" <<EOF
kubectl get namespace foreman
kubectl --namespace foreman create --filename -
helm get values foreman --namespace foreman --all --output=json
helm get values execution --namespace foreman --all --output=json
helm status foreman --namespace foreman
helm status execution --namespace foreman
kubectl --namespace foreman wait --for=condition=Ready pod --selector=app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy --timeout=10m
helm test foreman --namespace foreman --logs --timeout 10m
helm lint ${repo_root}/charts/foreman-stack --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --show-only templates/foreman.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --show-only templates/dynflow.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --show-only templates/migrations.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --set-string releaseOperation.id=test-operation --set-string releaseOperation.ownerUid=test-operation --show-only templates/dependency-preflight.yaml
helm lint ${repo_root}/charts/foreman-execution-proxy --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml
helm template execution ${repo_root}/charts/foreman-execution-proxy --namespace foreman --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml
kubectl --namespace foreman apply --dry-run=server --filename -
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --set-string releaseOperation.id=test-operation --set-string releaseOperation.ownerUid=test-operation
kubectl --namespace foreman apply --filename -
kubectl --namespace foreman wait --for=condition=complete job --selector=platform.theforeman.org/release-operation=test-operation,app.kubernetes.io/component=dependency-preflight --timeout=30m
kubectl --namespace foreman apply --filename -
kubectl --namespace foreman wait --for=condition=complete job --selector=platform.theforeman.org/release-operation=test-operation --timeout=30m
helm upgrade foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --set releaseOperation.skipMigrationJobs=true --wait --wait-for-jobs --timeout 30m
helm test foreman --namespace foreman --filter name=.*-smoke-test$ --logs --timeout 10m
helm upgrade execution ${repo_root}/charts/foreman-execution-proxy --namespace foreman --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml --wait --timeout 30m
kubectl --namespace foreman wait --for=condition=Ready pod --selector=app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy --timeout=10m
helm test foreman --namespace foreman --logs --timeout 10m
helm test execution --namespace foreman --logs --timeout 10m
kubectl --namespace foreman get lease foreman-kubernetes-release --output=jsonpath={.spec.holderIdentity}
kubectl --namespace foreman delete lease foreman-kubernetes-release --wait=true
EOF
diff -u "${temporary_directory}/expected.log" "${tool_log}"

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='wait --for=condition=complete job' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed migration stage unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade foreman ' "${tool_log}"; then
  echo 'application workloads were upgraded after migration failure' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_FAIL_MATCH='upgrade foreman ' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed application upgrade unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade execution ' "${tool_log}"; then
  echo 'execution proxy was upgraded after the application upgrade failed' >&2
  exit 1
fi

: > "${tool_log}"
: > "${temporary_directory}/match-count"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_FAIL_MATCH='test foreman ' \
  FAKE_HELM_FAIL_ON_MATCH=2 \
  FAKE_HELM_MATCH_COUNT_FILE="${temporary_directory}/match-count" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed post-upgrade application smoke test unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade execution ' "${tool_log}"; then
  echo 'execution proxy was upgraded after the application smoke test failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_FOREMAN_DEPLOYMENT=0 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'maintenance-mode render was accepted by the normal upgrade helper' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'an upgrade started after preflight detected maintenance mode' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SECRET=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'upgrade accepted a missing externally managed Secret' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'an upgrade started after Secret preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SECRET=1 \
  FAKE_SECRET_JSON='{"data":{"username":"dXNlcg=="}}' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'upgrade accepted an externally managed Secret without its required key' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'an upgrade started after Secret key preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='apply --dry-run=server' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'upgrade accepted a server-side admission rejection' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'an upgrade started after admission preflight failed' >&2
  exit 1
fi

if grep -Fq -- '--atomic' "${repo_root}/scripts/upgrade-release.sh"; then
  echo 'upgrade helper must not automatically roll back migrated schemas' >&2
  exit 1
fi

echo 'Upgrade release sequencing checks passed.'
