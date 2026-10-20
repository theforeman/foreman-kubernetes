#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 seed|assert|cleanup TEMPORARY_DIRECTORY STATE_FILE" >&2
  exit 2
fi

mode="$1"
temporary_directory="$2"
state_file="$3"
namespace="${NAMESPACE:-foreman}"

for variable in \
  KUBEVIRT_API_HOST \
  KUBEVIRT_API_PORT \
  KUBEVIRT_NAMESPACE \
  KUBEVIRT_TOKEN_FILE \
  KUBEVIRT_CA_FILE \
  KUBEVIRT_STORAGE_CLASS; do
  if [[ -z "${!variable:-}" ]]; then
    echo "${variable} is required for KubeVirt qualification" >&2
    exit 2
  fi
done

for credential_file in "${KUBEVIRT_TOKEN_FILE}" "${KUBEVIRT_CA_FILE}"; do
  if [[ ! -r "${credential_file}" ]]; then
    echo "KubeVirt credential file is not readable: ${credential_file}" >&2
    exit 2
  fi
done

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

  if [[ "${method}" == POST || "${method}" == PUT ]]; then
    curl_args+=(--data-binary @-)
  fi

  curl "${curl_args[@]}" "https://foreman.test:8443${path}"
}

kubevirt_auth_header() {
  local header_file="${temporary_directory}/kubevirt-authorization"
  umask 077
  printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "${KUBEVIRT_TOKEN_FILE}")" > "${header_file}"
  printf '%s\n' "${header_file}"
}

kubevirt_api() {
  local method="$1"
  local path="$2"
  local header_file

  header_file="$(kubevirt_auth_header)"
  curl \
    --silent \
    --show-error \
    --cacert "${KUBEVIRT_CA_FILE}" \
    --header "@${header_file}" \
    --request "${method}" \
    "https://${KUBEVIRT_API_HOST}:${KUBEVIRT_API_PORT}${path}"
}

kubevirt_status() {
  local path="$1"
  local header_file

  header_file="$(kubevirt_auth_header)"
  curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --cacert "${KUBEVIRT_CA_FILE}" \
    --header "@${header_file}" \
    "https://${KUBEVIRT_API_HOST}:${KUBEVIRT_API_PORT}${path}"
}

kubevirt_delete_status() {
  local path="$1"
  local header_file

  header_file="$(kubevirt_auth_header)"
  curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --cacert "${KUBEVIRT_CA_FILE}" \
    --header "@${header_file}" \
    --request DELETE \
    "https://${KUBEVIRT_API_HOST}:${KUBEVIRT_API_PORT}${path}"
}

assert_api_hides_credentials() {
  local response="$1"

  if jq --exit-status \
    'has("token") or has("password") or has("ca_cert")' \
    <<<"${response}" >/dev/null; then
    echo 'Foreman compute-resource API exposed KubeVirt credentials' >&2
    exit 1
  fi
}

preferred_version() {
  kubevirt_api GET /apis/kubevirt.io | \
    jq --exit-status --raw-output '.preferredVersion.version'
}

probe_compute_resource() {
  local compute_resource_id="$1"
  local expected_version="$2"
  local output

  output="$(kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env \
      "COMPUTE_RESOURCE_ID=${compute_resource_id}" \
      "EXPECTED_KUBEVIRT_VERSION=${expected_version}" \
      "EXPECTED_STORAGE_CLASS=${KUBEVIRT_STORAGE_CLASS}" \
    bin/rails runner '
      require "json"
      resource = ComputeResource.unscoped.find(ENV.fetch("COMPUTE_RESOURCE_ID"))
      client = resource.send(:client)
      abort "Kubernetes API or namespace validation failed" unless client.valid?
      abort "KubeVirt API group is unavailable" unless client.virt_supported?
      version = client.send(:kubevirt_client).version
      expected_version = ENV.fetch("EXPECTED_KUBEVIRT_VERSION")
      abort "Foreman selected #{version}, expected #{expected_version}" unless version == expected_version
      storage_classes = resource.storage_classes.map(&:name)
      expected_storage_class = ENV.fetch("EXPECTED_STORAGE_CLASS")
      abort "storage class #{expected_storage_class} is unavailable" unless storage_classes.include?(expected_storage_class)
      puts JSON.generate(version: version, storage_classes: storage_classes)
    ')"

  jq --exit-status \
    --arg version "${expected_version}" \
    '.version == $version and (.storage_classes | length > 0)' \
    <<<"${output}" >/dev/null
}

