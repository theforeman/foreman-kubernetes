# Disposable kind integration test

`run.sh` creates a dedicated single-node kind cluster, installs ingress-nginx, PostgreSQL, Valkey, generated short-lived PKI, and the complete chart. It then verifies:

- initial Pulp and Foreman migrations;
- separate Candlepin migration ownership and readiness of its single
  application pod;
- Foreman health both with and without the optional client certificate;
- the chart-owned Helm smoke test against Foreman/Katello aggregate health,
  Candlepin status, and Pulp status through the default NetworkPolicies;
- the exact digest and non-root runtime identity of every application image,
  its required executable and packaged plugin inventory, and the enabled Pulp
  components reported by the live API; the resulting report is retained with
  the compatibility evidence;
- automatic Pulp Smart Proxy registration through the private mTLS endpoint;
- deployment and API registration of a separate, singleton execution Smart
  Proxy whose advertised features must equal Ansible, Dynflow, and Script;
- real SSH and Ansible command jobs from Foreman against a disposable
  unprivileged target, including verification that Foreman selected the
  registered execution proxy;
- an egress-restricted execution proxy which reaches only cluster DNS, the
  Foreman ingress, and the disposable SSH target, plus a denied connection to
  an unrelated in-cluster content service;
- discovery, import, host assignment, and execution of a disposable Ansible
  role published declaratively to the proxy's content claim;
- replacement of that already imported role with a second revision, followed
  by another synchronization and execution which rejects the stale revision;
- expected-failure and cancellation paths followed by a successful job proving
  the executor remains usable;
- deletion of the execution-proxy Pod after a long-running command reaches the
  target; the task must become terminal and a fresh command must then succeed,
  without claiming transparent continuation of the interrupted SSH process;
- absence of a public Pulp administrative API route;
- Katello file, Python, OCI container, Debian, and RPM content lifecycles against
  an in-cluster deterministic source: organization and product creation,
  repository synchronization, metadata indexing, public Pulp, PyPI, and OCI
  registry delivery, Content View publication, and Activation Key assignment;
- container tags and manifests are checked through Pulp and the published
  registry manifest is fetched through the client-certificate compatibility route;
- an encrypted Restic backup of all three PostgreSQL databases, Pulp storage,
  and the declared Secret escrow;
- restoration after deliberately changing independent probes, deleting the
  entire application namespace, recreating empty databases and Pulp storage,
  and retaining application state only in the Restic repository;
- Foreman readiness and Pulp registration after leaving restore maintenance;
- the complete Katello object graph, published file, Python package metadata,
  PyPI simple index, and package checksum after restoration, so the recovery
  check covers real application state in addition to probes;
- Foreman virt-who Configure API validation, a libvirt configuration, its
  encrypted hidden reporting identity, generated deployment script, endpoint
  update, `unknown` to `ok` report state, cleanup, and preservation through the
  same clean-namespace database restore;
- optional qualification against an externally operated KubeVirt cluster:
  preferred API discovery, secret-safe compute-resource registration, storage
  discovery, creation of one stopped VM and PVC in a dedicated namespace,
  preservation through database restore and application upgrades, and complete
  cleanup;
- execution-proxy re-registration and successful new jobs after the clean
  namespace restore and again after rotating its server TLS, Foreman client
  TLS, and SSH identities and restarting both ends of the SSH trust relation;
- Dynflow worker scaling;
- a deliberately failed Foreman migration caused by temporary invalid database
  credentials: no application Helm revision or replacement Pod may be created,
  every previous application workload Pod must remain present, an
  already-running Remote Execution job and a fresh job must succeed, and a
  subsequent healthy revision must run migrations and replace the affected
  Pods;
- the same migration gate with temporary invalid Candlepin credentials, then a
  healthy roll-forward which replaces the singleton through its `Recreate`
  strategy;
- a second Helm revision with migration gates and confirmed Foreman and Dynflow
  Pod replacement while a Remote Execution job remains active and completes;
- a configuration-changing execution-proxy rollout while another active job
  completes, followed by a fresh job through the replacement Pod.
- adoption of both existing Helm releases by the real two-replica
  `ForemanRelease` controller, a genuine failed Candlepin migration which
  enters `Blocked` without replacing workloads, leader Pod loss and standby
  takeover, refusal to retry an unchanged token, and a successful explicit
  retry through both application and execution-proxy verification;
- removal of the temporary adoption permissions after the controller has
  labelled both releases, plus another successful managed-host job through the
  controller-owned result;
- a Ready-state drift audit which repairs a modified stateless ConfigMap,
  blocks rather than replacing a modified PVC, resumes only after the PVC is
  restored and a new retry token is supplied, and publishes the earliest
  validated certificate expiry in release status;
- a chart-owned Pulp storage probe against a digest-pinned, disposable
  S3-compatible endpoint: bucket versioning, multipart upload, byte-for-byte
  SDK and signed-URL reads, delete marker verification, permanent cleanup of
  every probe version, rejection of a retired key, and a complete repeat after
  credential rotation;
- Kubernetes `restricted` Pod Security admission for every application,
  execution-proxy, migration, test, recovery, and controller Pod created after
  the disposable dependencies are ready. The object-storage emulator and SSH
  target are recreated under the same policy during their lifecycle drills, so
  the assertion covers admission after installation as well.

The test is intentionally opt-in because it downloads the real application images and needs substantially more CPU, memory, and time than chart rendering:

```sh
tests/kind/run.sh
```

