#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/foreman-diagnostics-test.XXXXXX")"
cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

mkdir -p "${test_root}/bin" "${test_root}/extracted"
call_log="${test_root}/calls.log"

cat >"${test_root}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"${FAKE_CALL_LOG}"

case " $* " in
  *' version --output=json '*)
    printf '%s\n' '{"clientVersion":{"gitVersion":"v1.test"}}'
    ;;
  *' get foremanrelease foreman '*)
    printf '%s\n' '{"apiVersion":"platform.theforeman.org/v1alpha1","kind":"ForemanRelease","metadata":{"name":"foreman","namespace":"platform","uid":"owner"},"spec":{"application":{"releaseName":"application"},"executionProxy":{"releaseName":"executor"}},"status":{"phase":"Ready"}}'
    ;;
  *' get nodes --output=json '*)
    printf '%s\n' '{"apiVersion":"v1","kind":"NodeList","items":[{"metadata":{"name":"worker-1","annotations":{"private":"NODE_SECRET"},"labels":{"kubernetes.io/arch":"amd64","kubernetes.io/os":"linux","node.kubernetes.io/instance-type":"standard","topology.kubernetes.io/zone":"zone-a","private.example/token":"NODE_SECRET"}},"spec":{"providerID":"NODE_SECRET","taints":[{"key":"dedicated","value":"foreman","effect":"NoSchedule"}]},"status":{"conditions":[{"type":"Ready","status":"True","reason":"KubeletReady","message":"private details","lastTransitionTime":"2026-09-25T00:00:00Z"}],"nodeInfo":{"architecture":"amd64","operatingSystem":"linux","osImage":"Test Linux","kernelVersion":"6.test","containerRuntimeVersion":"containerd://2.test","kubeletVersion":"v1.test","machineID":"NODE_SECRET"}}}]}'
    ;;
  *' get secrets '*)
    printf '%s\n' '{"apiVersion":"v1","kind":"SecretList","items":[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"runtime","namespace":"platform","labels":{"app":"foreman"},"annotations":{"last-applied":"TOPSECRET"},"creationTimestamp":"2026-09-25T00:00:00Z"},"type":"Opaque","data":{"password":"VE9QU0VDUkVU","token":"VE9QU0VDUkVU"}}]}'
    ;;
  *)
    printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}'
    ;;
esac
EOF

cat >"${test_root}/bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >>"${FAKE_CALL_LOG}"

case " $* " in
  *' version '*) printf '%s\n' 'version.BuildInfo{Version:"v3.test"}' ;;
  *' list '*) printf '%s\n' '[]' ;;
  *' status '*) printf '%s\n' '{"info":{"status":"deployed"},"version":1}' ;;
  *' history '*) printf '%s\n' '[]' ;;
  *) exit 1 ;;
esac
EOF

chmod +x "${test_root}/bin/kubectl" "${test_root}/bin/helm"
archive="${test_root}/diagnostics.tar.gz"
PATH="${test_root}/bin:${PATH}" FAKE_CALL_LOG="${call_log}" NAMESPACE=platform \
  "${repo_root}/scripts/collect-diagnostics.sh" "${archive}" >/dev/null

tar --extract --gzip --file "${archive}" --directory "${test_root}/extracted"
if rg -Fq 'TOPSECRET' "${test_root}/extracted"; then
  echo 'diagnostic archive leaked a Secret payload' >&2
  exit 1
fi
if rg -Fq 'NODE_SECRET' "${test_root}/extracted"; then
  echo 'diagnostic archive leaked private Node provider metadata' >&2
  exit 1
fi
jq --exit-status '
  .items == [{
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "runtime",
      namespace: "platform",
      labels: {app: "foreman"},
      annotationKeys: ["last-applied"],
      creationTimestamp: "2026-09-25T00:00:00Z"
    },
    type: "Opaque",
    keys: ["password", "token"]
  }]
' "${test_root}/extracted/namespace/secrets.json" >/dev/null
jq --exit-status '
  .items == [{
    metadata: {
      name: "worker-1",
      labels: {
        "kubernetes.io/arch": "amd64",
        "kubernetes.io/os": "linux",
        "node.kubernetes.io/instance-type": "standard",
        "topology.kubernetes.io/zone": "zone-a"
      }
    },
    spec: {
      unschedulable: false,
      taints: [{key: "dedicated", value: "foreman", effect: "NoSchedule"}]
    },
    status: {
      conditions: [{type: "Ready", status: "True", lastTransitionTime: "2026-09-25T00:00:00Z"}],
      nodeInfo: {
        architecture: "amd64",
        operatingSystem: "linux",
        osImage: "Test Linux",
        kernelVersion: "6.test",
        containerRuntimeVersion: "containerd://2.test",
        kubeletVersion: "v1.test"
      }
    }
  }]
' "${test_root}/extracted/cluster/nodes.json" >/dev/null
rg -Fq $'ok\tcluster/nodes.json' "${test_root}/extracted/collection.tsv"
rg -Fq 'helm status application' "${call_log}"
rg -Fq 'helm status executor' "${call_log}"
if rg -q 'kubectl .* logs([[:space:]]|$)' "${call_log}"; then
  echo 'diagnostic collection unexpectedly captured Pod logs' >&2
  exit 1
fi

echo 'Diagnostic bundle is read-only and redacts every Secret value.'
