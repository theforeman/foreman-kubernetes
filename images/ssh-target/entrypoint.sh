#!/bin/sh
set -eu

authorized_key=/keys/authorized_key

if [ ! -s "${authorized_key}" ]; then
  echo "SSH target public key is missing: ${authorized_key}" >&2
  exit 1
fi

exec /usr/sbin/sshd -D -e
