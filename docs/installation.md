# Installation

The platform is installed as a paired application and execution-proxy release.
The pair must come from one entry in `compatibility/release-sets.json`; do not
mix image profiles from different sets.

## Prerequisites

- a Kubernetes cluster with a default StorageClass and an ingress controller;
- external PostgreSQL databases for Foreman, Candlepin, and Pulp;
- external Valkey/Redis endpoints for Rails caching, Dynflow, and Pulp; the
  production profile requires authenticated TLS and a trusted CA;
- DNS names and TLS material for the Foreman and Pulp endpoints;
- the namespace and every Secret referenced by the selected values;
- Helm, kubectl, jq, Ruby, and access to the digest-pinned images.
- permission to create, read, update, and delete a namespaced Kubernetes Lease;
- When ingress is enabled, an IngressClass backed by
  `k8s.io/ingress-nginx`; the install and upgrade helpers verify the
  controller because the client-certificate bridge uses ingress-nginx
  variables and annotations.
- When a resource-based horizontal autoscaler is enabled, the aggregated
  `v1beta1.metrics.k8s.io` API must exist and report `Available=True` (normally
  provided by metrics-server).
- When `scheduling.priorityClassName` is set, that cluster-scoped
  `PriorityClass` must already exist. Guarded preflight verifies it before any
  release mutation.

The chart does not create production credentials. Copy the example values into
deployment-owned files outside this repository and create the referenced
Secrets through the site's secret-management workflow.

The three Valkey endpoint blocks may reference one service, but a production
deployment should keep the disposable Foreman cache separate from the durable
Dynflow queue. Configure the Dynflow service with persistence, replication or
managed failover, and `maxmemory-policy noeviction`. The Foreman cache and
Dynflow `*-uri-auth` Secret values are URI userinfo including the trailing
`@`; percent-encode reserved characters before storing them. Pulp uses the
separate raw `pulp-password` value for its default Valkey ACL user.

Foreman email is opt-in. Set `foreman.email.enabled=true`, configure the relay
under `foreman.email.smtp`, and create the selected two-key Secret when SMTP
authentication is used. The chart enables automatic STARTTLS and certificate
peer verification; use a relay with a certificate trusted by the Foreman
image. When egress isolation is enabled, declare only that relay and its actual
port under `networkPolicy.egress.external.smtp`.

Sites that require an outbound HTTP(S) proxy can set
`outboundProxy.enabled=true` and provide the three selected keys in
`outboundProxy.existingSecret`. The chart emits both upper- and lower-case
proxy variables for Foreman/Katello Rails processes, Pulp processes, the Pulp
object-storage test, and recovery Jobs. Proxy URLs, including optional
credentials, stay in the Secret and never enter a ConfigMap or rendered value.
Set `NO_PROXY`/`no-proxy` to include at least `localhost`, `127.0.0.1`, `.svc`,
and `.cluster.local`, plus every direct PostgreSQL, Valkey, Kubernetes API,
object-storage, workload-identity metadata, or other internal endpoint used by
the deployment. Candlepin, PostgreSQL, Valkey, SMTP, SSH, and Smart
Proxy protocols are not HTTP proxy clients and keep their existing direct
network paths.

With egress isolation, identify the proxy by an exact selector or CIDR and its
listener ports under `networkPolicy.egress.outboundProxy`. Direct egress rules
remain necessary for every destination listed in `NO_PROXY`. The recovery
repository policy also remains explicit because Restic may use a non-HTTP
transport such as SFTP. After rotating proxy credentials, change
`secretRolloutToken` for a manually managed release. The controller detects a
valid referenced Secret rotation and supplies this token itself.

## ForemanRelease controller (experimental)

The guarded scripts remain the supported development entry point. The same
sequence is also implemented by the experimental `ForemanRelease` controller.
Its image contains only this orchestration repository, Ruby, Helm, and kubectl;
Foreman, Katello, Candlepin, Pulp, and Smart Proxy remain separate images and
Helm releases.

