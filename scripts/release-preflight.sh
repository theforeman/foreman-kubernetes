#!/usr/bin/env bash

# Shared, read-only cluster checks for install-release.sh and upgrade-release.sh.

check_required_cluster_resources() {
  local rendered_resources="$1"
  local namespace="$2"
  local repo_root="$3"
  local required_resources resource_kind resource_name resource_contract
  local storage_classes resource_json

  echo 'Preflight: checking cluster storage, ingress, and external workload resources'
  required_resources="$(ruby "${repo_root}/scripts/required-cluster-resources.rb" \
    <<<"${rendered_resources}")"
  while IFS=$'\t' read -r resource_kind resource_name resource_contract; do
    [[ -n "${resource_kind}" ]] || continue
    case "${resource_kind}" in
      DefaultStorageClass)
        storage_classes="$(kubectl get storageclass --output=json)" || {
          echo 'unable to inspect StorageClasses' >&2
          return 1
        }
        jq --exit-status '
          any(
            .items[];
            .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
            .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
          )
        ' <<<"${storage_classes}" >/dev/null || {
          echo 'a rendered PVC relies on a default StorageClass, but none is configured' >&2
          return 1
        }
        ;;
      StorageClass)
        kubectl get "${resource_kind}" "${resource_name}" >/dev/null || {
          echo "required ${resource_kind} ${resource_name} does not exist" >&2
          return 1
        }
        ;;
      IngressClass)
        resource_json="$(kubectl get "${resource_kind}" "${resource_name}" --output=json)" || {
          echo "required ${resource_kind} ${resource_name} does not exist" >&2
          return 1
        }
        if [[ -n "${resource_contract}" ]]; then
          jq --exit-status --arg controller "${resource_contract}" \
            '.spec.controller == $controller' <<<"${resource_json}" >/dev/null || {
            echo "IngressClass ${resource_name} is not managed by required controller ${resource_contract}" >&2
            return 1
          }
        fi
        ;;
      APIService)
        resource_json="$(kubectl get apiservice "${resource_name}" --output=json)" || {
          echo "required APIService ${resource_name} does not exist" >&2
          return 1
        }
        if [[ "${resource_contract}" == 'Available' ]]; then
          jq --exit-status '
            any(
              .status.conditions[]?;
              .type == "Available" and .status == "True"
            )
          ' <<<"${resource_json}" >/dev/null || {
            echo "APIService ${resource_name} is not Available; autoscaling cannot read resource metrics" >&2
            return 1
          }
        fi
        ;;
      CustomResourceDefinition)
        kubectl get customresourcedefinition "${resource_name}" >/dev/null || {
          echo "required CustomResourceDefinition ${resource_name} does not exist" >&2
          return 1
        }
        ;;
      PriorityClass)
        kubectl get priorityclass "${resource_name}" >/dev/null || {
          echo "required PriorityClass ${resource_name} does not exist" >&2
          return 1
        }
        ;;
      NodeScheduling)
        resource_json="$(kubectl get nodes --output=json)" || {
          echo 'unable to inspect Kubernetes nodes' >&2
          return 1
        }
        jq --exit-status --argjson scheduling "${resource_name}" '
          def tolerates($taint; $tolerations):
            any(
              $tolerations[];
              ((.effect // "") == "" or .effect == $taint.effect) and
              (if (.operator // "Equal") == "Exists" then
                 ((.key // "") == "" or .key == $taint.key)
               else
                 .key == $taint.key and (.value // "") == ($taint.value // "")
               end)
            );
          any(
            .items[];
            . as $node |
            (.spec.unschedulable // false) != true and
            any(.status.conditions[]?; .type == "Ready" and .status == "True") and
            all($scheduling.nodeSelector | to_entries[]; $node.metadata.labels[.key] == .value) and
            all(
              ($node.spec.taints // [])[] |
                select(.effect == "NoSchedule" or .effect == "NoExecute");
              tolerates(.; $scheduling.tolerations)
            )
          )
        ' <<<"${resource_json}" >/dev/null || {
          echo "rendered workloads require a Ready, uncordoned node matching ${resource_name} with tolerated hard taints, but none is available" >&2
          return 1
        }
        ;;
      PersistentVolumeClaim)
        local claim_phase claim_storage_class
        resource_json="$(kubectl --namespace "${namespace}" get persistentvolumeclaim \
          "${resource_name}" --output=json)" || {
          echo "required PersistentVolumeClaim ${namespace}/${resource_name} does not exist" >&2
          return 1
        }
        claim_phase="$(jq --raw-output '.status.phase // ""' <<<"${resource_json}")"
        if [[ "${claim_phase}" != 'Bound' ]]; then
          claim_storage_class="$(jq --raw-output '.spec.storageClassName // ""' <<<"${resource_json}")"
          if [[ "${claim_phase}" != 'Pending' || -z "${claim_storage_class}" ]]; then
            echo "required PersistentVolumeClaim ${namespace}/${resource_name} is not Bound" >&2
            return 1
          fi
          resource_json="$(kubectl get storageclass "${claim_storage_class}" --output=json)" || {
            echo "StorageClass ${claim_storage_class} for Pending PersistentVolumeClaim ${namespace}/${resource_name} does not exist" >&2
            return 1
          }
          jq --exit-status '.volumeBindingMode == "WaitForFirstConsumer"' \
            <<<"${resource_json}" >/dev/null || {
            echo "required PersistentVolumeClaim ${namespace}/${resource_name} is Pending without delayed binding" >&2
            return 1
          }
        fi
        ;;
      ServiceAccount)
        kubectl --namespace "${namespace}" get "${resource_kind}" "${resource_name}" >/dev/null || {
          echo "required ${resource_kind} ${namespace}/${resource_name} does not exist" >&2
          return 1
        }
        ;;
      *)
        echo "unsupported preflight resource kind: ${resource_kind}" >&2
        return 1
        ;;
    esac
  done <<<"${required_resources}"
}

check_required_secrets() {
  local rendered_resources="$1"
  local namespace="$2"
  local repo_root="$3"
  local required_secrets certificate_identities secret_name secret_keys
  local secret_json secret_key secret_identities
  local certificate_minimum_validity_seconds
  local -a keys

  certificate_minimum_validity_seconds="${CERTIFICATE_MINIMUM_VALIDITY_SECONDS:-86400}"
  [[ "${certificate_minimum_validity_seconds}" =~ ^[0-9]+$ ]] || {
    echo 'CERTIFICATE_MINIMUM_VALIDITY_SECONDS must be a non-negative integer' >&2
    return 1
  }

  echo 'Preflight: checking externally managed Secrets and referenced keys'
  required_secrets="$(ruby "${repo_root}/scripts/required-secrets.rb" \
    <<<"${rendered_resources}")"
  certificate_identities="$(ruby "${repo_root}/scripts/certificate-identities.rb" \
    <<<"${rendered_resources}")"
  while IFS=$'\t' read -r secret_name secret_keys; do
    [[ -n "${secret_name}" ]] || continue
    secret_json="$(kubectl --namespace "${namespace}" get secret \
      "${secret_name}" --output=json)" || {
      echo "required Secret ${namespace}/${secret_name} does not exist" >&2
      return 1
    }
    [[ -n "${secret_keys}" ]] || continue
    IFS=',' read -r -a keys <<<"${secret_keys}"
    for secret_key in "${keys[@]}"; do
      jq --exit-status --arg key "${secret_key}" '.data[$key] != null' \
        <<<"${secret_json}" >/dev/null || {
        echo "required key ${secret_key} does not exist in Secret ${namespace}/${secret_name}" >&2
        return 1
      }
    done
    secret_identities="$(jq --compact-output --arg name "${secret_name}" \
      '.[$name] // {}' <<<"${certificate_identities}")"
    ruby "${repo_root}/scripts/validate-secret-certificates.rb" \
      "${namespace}" "${secret_name}" "${secret_keys}" \
      "${certificate_minimum_validity_seconds}" "${secret_identities}" \
      <<<"${secret_json}" || return 1
  done <<<"${required_secrets}"
}

check_server_admission() {
  local rendered_resources="$1"
  local namespace="$2"

  echo 'Preflight: checking Kubernetes admission and immutable fields'
  kubectl --namespace "${namespace}" apply --dry-run=server --filename - \
    <<<"${rendered_resources}" >/dev/null || {
    echo 'server-side admission dry-run rejected the rendered release' >&2
    return 1
  }
}

validate_release_lease_configuration() {
  local duration_seconds="$1"
  local renew_interval_seconds="$2"

  [[ "${duration_seconds}" =~ ^[0-9]+$ ]] || {
    echo 'RELEASE_LEASE_DURATION_SECONDS must be an integer' >&2
    return 1
  }
  [[ "${renew_interval_seconds}" =~ ^[0-9]+$ ]] || {
    echo 'RELEASE_LEASE_RENEW_INTERVAL_SECONDS must be an integer' >&2
    return 1
  }
  (( duration_seconds >= 30 )) || {
    echo 'RELEASE_LEASE_DURATION_SECONDS must be at least 30' >&2
    return 1
  }
  (( renew_interval_seconds >= 5 && renew_interval_seconds < duration_seconds )) || {
    echo 'RELEASE_LEASE_RENEW_INTERVAL_SECONDS must be at least 5 and shorter than the Lease duration' >&2
    return 1
  }
}

release_lease_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

new_release_lease_manifest() {
  local namespace="$1"
  local lease_name="$2"
  local holder_id="$3"
  local duration_seconds="$4"
  local operation="$5"
  local compatibility_set="$6"
  local now

  now="$(release_lease_timestamp)"
  jq --null-input \
    --arg namespace "${namespace}" \
    --arg lease_name "${lease_name}" \
    --arg holder_id "${holder_id}" \
    --argjson duration_seconds "${duration_seconds}" \
    --arg operation "${operation}" \
    --arg compatibility_set "${compatibility_set}" \
    --arg now "${now}" \
    '{
      apiVersion: "coordination.k8s.io/v1",
      kind: "Lease",
      metadata: {
        namespace: $namespace,
        name: $lease_name,
        annotations: {
          "foreman-kubernetes.io/operation": $operation,
          "foreman-kubernetes.io/compatibility-set": $compatibility_set
        }
      },
      spec: {
        holderIdentity: $holder_id,
        leaseDurationSeconds: $duration_seconds,
        acquireTime: $now,
        renewTime: $now
      }
    }'
}

release_lease_state() {
  ruby -rjson -rtime -e '
    begin
      lease = JSON.parse(STDIN.read)
      renewed_at = lease.dig("spec", "renewTime") || lease.dig("spec", "acquireTime")
      duration = Integer(lease.dig("spec", "leaseDurationSeconds"))
      raise ArgumentError if renewed_at.nil? || duration <= 0

      puts(Time.now.utc >= Time.iso8601(renewed_at).utc + duration ? "expired" : "active")
    rescue JSON::ParserError, ArgumentError, TypeError
      puts "invalid"
    end
  '
}

replace_release_lease_manifest() {
  local lease_json="$1"
  local holder_id="$2"
  local duration_seconds="$3"
  local operation="$4"
  local compatibility_set="$5"
  local now

  now="$(release_lease_timestamp)"
  jq \
    --arg holder_id "${holder_id}" \
    --argjson duration_seconds "${duration_seconds}" \
    --arg operation "${operation}" \
    --arg compatibility_set "${compatibility_set}" \
    --arg now "${now}" \
    '{
      apiVersion: "coordination.k8s.io/v1",
      kind: "Lease",
      metadata: {
        namespace: .metadata.namespace,
        name: .metadata.name,
        resourceVersion: .metadata.resourceVersion,
        annotations: ((.metadata.annotations // {}) + {
          "foreman-kubernetes.io/operation": $operation,
          "foreman-kubernetes.io/compatibility-set": $compatibility_set
        })
      },
      spec: {
        holderIdentity: $holder_id,
        leaseDurationSeconds: $duration_seconds,
        acquireTime: $now,
        renewTime: $now
      }
    }' <<<"${lease_json}"
}

acquire_release_lease() {
  local namespace="$1"
  local lease_name="$2"
  local holder_id="$3"
  local duration_seconds="$4"
  local operation="$5"
  local compatibility_set="$6"
  local manifest existing_lease existing_holder existing_state replacement

  manifest="$(new_release_lease_manifest "${namespace}" "${lease_name}" \
    "${holder_id}" "${duration_seconds}" "${operation}" "${compatibility_set}")"
  if kubectl --namespace "${namespace}" create --filename - \
    <<<"${manifest}" >/dev/null 2>&1; then
    release_lease_acquired=true
    return 0
  fi

  existing_lease="$(kubectl --namespace "${namespace}" get lease \
    "${lease_name}" --output=json 2>/dev/null)" || {
    echo "unable to create or inspect release Lease ${namespace}/${lease_name}" >&2
    return 1
  }
  existing_holder="$(jq --raw-output '.spec.holderIdentity // "unknown"' \
    <<<"${existing_lease}")"
  existing_state="$(release_lease_state <<<"${existing_lease}")"
  case "${existing_state}" in
    active)
      echo "release Lease ${namespace}/${lease_name} is held by ${existing_holder}" >&2
      return 1
      ;;
    expired) ;;
    *)
      echo "release Lease ${namespace}/${lease_name} has an invalid expiry contract; refusing to steal it" >&2
      return 1
      ;;
  esac

  replacement="$(replace_release_lease_manifest "${existing_lease}" \
    "${holder_id}" "${duration_seconds}" "${operation}" "${compatibility_set}")"
  if ! kubectl --namespace "${namespace}" replace --filename - \
    <<<"${replacement}" >/dev/null; then
    echo "expired release Lease ${namespace}/${lease_name} changed before it could be claimed" >&2
    return 1
  fi
  release_lease_acquired=true
}

