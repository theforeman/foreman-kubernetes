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
receiver_name="webhook-receiver"
receiver_url="http://${receiver_name}:9999"

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
  local output="$4"

  curl \
    --silent \
    --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve foreman.test:8443:127.0.0.1 \
    --user admin:foreman-test \
    --request "${method}" \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data "${payload}" \
    --output "${output}" \
    --write-out '%{http_code}' \
    "https://foreman.test:8443${path}"
}

default_taxonomy_id() {
  foreman_api GET "/api/$1?per_page=1000" | jq --exit-status --raw-output '.results[0].id'
}

create_domain() {
  local name="$1"
  local organization_id="$2"
  local location_id="$3"

  foreman_api POST /api/domains "$(
    jq --compact-output --null-input \
      --arg name "${name}" \
      --argjson organization_id "${organization_id}" \
      --argjson location_id "${location_id}" '{
        domain: {
          name: $name,
          organization_ids: [$organization_id],
          location_ids: [$location_id]
        }
      }'
  )" | jq --exit-status --raw-output '.id'
}

receiver_uid() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/name="${receiver_name}" \
    --output=jsonpath='{.items[0].metadata.uid}'
}

deploy_receiver() {
  local foreman_image

  foreman_image="$(kubectl --namespace "${namespace}" get \
    deployment/foreman-foreman-stack-foreman \
    --output=jsonpath='{.spec.template.spec.containers[0].image}')"
  kubectl --namespace "${namespace}" create configmap "${receiver_name}" \
    --from-file=receiver.rb="$(dirname "$0")/webhook-receiver.rb" \
    --dry-run=client --output=yaml | kubectl apply --filename=-
  kubectl apply --filename=- <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${receiver_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${receiver_name}
    app.kubernetes.io/instance: webhook-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${receiver_name}
      app.kubernetes.io/instance: webhook-test
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${receiver_name}
        app.kubernetes.io/instance: webhook-test
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 994
        runAsGroup: 994
        fsGroup: 994
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: receiver
          image: ${foreman_image}
          imagePullPolicy: IfNotPresent
          command: [ruby, /opt/webhook-receiver/receiver.rb]
          ports:
            - name: http
              containerPort: 9999
          readinessProbe:
            tcpSocket:
              port: http
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: receiver
              mountPath: /opt/webhook-receiver
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: receiver
          configMap:
            name: ${receiver_name}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${receiver_name}
  namespace: ${namespace}
spec:
  selector:
    app.kubernetes.io/name: ${receiver_name}
    app.kubernetes.io/instance: webhook-test
  ports:
    - name: http
      port: 9999
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${receiver_name}-ingress
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${receiver_name}
      app.kubernetes.io/instance: webhook-test
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchExpressions:
              - key: app.kubernetes.io/instance
                operator: In
                values: [foreman]
              - key: app.kubernetes.io/component
                operator: In
                values: [foreman, dynflow-worker]
      ports:
        - protocol: TCP
          port: 9999
EOF
  kubectl --namespace "${namespace}" rollout status \
    deployment/"${receiver_name}" --timeout=5m
}

wait_for_delivery() {
  local marker="$1"

  for _ in $(seq 1 120); do
    if kubectl --namespace "${namespace}" logs deployment/"${receiver_name}" \
      --all-containers=true 2>/dev/null | grep --fixed-strings --quiet "${marker}"; then
      return
    fi
    sleep 2
  done

  echo "webhook receiver did not observe ${marker}" >&2
  kubectl --namespace "${namespace}" logs deployment/"${receiver_name}" \
    --all-containers=true >&2 || true
  exit 1
}

seed_lifecycle() {
  local identifier
  local template_name
  local webhook_name
  local first_domain
  local second_domain
  local receiver_uid_before
  local organization_id
  local location_id
  local template_id
  local webhook_id
  local first_domain_id
  local second_domain_id
  local failure_response
  local failure_status
  local state_file_tmp

  identifier="$(date -u +%Y%m%d%H%M%S)-${RANDOM}"
  template_name="Kubernetes webhook template ${identifier}"
  webhook_name="Kubernetes webhook ${identifier}"
  first_domain="webhook-${identifier}.example.test"
  second_domain="webhook-restarted-${identifier}.example.test"
  jq --null-input \
    --arg templateName "${template_name}" \
    --arg webhookName "${webhook_name}" \
    --arg firstDomain "${first_domain}" \
    --arg secondDomain "${second_domain}" \
    '{templateName: $templateName, webhookName: $webhookName, firstDomain: $firstDomain, secondDomain: $secondDomain}' \
    > "${state_file}"

  deploy_receiver
  organization_id="$(default_taxonomy_id organizations)"
  location_id="$(default_taxonomy_id locations)"
  template_id="$(
    foreman_api POST /api/webhook_templates "$(
      jq --compact-output --null-input \
        --arg name "${template_name}" \
        --arg template '{"id": <%= @object.id %>, "name": "<%= @object.name %>"}' \
        --argjson organization_id "${organization_id}" \
        --argjson location_id "${location_id}" '{
          webhook_template: {
            name: $name,
            template: $template,
            organization_ids: [$organization_id],
            location_ids: [$location_id]
          }
        }'
    )" | jq --exit-status --raw-output '.id'
  )"
  webhook_id="$(
    foreman_api POST /api/webhooks "$(
    jq --compact-output --null-input \
      --arg name "${webhook_name}" \
      --arg target_url "${receiver_url}/success" \
      --argjson template_id "${template_id}" '{
        webhook: {
          name: $name,
          target_url: $target_url,
          http_method: "POST",
          http_content_type: "application/json",
          event: "domain_created",
          webhook_template_id: $template_id,
          enabled: true,
          verify_ssl: false
        }
      }'
    )" | jq --exit-status --raw-output '.id'
  )"
  first_domain_id="$(create_domain "${first_domain}" "${organization_id}" "${location_id}")"
  wait_for_delivery "${first_domain}"

  foreman_api PUT "/api/webhooks/${webhook_id}" "$({
    jq --compact-output --null-input \
      --arg target_url "${receiver_url}/failure" \
      '{webhook: {target_url: $target_url}}'
  })" >/dev/null
  failure_response="${temporary_directory}/webhook-expected-failure.json"
  failure_status="$(
    foreman_api_status POST "/api/webhooks/${webhook_id}/test" \
      '{"payload":"expected-failure"}' "${failure_response}"
  )"
  if [[ "${failure_status}" != 422 ]] || \
     ! jq --exit-status '.error.message == "Service Unavailable"' "${failure_response}" >/dev/null; then
    echo "Expected visible webhook destination failure, got HTTP ${failure_status}" >&2
    cat "${failure_response}" >&2
    exit 1
  fi
  if ! kubectl --namespace "${namespace}" logs deployment/"${receiver_name}" \
    --all-containers=true | grep --fixed-strings '"path":"/failure","status":503' >/dev/null; then
    echo 'Webhook receiver did not record the controlled HTTP 503 response' >&2
    exit 1
  fi
  foreman_api PUT "/api/webhooks/${webhook_id}" "$({
    jq --compact-output --null-input \
      --arg target_url "${receiver_url}/success" \
      '{webhook: {target_url: $target_url}}'
  })" >/dev/null
  foreman_api POST "/api/webhooks/${webhook_id}/test" \
    '{"payload":"corrected-destination"}' >/dev/null

  receiver_uid_before="$(receiver_uid)"
  kubectl --namespace "${namespace}" delete pod \
    --selector=app.kubernetes.io/name="${receiver_name}" --wait=true
  kubectl --namespace "${namespace}" rollout status \
    deployment/"${receiver_name}" --timeout=5m
  if [[ "$(receiver_uid)" == "${receiver_uid_before}" ]]; then
    echo 'webhook receiver Pod was not replaced' >&2
    exit 1
  fi

  second_domain_id="$(create_domain "${second_domain}" "${organization_id}" "${location_id}")"
  wait_for_delivery "${second_domain}"

  state_file_tmp="${state_file}.tmp"
  jq \
    --argjson templateId "${template_id}" \
    --argjson webhookId "${webhook_id}" \
    --argjson firstDomainId "${first_domain_id}" \
    --argjson secondDomainId "${second_domain_id}" \
    '. + {
      templateId: $templateId,
      webhookId: $webhookId,
      firstDomainId: $firstDomainId,
      secondDomainId: $secondDomainId
    }' "${state_file}" > "${state_file_tmp}"
  mv "${state_file_tmp}" "${state_file}"
}