create_vm() {
  local compute_resource_id="$1"
  local vm_name="$2"

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env \
      "COMPUTE_RESOURCE_ID=${compute_resource_id}" \
      "KUBEVIRT_VM_NAME=${vm_name}" \
      "KUBEVIRT_STORAGE_CLASS=${KUBEVIRT_STORAGE_CLASS}" \
    bin/rails runner '
      resource = ComputeResource.unscoped.find(ENV.fetch("COMPUTE_RESOURCE_ID"))
      vm = resource.create_vm(
        name: ENV.fetch("KUBEVIRT_VM_NAME"),
        cpu_cores: "1",
        memory: (512 * 1024 * 1024).to_s,
        start: false,
        volumes_attributes: {
          "0" => {
            capacity: "1",
            storage_class: ENV.fetch("KUBEVIRT_STORAGE_CLASS"),
            bootable: "true"
          }
        },
        interfaces_attributes: {
          "0" => {cni_provider: "pod", network: nil}
        }
      )
      abort "Foreman created an unexpected VM" unless vm.name == ENV.fetch("KUBEVIRT_VM_NAME")
      puts vm.name
    '
}

destroy_vm() {
  local compute_resource_id="$1"
  local vm_name="$2"

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env \
      "COMPUTE_RESOURCE_ID=${compute_resource_id}" \
      "KUBEVIRT_VM_NAME=${vm_name}" \
    bin/rails runner '
      resource = ComputeResource.unscoped.find_by(id: ENV.fetch("COMPUTE_RESOURCE_ID"))
      if resource
        begin
          resource.destroy_vm(ENV.fetch("KUBEVIRT_VM_NAME"))
        rescue ActiveRecord::RecordNotFound
          nil
        end
      end
    '
}

assert_external_vm_status() {
  local version="$1"
  local vm_name="$2"
  local expected_status="$3"
  local path="/apis/kubevirt.io/${version}/namespaces/${KUBEVIRT_NAMESPACE}/virtualmachines/${vm_name}"
  local actual_status

  actual_status="$(kubevirt_status "${path}")"
  if [[ "${actual_status}" != "${expected_status}" ]]; then
    echo "KubeVirt VM ${vm_name} returned ${actual_status}, expected ${expected_status}" >&2
    exit 1
  fi
}

wait_for_external_deletion() {
  local version="$1"
  local vm_name="$2"
  local pvc_name="$3"
  local vm_status
  local pvc_status

  for _ in $(seq 1 60); do
    vm_status="$(kubevirt_status "/apis/kubevirt.io/${version}/namespaces/${KUBEVIRT_NAMESPACE}/virtualmachines/${vm_name}")"
    pvc_status="$(kubevirt_status "/api/v1/namespaces/${KUBEVIRT_NAMESPACE}/persistentvolumeclaims/${pvc_name}")"
    if [[ "${vm_status}" == 404 && "${pvc_status}" == 404 ]]; then
      return
    fi
    sleep 2
  done

  echo "KubeVirt cleanup left VM status ${vm_status} and PVC status ${pvc_status}" >&2
  exit 1
}

cleanup_resources() {
  local compute_resource_id
  local version
  local vm_name
  local pvc_name

  [[ -f "${state_file}" ]] || return 0
  compute_resource_id="$(jq --exit-status --raw-output '.computeResourceId' "${state_file}")"
  version="$(jq --exit-status --raw-output '.preferredVersion' "${state_file}")"
  vm_name="$(jq --exit-status --raw-output '.vmName' "${state_file}")"
  pvc_name="$(jq --exit-status --raw-output '.pvcName' "${state_file}")"

  destroy_vm "${compute_resource_id}" "${vm_name}" || true
  if [[ "$(kubevirt_status "/apis/kubevirt.io/${version}/namespaces/${KUBEVIRT_NAMESPACE}/virtualmachines/${vm_name}")" != 404 ]]; then
    kubevirt_delete_status "/apis/kubevirt.io/${version}/namespaces/${KUBEVIRT_NAMESPACE}/virtualmachines/${vm_name}" >/dev/null
  fi
  if [[ "$(kubevirt_status "/api/v1/namespaces/${KUBEVIRT_NAMESPACE}/persistentvolumeclaims/${pvc_name}")" != 404 ]]; then
    kubevirt_delete_status "/api/v1/namespaces/${KUBEVIRT_NAMESPACE}/persistentvolumeclaims/${pvc_name}" >/dev/null
  fi
  if foreman_api GET "/api/compute_resources/${compute_resource_id}" >/dev/null 2>&1; then
    foreman_api DELETE "/api/compute_resources/${compute_resource_id}" >/dev/null
  fi
  wait_for_external_deletion "${version}" "${vm_name}" "${pvc_name}"
  rm -f "${state_file}"
}