Publish `images/release-operator/Dockerfile` through the operator image workflow
and retain the digest it reports. Then install the chart; Helm creates the CRD
before the controller pair during the first installation:
in the application namespace:

```sh
kubectl create namespace foreman
helm upgrade --install foreman-release-operator \
  charts/foreman-release-operator \
  --namespace foreman \
  --set-string image.repository=ghcr.io/OWNER/REPOSITORY/release-operator \
  --set-string image.tag=VERSION@sha256:REVIEWED_DIGEST
```

Helm intentionally does not upgrade CRDs. Before upgrading an existing
operator release to a repository revision whose CRD changed, apply the reviewed
CRD explicitly and only then upgrade the chart:

```sh
kubectl apply --server-side \
  --field-manager=foreman-release-operator \
  --filename operator/crd/platform.theforeman.org_foremanreleases.yaml
```

Preflight follows Secret-backed environment variables, projected keys, and
file-level `subPath` mounts. A Secret that exists but lacks a certificate or
key consumed through an unfiltered Secret volume is rejected before any
release mutation. Every required X.509 identity must be parseable, already
valid, and valid for at least another 24 hours by default. A CA rotation bundle
may retain expired roots but must contain at least one certificate valid beyond
that window. Known certificate and private-key pairs must match, and a leaf
stored beside its CA bundle must verify against that bundle. Set
`controller.certificateMinimumValiditySeconds` on the operator chart to use a
stricter rotation window. The manual guarded scripts accept the equivalent
`CERTIFICATE_MINIMUM_VALIDITY_SECONDS` environment variable; reducing it to
zero removes only the remaining-lifetime buffer, not parsing, key, or trust
checks.

Store the two environment value documents in one same-namespace Secret. They
may reference the normal runtime credential Secrets; their contents are not
copied into the custom resource or its status.

```sh
kubectl --namespace foreman create secret generic foreman-release-values \
  --from-file=application.yaml=/secure/path/application-values.yaml \
  --from-file=execution-proxy.yaml=/secure/path/execution-proxy-values.yaml
kubectl --namespace foreman apply --filename examples/foreman-release.yaml
kubectl --namespace foreman get foremanrelease foreman --watch
```

The operator Service exposes `/metrics` on port 9393 by default. Kubernetes
uses `/livez` for process liveness and `/readyz` for the freshness of successful
API cycles. Configure a generic Prometheus scraper through
`service.annotations`, or set `monitoring.serviceMonitor.enabled=true` when the
Prometheus Operator CRD is installed. `monitoring.serviceMonitor.labels` must
match that installation's ServiceMonitor selector; the scrape interval and
timeout are configurable and bounded to explicit duration strings.
The leader also exports `foreman_release_status`, desired and observed
generation gauges, drift-audit health, earliest certificate expiry, and
deletion state for each CR. Standby
and API-failed candidates clear that inventory instead of serving stale release
state.
The Service publishes NotReady Pod addresses deliberately so a monitoring
system can still scrape the failure state. If the Prometheus Operator CRDs are
installed, `monitoring.prometheusRule.enabled=true` adds alerts for missing
metrics, no ready candidate, unhealthy leader cardinality, and failed cycles;
it also reports a Ready release whose latest drift audit failed and certificate
lifetimes inside seven-day warning or 24-hour critical windows. Optional
`monitoring.prometheusRule.labels` attach the labels selected by that
Prometheus installation.
Set `monitoring.grafanaDashboard.enabled=true` when a Grafana dashboard sidecar
already watches labelled ConfigMaps. The default
`monitoring.grafanaDashboard.labels` uses `grafana_dashboard: "1"`; replace it
with the deployment's discovery label when necessary. The chart supplies only
the dashboard and never installs Grafana.

The application and execution-proxy charts also provide opt-in workload
alerts. Enable `monitoring.prometheusRule.enabled=true` in each release and set
`monitoring.prometheusRule.labels` to the Prometheus Operator discovery labels.
These rules consume kube-state-metrics to report missing metrics, unavailable
Deployments, crash-looping containers, failed application Jobs, and Pending or
Lost chart-owned PVCs. Guarded preflight requires the `PrometheusRule` CRD
before changing workloads. Application rules are deliberately absent from a
maintenance revision, where the database-writing Deployments are expected to
be stopped; controller alerts continue to report the release operation.