assert_recovered_lifecycle() {
  local template_name
  local webhook_name
  local first_domain
  local second_domain
  local recovery_domain
  local organization_id
  local location_id
  local template_id
  local webhook_id
  local first_domain_id
  local second_domain_id
  local recovery_domain_id

  deploy_receiver
  template_name="$(jq --exit-status --raw-output '.templateName' "${state_file}")"
  webhook_name="$(jq --exit-status --raw-output '.webhookName' "${state_file}")"
  first_domain="$(jq --exit-status --raw-output '.firstDomain' "${state_file}")"
  second_domain="$(jq --exit-status --raw-output '.secondDomain' "${state_file}")"
  recovery_domain="recovered-${second_domain}"
  organization_id="$(default_taxonomy_id organizations)"
  location_id="$(default_taxonomy_id locations)"
  template_id="$(jq --exit-status --raw-output '.templateId' "${state_file}")"
  webhook_id="$(jq --exit-status --raw-output '.webhookId' "${state_file}")"
  first_domain_id="$(jq --exit-status --raw-output '.firstDomainId' "${state_file}")"
  second_domain_id="$(jq --exit-status --raw-output '.secondDomainId' "${state_file}")"

  foreman_api GET "/api/webhook_templates/${template_id}" | \
    jq --exit-status --arg name "${template_name}" '.name == $name' >/dev/null
  foreman_api GET "/api/webhooks/${webhook_id}" | \
    jq --exit-status --arg name "${webhook_name}" '.name == $name and .enabled == true' >/dev/null
  recovery_domain_id="$(create_domain "${recovery_domain}" "${organization_id}" "${location_id}")"
  wait_for_delivery "${recovery_domain}"

  foreman_api DELETE "/api/webhooks/${webhook_id}" >/dev/null
  foreman_api DELETE "/api/webhook_templates/${template_id}" >/dev/null
  foreman_api DELETE "/api/domains/${first_domain_id}" >/dev/null
  foreman_api DELETE "/api/domains/${second_domain_id}" >/dev/null
  foreman_api DELETE "/api/domains/${recovery_domain_id}" >/dev/null
  cleanup_receiver
}

cleanup_receiver() {
  kubectl --namespace "${namespace}" delete \
    deployment/"${receiver_name}" \
    service/"${receiver_name}" \
    configmap/"${receiver_name}" \
    networkpolicy/"${receiver_name}-ingress" \
    --ignore-not-found=true
}

case "${mode}" in
  seed)
    seed_lifecycle
    ;;
  assert)
    assert_recovered_lifecycle
    ;;
  cleanup)
    cleanup_receiver
    ;;
  *)
    echo "unsupported mode: ${mode}" >&2
    exit 2
    ;;
esac
