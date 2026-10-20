#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 COMPUTE_RESOURCE_ID" >&2
  exit 2
fi

compute_resource_id="$1"
foreman_url="${FOREMAN_URL:-}"
foreman_curl_config="${FOREMAN_CURL_CONFIG:-}"
kubevirt_token_file="${KUBEVIRT_TOKEN_FILE:-}"

fail() {
  echo "$1" >&2
  exit 1
}

[[ "${compute_resource_id}" =~ ^[0-9]+$ ]] || fail 'COMPUTE_RESOURCE_ID must be numeric'
[[ "${foreman_url}" == https://* ]] || fail 'FOREMAN_URL must use https://'
foreman_url="${foreman_url%/}"
[[ -r "${foreman_curl_config}" ]] || fail 'FOREMAN_CURL_CONFIG must name a readable curl configuration file'
[[ -s "${kubevirt_token_file}" && -r "${kubevirt_token_file}" ]] || \
  fail 'KUBEVIRT_TOKEN_FILE must name a readable, non-empty token file'

for dependency in curl jq; do
  command -v "${dependency}" >/dev/null 2>&1 || fail "${dependency} is required"
done

resource_url="${foreman_url}/api/compute_resources/${compute_resource_id}"
current_resource="$(curl \
  --config "${foreman_curl_config}" \
  --fail-with-body \
  --silent \
  --show-error \
  --request GET \
  --header 'Accept: application/json' \
  "${resource_url}")"

if ! jq --exit-status \
  --arg id "${compute_resource_id}" \
  '(.id | tostring) == $id and .provider == "Kubevirt"' \
  <<<"${current_resource}" >/dev/null; then
  fail "compute resource ${compute_resource_id} is not a KubeVirt provider"
fi

umask 077
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/foreman-kubevirt-token.XXXXXX")"
response_file="${temporary_directory}/response.json"
cleanup() {
  rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT

if ! jq --null-input \
  --rawfile token "${kubevirt_token_file}" \
  '{compute_resource: {password: ($token | sub("[\\r\\n]+$"; ""))}}' | \
  curl \
    --config "${foreman_curl_config}" \
    --fail-with-body \
    --silent \
    --show-error \
    --request PUT \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    --output "${response_file}" \
    "${resource_url}"; then
  [[ ! -s "${response_file}" ]] || cat "${response_file}" >&2
  fail "failed to rotate the token for compute resource ${compute_resource_id}"
fi

if ! jq --exit-status \
  --arg id "${compute_resource_id}" \
  '(.id | tostring) == $id and .provider == "Kubevirt"' \
  "${response_file}" >/dev/null; then
  fail 'Foreman returned an unexpected compute resource after token rotation'
fi

echo "Rotated KubeVirt token for compute resource ${compute_resource_id}."
