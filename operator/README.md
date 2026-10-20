# Foreman release operator contract

This directory defines the API and deterministic lifecycle contract for the
release controller. `operator/lib/foreman_release/state_machine.rb` is the
executable, side-effect-free transition core used to build durable status,
conditions, operation identity, explicit retries, and pause observations.
`operator/bin/foreman-release-controller` runs that core as a namespaced
polling controller and isolates failures between custom resources. The chart
installs the exact CRD from `operator/crd/` through its Helm `crds/` directory and
tests both copies byte-for-byte to prevent API drift. The chart
runs two candidates behind a PodDisruptionBudget. Each polling cycle renews a
separate leader Lease keyed by the Pod UID; a live foreign holder remains a
standby and an expired holder is replaced with a resource-version-guarded
update. The release-operation Lease below remains a second fence shared with
manual writers.

The controller serves `/livez`, `/readyz`, and Prometheus text metrics on its
health port. Readiness requires at least one successful leader or standby API
cycle within the configured staleness window; a responsive process with a
wedged or unreachable Kubernetes API therefore leaves Service endpoints
without triggering an immediate liveness restart. Metrics expose only process
state, current leader role, cycle counters, and the last successful timestamp,
plus each observed release phase, generation convergence, and drift-audit
health. A successful Ready audit also publishes the earliest usable certificate
expiry for each release. Metric labels are
limited to namespace, release name, and the fixed phase vocabulary; they never
contain release specs, Secret contents, or command output.
The metrics Service keeps NotReady candidates discoverable. An opt-in
`ServiceMonitor` and `PrometheusRule` are emitted only when their external CRDs
are explicitly available and each feature is enabled; the operator chart does
not install or own a monitoring stack. The ServiceMonitor selects the exact
metrics Service labels and supplies bounded scrape timing, so the packaged
alerts have a native discovery path without relying on installation-specific
annotation scraping.
The controller's ingress NetworkPolicy blocks Pod-to-Pod access to the combined
health/metrics port by default; kubelet health probes remain independent of
Pod ingress policy. Enabling the ServiceMonitor requires explicit Prometheus
peers, which are then admitted only to that port. The separate optional egress
policy permits DNS and an explicit Kubernetes API destination and has no
permissive fallback.
The same opt-in rule group alerts on a `Blocked` release, a failed drift audit,
a generation that remains unobserved for ten minutes, and the earliest
certificate entering seven-day warning or 24-hour critical windows. An independent
opt-in Grafana dashboard ConfigMap visualizes controller health, cycle outcomes,
release phases, blocked releases, generation convergence, and drift-audit
health plus remaining certificate lifetime. Its discovery labels are configurable and the chart still does not
install Grafana or a sidecar.
Every persisted phase transition and pause/resume condition also emits a
namespaced `events.k8s.io/v1` Event, so `kubectl describe` exposes release
progress without reading controller logs. A Ready audit failure emits one
deduplicated Warning even though it deliberately leaves the release available;
clearing that failure emits a recovery Event. Status remains authoritative:
Event publication is best-effort and an unavailable Event API cannot block or
repeat a release operation.

`operator/lib/foreman_release/reconciler.rb` turns the transition contract into
an idempotent reconciliation loop behind a side-effect adapter. It persists a
phase before the following reconciliation performs work, observes active
dependency checks, migrations, and rollouts to a safe pause boundary, reuses the persisted
operation ID after restart, and accepts a blocked retry only after
`spec.retryToken` changes. A changed `spec.reconcileToken` starts the same full
validation and rollout for updated values or rotated Secrets without inventing
a new compatibility set. The Helm chart carries that ID plus the owning
ForemanRelease UID on deterministic dependency-preflight, migration, and Pulp registration Jobs, so a
restarted controller adopts them rather than launching duplicate schema
changes.
Pending dependency-preflight and migration names plus successfully submitted application/proxy Helm
revisions are checkpointed into the active operation before the next poll. A
missing member of an already submitted Deployment or registration-Job set
causes the controller to idempotently resubmit that release with migration Jobs
suppressed, instead of waiting until the phase timeout. This repairs partial
resource deletion without re-running a schema change.
After a release is `Ready`, the controller also audits both recorded Helm
revisions and every non-Job object declared by the exact application and
execution-proxy renders. It compares chart-declared labels, annotations,
configuration payloads, and spec fields while ignoring status, server defaults,
and additional admission-injected fields. The interval is bounded by `spec.driftCheckSeconds`
(60 seconds by default). The same audit re-reads every external Secret and
revalidates required certificate dates, key pairs, trust chains, and DNS
identities. Each release records a SHA-256 fingerprint of required Secret
names, keys, and Kubernetes resource versions without storing Secret contents.
An unusable Secret records a drift-audit error and raises the monitoring alert,
but never interrupts running Pods. A valid Secret update, missing or modified
stateless object, or out-of-band Helm revision starts a new uniquely sequenced
`Repair` operation. It repeats
preflight, Lease fencing, both rollouts, registration, and smoke verification,
but deliberately skips database migrations because the compatibility set was
already migrated. The Secret fingerprint is supplied as the chart's rollout
token, including for file-level `subPath` mounts. A Secret change during an
active operation fails the pinned-input check. Changed values Secret content
also remains explicit through `spec.reconcileToken`. A missing or modified PVC
enters `Blocked` instead: silently creating or rewriting storage is not a valid
recovery procedure.

