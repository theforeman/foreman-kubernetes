#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 v1|v2" >&2
  exit 2
fi

revision="$1"
namespace="foreman"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "${revision}" in
  v1 | v2) ;;
  *)
    echo "unsupported Ansible content revision: ${revision}" >&2
    exit 2
    ;;
esac

ansible_config=$'[defaults]\nroles_path = /etc/ansible/roles\n'
printf -v defaults_main '%s\n' \
  '---' \
  "foreman_kubernetes_content_revision: \"${revision}\""
meta_main=$'---\ngalaxy_info:\n  role_name: foreman_kubernetes_test\n  author: Foreman Kubernetes integration\n  description: Disposable role for the execution-plane integration drill\n  license: GPL-3.0-or-later\n  min_ansible_version: "2.15"\ndependencies: []\n'
printf -v tasks_main '%s\n' \
  '---' \
  '- name: Record the role execution' \
  '  ansible.builtin.file:' \
  '    path: "/tmp/foreman-kubernetes-role-{{ foreman_kubernetes_content_revision }}-ok"' \
  '    state: touch' \
  '    mode: "0644"'

kubectl --namespace "${namespace}" create configmap execution-ansible-content \
  --from-literal=ansible.cfg="${ansible_config}" \
  --from-literal=defaults-main.yml="${defaults_main}" \
  --from-literal=meta-main.yml="${meta_main}" \
  --from-literal=tasks-main.yml="${tasks_main}" \
  --dry-run=client \
  --output=yaml | kubectl apply --filename=-

kubectl --namespace "${namespace}" delete job execution-ansible-content-loader \
  --ignore-not-found=true \
  --wait=true
kubectl apply --filename="${repo_root}/tests/kind/execution-ansible-content-job.yaml"
kubectl --namespace "${namespace}" wait \
  --for=condition=complete \
  job/execution-ansible-content-loader \
  --timeout=5m

echo "Published Ansible content revision ${revision}."