The `Full integration` GitHub Actions workflow exposes the same drill through a
manual dispatch on an amd64 runner. Successful complete runs retain a
promotion-eligible evidence artifact bound to the exact commit, profiles, and
test contract. Failed runs retain a short-lived diagnostic artifact and always
remove the disposable cluster.

The temporary cluster and generated PKI are removed on success or failure. Set `KEEP_CLUSTER=1` only while diagnosing a failure. An existing cluster with the same name is never modified unless `REUSE_CLUSTER=1` is explicit.

The harness builds `images/recovery-toolbox/Dockerfile`, the test-only
`images/ssh-target/Dockerfile`, and `images/release-operator/Dockerfile`
locally and loads them into kind; it publishes none of them. The SSH target
permits only the generated short-lived public key for its unprivileged
`foreman` user and exists solely inside the disposable namespace. Set
`SKIP_RECOVERY_TEST=1` for a faster diagnostic run that omits the recovery
toolbox build and recovery drill; the SSH target and release operator are still
built because execution and controller tests remain active.

The S3 qualification fixture uses the signed upstream SeaweedFS 4.47 image by
immutable multi-platform digest. It is test infrastructure only; production
deployments still provide and operate their own versioned bucket.

The webhook lifecycle fixture reuses the already selected Foreman image for a
small in-cluster HTTP receiver, so it does not add another runtime image. It
creates a real `domain_created.event.foreman` webhook, observes asynchronous
delivery, requires an HTTP 503 to remain visible, corrects the target, replaces
the receiver Pod, and repeats delivery after clean-namespace database restore.
The receiver has a separate ingress policy that admits only the Foreman web and
Dynflow worker components. This tests the plugin's real behavior without
claiming an automatic retry policy the plugin does not implement.

The virt-who Configure lifecycle exercises the Foreman plugin but does not run
the generated script. That script expects an external RPM-based host with root,
package repositories, and systemd, and the resulting virt-who process needs its
own hypervisor and Foreman/Candlepin network paths. The disposable test proves
configuration, credential, script, state, and recovery behavior without
misrepresenting that external host as a chart-owned Kubernetes daemon.

KubeVirt qualification is disabled by default and does not install or emulate a
hypervisor. Set `KUBEVIRT_QUALIFY=1` and provide `KUBEVIRT_API_HOST`,
`KUBEVIRT_API_PORT`, `KUBEVIRT_NAMESPACE`, `KUBEVIRT_STORAGE_CLASS`, plus
readable `KUBEVIRT_TOKEN_FILE` and `KUBEVIRT_CA_FILE` paths. Use a dedicated
namespace and a least-privilege service account that can discover the
`kubevirt.io` API, read StorageClasses, and create, inspect, and delete
VirtualMachines and PVCs in that namespace. The token and CA contents are never
written into the retained state file. The drill compares Foreman's selected API
version with the cluster's preferred version, leaves the VM stopped, and has a
direct API cleanup fallback if Foreman becomes unavailable. It still requires
an application image containing the prepared dynamic-version compatibility
fix; the current packaged plugin must not be promoted merely because the drill
exists.

The web availability drill uses the host's existing `curl` and the public TLS
ingress. It sends 640 dependency-aware requests while deleting one of two ready
Foreman web Pods, requires the replacement to become ready, rejects any invalid
response, and returns the Deployment to the profile's single test replica. It
proves request continuity under one Pod loss, not a production load limit.

Pulp has a separate continuity drill after the content lifecycle publishes its
test artifact. A restricted in-cluster Pod sends 640 private API health
requests while host clients download and checksum the public artifact 640
times. The harness removes one API and one content Pod together, requires both
replacements to become ready, and then restores the test profile's replica
counts. This is availability evidence rather than a throughput benchmark.

The `foreman` namespace is labelled for `restricted` enforcement, audit, and
warnings at the Kubernetes 1.34 policy version before Helm creates any product
workload. The version intentionally matches the default pinned kind node. When
testing another node image, keep the selected policy version supported by that
cluster instead of weakening enforcement.

By default the harness resolves the paired, digest-pinned nightly candidate
from `compatibility/release-sets.json` and the `kind-v1.34-amd64` qualification
target from `compatibility/cluster-platforms.json`. That target pins the kind
node, Kubernetes 1.34.11, containerd, ingress-nginx chart 4.15.1, and the
`restricted` v1.34 Pod Security policy. The harness checks the live node before
installing dependencies. `COMPATIBILITY_SET` selects another declared pair and
`CLUSTER_PLATFORM` selects one of that pair's declared qualification targets.
The published application images are currently `linux/amd64` only. The script
refuses an ARM host unless `ALLOW_EMULATION=1` explicitly opts into the slower,
host-dependent emulation path. For candidate development, `IMAGE_PROFILE` and
`EXECUTION_PROXY_IMAGE_PROFILE` may override both halves of the pair together;
a one-sided override is rejected. `KIND_NODE_IMAGE=...` selects another
Kubernetes test image for diagnostics, but evidence from that override cannot
promote the declared platform.

Set `INTEGRATION_EVIDENCE_FILE` to write a result record after all assertions:

```sh
INTEGRATION_EVIDENCE_FILE=artifacts/integration-result.json tests/kind/run.sh
```

Only a complete native `linux/amd64` GitHub Actions run of the profiles declared
by the selected set is eligible for promotion. Other records remain useful for
diagnosis but cannot change a set to `supported`.
