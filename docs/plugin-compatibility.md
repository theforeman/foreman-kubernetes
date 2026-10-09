# Plugin compatibility and placement

Compatibility is tracked against the plugins packaged in the official Foreman,
Pulp, and Foreman Proxy images. This is narrower than every community plugin in
the Foreman ecosystem. A community plugin first needs a reproducible image build
before this chart can make a runtime compatibility claim.

The machine-readable inventory is
[`compatibility/plugin-matrix.json`](../compatibility/plugin-matrix.json). Its
states deliberately distinguish four different facts:

1. the package exists in an image;
2. the application can load it and run its migrations;
3. external services, credentials, routes, persistence, and egress are modelled;
4. its real workflow passed the amd64 integration suite.

Only `foreman-tasks` and `katello` are enabled by default. They are wired into
the chart, but remain labelled `integration-pending` until the full install and
content lifecycle test passes. Other packaged Rails plugins require
`foreman.pluginPolicy.allowUnverified=true`; this is an explicit test escape
hatch, not a support claim. The schema rejects plugin names that are absent
from the reviewed official image.

## Foreman image

| Plugin | Default | Placement | Missing proof or contract |
| --- | --- | --- | --- |
| `foreman-tasks` | yes | Foreman and Dynflow pods | full integration run |
| `katello` | yes | Foreman pods | full Katello content lifecycle |
| `foreman_remote_execution` | no | Foreman plus the execution Smart Proxy chart | success/failure/cancel and interrupted-job convergence are modelled; live run and retry policy remain |
| `foreman_ansible` | no | Foreman plus the execution Smart Proxy chart | role import, execution, and content replacement are modelled; live run remains |
| `foreman_google` | no | Foreman pods | provider credentials, egress, API test |
| `foreman_azure_rm` | no | Foreman pods | provider credentials, egress, API test |
| `foreman_kubevirt` | no | Foreman pods | upstream API-version fix, KubeVirt credentials, egress, API test |
| `foreman_rh_cloud` | no | Foreman pods | cloud credentials, egress, service workflow |
| `foreman_webhooks` | no | Foreman and Dynflow pods | dedicated destination allow-list; delivery, failure, receiver replacement, and clean-recovery drill implemented but unrun |
| `foreman_virt_who_configure` | no | Foreman plus external virt-who host | configuration API, generated deployment script, report state, service-user cleanup, and clean-recovery drill implemented but unrun |

The base image also installs compute-provider packages for libvirt, VMware,
OpenStack, and EC2. These are not selected through `FOREMAN_ENABLED_PLUGINS`;
each still needs provider-specific credential, egress, and lifecycle tests.

The reviewed `foreman_kubevirt` source forces `v1alpha3`, even though its
`fog-kubevirt` dependency already discovers the preferred version from the
cluster's `kubevirt.io` API group. That override is also inconsistent with the
plugin's `kubevirt.io/v1` owner references. A separate local upstream commit
removes the override and tests the complete client-options contract. The plugin
remains `packaged-integration-pending` until that fix is accepted into the
official image and a real cluster workflow covers connection validation, VM
creation, restart, deletion, and recovery. The chart will not hide the problem
with a mock KubeVirt endpoint.

The reviewed `fog-kubevirt` source also lists
`NetworkAttachmentDefinition` objects without a namespace even though the
compute resource is namespace-scoped. That would require a needlessly broad
cluster permission. A second local upstream commit passes the configured
namespace to the client and has a focused regression test. Least-privilege RBAC
and promotion depend on shipping both fixes.

The fog create request also uses the discovered URL version (`v1`) directly as
the custom resource body's `apiVersion`. KubeVirt VirtualMachines require the
grouped value (`kubevirt.io/v1`). The prepared fog patch composes the group and
discovered version and verifies the exact request body before it reaches
Kubernetes.

Connection validation has a separate correctness gap: failed Kubernetes and
KubeVirt probes return `false` without adding a model error. Rails does not use
the return value of this after-validation callback to invalidate the compute
resource, so an unusable provider can be saved without an actionable error. A
third local upstream commit records distinct errors for an unreachable
Kubernetes API and a reachable API without KubeVirt, with regression coverage.

Volume creation has two additional edge cases covered by the local patch
series. An explicitly non-bootable disk sent as `bootable: "false"` must not be
treated as a boot disk and skipped during image provisioning. If a later PVC
creation fails, every PVC already created by that request must be removed before
the error is returned. The prepared tests cover both behaviors.

Deletion had the inverse safety problem: the plugin removed PVCs before asking
Kubernetes to delete the VM. A failed VM deletion could therefore leave a VM
whose storage was already gone. The local fix captures the volume list, requires
the VM delete call to succeed, and only then removes plugin-managed PVCs.

The upstream credential guide in the reviewed revision still recommends a
cluster-admin identity and legacy automatically generated ServiceAccount token
Secrets. The local documentation patch replaces that with a dedicated,
least-privilege ServiceAccount, bounded TokenRequest tokens, current CA export,
and explicit rotation guidance.

An opt-in external-cluster drill is prepared for that later qualification. It
registers the compute resource through Foreman's API without retaining token or
CA material in its state artifact, requires Foreman and the cluster discovery
endpoint to select the same API version, creates one stopped VM and PVC, checks
the relationship after clean database recovery and application upgrades, and
removes both Kubernetes resources and the Foreman record. It remains unrun and
does not change the plugin's compatibility status.

