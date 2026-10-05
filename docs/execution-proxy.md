# Central execution Smart Proxy

`charts/foreman-execution-proxy` is a separate Smart Proxy deployment for the
Foreman Remote Execution and Ansible control plane. It is not part of the
Foreman web Deployment and it is not an edge provisioning proxy.

## Feature boundary

The profile loads only the image plugins `remote_execution_ssh` and `ansible`.
Their packaged dependency provides Dynflow, so the only advertised Smart Proxy
features must be:

- `script` (the Remote Execution SSH provider);
- `ansible`;
- `dynflow`.

The image also contains `container_gateway`, while the base Smart Proxy package
contains network-oriented modules. They are not loaded or enabled. The
readiness probe calls the local mTLS `/features` endpoint and requires the
running feature set to equal those three names exactly. A Pod advertising DHCP,
DNS, TFTP, BMC, Realm, Discovery, Puppet/OpenVox, OpenSCAP, logs, registration,
templates, container gateway, or any future accidental feature stays out of
Service endpoints.

The Deployment has no host network, host PID/IPC namespace, Kubernetes API
token, privileged mode, or Linux capabilities. Its Service is `ClusterIP` only.
Edge DHCP/DNS/TFTP and isolated management networks remain the responsibility
of separately registered Smart Proxies placed near those networks.

## Current scale and state contract

The replica count is fixed to one. This is intentional, not a missing HPA:

- Smart Proxy Dynflow defaults to memory-only persistence, so the chart points
  it at a SQLite database on the state claim;
- REx also keeps some SSH job data in the process;
- Ansible runner artifacts and SSH control sockets are local to the executor;
- two replicas behind one Service would not provide ownership or handoff for an
  already dispatched job.

The state PVC contains the Dynflow database plus REx and Ansible runner working
directories. `Recreate` prevents two pods from owning it during a rollout. A
restart can retain the Dynflow plan and runner files, but site-loss recovery of
an in-flight command is not yet claimed. The platform recovery set does include
this state claim, the Ansible content claim, and all external Secrets referenced
by the execution release once the proxy is stopped. Restoring those files
recovers the control-plane inputs; it cannot prove whether a remote command
completed while connectivity was lost. Treat Foreman as the job source of truth
and retry interrupted jobs only after validating their target-side effects.
During an application backup or restore, the guarded recovery helper first
stops application dispatchers and then sets `maintenance.enabled=true` on this
release. Maintenance removes the executor Deployment and smoke Job while
retaining its Service, identity, configuration, network isolation, and both
PVCs. The helper waits for the old Pod to disappear before the application
recovery Job mounts and captures those claims. A failed recovery leaves the proxy stopped; use the same
guarded `recover-release.sh resume` path to restart the application and then
the proxy.
Use `scheduling.nodeSelector` and `scheduling.tolerations` when these RWO claims
can attach only to a dedicated node pool. The same settings reach the smoke
Job, so successful release validation proves that the selected pool can also
run its operational gates. A configured `scheduling.priorityClassName` must
refer to an existing cluster-scoped PriorityClass and is checked by preflight.

The chart overrides the image's shell-form command so Smart Proxy runs directly
as PID 1 and receives Kubernetes termination signals. A short `preStop` drain
removes the Pod from its Service before shutdown; the remaining termination
window is available to active Dynflow, SSH, and Ansible work.

Ansible roles, collections, and `ansible.cfg` live on a separate claim mounted
read-only at `/etc/ansible`. Prefer a reviewed Git/Ansible Galaxy pipeline that
publishes immutable content to that claim. Every selectable execution proxy
must receive the same role and collection versions; importing role metadata in
Foreman does not distribute role content to executors.

## Required identity material

The chart consumes existing Secrets and never generates private keys:

| Value | Required keys by default | Purpose |
| --- | --- | --- |
| `proxy.existingTlsSecret` | `ca.crt`, `tls.crt`, `tls.key` | HTTPS server identity and trusted client CA |
| `proxy.existingForemanClientSecret` | `ca.crt`, `tls.crt`, `tls.key` | mTLS client identity for callbacks to Foreman |
| `ssh.existingKeySecret` | `id_rsa_foreman_proxy`, `id_rsa_foreman_proxy.pub` | authentication to managed hosts and public-key publication |
| `ssh.hostKeyVerification.existingKnownHostsSecret` | `known_hosts` | optional pinned host keys or `@cert-authority` records |
| `smokeTest.foremanCertificateSecret` | `client_cert.pem`, `client_key.pem` | Foreman identity used to verify the proxy mTLS boundary |

Host-key verification is enabled by default and the trust Secret is therefore
part of the normal installation preflight. Disabling it is intended only for a
disposable test target and requires the exact value
`I_UNDERSTAND_HOST_KEYS_ARE_NOT_VERIFIED` in
`ssh.hostKeyVerification.insecureSkipVerificationAcknowledgement`.

Secret key names are configurable. The SSH key projection is group-readable
only long enough for a non-root init container to copy it into an `emptyDir`
with mode `0600`; the main container receives that runtime copy read-only.
After updating any of these Secrets, change `secretRolloutToken` in the same
Helm revision. That recreates the singleton pod so projected TLS files are
reopened and the init container copies the new SSH identity into runtime
storage. Updating a Secret without changing the token is not a completed
rotation.

SSH user certificates are supported by enabling `ssh.userCertificate` and
adding the configured certificate and CA public-key entries to the SSH Secret.
The same known-hosts/SSH-CA file is applied to both Remote Execution and
Ansible, so neither execution path silently learns an untrusted target key.