renew_release_lease_once() {
  local namespace="$1"
  local lease_name="$2"
  local holder_id="$3"
  local duration_seconds="$4"
  local lease_json current_holder now renewed_manifest

  lease_json="$(kubectl --namespace "${namespace}" get lease \
    "${lease_name}" --output=json 2>/dev/null)" || return 1
  current_holder="$(jq --raw-output '.spec.holderIdentity // ""' <<<"${lease_json}")"
  [[ "${current_holder}" == "${holder_id}" ]] || return 1
  now="$(release_lease_timestamp)"
  renewed_manifest="$(jq \
    --arg holder_id "${holder_id}" \
    --argjson duration_seconds "${duration_seconds}" \
    --arg now "${now}" \
    '{
      apiVersion: "coordination.k8s.io/v1",
      kind: "Lease",
      metadata: {
        namespace: .metadata.namespace,
        name: .metadata.name,
        resourceVersion: .metadata.resourceVersion,
        annotations: (.metadata.annotations // {})
      },
      spec: {
        holderIdentity: $holder_id,
        leaseDurationSeconds: $duration_seconds,
        acquireTime: .spec.acquireTime,
        renewTime: $now
      }
    }' <<<"${lease_json}")"
  kubectl --namespace "${namespace}" replace --filename - \
    <<<"${renewed_manifest}" >/dev/null
}

