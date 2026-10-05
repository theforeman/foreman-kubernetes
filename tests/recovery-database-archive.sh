#!/usr/bin/env sh

set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/bin" "${test_root}/dumps"
# The generated stub must expand these variables when it is executed, not now.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/sh' \
  ': "${PG_RESTORE_ARGUMENTS:?}"' \
  'printf "%s\n" "$@" > "${PG_RESTORE_ARGUMENTS}"' \
  'if [ "$1" = --list ]; then' \
  '  grep -q "^valid$" "$2"' \
  'fi' > "${test_root}/bin/pg_restore"
chmod 0700 "${test_root}/bin/pg_restore"

printf 'valid\n' > "${test_root}/dumps/valid.dump"
printf 'broken\n' > "${test_root}/dumps/broken.dump"
export PATH="${test_root}/bin:${PATH}"
export PG_RESTORE_ARGUMENTS="${test_root}/pg-restore-arguments"

# shellcheck disable=SC1091
. "${repo_root}/charts/foreman-stack/files/recovery-common.sh"

validate_database_dump Foreman "${test_root}/dumps/valid.dump" >/dev/null
if validate_database_dump Foreman "${test_root}/dumps/broken.dump" >/dev/null 2>&1; then
  echo 'unreadable database archive passed recovery validation' >&2
  exit 1
fi

restore_database Foreman "${test_root}/dumps/valid.dump" --dbname foreman >/dev/null
grep -Fx -- '--clean' "${PG_RESTORE_ARGUMENTS}" >/dev/null
grep -Fx -- '--exit-on-error' "${PG_RESTORE_ARGUMENTS}" >/dev/null
grep -Fx -- '--single-transaction' "${PG_RESTORE_ARGUMENTS}" >/dev/null

printf 'Recovery validates database archives and restores each one transactionally.\n'