seed_lifecycle() {
  local compute_resource
  local compute_resource_id
  local resource_name
  local version
  local vm_name
  local pvc_name

  version="$(preferred_version)"
  resource_name="Kubernetes KubeVirt qualification ${GITHUB_RUN_ID:-$$}"
  vm_name="foreman-qualification-${GITHUB_RUN_ID:-$$}"
  pvc_name="${vm_name}-claim-1"

  compute_resource="$(jq -n \
    --arg name "${resource_name}" \
    --arg hostname "${KUBEVIRT_API_HOST}" \
    --arg port "${KUBEVIRT_API_PORT}" \
    --arg namespace "${KUBEVIRT_NAMESPACE}" \
    --rawfile token "${KUBEVIRT_TOKEN_FILE}" \
    --rawfile ca_cert "${KUBEVIRT_CA_FILE}" \
    '{
      compute_resource: {
        name: $name,
        provider: "Kubevirt",
        hostname: $hostname,
        api_port: $port,
        namespace: $namespace,
        token: ($token | sub("[\\r\\n]+$"; "")),
        ca_cert: $ca_cert
      }
    }' | foreman_api POST /api/compute_resources)"
  assert_api_hides_credentials "${compute_resource}"
  compute_resource_id="$(jq --exit-status --raw-output '.id' <<<"${compute_resource}")"

  jq -n \
    --argjson compute_resource_id "${compute_resource_id}" \
    --arg resource_name "${resource_name}" \
    --arg version "${version}" \
    --arg vm_name "${vm_name}" \
    --arg pvc_name "${pvc_name}" \
    '{
      computeResourceId: $compute_resource_id,
      computeResourceName: $resource_name,
      preferredVersion: $version,
      vmName: $vm_name,
      pvcName: $pvc_name
    }' > "${state_file}"

  probe_compute_resource "${compute_resource_id}" "${version}"
  create_vm "${compute_resource_id}" "${vm_name}"
  assert_external_vm_status "${version}" "${vm_name}" 200
}

assert_lifecycle() {
  local compute_resource
  local compute_resource_id
  local resource_name
  local version
  local vm_name

  compute_resource_id="$(jq --exit-status --raw-output '.computeResourceId' "${state_file}")"
  resource_name="$(jq --exit-status --raw-output '.computeResourceName' "${state_file}")"
  version="$(jq --exit-status --raw-output '.preferredVersion' "${state_file}")"
  vm_name="$(jq --exit-status --raw-output '.vmName' "${state_file}")"

  compute_resource="$(foreman_api GET "/api/compute_resources/${compute_resource_id}")"
  assert_api_hides_credentials "${compute_resource}"
  jq --exit-status \
    --arg name "${resource_name}" \
    --arg hostname "${KUBEVIRT_API_HOST}" \
    --arg namespace "${KUBEVIRT_NAMESPACE}" \
    '.name == $name and .hostname == $hostname and .namespace == $namespace' \
    <<<"${compute_resource}" >/dev/null
  probe_compute_resource "${compute_resource_id}" "${version}"
  assert_external_vm_status "${version}" "${vm_name}" 200
}

cleanup_failed_seed() {
  local exit_status=$?

  trap - EXIT
  if [[ ${exit_status} -ne 0 ]]; then
    cleanup_resources || true
  fi
  exit "${exit_status}"
}

case "${mode}" in
  seed)
    trap cleanup_failed_seed EXIT
    seed_lifecycle
    ;;
  assert)
    assert_lifecycle
    ;;
  cleanup)
    cleanup_resources
    ;;
  *)
    echo "unsupported mode: ${mode}" >&2
    exit 2
    ;;
esac
