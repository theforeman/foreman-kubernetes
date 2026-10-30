#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
fake_bin="${temporary_directory}/bin"
tool_log="${temporary_directory}/tools.log"
application_values="${temporary_directory}/application.yaml"
execution_values="${temporary_directory}/execution.yaml"
application_profile_override="${temporary_directory}/application-profile.yaml"
execution_profile_override="${temporary_directory}/execution-profile.yaml"

cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}"
: > "${application_values}"
: > "${execution_values}"
: > "${application_profile_override}"
: > "${execution_profile_override}"
: > "${tool_log}"
export RELEASE_HOLDER_ID=test-recovery-holder

cat > "${fake_bin}/helm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ "${FAKE_RECOVERY_UPGRADE_FAIL:-0}" == 1 && "$1" == upgrade && "$*" == *'backup.enabled=true'* ]]; then
  exit 1
fi
if [[ "${FAKE_HELM_STATUS_MISSING:-0}" == 1 && "$1" == status ]]; then
  exit 1
fi
case "$*" in
  'get values foreman --namespace foreman --all --output=json')
    printf '{"platform":{"compatibilitySet":"%s"},"maintenance":{"enabled":%s},"backup":{"enabled":false},"restore":{"enabled":false}}\n' \
      "${FAKE_APPLICATION_SET:-nightly-candidate-2026-09-24}" "${FAKE_MAINTENANCE_ENABLED:-false}"
    ;;
  'get values execution --namespace foreman --all --output=json')
    printf '{"compatibilitySet":"%s","maintenance":{"enabled":%s}}\n' \
      "${FAKE_EXECUTION_SET:-nightly-candidate-2026-09-24}" "${FAKE_MAINTENANCE_ENABLED:-false}"
    ;;
esac
if [[ "$1" == template && "$2" == foreman ]]; then
  if [[ "$*" == *'backup.enabled=true'* || "$*" == *'restore.enabled=true'* ]]; then
    printf '%s\n' 'apiVersion: batch/v1' 'kind: Job' 'metadata:' '  name: recovery'
  else
    printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: foreman'
  fi
fi
if [[ "$1" == template && "$2" == execution && "$*" != *'maintenance.enabled=true'* ]]; then
  cat <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: execution
  labels:
    app.kubernetes.io/component: execution-proxy
spec:
  template:
    spec:
      volumes:
        - name: state
          persistentVolumeClaim:
            claimName: execution-state
        - name: ansible-content
          persistentVolumeClaim:
            claimName: execution-ansible
        - name: server-tls
          secret:
            secretName: execution-tls
YAML
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
  printf '%s' "${RELEASE_HOLDER_ID}"
fi
if [[ "$*" == *'get persistentvolumeclaim execution-'*' --output=json' ]]; then
  printf '{"status":{"phase":"%s"}}\n' "${FAKE_PVC_PHASE:-Bound}"
fi
SCRIPT

chmod +x "${fake_bin}/helm" "${fake_bin}/kubectl"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-1 >/dev/null 2>&1; then
  echo 'candidate compatibility set was accepted without explicit qualification opt-in' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'candidate gate invoked cluster tools before rejecting recovery' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  APPLICATION_PROFILE_OVERRIDE="${application_profile_override}" \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-pair >/dev/null 2>&1; then
  echo 'recovery accepted only one qualification profile override' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'incomplete recovery profile override invoked cluster tools' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_EXECUTION_SET='previous-set' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-0 >/dev/null 2>&1; then
  echo 'recovery accepted application and execution proxy from different compatibility sets' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'recovery mutation started after installed-set validation failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_PVC_PHASE=Pending \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-pvc >/dev/null 2>&1; then
  echo 'recovery accepted an unbound execution-proxy PersistentVolumeClaim' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'recovery mutation started after PersistentVolumeClaim preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  APPLICATION_PROFILE_OVERRIDE="${application_profile_override}" \
  EXECUTION_PROXY_PROFILE_OVERRIDE="${execution_profile_override}" \
  INITIALIZE_REPOSITORY=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-1 >/dev/null

