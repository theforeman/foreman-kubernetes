#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 TEMPORARY_DIRECTORY" >&2
  exit 2
fi

temporary_directory="$1"
namespace="foreman"
proxy_name="Kubernetes execution proxy"
proxy_url="https://execution-foreman-execution-proxy:8443"
target_name="execution-target.foreman.svc.cluster.local"
role_name="foreman_kubernetes_test"
role_revision="${EXPECTED_ROLE_REVISION:-v1}"
test_proxy_interruption="${TEST_PROXY_INTERRUPTION:-0}"
execution_scenario="${EXECUTION_SCENARIO:-full}"
execution_state_file="${EXECUTION_STATE_FILE:-}"
execution_upgrade_name="${EXECUTION_UPGRADE_NAME:-}"

case "${role_revision}" in
  v1 | v2) ;;
  *)
    echo "unsupported expected Ansible content revision: ${role_revision}" >&2
    exit 2
    ;;
esac

case "${test_proxy_interruption}" in
  0 | 1) ;;
  *)
    echo "TEST_PROXY_INTERRUPTION must be 0 or 1" >&2
    exit 2
    ;;
esac

case "${execution_scenario}" in
  full | start-upgrade | finish-upgrade) ;;
  *)
    echo "unsupported execution scenario: ${execution_scenario}" >&2
    exit 2
    ;;
esac