Managed monitoring rules participate in the same drift contract as Deployments,
Services, Ingresses, NetworkPolicies, disruption budgets, and autoscalers. A
deleted or edited `PrometheusRule` therefore cannot silently disable release
alerts while the controller continues reporting `Ready`.

The adapter boundary now includes three concrete, tested primitives:

- `ReleaseCatalog` resolves only in-image profiles, enforces candidate and
  retired-set policy, verifies profile identity, and rejects mutable image
  references;
- `ValuesReader` loads application and execution-proxy values only from the
  referenced Secret keys in the ForemanRelease namespace and requires each to
  be a YAML mapping;
- `KubernetesClient` lists namespaced releases, reads Secret keys without
  placing their contents in command arguments, and updates the status
  subresource with a JSON Patch `resourceVersion` precondition.

`RuntimeAdapter` binds those primitives to Helm and Kubernetes without a
blocking `--wait`. Validation pins SHA-256 fingerprints for both values Secret
keys and both in-image profiles into the operation status, so a mutable Secret
or a controller-image change cannot silently alter an in-flight release. It
first creates one ForemanRelease-owned dependency Job. That Job proves
authenticated, read-only access to the Foreman and Pulp databases, both Valkey
roles, optional Pulp object storage, and Candlepin's Liquibase status command.
The `CheckingDependencies` phase must succeed before any schema-changing Job is
created. It then prepares the chart-owned ServiceAccount, PVC, and desired
ConfigMaps and creates three ForemanRelease-owned migration Jobs without
changing any Deployment. Existing Pods mount those ConfigMaps through
`subPath`, so they retain their old configuration inode during migrations. Only
after all three Jobs succeed does it submit the application Helm revision with
migration Jobs suppressed, observe every expected Deployment and Pulp
registration Job, then submit deterministic smoke-test Jobs. Deployment observation requires every
desired replica to be updated, ready, and available with no old or unavailable
replica remaining; an `Available=True` condition backed only by the previous
ReplicaSet cannot advance the release. The execution-proxy release follows the
same operation identity and is applied only after the application smoke test
succeeds. Once available, an idempotent Rails Job registers it without an API
password and requires Foreman to associate exactly Ansible, Dynflow, and Script
before the final application and external mTLS smoke gates run.

Before the Lease is acquired, `ClusterPreflight` derives dependencies from the
exact combined render. It verifies referenced Secret keys, external PVCs and
ServiceAccounts, explicit or default StorageClasses, the required IngressClass
controller, referenced PriorityClasses, and metrics API availability. Required
X.509 inputs are parsed and must remain valid for the configured safety window;
known certificate/key pairs and colocated CA chains are verified as well. The
TLS certificate selected by each Ingress must also cover every DNS name in
that Ingress; shared Secrets are checked against the union of their hosts.
Candlepin, the Pulp control proxy, and the execution proxy declare the exact
internal Service name their server certificate must cover, so the same check
also protects in-cluster mTLS clients. The complete render must then pass
Kubernetes server-side admission dry-run before the operation can acquire its
mutation Lease. The manual install and upgrade
scripts use the same `ManifestRequirements` implementation, so their preflight
inventory cannot drift from the controller.
The chart's namespaced Role is checked against every resource kind rendered by
both managed charts. A new application object cannot enter the release graph
without explicit CRUD coverage, while Pods remain read-only and cluster-scoped
preflight access remains separately read-only.

Operator-owned Jobs intentionally have no completion TTL, so Kubernetes cannot
erase an unobserved result during a controller outage. Once a release reaches
`Ready`, the controller removes only wholly terminal histories older than the
newest `spec.operationHistoryLimit` operations (three by default). It always
preserves the current operation and any operation containing an unfinished Job.
Cleanup is best-effort and cannot turn a healthy release into `Blocked`. Jobs
from the manual Helm workflow retain their one-hour TTL.

`LeaseManager` implements both fencing boundaries. Controller candidates use
the short-lived `foreman-release-controller-leader` Lease to elect one active
poller. Every release operation and all guarded shell workflows use the separate namespaced
`foreman-kubernetes-release` Lease. Its holder identity combines the durable
operation ID with the controller Pod UID, so a restarted
process in the same Pod can renew it while a replacement Pod must wait for the
old holder to release or expire. Another live holder causes a requeue, and only
an expired or explicitly released Lease can be claimed. Release is an
optimistic `replace` that clears the holder instead
of an unsafe unchecked delete. Every migration, rollout, and verification
reconciliation renews the Lease, including a release paused at a safe boundary.
Every Helm and kubectl subprocess has a hard execution deadline and runs in its
own process group. A timeout sends TERM and then KILL after a short grace
period, so a wedged client cannot bypass the CR phase budget or retain a Lease
forever. The operation Lease duration must exceed four command deadlines.
Preflight also rejects another ForemanRelease that names either of the same
Helm releases, preventing two CRs from taking turns mutating one release.
An existing Helm release without this CR's owner UID is rejected unless the
matching `spec.application.adoptExisting` or
`spec.executionProxy.adoptExisting` flag is explicitly enabled. Once labelled
resources exist, retries and later compatibility-set changes recognize the
release as already owned without keeping that adoption escape hatch enabled.