application_upgrade='helm upgrade foreman'
execution_upgrade='helm upgrade execution'
application_maintenance='--set maintenance.enabled=true --set backup.enabled=false --set restore.enabled=false'
application_normal='--set maintenance.enabled=false --set backup.enabled=false --set restore.enabled=false'
execution_maintenance='--set maintenance.enabled=true --set smokeTest.enabled=false'
execution_normal='--set maintenance.enabled=false'
grep -Fq -- '--set backup.enabled=true --set-string backup.requestId=request-1 --set backup.initializeRepository=true' "${tool_log}"
grep -Fq -- "--values ${application_profile_override}" "${tool_log}"
grep -Fq -- "--values ${execution_profile_override}" "${tool_log}"
grep -Fq -- '--set recovery.executionProxy.enabled=true --set-string recovery.executionProxy.release=execution --set-string recovery.executionProxy.stateClaim=execution-state --set-string recovery.executionProxy.ansibleClaim=execution-ansible --set-json recovery.executionProxy.secretNames=["execution-tls"] --set-json recovery.scheduling={"priorityClassName":"","nodeSelector":{},"tolerations":[]}' "${tool_log}"
grep -Fq -- "${application_normal}" "${tool_log}"
grep -Fq -- "${execution_maintenance}" "${tool_log}"
grep -Fq 'kubectl --namespace foreman apply --dry-run=server --filename -' "${tool_log}"
application_maintenance_line="$(grep -Fn "${application_upgrade}" "${tool_log}" | grep -- "${application_maintenance}" | grep -v 'backup.enabled=true' | cut -d: -f1)"
execution_maintenance_line="$(grep -Fn "${execution_upgrade}" "${tool_log}" | grep -- "${execution_maintenance}" | cut -d: -f1)"
recovery_line="$(grep -Fn "${application_upgrade}" "${tool_log}" | grep 'backup.enabled=true' | cut -d: -f1)"
application_normal_line="$(grep -Fn "${application_upgrade}" "${tool_log}" | grep -- "${application_normal}" | cut -d: -f1)"
execution_normal_line="$(grep -Fn "${execution_upgrade}" "${tool_log}" | grep -- "${execution_normal}" | cut -d: -f1)"
if ! (( application_maintenance_line < execution_maintenance_line &&
        execution_maintenance_line < recovery_line &&
        recovery_line < application_normal_line &&
        application_normal_line < execution_normal_line )); then
  echo 'application, execution proxy, recovery, and resume operations ran out of order' >&2
  exit 1
fi
grep -Fq 'kubectl --namespace foreman wait --for=delete pod --selector=app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy' "${tool_log}"

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RECOVERY_UPGRADE_FAIL=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-2 >/dev/null 2>&1; then
  echo 'failed backup unexpectedly succeeded' >&2
  exit 1
fi
if grep -F "${application_upgrade}" "${tool_log}" | grep -Fq -- "${application_normal}"; then
  echo 'application left maintenance mode after a failed backup' >&2
  exit 1
fi
if grep -F "${execution_upgrade}" "${tool_log}" | grep -Fq -- "${execution_normal}"; then
  echo 'execution proxy left maintenance mode after a failed backup' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='apply --dry-run=server' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-admission >/dev/null 2>&1; then
  echo 'recovery accepted a server-side admission rejection' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'recovery mutation started after admission preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  RESTORE_SNAPSHOT=abc123 \
  RESTORE_SECRETS=1 \
  OBJECT_STORAGE_RECOVERY_POINT=provider-snapshot-abc123 \
  RECOVERY_FROM_QUIESCED=1 \
  FAKE_MAINTENANCE_ENABLED=true \
  "${repo_root}/scripts/recover-release.sh" restore \
    "${application_values}" "${execution_values}" request-3 >/dev/null