if [[ "${execution_scenario}" != full ]]; then
  if [[ -z "${execution_state_file}" || -z "${execution_upgrade_name}" ]]; then
    echo 'EXECUTION_STATE_FILE and EXECUTION_UPGRADE_NAME are required for upgrade scenarios' >&2
    exit 2
  fi
  case "${execution_state_file}" in
    "${temporary_directory}"/*) ;;
    *)
      echo 'EXECUTION_STATE_FILE must be inside the temporary directory' >&2
      exit 2
      ;;
  esac
  if [[ ! "${execution_upgrade_name}" =~ ^[a-z0-9-]+$ ]]; then
    echo 'EXECUTION_UPGRADE_NAME must contain only lowercase letters, numbers, and hyphens' >&2
    exit 2
  fi
fi

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

wait_for_task() {
  local task_id="$1"
  local expected_result="${2:-success}"

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env "TASK_ID=${task_id}" "EXPECTED_RESULT=${expected_result}" bin/rails runner '
      task = ForemanTasks::Task.find(ENV.fetch("TASK_ID"))
      expected = ENV.fetch("EXPECTED_RESULT")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
      loop do
        task.reload
        if task.state == "stopped"
          valid = case expected
                  when "success" then task.result == "success"
                  when "error" then task.result == "error"
                  when "warning" then task.result == "warning"
                  when "not-success" then task.result != "success"
                  when "terminal" then true
                  else false
                  end
          abort "Task #{task.id} ended with #{task.result}, expected #{expected}" unless valid
          puts "Task #{task.id} ended with expected result #{task.result}"
          break
        end
        abort "Timed out waiting for task #{task.id}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    '
}

create_script_job() {
  local command="$1"

  foreman_api POST '/api/job_invocations?include_hosts=false' "$(
    jq --compact-output --null-input \
      --arg command "${command}" \
      --arg search_query "name = \"${target_name}\"" '{
        job_invocation: {
          feature: "run_script",
          inputs: {command: $command},
          search_query: $search_query,
          targeting_type: "static_query",
          ssh_user: "foreman"
        }
      }'
  )"
}

wait_for_task_proxy() {
  local task_id="$1"
  local provider="$2"
  local sub_task_id
  local details

  for _ in $(seq 1 120); do
    sub_task_id="$(
      foreman_api GET "/foreman_tasks/api/tasks/${task_id}/sub_tasks?per_page=all" | \
        jq --raw-output '.results[0].id // empty'
    )"
    if [[ -n "${sub_task_id}" ]]; then
      details="$(foreman_api GET "/foreman_tasks/api/tasks/${sub_task_id}/details")"
      if jq --exit-status --arg proxy_url "${proxy_url}" '
        any((.running_steps // [])[]?;
          .action_class == "Actions::RemoteExecution::ProxyAction" and
          (.input | contains("\"proxy_url\"=>\"" + $proxy_url + "\"")))
      ' <<<"${details}" >/dev/null; then
        return
      fi
    fi
    sleep 1
  done

  echo "${provider} task ${task_id} was not dispatched through ${proxy_url}" >&2
  exit 1
}

assert_egress_boundary() {
  local proxy_deployment="deployment/execution-foreman-execution-proxy"
  local ingress_address

  ingress_address="$(
    kubectl --namespace ingress-nginx get service ingress-nginx-controller \
      --output=jsonpath='{.spec.clusterIP}'
  )"

  kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e '
      expected = ARGV.fetch(0)
      addresses = Addrinfo.getaddrinfo("foreman.test", 443).map(&:ip_address).uniq
      abort("foreman.test resolved to #{addresses.join(", ")}, expected #{expected}") unless addresses.include?(expected)
    ' "${ingress_address}"

  kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e 'Socket.tcp("foreman.test", 443, connect_timeout: 5).close'
  kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e 'Socket.tcp(ARGV.fetch(0), 22, connect_timeout: 5).close' \
    "${target_name}"

  if kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e 'Socket.tcp("content-source", 80, connect_timeout: 3).close' \
    >/dev/null 2>&1; then
    echo 'Execution proxy reached an undeclared in-cluster destination' >&2
    exit 1
  fi
}

first_result_id() {
  jq --exit-status --raw-output '.results[0].id'
}

exact_result_id() {
  local name="$1"

  jq --exit-status --raw-output --arg name "${name}" \
    'first(.results[] | select(.name == $name)) | .id'
}

default_taxonomy_id() {
  local endpoint="$1"

  foreman_api GET "/api/${endpoint}?per_page=all" | first_result_id
}

register_execution_proxy() {
  local location_id="$1"
  local organization_id="$2"
  local proxy
  local proxy_id
  local proxies
  local features

  proxies="$(foreman_api GET '/api/smart_proxies?per_page=all')"
  proxy_id="$(exact_result_id "${proxy_name}" <<<"${proxies}" || true)"

  if [[ -z "${proxy_id}" ]]; then
    proxy="$(foreman_api POST /api/smart_proxies "$(
      jq --compact-output --null-input \
        --arg name "${proxy_name}" \
        --arg url "${proxy_url}" \
        --argjson organization_id "${organization_id}" \
        --argjson location_id "${location_id}" '{
          smart_proxy: {
            name: $name,
            url: $url,
            organization_ids: [$organization_id],
            location_ids: [$location_id]
          }
        }'
    )")"
    proxy_id="$(jq --exit-status --raw-output '.id' <<<"${proxy}")"
  else
    foreman_api PUT "/api/smart_proxies/${proxy_id}" "$(
      jq --compact-output --null-input \
        --arg url "${proxy_url}" \
        --argjson organization_id "${organization_id}" \
        --argjson location_id "${location_id}" '{
          smart_proxy: {
            url: $url,
            organization_ids: [$organization_id],
            location_ids: [$location_id]
          }
        }'
    )" >/dev/null
  fi

  foreman_api PUT "/api/smart_proxies/${proxy_id}/refresh" '{}' >/dev/null
  proxy="$(foreman_api GET "/api/smart_proxies/${proxy_id}")"
  features="$(jq --exit-status --raw-output \
    '[.features[].name] | sort | join(",")' <<<"${proxy}")"
  if [[ "${features}" != "Ansible,Dynflow,Script" ]]; then
    echo "Execution proxy features are '${features}', expected 'Ansible,Dynflow,Script'" >&2
    exit 1
  fi

  printf '%s\n' "${proxy_id}"
}

ensure_target_host() {
  local location_id="$1"
  local organization_id="$2"
  local host_id
  local hosts

  hosts="$(foreman_api GET '/api/hosts?per_page=all')"
  host_id="$(exact_result_id "${target_name}" <<<"${hosts}" || true)"
  if [[ -z "${host_id}" ]]; then
    host_id="$(
      foreman_api POST /api/hosts "$(
        jq --compact-output --null-input \
          --arg name "${target_name}" \
          --argjson organization_id "${organization_id}" \
          --argjson location_id "${location_id}" '{
            host: {
              name: $name,
              managed: false,
              build: false,
              organization_id: $organization_id,
              location_id: $location_id
            }
          }'
      )" | jq --exit-status --raw-output '.id'
    )"
  fi

  printf '%s\n' "${host_id}"
}

configure_execution_defaults() {
  # The disposable target deliberately has no privilege-escalation tool. Keep
  # the effective user equal to the SSH login so REx exercises its no-op path.
  foreman_api PUT /api/settings/remote_execution_ssh_user \
    '{"setting":{"value":"foreman"}}' >/dev/null
  foreman_api PUT /api/settings/remote_execution_effective_user \
    '{"setting":{"value":"foreman"}}' >/dev/null
}

sync_ansible_role() {
  local proxy_id="$1"
  local available_roles
  local role_id
  local sync_response
  local task_id

  role_id="$(
    foreman_api GET '/ansible/api/v2/ansible_roles?per_page=all' | \
      exact_result_id "${role_name}" || true
  )"
  available_roles="$(foreman_api GET "/ansible/api/v2/ansible_roles/fetch?proxy_id=${proxy_id}")"
  if ! jq --exit-status --arg role_name "${role_name}" \
    '.results.ansible_roles[] | select(.name == $role_name)' \
    <<<"${available_roles}" >/dev/null; then
    if [[ -n "${role_id}" ]]; then
      printf '%s\n' "${role_id}"
      return
    fi
    echo "Ansible role ${role_name} is not visible through Smart Proxy ${proxy_id}" >&2
    exit 1
  fi

  sync_response="$(foreman_api PUT /ansible/api/v2/ansible_roles/sync "$(
    jq --compact-output --null-input \
      --argjson proxy_id "${proxy_id}" \
      --arg role_name "${role_name}" '{
        proxy_id: $proxy_id,
        role_names: [$role_name]
      }'
  )")"
  task_id="$(jq --raw-output '.id // empty' <<<"${sync_response}")"
  if [[ -n "${task_id}" ]]; then
    wait_for_task "${task_id}" >&2
  fi

  role_id="$(foreman_api GET '/ansible/api/v2/ansible_roles?per_page=all' | \
    exact_result_id "${role_name}")"
  printf '%s\n' "${role_id}"
}

assign_ansible_role() {
  local host_id="$1"
  local role_id="$2"

  foreman_api POST "/api/hosts/${host_id}/assign_ansible_roles" "$(
    jq --compact-output --null-input \
      --argjson role_id "${role_id}" '{ansible_role_ids: [$role_id]}'
  )" >/dev/null

  foreman_api GET "/api/hosts/${host_id}/ansible_roles" | \
    jq --exit-status --arg role_name "${role_name}" \
      '.[] | select(.name == $role_name)' >/dev/null
}

run_job() {
  local marker="$1"
  local provider="$2"
  local template_id="${3:-}"
  local invocation
  local task_id
  local payload

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${marker}"

  if [[ "${provider}" == Script ]]; then
    invocation="$(create_script_job "sleep 5; touch /tmp/${marker}")"
  else
    payload="$(jq --compact-output --null-input \
      --arg command "sleep 5; touch /tmp/${marker}" \
      --arg search_query "name = \"${target_name}\"" \
      --argjson template_id "${template_id}" '{
        job_invocation: {
          job_template_id: $template_id,
          inputs: {command: $command},
          search_query: $search_query,
          targeting_type: "static_query",
          ssh_user: "foreman"
        }
      }')"
    invocation="$(foreman_api POST '/api/job_invocations?include_hosts=false' "${payload}")"
  fi

  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"
  wait_for_task_proxy "${task_id}" "${provider}"
  wait_for_task "${task_id}"

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${marker}"
}

assert_failed_job() {
  local invocation
  local invocation_id
  local task_id

  invocation="$(create_script_job 'sleep 5; printf "expected failure\\n"; exit 23')"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"
  wait_for_task_proxy "${task_id}" 'Expected-failure Script'
  wait_for_task "${task_id}" warning

  foreman_api GET "/api/job_invocations/${invocation_id}?include_hosts=false" | \
    jq --exit-status '.failed == 1 and .succeeded == 0' >/dev/null
}

assert_cancelled_job() {
  local cancellation
  local invocation
  local invocation_id
  local task_id

  invocation="$(create_script_job 'sleep 300')"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"

  wait_for_task_proxy "${task_id}" 'Cancelled Script'
  cancellation="$(foreman_api POST "/api/job_invocations/${invocation_id}/cancel" '{}')"
  jq --exit-status '.cancelled == true' <<<"${cancellation}" >/dev/null
  wait_for_task "${task_id}" not-success

  foreman_api GET "/api/job_invocations/${invocation_id}?include_hosts=false" | \
    jq --exit-status '.cancelled == 1 and .succeeded == 0' >/dev/null
}

wait_for_target_marker() {
  local marker="$1"

  for _ in $(seq 1 120); do
    if kubectl --namespace "${namespace}" exec deployment/execution-target -- \
      test -f "/tmp/${marker}"; then
      return
    fi
    sleep 1
  done

  echo "Target marker ${marker} was not created" >&2
  exit 1
}

assert_interrupted_job_recovery() {
  local started_marker="foreman-kubernetes-interrupted-started"
  local finished_marker="foreman-kubernetes-interrupted-finished"
  local proxy_pod
  local invocation
  local task_id

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${started_marker}" "/tmp/${finished_marker}"

  invocation="$(create_script_job \
    "touch /tmp/${started_marker}; sleep 60; touch /tmp/${finished_marker}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"

  wait_for_task_proxy "${task_id}" 'Interrupted Script'
  wait_for_target_marker "${started_marker}"
  proxy_pod="$(kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy \
    --output=jsonpath='{.items[0].metadata.name}')"
  kubectl --namespace "${namespace}" delete pod "${proxy_pod}" \
    --grace-period=0 \
    --force \
    --wait=true \
    --timeout=5m
  kubectl --namespace "${namespace}" rollout status \
    deployment/execution-foreman-execution-proxy \
    --timeout=10m

  wait_for_task "${task_id}" terminal
  run_job foreman-kubernetes-after-proxy-restart-ok Script
}

start_upgrade_job() {
  local started_marker="foreman-kubernetes-${execution_upgrade_name}-started"
  local finished_marker="foreman-kubernetes-${execution_upgrade_name}-finished"
  local state_file_tmp="${execution_state_file}.tmp"
  local invocation
  local invocation_id
  local task_id

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${started_marker}" "/tmp/${finished_marker}"

  invocation="$(create_script_job \
    "touch /tmp/${started_marker}; sleep 90; touch /tmp/${finished_marker}")"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"

  wait_for_task_proxy "${task_id}" "${execution_upgrade_name}"
  wait_for_target_marker "${started_marker}"
  jq --null-input \
    --arg name "${execution_upgrade_name}" \
    --argjson invocation_id "${invocation_id}" \
    --arg task_id "${task_id}" \
    --arg started_marker "${started_marker}" \
    --arg finished_marker "${finished_marker}" '{
      name: $name,
      invocation_id: $invocation_id,
      task_id: $task_id,
      started_marker: $started_marker,
      finished_marker: $finished_marker
    }' > "${state_file_tmp}"
  mv "${state_file_tmp}" "${execution_state_file}"

  echo "Execution job ${invocation_id} is active for ${execution_upgrade_name}."
}

assert_upgrade_job() {
  local state
  local state_name
  local task_id
  local finished_marker

  if [[ ! -s "${execution_state_file}" ]]; then
    echo "upgrade execution state does not exist: ${execution_state_file}" >&2
    exit 1
  fi
  state="$(jq --exit-status '.' "${execution_state_file}")"
  state_name="$(jq --exit-status --raw-output '.name' <<<"${state}")"
  if [[ "${state_name}" != "${execution_upgrade_name}" ]]; then
    echo "upgrade state belongs to ${state_name}, expected ${execution_upgrade_name}" >&2
    exit 1
  fi

  task_id="$(jq --exit-status --raw-output '.task_id' <<<"${state}")"
  finished_marker="$(jq --exit-status --raw-output '.finished_marker' <<<"${state}")"

  wait_for_task "${task_id}" success
  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${finished_marker}"
  run_job "foreman-kubernetes-${execution_upgrade_name}-fresh-ok" Script

  echo "Active execution job and fresh execution both succeeded after ${execution_upgrade_name}."
}

run_role_job() {
  local host_id="$1"
  local marker="foreman-kubernetes-role-${role_revision}-ok"
  local unexpected_revision
  local unexpected_marker
  local invocation
  local task_id

  if [[ "${role_revision}" == v1 ]]; then
    unexpected_revision=v2
  else
    unexpected_revision=v1
  fi
  unexpected_marker="foreman-kubernetes-role-${unexpected_revision}-ok"

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${marker}" "/tmp/${unexpected_marker}"

  invocation="$(foreman_api POST "/api/hosts/${host_id}/play_roles")"
  task_id="$(jq --exit-status --raw-output '.task_id // .dynflow_task.id' <<<"${invocation}")"
  wait_for_task "${task_id}"

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${marker}"
  if kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${unexpected_marker}"; then
    echo "Ansible role executed stale content revision ${unexpected_revision}" >&2
    exit 1
  fi

}

case "${execution_scenario}" in
  full | start-upgrade)
    organization_id="$(default_taxonomy_id organizations)"
    location_id="$(default_taxonomy_id locations)"
    assert_egress_boundary
    proxy_id="$(register_execution_proxy "${location_id}" "${organization_id}")"
    host_id="$(ensure_target_host "${location_id}" "${organization_id}")"
    configure_execution_defaults
    ;;
esac

case "${execution_scenario}" in
  full)
    role_id="$(sync_ansible_role "${proxy_id}")"
    assign_ansible_role "${host_id}" "${role_id}"

    ansible_template_id="$(foreman_api GET '/api/job_templates?per_page=all' | \
      exact_result_id 'Run Command - Ansible Default')"

    assert_failed_job
    assert_cancelled_job
    run_job foreman-kubernetes-rex-ok Script
    run_job foreman-kubernetes-ansible-ok Ansible "${ansible_template_id}"
    run_role_job "${host_id}"
    if [[ "${test_proxy_interruption}" == 1 ]]; then
      assert_interrupted_job_recovery
    fi
    echo "Execution proxy registration, failure/cancellation, role sync, SSH, Ansible command, and Ansible role ${role_revision} checks passed."
    ;;
  start-upgrade)
    start_upgrade_job
    ;;
  finish-upgrade)
    assert_upgrade_job
    ;;
esac