Every active phase has an explicit wall-clock budget in `spec.timeouts`.
`status.phaseStartedAt` survives controller restarts and Lease contention does
not reset it, so an unschedulable Pod or permanently pending rollout eventually
enters `Blocked` with the expired phase and budget recorded in operation
status. A pause at a safe boundary stops work; resuming intentionally starts a
fresh budget for that phase. Active migrations and rollouts continue to be
observed while paused and remain subject to their original safety deadline.

`ForemanRelease` is namespaced because its Helm releases, values Secrets,
migration Jobs, and status all belong to one application namespace. The
controller reads, but does not copy, the repository's digest-pinned
compatibility sets. Both the application and execution-proxy values are
referenced from same-namespace Secrets so credentials never enter the custom
resource or its status.

New resources use `platform.theforeman.org/v1beta1`, which is the CRD storage
version. The schema-compatible `v1alpha1` endpoint remains served so existing
manifests and stored objects continue to round-trip without a conversion
webhook. Both versions expose the same status subresource and structural
schema; a future incompatible API change must add explicit conversion rather
than reinterpret an existing field.

Preflight discovers compatibility-set identities from existing Helm releases
and combines them with the last successful set retained in status. Every
discovered source must be listed by the target set's `upgradeFrom` contract.
The validated source list is retained in operation status, including split
roll-forward states where application and proxy temporarily use different
allowed sets.

The controller owns release sequencing only:

1. validate the selected compatibility set and referenced values;
2. acquire and renew a Lease for this Foreman release;
3. run authenticated, read-only dependency checks and stop before schema
   mutation if any dependency is unavailable;
4. create revision-owned Candlepin, Pulp, and Foreman migration Jobs and wait
   (or preserve the migrated schema for an automatically detected repair);
5. roll and verify Foreman/Katello, Pulp, Candlepin, and Dynflow workloads;
6. roll the paired execution proxy;
7. run the final service and execution checks, then publish `Ready`.

The Lease is held only for one operation, renewed while a non-quiescent phase
is active, and released after `Ready` or `Blocked`. Its expiry permits another
controller instance to resume observation after a crash; it never authorizes a
second migration Job. Revision Jobs require the ForemanRelease UID and
operation ID as labels, and reconciliation must adopt an existing matching Job
before considering creation.

It does not own PostgreSQL, Valkey, object storage, PKI, edge Smart
Proxies, DHCP, DNS, or TFTP. It also never restores a database or performs an
automatic Helm rollback after migrations.

## Failure and retry contract

`operator/release-state-machine.json` is the machine-readable transition
contract. Any failed validation, dependency check, migration, rollout, or
verification moves the resource to `Blocked` with a condition and keeps the
last known application revision running where Kubernetes can do so safely. A
retry is accepted only after the operator observes a changed `spec.retryToken`;
merely reconciling the same failed object cannot restart migration Jobs.

`spec.paused` prevents the next phase from starting. It does not kill a running
migration Job, terminate a rollout, or cancel active Remote Execution work.
The controller observes the current phase to a safe boundary and then remains
paused.

Every observed ForemanRelease receives the
`platform.theforeman.org/release-protection` finalizer before work starts.
Deleting the CR never uninstalls Helm releases or deletes application data. It
first requests the same safe pause, waits for an active migration or rollout
to reach its observable boundary, proves ownership of the operation Lease,
releases it, and then removes the finalizer. A replacement leader waits for a
live previous holder and can finish deletion only after safely claiming an
expired Lease. A forced manual finalizer removal bypasses that safety
contract and is reserved for recovery when no controller can be restored.

`spec.failurePolicy.afterMigration` intentionally accepts only `Halt`. A future
API version may add separately authorized restore orchestration, but it must
not reinterpret Deployment rollback as database rollback.

The status uses the conventional `Available`, `Progressing`, `Degraded`, and
`Paused` condition types. Conditions describe durable observations; `phase`
selects the next state-machine transition. Every status write carries the
observed resource generation so a client can distinguish current state from a
stale controller report.

## Current boundary

The CRD and state graph are statically validated by `tests/operator-contract.rb`.
`tests/operator-state-machine.rb` also executes the complete happy path, pause,
blocked retry, busy Lease, invalid transition, conditions, and operation
replacement and progress-checkpoint behavior. `tests/operator-reconciler.rb`
simulates a controller restart during migration, safe-boundary pause, a failed
validation, an explicit retry, and a same-generation drift repair. The
two-candidate controller, bounded RBAC, chart, and publication image are
present and covered by command-level simulations. The full integration harness
also prepares a real-cluster adoption, failed Candlepin migration, blocked
retry guard, active-leader deletion, standby takeover, explicit retry, and
final managed-host execution. A retained successful amd64 run of that prepared
drill is still required before treating the controller path as production-ready.
