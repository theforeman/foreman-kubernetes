#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shellcheck -x \
  -P "${repo_root}/scripts" \
  -P "${repo_root}/charts/foreman-stack/files" \
  "${repo_root}/charts/foreman-stack/files/backup.sh" \
  "${repo_root}/charts/foreman-stack/files/recovery-common.sh" \
  "${repo_root}/charts/foreman-stack/files/restore.sh" \
  "${repo_root}/images/ssh-target/entrypoint.sh" \
  "${repo_root}/scripts/collect-diagnostics.sh" \
  "${repo_root}/scripts/install-release.sh" \
  "${repo_root}/scripts/recover-release.sh" \
  "${repo_root}/scripts/release-preflight.sh" \
  "${repo_root}/scripts/upgrade-release.sh" \
  "${repo_root}/tests/collect-diagnostics.sh" \
  "${repo_root}/tests/install-release.sh" \
  "${repo_root}/tests/kind/apply-secrets.sh" \
  "${repo_root}/tests/kind/content-lifecycle.sh" \
  "${repo_root}/tests/kind/execution-plane.sh" \
  "${repo_root}/tests/kind/publish-ansible-content.sh" \
  "${repo_root}/tests/kind/run.sh" \
  "${repo_root}/tests/kind/virt-who-config-lifecycle.sh" \
  "${repo_root}/tests/kind/kubevirt-lifecycle.sh" \
  "${repo_root}/tests/recover-release.sh" \
  "${repo_root}/tests/recovery-database-archive.sh" \
  "${repo_root}/tests/recovery-integrity.sh" \
  "${repo_root}/tests/recovery-quiescence.sh" \
  "${repo_root}/tests/render.sh" \
  "${repo_root}/tests/shellcheck.sh" \
  "${repo_root}/tests/upgrade-release.sh"

echo 'All shell scripts passed ShellCheck.'
