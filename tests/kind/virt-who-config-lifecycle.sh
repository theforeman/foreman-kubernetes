#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 seed|assert|cleanup TEMPORARY_DIRECTORY CONTENT_STATE_FILE STATE_FILE" >&2
  exit 2
fi

mode="$1"
temporary_directory="$2"
content_state_file="$3"
state_file="$4"
namespace="${NAMESPACE:-foreman}"
config_name="Kubernetes integration virt-who"
initial_server="qemu+ssh://virt-who-initial.example.test/system"
updated_server="qemu+ssh://virt-who-updated.example.test/system"

foreman_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=foreman \
    --output=json | jq --exit-status --raw-output '
      [.items[] |
       select(.status.phase == "Running") |
       select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] |
      sort_by(.metadata.creationTimestamp) |
      last |
      .metadata.name'
}

foreman_api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local -a curl_args=(
    --fail-with-body
    --silent
    --show-error
    --cacert "${temporary_directory}/ca.crt"
    --resolve foreman.test:8443:127.0.0.1
    --user admin:foreman-test
    --request "${method}"
    --header 'Accept: application/json'
    --header 'Content-Type: application/json'
  )

  if [[ -n "${payload}" ]]; then
    curl_args+=(--data "${payload}")
  fi

  curl "${curl_args[@]}" "https://foreman.test:8443${path}"
}

foreman_api_status() {
  local method="$1"
  local path="$2"
  local payload="$3"
  local output_file="$4"

  curl --silent --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve foreman.test:8443:127.0.0.1 \
    --user admin:foreman-test \
    --request "${method}" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data "${payload}" \
    --output "${output_file}" \
    --write-out '%{http_code}' \
    "https://foreman.test:8443${path}"
}

rails_runner() {
  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- "$@"
}

deploy_script() {
  local config_id="$1"

  foreman_api GET \
    "/foreman_virt_who_configure/api/v2/configs/${config_id}/deploy_script.json" |
    jq --exit-status --raw-output '.virt_who_config_script'
}

assert_service_identity() {
  local config_id="$1"
  local expected_login="$2"

  rails_runner env \
    "CONFIG_ID=${config_id}" \
    "EXPECTED_LOGIN=${expected_login}" \
    bin/rails runner '
      config = ForemanVirtWhoConfigure::Config.find(ENV.fetch("CONFIG_ID"))
      service_user = config.service_user
      user = User.unscoped.find(service_user.user_id)
      abort "Unexpected service login" unless service_user.username == ENV.fetch("EXPECTED_LOGIN")
      abort "Service password is not encrypted at rest" unless service_user.encrypted_password_in_db.to_s.start_with?("encrypted-")
      abort "Service user is not hidden" unless user.auth_source.is_a?(ForemanVirtWhoConfigure::AuthSourceHiddenWithAuthentication)
      abort "Service user lost its organization" unless user.organizations.include?(config.organization)
      abort "Service user lost the Virt-who Reporter role" unless user.roles.exists?(name: "Virt-who Reporter")
    '
}

assert_script_contract() {
  local script="$1"
  local config_id="$2"
  local service_login="$3"

  grep --fixed-strings --quiet '#!/bin/bash' <<<"${script}"
  grep --fixed-strings --quiet "[virt-who-config-${config_id}]" <<<"${script}"
  grep --fixed-strings --quiet "server=${updated_server}" <<<"${script}"
  grep --fixed-strings --quiet 'username=foreman' <<<"${script}"
  grep --fixed-strings --quiet 'rhsm_hostname=foreman.test' <<<"${script}"
  grep --fixed-strings --quiet "rhsm_username=${service_login}" <<<"${script}"
  grep --fixed-strings --quiet \
    "cat > /etc/virt-who.d/virt-who-config-${config_id}.conf" <<<"${script}"
  grep --fixed-strings --quiet 'systemctl restart virt-who' <<<"${script}"
  # The generated script must retain its own runtime variable, not expand ours.
  # shellcheck disable=SC2016
  grep --fixed-strings --quiet 'exit $result_code' <<<"${script}"
  if grep --fixed-strings --quiet "server=${initial_server}" <<<"${script}"; then
    echo 'updated deploy script retained the previous hypervisor endpoint' >&2
    exit 1
  fi
}

delete_config_and_identity() {
  local config_id="$1"
  local service_user_id="$2"
  local service_login="$3"

  foreman_api DELETE \
    "/foreman_virt_who_configure/api/v2/configs/${config_id}" >/dev/null
  rails_runner env \
    "CONFIG_ID=${config_id}" \
    "SERVICE_USER_ID=${service_user_id}" \
    "SERVICE_LOGIN=${service_login}" \
    bin/rails runner '
      abort "Virt-who config survived deletion" if ForemanVirtWhoConfigure::Config.exists?(ENV.fetch("CONFIG_ID"))
      abort "Service identity survived deletion of its last config" if ForemanVirtWhoConfigure::ServiceUser.exists?(ENV.fetch("SERVICE_USER_ID"))
      abort "Hidden Foreman user survived deletion of its last config" if User.unscoped.exists?(login: ENV.fetch("SERVICE_LOGIN"))
    '
}

