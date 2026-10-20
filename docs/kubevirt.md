# KubeVirt compute provider

Foreman runs the `foreman_kubevirt` plugin in its web and Dynflow processes. It
does not turn the application cluster itself into a KubeVirt cluster. Treat the
target as an independently operated provider with its own API availability,
storage, networking, backups, and upgrade lifecycle.

## Current compatibility gate

Do not promote the current packaged plugin yet. The reviewed release forces the
obsolete `v1alpha3` API. The local upstream fix removes that override so
`fog-kubevirt` uses the preferred version advertised by `/apis/kubevirt.io`.
The reviewed fog client also lists NetworkAttachmentDefinitions cluster-wide;
a second local fix scopes that request to the compute resource namespace. It
also needs a fix that sends the grouped `kubevirt.io/v1` value in created VM
objects rather than the URL-only `v1` version. These fixes are accompanied by a
plugin validation fix that turns failed Kubernetes
and KubeVirt probes into actionable model errors. The local series also fixes
image data-disk selection and partial-PVC cleanup. All fixes and the external-
cluster lifecycle must ship and pass before support is claimed. VM deletion
must also preserve PVCs when Kubernetes rejects the VM delete request.

## Least-privilege target namespace

[`examples/kubevirt-rbac.yaml`](../examples/kubevirt-rbac.yaml) creates the
example `foreman-managed-vms` namespace and a dedicated service account. Change
the namespace and object names consistently before applying it to a real
cluster. The namespaced Role permits only the operations used by the reviewed
plugin:

- create, inspect, update, and delete VirtualMachines;
- inspect VirtualMachineInstances and open their VNC subresource;
- create and remove PVCs and cloud-init Secrets;
- discover NetworkAttachmentDefinitions in the managed namespace.

The ClusterRole can read only the named namespace and list StorageClasses. It
does not grant node access or wildcard verbs/resources. Kubernetes' normal
authenticated discovery binding supplies API discovery endpoints.

The service account deliberately has `automountServiceAccountToken: false`.
Create a bounded token only when configuring or rotating Foreman:

```sh
kubectl --namespace foreman-managed-vms create token foreman-kubevirt \
  --duration=24h > /secure/path/foreman-kubevirt.token
```

The API server may cap the requested lifetime. The current plugin persists a
bearer token in Foreman's encrypted compute-resource password column; it cannot
consume a projected token directly. Production use therefore needs an explicit
rotation process before expiry. Do not replace this with a cluster-admin token
or a legacy non-expiring token merely to avoid rotation.

Rotate an existing compute resource with the repository helper. Keep Foreman
authentication and TLS settings in a mode-0600 curl configuration so neither
the Foreman credential nor the KubeVirt token appears in process arguments:

```sh
cat > /secure/path/foreman.curlrc <<'EOF'
user = "operator:personal-access-token"
cacert = "/secure/path/foreman-ca.crt"
EOF
chmod 600 /secure/path/foreman.curlrc /secure/path/foreman-kubevirt.token

FOREMAN_URL=https://foreman.example.test \
FOREMAN_CURL_CONFIG=/secure/path/foreman.curlrc \
KUBEVIRT_TOKEN_FILE=/secure/path/foreman-kubevirt.token \
scripts/rotate-kubevirt-token.sh COMPUTE_RESOURCE_ID
```

The helper first verifies that the ID belongs to a KubeVirt compute resource,
then sends only the new password/token attribute. A failed connection
validation leaves the update unsuccessful once the prepared plugin validation
fix is included in the image. Schedule rotation with overlap before expiry and
verify a provider API operation afterwards; the helper does not mint tokens.

Export the cluster CA separately:

```sh
kubectl config view --raw --minify \
  --output='jsonpath={.clusters[0].cluster.certificate-authority-data}' | \
  base64 --decode > /secure/path/kubevirt-ca.crt
```

## Network boundary

With restricted egress, add only the provider API CIDR or selector and listener
port under `networkPolicy.egress.external.computeProviders`. Do not add the
target to Pulp or Candlepin policy. If the API is reached through the configured
HTTP(S) proxy instead, keep the direct provider peer list empty and ensure the
provider hostname is not accidentally present in `NO_PROXY`.

## Qualification

The disposable integration harness can qualify an existing provider without
installing KubeVirt or using CPU emulation:

```sh
KUBEVIRT_QUALIFY=1 \
KUBEVIRT_API_HOST=kube-api.example.test \
KUBEVIRT_API_PORT=6443 \
KUBEVIRT_NAMESPACE=foreman-managed-vms \
KUBEVIRT_STORAGE_CLASS=ceph-rbd \
KUBEVIRT_TOKEN_FILE=/secure/path/foreman-kubevirt.token \
KUBEVIRT_CA_FILE=/secure/path/kubevirt-ca.crt \
tests/kind/run.sh
```

Use an empty, dedicated namespace. The test creates one stopped VM and one 1 GiB
PVC, carries the Foreman compute resource through database recovery and later
rollouts, and then removes the external resources and Foreman record. Credential
contents are not stored in the lifecycle state. Failure cleanup uses the target
API directly when Foreman is unavailable.