All three charts expose `scheduling.nodeSelector`, `scheduling.tolerations`,
and `scheduling.priorityClassName`. The application setting is deliberately
applied to every web, worker, migration, recurring-task, smoke-test, and
recovery Pod so a guarded release cannot strand an operational gate outside
the node pool used by the long-running workloads. The execution chart applies
the same policy to its singleton proxy and smoke test; select nodes that can
attach both RWO claims. Configure the operator separately so a bad application
node selector cannot also remove the controller needed to report the failure.
For every rendered `nodeSelector`, guarded preflight requires at least one
matching Ready, uncordoned node before migrations begin. This covers both the
release profile's `kubernetes.io/arch` constraint and deployment-specific pool
labels. The same check rejects nodes whose `NoSchedule` or `NoExecute` taints
are not covered by that workload's tolerations. Soft `PreferNoSchedule`, node
affinity, storage topology, and live capacity remain normal Kubernetes
scheduler policy.

An existing PersistentVolumeClaim referenced by a rendered workload but not
owned by either chart must already be `Bound`, except for a `Pending` claim
whose StorageClass explicitly uses `WaitForFirstConsumer`. That delayed claim
is allowed to bind when its workload is scheduled. Guarded preflight rejects a
missing or `Lost` external claim and a `Pending` claim backed by immediate
binding before migrations start. Claims rendered by the charts are created
later in the staged release and are not subject to this pre-existence check.

The release controller is a privileged in-namespace client of the Kubernetes
API. Set `networkPolicy.egress.enabled=true` only after listing the in-cluster
API Service CIDR or another exact endpoint under
`networkPolicy.egress.apiServer.peers`. The resulting egress-only policy permits
DNS and the declared API ports; it does not filter kubelet health probes or
Prometheus ingress. The chart refuses to enable isolation with an empty API
destination.

Optional compute-resource plugins run inside the Foreman and Dynflow pods. With
egress isolation enabled, list their exact API selectors or CIDRs and ports in
`networkPolicy.egress.external.computeProviders`. This covers direct KubeVirt,
Google, Azure, and RH Cloud provider calls without opening the same destination
to Pulp or Candlepin. If all selected provider clients are deliberately routed
through the configured HTTP(S) proxy, the explicit provider destination may be
empty. Enabling one of those plugins without either route is rejected.

Two candidates run by default. A short namespaced leader Lease allows only the
Pod whose UID is the current holder to list and reconcile releases; the standby
takes over only after that Lease expires or is explicitly released. A separate
operation Lease continues to serialize the actual release mutation with manual
install, upgrade, backup, and restore workflows. Every release operation is
restart-safe: its input fingerprints, phase, operation Lease holder, migration
Job names, dependency-preflight Job name, submitted Helm revisions, and
verified Helm revisions are durable.
If part of a submitted Deployment or registration-Job set disappears, the
controller reapplies the same release with migration Jobs suppressed. Change
`spec.retryToken` only after correcting a `Blocked` condition. Set
`spec.paused=true` to stop at the next safe phase boundary; it never terminates
an active migration or rollout.

While `Ready`, the controller checks for missing or modified Helm-managed
objects and out-of-band Helm revisions every `spec.driftCheckSeconds` (60 seconds by
default). It also revalidates every external Secret and TLS identity. A valid
referenced Secret update starts a migration-free repair whose per-release
fingerprint becomes `secretRolloutToken`; an expired or incorrectly rotated
certificate instead appears in `lastDriftCheckError` and the drift-audit alert
without interrupting the working Pods.
Missing or modified stateless resources or a changed Helm revision start a
uniquely identified repair: the normal preflight, lock, rollout, registration,
and smoke gates run again, while schema migrations remain skipped. A missing
PVC instead enters `Blocked` and requires explicit storage recovery. Declared
fields are compared while Kubernetes defaults, status, and additional
admission-injected fields are ignored. The check
never adopts changed values Secret content; update `spec.reconcileToken` when
that change is intentional.

