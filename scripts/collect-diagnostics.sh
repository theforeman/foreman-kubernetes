#!/usr/bin/env bash

set -euo pipefail

namespace="${NAMESPACE:-foreman}"
release_name="${FOREMAN_RELEASE_NAME:-foreman}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
output="${1:-foreman-kubernetes-diagnostics-${timestamp}.tar.gz}"
kubectl_bin="${KUBECTL_BIN:-kubectl}"
helm_bin="${HELM_BIN:-helm}"

for dependency in "${kubectl_bin}" "${helm_bin}" jq tar; do
  command -v "${dependency}" >/dev/null || {
    echo "required command is not available: ${dependency}" >&2
    exit 1
  }
done

[[ ! -e "${output}" ]] || {
  echo "diagnostic archive already exists: ${output}" >&2
  exit 1
}

umask 077
workdir="$(mktemp -d "${TMPDIR:-/tmp}/foreman-kubernetes-diagnostics.XXXXXX")"
bundle="${workdir}/bundle"
mkdir -p "${bundle}/cluster" "${bundle}/helm" "${bundle}/namespace"
cleanup() {
  rm -rf -- "${workdir}"
}
trap cleanup EXIT

results="${bundle}/collection.tsv"
printf 'status\tartifact\n' >"${results}"

capture() {
  local artifact="$1"
  shift
  local destination="${bundle}/${artifact}"

  mkdir -p "$(dirname "${destination}")"
  if "$@" >"${destination}" 2>"${destination}.stderr"; then
    rm -f -- "${destination}.stderr"
    printf 'ok\t%s\n' "${artifact}" >>"${results}"
  else
    printf 'failed\t%s\n' "${artifact}" >>"${results}"
  fi
}

cat >"${bundle}/README.txt" <<'EOF'
This is a read-only Foreman Kubernetes diagnostic bundle.

Secret payloads, Helm values, Pod logs, database dumps, and application data
are deliberately excluded. secrets.json contains only Secret metadata and key
names. Review the remaining topology, events, object specifications, and error
files before sharing the archive outside the organization.
EOF

jq --null-input \
  --arg collectedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg namespace "${namespace}" \
  --arg release "${release_name}" \
  '{collectedAt: $collectedAt, namespace: $namespace, foremanRelease: $release,
    excludes: ["Secret payloads", "Helm values", "Pod logs", "database dumps", "application data"]}' \
  >"${bundle}/metadata.json"

capture cluster/kubectl-version.json "${kubectl_bin}" version --output=json
capture cluster/helm-version.txt "${helm_bin}" version
capture cluster/storageclasses.json "${kubectl_bin}" get storageclasses --output=json
capture cluster/ingressclasses.json "${kubectl_bin}" get ingressclasses --output=json
capture cluster/metrics-api.json "${kubectl_bin}" get apiservice v1beta1.metrics.k8s.io --output=json

node_file="${bundle}/cluster/nodes.json"
if node_json="$("${kubectl_bin}" get nodes --output=json 2>"${node_file}.stderr")" &&
  jq '{apiVersion, kind, items: [.items[] | {
        metadata: {
          name: .metadata.name,
          labels: ((.metadata.labels // {}) | with_entries(select(
            .key == "kubernetes.io/arch" or
            .key == "kubernetes.io/os" or
            .key == "node.kubernetes.io/instance-type" or
            (.key | startswith("topology.kubernetes.io/"))
          )))
        },
        spec: {
          unschedulable: (.spec.unschedulable // false),
          taints: [(.spec.taints // [])[] | {key, value, effect}]
        },
        status: {
          conditions: [(.status.conditions // [])[] | {type, status, lastTransitionTime}],
          nodeInfo: ((.status.nodeInfo // {}) | {
            architecture, operatingSystem, osImage, kernelVersion,
            containerRuntimeVersion, kubeletVersion
          })
        }
      }]}' <<<"${node_json}" >"${node_file}"; then
  rm -f -- "${node_file}.stderr"
  printf 'ok\t%s\n' 'cluster/nodes.json' >>"${results}"
else
  unset node_json
  printf 'failed\t%s\n' 'cluster/nodes.json' >>"${results}"
fi
unset node_json

release_file="${bundle}/namespace/foremanrelease.json"
if "${kubectl_bin}" --namespace "${namespace}" get foremanrelease "${release_name}" \
  --output=json >"${release_file}" 2>"${release_file}.stderr"; then
  rm -f -- "${release_file}.stderr"
  printf 'ok\t%s\n' 'namespace/foremanrelease.json' >>"${results}"
else
  printf 'failed\t%s\n' 'namespace/foremanrelease.json' >>"${results}"
fi

application_release="foreman"
execution_release="execution"
if jq --exit-status . "${release_file}" >/dev/null 2>&1; then
  application_release="$(jq --raw-output '.spec.application.releaseName // "foreman"' "${release_file}")"
  execution_release="$(jq --raw-output '.spec.executionProxy.releaseName // "execution"' "${release_file}")"
fi

capture namespace/workloads.json "${kubectl_bin}" --namespace "${namespace}" get \
  deployments,pods,services,jobs,cronjobs,horizontalpodautoscalers,ingresses,networkpolicies,poddisruptionbudgets,persistentvolumeclaims,serviceaccounts,configmaps \
  --output=json
capture namespace/events.json "${kubectl_bin}" --namespace "${namespace}" get events \
  --sort-by=.lastTimestamp --output=json
capture namespace/leases.json "${kubectl_bin}" --namespace "${namespace}" get leases --output=json

secret_file="${bundle}/namespace/secrets.json"
if secret_json="$("${kubectl_bin}" --namespace "${namespace}" get secrets --output=json 2>"${secret_file}.stderr")" &&
  jq '{apiVersion, kind, items: [.items[] | {
        apiVersion, kind,
        metadata: {
          name: .metadata.name,
          namespace: .metadata.namespace,
          labels: (.metadata.labels // {}),
          annotationKeys: ((.metadata.annotations // {}) | keys),
          creationTimestamp: .metadata.creationTimestamp
        },
        type,
        keys: ((.data // {}) | keys)
      }]}' <<<"${secret_json}" >"${secret_file}"; then
  rm -f -- "${secret_file}.stderr"
  printf 'ok\t%s\n' 'namespace/secrets.json' >>"${results}"
else
  unset secret_json
  printf 'failed\t%s\n' 'namespace/secrets.json' >>"${results}"
fi
unset secret_json

capture helm/releases.json "${helm_bin}" list --namespace "${namespace}" --all --output=json
for managed_release in "${application_release}" "${execution_release}"; do
  capture "helm/${managed_release}-status.json" "${helm_bin}" status "${managed_release}" \
    --namespace "${namespace}" --output=json
  capture "helm/${managed_release}-history.json" "${helm_bin}" history "${managed_release}" \
    --namespace "${namespace}" --output=json
done

tar --create --gzip --file "${output}" --directory "${bundle}" .
echo "Diagnostic archive written to ${output}"
