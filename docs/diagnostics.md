# Diagnostics and support bundles

Run the read-only collector before changing a failed release:

```sh
NAMESPACE=foreman FOREMAN_RELEASE_NAME=foreman \
  scripts/collect-diagnostics.sh /secure/path/foreman-diagnostics.tar.gz
```

The output path must not already exist. The archive is created with owner-only
permissions and contains:

- the selected `ForemanRelease`, including durable operation and drift status;
- Kubernetes and Helm client versions plus relevant cluster capability state;
- a reduced Node scheduling inventory with architecture, selected topology
  labels, cordon and taint state, readiness, and runtime versions;
- namespaced workloads, Services, Jobs, CronJobs, claims, policies, disruption
  budgets, ConfigMaps, ServiceAccounts, Leases, and Events;
- Helm release status and revision history for the application and execution
  releases; and
- `collection.tsv`, which identifies unavailable artifacts without aborting the
  rest of the collection.

The collector never requests Pod logs, Helm values, database dumps, or
application data. Kubernetes Secret objects are transformed immediately: the
archive retains only their name, namespace, type, labels, creation time,
annotation key names, and data key names. Annotation values are
also discarded because a last-applied annotation can contain a serialized
Secret. Every value under `data` is discarded before the archive is written.
Node objects are reduced before they are written. Provider IDs, annotations,
arbitrary labels, machine IDs, addresses, capacity, and condition messages are
excluded; only fields needed to diagnose platform scheduling are retained.

This boundary prevents direct Secret disclosure; it does not make the whole
bundle public. Resource specifications, Events, hostnames, image references,
and topology are operationally sensitive. Review the extracted archive before
sharing it outside the organization.

The collector does not mutate the cluster and does not acquire the release
Lease. A failed artifact usually indicates missing read permission or an
unavailable API; inspect the adjacent `.stderr` file and `collection.tsv`.
Collecting diagnostics must not be used as evidence that a restore, migration,
or end-to-end workload succeeded.