The values Secrets are deliberately not watched as implicit rollout triggers,
because they can alter topology and migration behavior. Change
`spec.reconcileToken` after changing either values payload. The controller then
creates a new operation, fingerprints and validates both current values
payloads, and runs the complete application-plus-execution release even when
`spec.compatibilitySet` is unchanged. Referenced runtime Secrets are different:
their names, required keys, and Kubernetes resource versions are hashed without
persisting their contents, checked throughout an operation, and automatically
rolled after a valid Ready-state change. `retryToken` has a separate purpose
and remains required to leave `Blocked`.

Completed controller-owned Job histories are retained for audit without a TTL,
then safely bounded after a successful release. Set `spec.operationHistoryLimit`
to keep between one and twenty completed operations (default: three). The
current operation and every operation with an unfinished Job are never pruned;
a cleanup failure leaves the release `Ready` and is retried by reconciliation.

Deleting a `ForemanRelease` is a detach operation, not an uninstall. Its
finalizer waits for the current migration or rollout to reach a safe pause,
releases the operation Lease, and then lets Kubernetes remove the CR while the
Foreman, execution-proxy, databases, PVCs, and external services remain in
place. Use the chart-specific uninstall and data-retention procedures only as
a separate, explicitly destructive operation.

Both `adoptExisting` flags default to false. Set the relevant flag only for the
first controlled takeover of an already installed Helm release, verify that
its values match the referenced Secret and compatibility profile, and return
the flag to false after ownership labels appear. A newly installed release or
one already labelled with this ForemanRelease UID needs no adoption override.
An adopted release must expose its original `compatibilitySet` in its computed
Helm values, and that set must be an allowed `upgradeFrom` source for the
requested target. The adoption flag does not bypass release compatibility.

Before changing a failed deployment, capture the Secret-redacted, read-only
bundle described in [`diagnostics.md`](diagnostics.md). It preserves release,
Helm, workload, Job, Event, and cluster-capability evidence without requesting
Pod logs or Secret payloads.

The full integration workflow now contains a real-cluster adoption, failed
migration, leader takeover, explicit retry, application rollout, proxy rollout,
and final execution drill using the locally built operator image. It retains
the blocked and ready status as evidence bound to the same compatibility set.
This is still a prepared qualification until that amd64 workflow completes;
do not replace the guarded scripts in production based on static validation
alone.

## Guarded first installation

Create the namespace and Secrets first:

```sh
kubectl create namespace foreman
kubectl apply --namespace foreman --filename /secure/path/foreman-secrets.yaml
```

Then install the paired release set:

```sh
ALLOW_CANDIDATE=1 scripts/install-release.sh \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml
```

`ALLOW_CANDIDATE=1` is required only while the selected set has not completed
the retained amd64 integration qualification. Do not use it as a substitute
for that qualification on a production cluster.

The installer performs these gates before changing application resources:

1. it resolves the requested compatibility set and rejects retired or
   unapproved candidate sets;
2. it acquires the same renewable release Lease used by upgrades, so two
   install/upgrade helpers cannot race each other; a crashed holder becomes
   reclaimable after the Lease expires;
3. it refuses to overwrite an existing Helm release;
4. it renders and lints both charts with deployment values followed by the
   authoritative digest-pinned image profiles;
5. it verifies every referenced IngressClass, named or default StorageClass,
   PriorityClass, required resource Metrics API, external PVC, and external
   ServiceAccount;
6. it discovers every non-optional, externally managed Secret used by a Pod
   template and verifies both the Secret and each explicitly referenced key;
7. it submits the complete render through Kubernetes server-side dry-run so
   admission policies, quotas, Pod Security, API validation, and immutable
   field conflicts reject the release before migrations start;
8. it rejects maintenance-only renders that omit normal migration workloads.