The HTTPS certificate must contain the cluster Service DNS name used when the
proxy is registered, for example:

```text
execution-foreman-execution-proxy.foreman.svc
```

Its client CA must trust the certificate Foreman presents to Smart Proxy. The
common name from that Foreman certificate must be present in
`proxy.trustedHosts`.

## Install and register

First enable the matching Rails plugins in the application release. The
provided overlay preserves the default Katello plugins and adds Remote
Execution plus Ansible:

```sh
helm upgrade --install foreman charts/foreman-stack \
  --namespace foreman \
  --values examples/cluster-values.yaml \
  --values examples/execution-control-plane-values.yaml
```

Create the proxy Secrets and content/state claims, then render or install the
separate execution release:

```sh
helm lint charts/foreman-execution-proxy \
  --values examples/execution-proxy-values.yaml
helm upgrade --install execution charts/foreman-execution-proxy \
  --namespace foreman \
  --values examples/execution-proxy-values.yaml
helm test foreman --namespace foreman --logs
helm test execution --namespace foreman --logs
```

The application test first registers or updates the execution proxy directly
through Foreman's Rails model, so it needs no administrator password or API
token. Saving the record performs Foreman's normal mTLS feature discovery; the
Job succeeds only when Foreman associates exactly Ansible, Dynflow, and Script.
It also rejects the ambiguous case where the desired name and URL already
belong to different proxy records.

The execution test connects to the proxy through its Service DNS name, verifies the
server certificate against `proxy.existingTlsSecret`, presents Foreman's own
client certificate, and requires the returned feature list to equal
`ansible`, `dynflow`, and `script`. It therefore catches a wrong DNS SAN,
untrusted Foreman identity, incorrect `trustedHosts`, and accidentally enabled
network-facing proxy modules before the release is accepted.

When `smartProxy.executionRegistration.enabled` is set in the application
values, `ForemanRelease` adopts that Rails Job after the proxy rollout and
registration is automatic. The Job uses the already mounted Foreman runtime
and database identity; it does not retain Foreman administrator credentials.
Manual Helm deployments run the same contract with `helm test foreman` only
after the execution release is available.

Before assigning the proxy to hosts, verify that Foreman shows only **Ansible**,
**Dynflow**, and **Script**, imports the expected role versions, and can execute
one harmless command plus one Ansible role against a disposable target.

## Network isolation

Ingress is limited by default to Foreman and Dynflow-labelled pods belonging to
the `foreman` Helm release in the same namespace. Override the ingress peers
when the application release has another name. Egress isolation is opt-in
because Kubernetes NetworkPolicy cannot translate `proxy.foremanUrl` or
managed-host names to addresses. Enabling it requires both:

- explicit Foreman peers and callback ports;
- explicit managed-host peers and every allowed SSH port.

The chart rejects an egress-restricted render when either peer set is empty.
The example profile shows the Foreman ingress address on HTTPS and a target
CIDR. The kind profile selects only its ingress controller and disposable SSH
target, then checks both allowed connections and a denied connection to an
unrelated in-cluster service. The allowed Foreman peer must describe the
address actually resolved by `proxy.foremanUrl`; it is not necessarily the
Foreman Pod address. Do not use `0.0.0.0/0` merely to make jobs pass; model the
actual management networks.

## Proof status

Static Helm, schema, relationship, security-context, and negative feature
boundary tests are implemented. The release controller adopts both the
application and execution `helm test` Jobs and does not mark the pair Ready
until the external proxy mTLS/feature check passes. The opt-in amd64 integration drill now also
installs the digest-pinned Smart Proxy, registers it through Foreman, requires
the exact Ansible/Dynflow/Script feature set, and runs harmless SSH and Ansible
commands against a disposable target. A short-lived content publisher writes a
test role to the proxy's content claim; the drill discovers and imports it
through Foreman, assigns it to the target, and executes it. An expected command
failure and a cancelled long-running command must both reach terminal state
before a successful command proves the executor remains usable. The drill
repeats the workflow after a clean namespace restore and after restarting the
proxy Pod with newly issued server TLS, client TLS, and SSH identities. It is
then republished as a second Ansible role-content revision; Foreman synchronizes
the existing role and the target must receive only the new revision's marker.
The drill also forcibly deletes the proxy Pod after a long-running command has
reached the target, bypassing its normal termination grace period. The
interrupted task may succeed or fail, but it must become terminal; a new command
must then succeed through the replacement Pod. This tests control-plane
recovery without promising transparent continuation of the active SSH process.
Separately, the prepared controlled-upgrade path starts a long-running command,
changes the Foreman/Dynflow configuration, and requires both the active command
and a fresh command to succeed after all affected Pods have been replaced. It
then repeats that contract for a configuration-changing `Recreate` rollout of
the execution proxy. Unlike the forced interruption, these upgrade assertions
require the in-flight command to finish successfully within the configured
termination grace period.
It is implemented but has not yet been executed against the published candidate
images.

Still required before production support:

1. run the complete pinned amd64 drill in CI and retain its evidence;
2. run the prepared failure, cancellation, and interrupted-job assertions, then
   decide whether application-level retry semantics are required;
3. run the prepared already-imported role replacement and identity rotation
   assertions against the candidate images;
4. run the prepared allow/deny egress probe and then validate deployment-specific
   Foreman and target networks;
5. run the prepared active-job application and proxy upgrade assertions and
   retain their Pod-replacement and job-result evidence.