grep -Fq -- '--set restore.enabled=true --set-string restore.requestId=request-3 --set-string restore.snapshot=abc123 --set restore.confirmation=RESTORE --set restore.secrets=true --set-string restore.objectStorageRecoveryPoint=provider-snapshot-abc123' "${tool_log}"
if grep -F "${application_upgrade}" "${tool_log}" | \
  grep -F -- "${application_maintenance}" | grep -Ev 'backup.enabled=true|restore.enabled=true' >/dev/null; then
  echo 'continued restore redundantly reapplied application maintenance mode' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" quiesce \
    "${application_values}" "${execution_values}" >/dev/null
grep -F "${application_upgrade}" "${tool_log}" | grep -Fq -- "${application_maintenance}"
grep -F "${execution_upgrade}" "${tool_log}" | grep -Fq -- "${execution_maintenance}"
if grep -F "${application_upgrade}" "${tool_log}" | grep -Eq 'backup.enabled=true|restore.enabled=true|maintenance.enabled=false'; then
  echo 'quiesce unexpectedly ran recovery or resumed the application' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  OBJECT_STORAGE_RECOVERY_POINT=provider-snapshot-backup123 \
  RECOVERY_FROM_QUIESCED=1 \
  FAKE_MAINTENANCE_ENABLED=true \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-s3 >/dev/null
grep -Fq -- '--set backup.enabled=true --set-string backup.requestId=request-s3 --set backup.initializeRepository=false --set-string backup.objectStorageRecoveryPoint=provider-snapshot-backup123' "${tool_log}"
if grep -F "${application_upgrade}" "${tool_log}" | \
  grep -F -- "${application_maintenance}" | grep -Ev 'backup.enabled=true|restore.enabled=true' >/dev/null; then
  echo 'continued backup redundantly reapplied application maintenance mode' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  OBJECT_STORAGE_RECOVERY_POINT=provider-snapshot-unsafe \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-unsafe >/dev/null 2>&1; then
  echo 'object-storage recovery point was accepted without prior quiescence' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'unsafe object-storage hand-off reached cluster tools' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_STATUS_MISSING=1 \
  ALLOW_CANDIDATE=1 \
  BOOTSTRAP_RESTORE=1 \
  "${repo_root}/scripts/recover-release.sh" restore \
    "${application_values}" "${execution_values}" request-bootstrap >/dev/null
if grep -Fq 'helm get values ' "${tool_log}"; then
  echo 'bootstrap restore tried to inspect values of absent releases' >&2
  exit 1
fi
bootstrap_first_upgrade_line="$(grep -Fn 'helm upgrade ' "${tool_log}" | head -n 1 | cut -d: -f1)"
bootstrap_first_test_line="$(grep -Fn 'helm test ' "${tool_log}" | head -n 1 | cut -d: -f1)"
if ! (( bootstrap_first_upgrade_line < bootstrap_first_test_line )); then
  echo 'bootstrap restore ran a smoke test before creating its maintenance releases' >&2
  exit 1
fi
grep -F "${application_upgrade}" "${tool_log}" | grep -Fq -- '--install'
grep -F "${execution_upgrade}" "${tool_log}" | grep -Fq -- '--install'
grep -F "${application_upgrade}" "${tool_log}" | grep -Fq -- '--set restore.enabled=true'

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  BOOTSTRAP_RESTORE=1 \
  "${repo_root}/scripts/recover-release.sh" restore \
    "${application_values}" "${execution_values}" request-existing >/dev/null 2>&1; then
  echo 'bootstrap restore accepted an existing Helm release' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'bootstrap restore mutated existing releases before rejecting them' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" resume \
    "${application_values}" "${execution_values}" >/dev/null
grep -F "${application_upgrade}" "${tool_log}" | grep -Fq -- "${application_normal}"
grep -F "${execution_upgrade}" "${tool_log}" | grep -Fq -- "${execution_normal}"
if grep -Fq -- 'maintenance.enabled=true' "${tool_log}"; then
  echo 'resume unexpectedly rendered or ran another recovery Job' >&2
  exit 1
fi

if grep -Fq -- '--atomic' "${repo_root}/scripts/recover-release.sh"; then
  echo 'recovery helper must not automatically roll back restored schemas or data' >&2
  exit 1
fi

echo 'Guarded recovery sequencing checks passed.'