seed_lifecycle() {
  local config
  local config_id
  local invalid_response="${temporary_directory}/virt-who-invalid.json"
  local invalid_status
  local organization_id
  local script
  local service_identity
  local service_login
  local service_user_id
  local shown

  organization_id="$(jq --exit-status --raw-output '.organization_id' \
    "${content_state_file}")"

  invalid_status="$(foreman_api_status POST \
    /foreman_virt_who_configure/api/v2/configs \
    "$(jq --compact-output --null-input \
      --argjson organization_id "${organization_id}" '{
        foreman_virt_who_configure_config: {
          name: "Invalid Kubernetes virt-who",
          interval: 120,
          filtering_mode: 0,
          hypervisor_id: "uuid",
          hypervisor_type: "kubevirt",
          satellite_url: "foreman.test",
          organization_id: $organization_id
        }
      }')" \
    "${invalid_response}")"
  if [[ "${invalid_status}" != 422 ]]; then
    echo "invalid KubeVirt configuration returned ${invalid_status}, expected 422" >&2
    exit 1
  fi
  if ! jq --exit-status \
    '.error.full_messages | map(select(test("Kubeconfig path"))) | length == 1' \
    "${invalid_response}" >/dev/null; then
    echo 'invalid KubeVirt configuration did not report the missing kubeconfig path' >&2
    exit 1
  fi

  config="$(foreman_api POST /foreman_virt_who_configure/api/v2/configs "$(
    jq --compact-output --null-input \
      --arg name "${config_name}" \
      --arg server "${initial_server}" \
      --argjson organization_id "${organization_id}" '{
        foreman_virt_who_configure_config: {
          name: $name,
          interval: 120,
          filtering_mode: 0,
          hypervisor_id: "uuid",
          hypervisor_type: "libvirt",
          hypervisor_server: $server,
          hypervisor_username: "foreman",
          satellite_url: "foreman.test",
          organization_id: $organization_id
        }
      }'
  )")"
  config_id="$(jq --exit-status --raw-output '.id' <<<"${config}")"
  if [[ "$(jq --exit-status --raw-output '.status' <<<"${config}")" != unknown ]]; then
    echo 'new virt-who configuration did not start in unknown state' >&2
    exit 1
  fi
  if jq --exit-status 'has("hypervisor_password")' <<<"${config}" >/dev/null; then
    echo 'virt-who configuration API exposed the hypervisor password field' >&2
    exit 1
  fi

  service_identity="$(rails_runner env "CONFIG_ID=${config_id}" bin/rails runner '
    config = ForemanVirtWhoConfigure::Config.find(ENV.fetch("CONFIG_ID"))
    puts [config.service_user.id, config.service_user.username].join(":")
    config.virt_who_touch!
  ' | tail -n 1)"
  service_user_id="${service_identity%%:*}"
  service_login="${service_identity#*:}"
  assert_service_identity "${config_id}" "${service_login}"

  shown="$(foreman_api GET \
    "/foreman_virt_who_configure/api/v2/configs/${config_id}")"
  if [[ "$(jq --exit-status --raw-output '.status' <<<"${shown}")" != ok ]]; then
    echo 'virt-who report touch did not move the configuration to ok' >&2
    exit 1
  fi
  if jq --exit-status 'has("hypervisor_password")' <<<"${shown}" >/dev/null; then
    echo 'virt-who show API exposed the hypervisor password field' >&2
    exit 1
  fi

  script="$(deploy_script "${config_id}")"
  grep --fixed-strings --quiet "server=${initial_server}" <<<"${script}"
  foreman_api PUT "/foreman_virt_who_configure/api/v2/configs/${config_id}" "$(
    jq --compact-output --null-input --arg server "${updated_server}" '{
      foreman_virt_who_configure_config: {hypervisor_server: $server}
    }'
  )" >/dev/null
  script="$(deploy_script "${config_id}")"
  assert_script_contract "${script}" "${config_id}" "${service_login}"

  jq --null-input \
    --argjson configId "${config_id}" \
    --argjson serviceUserId "${service_user_id}" \
    --arg serviceLogin "${service_login}" \
    --arg configName "${config_name}" \
    --arg updatedServer "${updated_server}" '{
      configId: $configId,
      serviceUserId: $serviceUserId,
      serviceLogin: $serviceLogin,
      configName: $configName,
      updatedServer: $updatedServer
    }' >"${state_file}"
}

assert_recovered_lifecycle() {
  local config_id
  local script
  local service_login
  local service_user_id
  local shown

  config_id="$(jq --exit-status --raw-output '.configId' "${state_file}")"
  service_user_id="$(jq --exit-status --raw-output '.serviceUserId' "${state_file}")"
  service_login="$(jq --exit-status --raw-output '.serviceLogin' "${state_file}")"
  shown="$(foreman_api GET \
    "/foreman_virt_who_configure/api/v2/configs/${config_id}")"
  if [[ "$(jq --exit-status --raw-output '.name' <<<"${shown}")" != "${config_name}" ]] ||
    [[ "$(jq --exit-status --raw-output '.status' <<<"${shown}")" != ok ]] ||
    [[ "$(jq --exit-status --raw-output '.hypervisor_server' <<<"${shown}")" != "${updated_server}" ]]; then
    echo 'restored virt-who configuration differs from the recovery point' >&2
    exit 1
  fi

  assert_service_identity "${config_id}" "${service_login}"
  script="$(deploy_script "${config_id}")"
  assert_script_contract "${script}" "${config_id}" "${service_login}"
  delete_config_and_identity "${config_id}" "${service_user_id}" "${service_login}"
}

cleanup_lifecycle() {
  local config_id
  local service_login
  local service_user_id

  [[ -f "${state_file}" ]] || return 0
  config_id="$(jq --exit-status --raw-output '.configId' "${state_file}")"
  service_user_id="$(jq --exit-status --raw-output '.serviceUserId' "${state_file}")"
  service_login="$(jq --exit-status --raw-output '.serviceLogin' "${state_file}")"
  delete_config_and_identity "${config_id}" "${service_user_id}" "${service_login}"
}

case "${mode}" in
  seed)
    seed_lifecycle
    ;;
  assert)
    assert_recovered_lifecycle
    ;;
  cleanup)
    cleanup_lifecycle
    ;;
  *)
    echo "unsupported mode: ${mode}" >&2
    exit 2
    ;;
esac
