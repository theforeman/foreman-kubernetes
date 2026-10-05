#!/usr/bin/env sh

set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

export RECOVERY_WORK_ROOT="${test_root}/work"
mkdir -p \
  "${RECOVERY_WORK_ROOT}/databases" \
  "${RECOVERY_WORK_ROOT}/metadata" \
  "${RECOVERY_WORK_ROOT}/secrets"

printf 'foreman\n' > "${RECOVERY_WORK_ROOT}/databases/foreman.dump"
printf 'candlepin\n' > "${RECOVERY_WORK_ROOT}/databases/candlepin.dump"
printf 'pulp\n' > "${RECOVERY_WORK_ROOT}/databases/pulp.dump"
printf '{"secret_names":["application-keys"]}\n' > "${RECOVERY_WORK_ROOT}/metadata/manifest.json"
printf '{"data":{"key":"value"}}\n' > "${RECOVERY_WORK_ROOT}/secrets/application-keys.json"

# The absolute path is resolved from the checkout at runtime.
# shellcheck disable=SC1091
. "${repo_root}/charts/foreman-stack/files/recovery-common.sh"

write_recovery_integrity
verify_recovery_integrity >/dev/null

printf 'tampered\n' >> "${RECOVERY_WORK_ROOT}/databases/foreman.dump"
if (verify_recovery_integrity >/dev/null 2>&1); then
  echo 'modified database dump passed recovery integrity verification' >&2
  exit 1
fi

printf 'foreman\n' > "${RECOVERY_WORK_ROOT}/databases/foreman.dump"
write_recovery_integrity
printf 'unlisted\n' > "${RECOVERY_WORK_ROOT}/metadata/unlisted"
sha256sum "${RECOVERY_WORK_ROOT}/metadata/unlisted" >> \
  "${RECOVERY_WORK_ROOT}/metadata/checksums.sha256"
if (verify_recovery_integrity >/dev/null 2>&1); then
  echo 'unlisted file passed recovery integrity verification' >&2
  exit 1
fi

printf 'Recovery integrity accepts the exact set and rejects modified or unlisted data.\n'