start_release_lease_renewal() {
  local namespace="$1"
  local lease_name="$2"
  local holder_id="$3"
  local duration_seconds="$4"
  local renew_interval_seconds="$5"
  local parent_pid="${BASHPID}"

  (
    renewal_sleep_pid=''
    trap '[[ -z "${renewal_sleep_pid}" ]] || kill -TERM "${renewal_sleep_pid}" 2>/dev/null || true; exit 0' INT TERM
    while true; do
      sleep "${renew_interval_seconds}" &
      renewal_sleep_pid=$!
      wait "${renewal_sleep_pid}"
      renewal_sleep_pid=''
      renewed=false
      for _attempt in 1 2 3; do
        if renew_release_lease_once "${namespace}" "${lease_name}" \
          "${holder_id}" "${duration_seconds}"; then
          renewed=true
          break
        fi
        sleep 2
      done
      if [[ "${renewed}" != true ]]; then
        echo "lost release Lease ${namespace}/${lease_name}; terminating the release operation" >&2
        kill -TERM "${parent_pid}" 2>/dev/null || true
        exit 1
      fi
    done
  ) &
  release_lease_renewal_pid=$!
}

stop_release_lease_renewal() {
  [[ -n "${release_lease_renewal_pid:-}" ]] || return 0
  kill -TERM "${release_lease_renewal_pid}" 2>/dev/null || true
  wait "${release_lease_renewal_pid}" 2>/dev/null || true
  release_lease_renewal_pid=''
}

release_operation_lease() {
  local namespace="$1"
  local lease_name="$2"
  local holder_id="$3"
  local current_holder

  stop_release_lease_renewal
  [[ "${release_lease_acquired:-false}" == true ]] || return 0
  current_holder="$(kubectl --namespace "${namespace}" get lease \
    "${lease_name}" --output=jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  if [[ "${current_holder}" == "${holder_id}" ]]; then
    kubectl --namespace "${namespace}" delete lease \
      "${lease_name}" --wait=true >/dev/null
  else
    echo "release Lease holder changed to ${current_holder:-unknown}; leaving it untouched" >&2
  fi
  release_lease_acquired=false
}