Foreman Webhooks uses the plugin's asynchronous delivery job for event-driven
requests and Ruby's standard HTTP client for the destination connection. The
chart accepts either a dedicated webhook peer/port allow-list or the declared
outbound proxy. The prepared drill proves successful event delivery, surfaces
an HTTP 503 from the destination, corrects the URL, replaces the receiver Pod,
and repeats delivery after clean database recovery. It deliberately does not
claim automatic retry of a failed request: the reviewed plugin has no
plugin-owned retry policy that this platform can promise.

`foreman_virt_who_configure` is a Foreman-side configuration and reporting
plugin, not a virt-who process supervisor. It creates a hidden, organization-
scoped reporting identity and renders a root deployment script which installs
and configures `virt-who` on a separate RPM-based host, writes
`/etc/virt-who.d`, and controls the host's systemd service. The Kubernetes chart
therefore enables only the Rails plugin and its migrations; it does not run
that generated script, mount a host init system, or claim ownership of
hypervisor connectivity. The prepared drill covers API validation, encrypted
credential storage, script generation and regeneration, report-state updates,
identity cleanup, and clean database recovery. A real external-host install and
report into Candlepin is still required before support can be claimed.

## Pulp image

The reviewed image contains `pulp_ansible`, `pulp_container`, `pulp_deb`,
`pulp_ostree`, `pulp_python`, `pulp_rpm`, and `pulp_smart_proxy`; Pulpcore also
provides the file and content-guard applications used by this chart. The schema
accepts only that inventory and always requires `pulp_certguard`, `pulp_file`,
and `pulp_smart_proxy` because Katello's control and registration path depends
on them.

The default enables container, Debian, file, and RPM content. The chart also
models the packaged optional routes: Galaxy uses `/pulp_ansible/galaxy`, Python
uses the API-backed `/pypi` endpoint, and OSTree uses the common
`/pulp/content` distribution path. A render contract enables every packaged
plugin together and verifies that no administrative `/pulp/api` route becomes
public. The mTLS application smoke test also calls Pulp Smart Proxy's live
feature endpoint and requires every enabled, advertised plugin capability plus
client-certificate authentication; this catches a packaged plugin whose Django
application or migrations failed to load. It is an API-surface gate, not a
substitute for a content workflow. Ansible, OSTree, and Python remain disabled
by default. The opt-in amd64 drill now creates a self-contained Python source
distribution, synchronizes it through Katello, checks indexed metadata and the
public PyPI package, publishes it in a Content View, and verifies the same state
after clean-namespace
recovery. The same lifecycle now creates an unsigned deterministic OCI image
fixture, synchronizes its tag and manifest through Katello, verifies the
published registry manifest over the internal mTLS compatibility route, and checks the
same state after clean recovery. It also creates an unsigned deterministic APT
repository, synchronizes its Debian package through Katello, includes it in the
published Content View, and verifies both the library and published package
after clean recovery. A minimal repository built from Katello's own `squirrel`
RPM fixture now covers the same synchronization, publication, metadata, and
recovery boundary for RPM content. All four plugin statuses remain
`integration-drill-implemented-unrun` until the complete amd64 drill passes; a
package and a correct route alone are not support evidence.

## Smart Proxy placement

There is no single mandatory Smart Proxy machine. Foreman supports multiple
proxies, and each should be placed close to the resources it controls.

| Function | Placement in this design | Reason |
| --- | --- | --- |
| Pulp content | Pulp control endpoint in Kubernetes | implemented as Pulp's `pulp_smart_proxy`, not a generic Smart Proxy pod |
| Remote Execution / Ansible | dedicated singleton execution-proxy chart or an external edge proxy | Kubernetes state, identity, feature, storage, and egress contracts plus command/role workflows are modelled; live failure proof is pending |
| DHCP / DNS / TFTP | external edge proxy | tied to provisioning networks, stable endpoints, backend state, and often privileged host integration |
| BMC / Redfish | external management-network proxy | must reach the isolated management network and handle privileged credentials |
| Discovery | external provisioning-network proxy | requires direct placement on the discovery/PXE network |
| Puppet/OpenVox CA | external dedicated proxy | owns CA and configuration-management state |
| OpenSCAP | external or dedicated proxy | owns report/content paths and client-facing connectivity |
| Templates / Registration | direct Foreman ingress unless an edge content proxy is required | no reason to add a central generic proxy merely because older all-in-one installations co-located it |

`smartProxy.mode` is currently fixed to `external`. The chart does not create a
generic Smart Proxy container, does not expose DHCP/DNS/TFTP service ports, and
does not grant host networking, privileged mode, or Linux capabilities to an
application pod. Consequently those services cannot be enabled through this
chart on the Foreman web Deployment.

The central-execution chart uses a positive feature allow-list rather than
accepting arbitrary `settings.d` files. The image loads only the REx SSH and
Ansible plugin packages (Dynflow is their dependency), and only their three
configuration files are enabled. Readiness calls the local mTLS `/features`
endpoint and requires its complete result to equal `ansible`, `dynflow`, and
`script`. NetworkPolicy and the restricted container security context are
secondary controls; the primary controls are that forbidden modules are never
configured and an accidental running feature removes the Pod from Service
endpoints.

## Promotion test

A plugin can move from `integration-pending` to supported only when its profile
proves:

- image package and dependency versions;
- migrations on a fresh database and during an upgrade;
- required Secrets, storage, routes, and egress;
- one successful real workflow and its observable failure path;
- restart and scale behavior for every component it adds;
- backup and restore of any new state.

The official plugin overview remains the discovery source for plugins outside
the current OCI images: <https://theforeman.org/plugins/>.