The application and execution namespaces should enforce the Kubernetes
`restricted` Pod Security Standard. Select an enforcement version supported by
the cluster and pin it deliberately, together with matching audit and warning
labels. The full integration environment uses `v1.34` because that is its
default pinned Kubernetes version; this is an admission contract, not a reason
to copy that version onto older clusters. External databases, caches, brokers,
object stores, and infrastructure Smart Proxies remain outside the chart's
namespace and must be secured by their respective operators.

It first applies one operation-labelled, read-only dependency Job. Its isolated
containers authenticate to the Foreman, Pulp, and Candlepin databases, both
Foreman Valkey roles and Pulp Valkey; an S3-backed Pulp deployment also performs
a bounded bucket listing through the configured static or workload identity.
No schema command is submitted unless that Job completes. It then applies only
the Helm-adoptable migration dependencies and three one-hour,
operation-labelled migration Jobs. Application Deployments are not submitted
until all three migration Jobs complete. The installer applies the application
with migration rendering suppressed, waits for Pulp registration, runs the
application smoke test, installs the execution proxy, and waits for its Pod.
The final gate idempotently registers the proxy through Foreman's Rails model,
repeats the application smoke test, and then calls the execution proxy
`/features` endpoint through Service DNS with Foreman's client certificate.
The release is accepted only when Foreman associates the proxy with exactly
`Ansible`, `Dynflow`, and `Script`, server TLS and client trust match, and the
external endpoint returns the same exact feature boundary.

`RELEASE_LEASE_NAME`, `RELEASE_HOLDER_ID`, `RELEASE_OPERATION_ID`,
`RELEASE_LEASE_DURATION_SECONDS`, and
`RELEASE_LEASE_RENEW_INTERVAL_SECONDS` may override the Lease defaults. The
renew interval must remain shorter than the duration. A manually supplied
operation ID must be a fresh Kubernetes label value for each attempt; normally
the helper generates it.

The controller additionally bounds Preflight, Lease acquisition, the
`CheckingDependencies` gate, migrations,
both workload rollouts, and verification through `spec.timeouts`. A phase that
exceeds its budget becomes `Blocked`; the operation Lease is released, but no
schema or workload rollback is attempted. Correct the scheduling, image,
storage, or endpoint failure and change `spec.retryToken` to reconcile again.
Every managed Deployment also has a shorter Kubernetes progress deadline, so
the controller can normally report the exact `ProgressDeadlineExceeded`
workload before the broader phase budget is exhausted.
Controller-side Helm and kubectl commands are independently bounded by
`controller.commandTimeoutSeconds`. A timed-out process group receives TERM
and then KILL after `controller.commandTerminationGraceSeconds`; the release
Lease is required to remain valid for more than four such command windows.

## Failure boundary

The script intentionally does not use Helm's atomic rollback. A failed install
may already have advanced one or more database schemas, and rolling workload
manifests back cannot roll those schemas back safely. Inspect the failed Jobs
and release state, repair the cause, and retry the same compatibility set.

If the application smoke gate fails, the execution proxy is not installed. If
the proxy fails after the application succeeded, keep the application release
and repair or retry only the proxy side. Never delete production PVCs or
databases as part of an automated retry.

Existing releases must use `scripts/upgrade-release.sh` and the procedure in
[`upgrades.md`](upgrades.md).

## Uninstall and persistent data

Every PVC created by the application and execution-proxy charts carries
`helm.sh/resource-policy: keep`. Removing either Helm release therefore leaves
Foreman shared temporary storage and avatars, filesystem-backed Pulp content,
execution Dynflow state, and Ansible content intact. This protects against an
accidental application uninstall; it does not protect against namespace
deletion, direct PVC deletion, storage failure, or a destructive storage-class
reclaim policy.

To reuse retained data predictably, reference the retained claim names through
the corresponding `existingClaim` values before installing a replacement
release. Delete a retained claim only as a separate, reviewed operation after
its recovery point and underlying volume policy have been verified. Helm
uninstall must never double as a data-retention decision.
