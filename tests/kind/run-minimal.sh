#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cluster_name="${KIND_CLUSTER_NAME:-foreman-minimal}"
node_image="${KIND_NODE_IMAGE:-kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d}"
namespace="${KIND_NAMESPACE:-foreman}"
release="${HELM_RELEASE:-foreman}"
context="kind-${cluster_name}"
created_cluster=false
created_namespace=false

cleanup() {
  if [[ "${KEEP_CLUSTER:-0}" == 1 ]]; then
    return
  fi

  if [[ "${created_cluster}" == true ]]; then
    kind delete cluster --name "${cluster_name}"
  elif [[ "${created_namespace}" == true ]]; then
    kubectl --context "${context}" delete namespace "${namespace}" --wait=false
  fi
}
trap cleanup EXIT

if ! kind get clusters | grep -Fxq "${cluster_name}"; then
  kind create cluster --name "${cluster_name}" --image "${node_image}" --wait 120s
  created_cluster=true
fi

if ! kubectl --context "${context}" get namespace "${namespace}" >/dev/null 2>&1; then
  created_namespace=true
fi
kubectl --context "${context}" create namespace "${namespace}" \
  --dry-run=client --output=yaml | \
  kubectl --context "${context}" apply --filename=-
kubectl --context "${context}" --namespace "${namespace}" apply \
  --filename "${repo_root}/tests/kind/dependencies.yaml"
kubectl --context "${context}" --namespace "${namespace}" rollout status deployment/postgresql \
  --timeout=180s

kubectl --context "${context}" --namespace "${namespace}" create secret generic foreman-runtime \
  --from-literal=DATABASE_URL='postgresql://foreman:foreman-test@postgresql:5432/foreman' \
  --from-literal=ENCRYPTION_KEY='0123456789abcdef0123456789abcdef' \
  --from-literal=SECRET_KEY_BASE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  --from-literal=SEED_ADMIN_USER=admin \
  --from-literal=SEED_ADMIN_PASSWORD=foreman-test \
  --dry-run=client --output=yaml | \
  kubectl --context "${context}" apply --filename=-

helm upgrade --install "${release}" "${repo_root}/charts/foreman" \
  --kube-context "${context}" \
  --namespace "${namespace}" \
  --set-string foreman.fqdn=foreman.test \
  --set-string foreman.externalUrl=http://foreman.test \
  --wait \
  --wait-for-jobs \
  --timeout 20m

helm test "${release}" --kube-context "${context}" \
  --namespace "${namespace}" --logs --timeout 5m
kubectl --context "${context}" --namespace "${namespace}" \
  get deployments,pods,services,jobs
