# Disaster recovery

The chart provides explicit, one-shot backup and restore Jobs. They create an
application-consistent recovery point only while maintenance mode has removed
all workloads that can write to Foreman, Candlepin, or Pulp state.
The guarded helper also stops the paired execution proxy before starting the
recovery Job. This prevents its Dynflow process from delivering callbacks or
changing execution state while the application databases are being captured
or replaced.

Quiescence includes Pods that are still terminating: a deletion timestamp does
not prove that a process has stopped writing. Completed and failed Job Pods are
ignored because their processes have already exited.

The recovery set contains:

- logical, custom-format PostgreSQL dumps for Foreman, Candlepin, and Pulp;
- Foreman's LDAP avatar files, whose hashes but not bytes live in PostgreSQL;
- the complete Pulp filesystem mounted at `/var/lib/pulp` when filesystem
  storage is selected;
- the paired execution proxy's Dynflow/runner state and reviewed Ansible
  content claims;
- an encrypted escrow copy of the application, certificate, ingress, and image
  pull Secrets known to both Helm releases;
- a versioned manifest identifying the Helm release, namespace, chart, and
  exact digest-pinned compatibility set;
- an exact SHA-256 inventory of the three dumps, recovery manifest, and every
  Secret escrow file.

Valkey is deliberately excluded. It contains cache and task transport state,
not the authoritative application records. Any work that was in flight when a
recovery point was taken must be reconciled after the restore.

## Boundaries

The chart does not own PostgreSQL servers, database roles, the Restic storage
backend, or its credentials. Production database physical backups, WAL
archiving, bucket replication, and storage snapshots remain the responsibility
of their respective operators. The Jobs provide a portable application-level
recovery set; they do not replace those infrastructure controls.

The repository credentials are intentionally not included in their own backup.
Escrow the repository Secret and its password outside the cluster. A local
Restic repository must use storage independent from the Pulp data claim or it
will not survive the same storage failure.

With Pulp object storage, the recovery set records the backend and exact
provider snapshot or versioning point but excludes bucket objects. Protect the
bucket independently with versioning or provider snapshots and replication.
The chart binds the point ID into the integrity-protected manifest and rejects
a restore that presents another ID. This detects operator mix-ups; the object
store remains responsible for proving that the supplied ID exists and was
successfully restored.

## Recovery toolbox

The `Recovery toolbox image` workflow builds and executes every command used by
the recovery scripts separately on `linux/amd64` and emulated `linux/arm64`.
Only after both checks pass does it publish one multi-platform image index to
GHCR with an SBOM and build provenance. Push a `recovery-v*` tag for a versioned
image or dispatch the workflow for a commit-tagged qualification build. Copy
the immutable `repository@sha256:...` index reference from its job summary.

For another registry, build and publish the same pinned Dockerfile before
enabling either Job:

```sh
docker build \
  --file Dockerfile \
  --tag registry.example.test/foreman-kubernetes-recovery-toolbox:0.1.0 \
  images/recovery-toolbox
docker push registry.example.test/foreman-kubernetes-recovery-toolbox:0.1.0
```

Set `recovery.image.repository` to the registry path and
`recovery.image.tag` to `version@sha256:digest`; the digest, rather than the
human-readable tag, is the deployment identity. The image contains only the
PostgreSQL client, Restic, `kubectl`, `jq`, and their runtime dependencies; the
versioned workflow scripts are mounted from the chart.

## Repository Secret

For a remote Restic repository, create a Secret containing
`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, and the backend-specific credentials.
The guarded install and upgrade helpers validate the first two keys before
making a release change. A repository mounted from a PVC needs only
`RESTIC_PASSWORD`; its path is supplied by the chart.
For example, an S3-compatible target can use:

```sh
kubectl --namespace foreman create secret generic foreman-backup-repository \
  --from-literal=RESTIC_REPOSITORY='s3:https://s3.example.test/foreman-backups' \
  --from-literal=RESTIC_PASSWORD='replace-me' \
  --from-literal=AWS_ACCESS_KEY_ID='replace-me' \
  --from-literal=AWS_SECRET_ACCESS_KEY='replace-me'
```

For a local Restic repository, put only `RESTIC_PASSWORD` in the Secret and set
`recovery.repository.existingClaim`. The chart then sets `RESTIC_REPOSITORY` to
`recovery.repository.path` inside that claim.

When restricted egress is enabled, set
`networkPolicy.egress.recovery.apiServer` to the control-plane endpoint used by
the in-cluster Kubernetes Service. A remote repository also requires
`networkPolicy.egress.recovery.repository`; list only the CIDRs and ports used
by that Restic backend (for example TCP 443 for S3 or TCP 22 for SFTP). The
repository rule is not rendered when `recovery.repository.existingClaim` is
set. Helm refuses to create a recovery Job with missing destinations instead
of silently giving this credential-rich Pod unrestricted egress.

Database dumps use an `emptyDir` with `recovery.work.sizeLimit` by default. Set
`recovery.work.existingClaim` when the three compressed dumps may exceed a
node's safe ephemeral-storage allowance.

## Create a recovery point

Every request needs a new lower-case identifier of at most 16 characters. The
first backup to a new repository additionally needs
`backup.initializeRepository=true`; leave it false afterwards.

```sh
INITIALIZE_REPOSITORY=1 \
  scripts/recover-release.sh backup \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-120000
```

The helper resolves the same compatibility set as installation and upgrades,
acquires their shared renewable Lease, checks the current application and
execution proxy, and validates every recovery dependency before changing the
release. Both installed Helm releases must identify the selected compatibility
set in their computed values. Recovery refuses a split or differently labelled
pair instead of storing data under the wrong release identity. It derives the
proxy's effective state and Ansible claim names plus every referenced Secret
from the normal execution render; operators do not duplicate those names in
the application values file. It also copies the proxy Pod's PriorityClass,
node selector, and tolerations to the recovery Job so the same RWO claims can
be mounted on a dedicated or tainted execution node pool. It then removes
the database-writing Deployments and recurring tasks, waits for the execution
proxy Pod to terminate, and only then creates the recovery Job. The application
is stopped first so it cannot dispatch new work while the proxy drains.
The Job independently verifies that their pods are gone before reading any
state. It fails instead of taking an online, potentially inconsistent copy.
The toolbox and Job run as the unprivileged Pulp UID/GID 700 under the
`restricted` Pod Security Standard. Kubernetes `fsGroup` grants the stopped
application volumes to the recovery process; restored cross-UID files are made
group-accessible before the normal Foreman and execution-proxy Pods remount
them under their own isolated groups. No root or added Linux capability is
required.
After success, the helper restores the normal digest-pinned application, then
the execution proxy, and runs both smoke tests. A failed transition or Job
deliberately leaves both releases in maintenance mode for inspection when they
were already quiesced.

Retention removes snapshot metadata according to the configured daily, weekly,
and monthly counts. Pruning repository packs is disabled by default because it
can be I/O intensive; enable it in a dedicated maintenance window.

The backup Job consumes Restic's machine-readable completion record and fails
unless it contains exactly one new snapshot ID. Before applying retention, it
reopens that exact snapshot and verifies its release and request tags, declared
roots, manifest, database dumps, avatar tree, every Secret escrow file, and the
Pulp tree when filesystem storage is used. The full snapshot ID is emitted in
the Job log only after this validation succeeds; retain it with the change or
recovery record instead of relying only on `latest`.

The request ID is stored inside the recovery manifest and must match the
request-specific Restic tag. The Job also records and verifies an exact SHA-256
inventory before uploading the set. Restic content addressing protects the
avatar and Pulp trees; the inventory provides an additional explicit boundary
for the independently restored logical dumps and Secret escrow.

For S3, use a two-step operation so the bucket point cannot be taken while
Pulp is still writing:

```sh
scripts/recover-release.sh quiesce \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml

# Create the provider snapshot/versioning point now and retain its exact ID.
RECOVERY_FROM_QUIESCED=1 \
OBJECT_STORAGE_RECOVERY_POINT=provider-snapshot-20260924-120000 \
INITIALIZE_REPOSITORY=1 \
  scripts/recover-release.sh backup \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-120000
```

`quiesce` validates both normal and maintenance renders, stops the application
before the execution proxy, and leaves both releases stopped. The continuation
verifies their installed maintenance state and refuses an object-storage point
without `RECOVERY_FROM_QUIESCED=1`. If the provider snapshot fails, use the
guarded `resume` command; do not invent a point ID. The successful backup log
prints the Restic snapshot ID and its bound object-storage point. Retain both in
the external recovery/change record; the manifest copy remains encrypted in
Restic.

## Restore a recovery point

The target PostgreSQL databases and roles must already exist. Current runtime
Secrets must let the restore Job connect to them. Use `latest` to select the
newest snapshot for this Helm release, or supply a full snapshot ID.
Before entering maintenance, the guarded recovery helper also submits the
complete maintenance-or-resume render to Kubernetes server-side dry-run. An
admission, quota, Pod Security, or immutable-field rejection therefore leaves
the running release untouched instead of discovering the problem after its
writers have stopped.

```sh
RESTORE_SNAPSHOT=latest \
  scripts/recover-release.sh restore \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-130000
```

For site-loss recovery into a namespace where neither Helm release exists,
pre-create the namespace, current database/repository Secrets, external
databases and roles, then use the explicit bootstrap gate:

```sh
BOOTSTRAP_RESTORE=1 \
RESTORE_SNAPSHOT=latest \
RESTORE_SECRETS=1 \
  scripts/recover-release.sh restore \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-140000
```

Bootstrap restore refuses to run when either release already exists. It
server-validates all maintenance, recovery, and normal manifests, installs
both releases without runtime Pods so their retained claims exist, restores
the selected recovery point, and then starts the application and execution
proxy in normal order. If it is interrupted after creating those maintenance
releases, inspect them and continue with the normal guarded restore path and a
new request ID; do not retry with the bootstrap flag or delete the retained
claims.

The Job validates the snapshot owner, tag, compatibility set, storage backend, manifest, all three
dumps, the avatar tree, the Pulp tree in filesystem mode, and every requested
Secret escrow file before modifying state. It also verifies the paths against
Restic's snapshot inventory, so stale files on a reused work volume cannot make
an incomplete snapshot appear valid. The exact checksum inventory is checked
again after restoring `/work`; a missing, extra, or modified dump, manifest, or
Secret export therefore fails before the destructive boundary. Only after that
preflight boundary does it delete or replace current data. In S3 mode it leaves
objects untouched and requires the exact point stored in the selected manifest
before leaving maintenance mode. It replaces objects inside
the existing databases but never drops or creates the databases or their roles.

A snapshot must first be restored with the same compatibility set that created
it. Run a normal guarded upgrade only after the restored release is healthy;
this keeps data restoration and application migration as two separately
auditable operations.

Secret escrow is not applied by default. This avoids silently reverting rotated
external database credentials. To restore it in the same environment, add
`--set restore.secrets=true`; all target Secrets must already exist because the
recovery ServiceAccount may patch only the explicitly named Secrets and cannot
create arbitrary ones. If database credentials changed after the snapshot,
reconcile them before restarting the applications.

Set `RESTORE_SECRETS=1` only when the encrypted Secret escrow should be applied.
For S3 mode, first run `quiesce`, restore the bucket, then continue with the ID
recorded in the selected recovery manifest:

```sh
RECOVERY_FROM_QUIESCED=1 \
OBJECT_STORAGE_RECOVERY_POINT=provider-snapshot-20260924-120000 \
RESTORE_SNAPSHOT=latest \
  scripts/recover-release.sh restore \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-130000
```

A successful restore automatically recreates workloads, runs Pulp and Foreman
migrations, re-registers the private Pulp endpoint, and executes the smoke
test. The restore Job compares the supplied provider ID with the encrypted
manifest before crossing its destructive boundary.

Filesystem snapshots using manifest schema 5 remain restorable. Schema 5 S3
snapshots are deliberately rejected because they contain only the former
generic acknowledgement and cannot bind a database dump to an exact external
bucket point.

After diagnosing a failed backup, restore, or interrupted recovery helper,
leave maintenance mode through the same guarded path. Resume restores the
application before the execution proxy and verifies both release boundaries:

```sh
scripts/recover-release.sh resume \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml
```

`ALLOW_CANDIDATE`, `COMPATIBILITY_SET`, the release/namespace overrides, and
the shared `RELEASE_LEASE_*` settings have the same meaning as in the install
and upgrade helpers. `RECOVERY_TIMEOUT`, `RESUME_TIMEOUT`, and `SMOKE_TIMEOUT`
control their respective waits. Candidate qualification may additionally pass
`APPLICATION_PROFILE_OVERRIDE` and `EXECUTION_PROXY_PROFILE_OVERRIDE`
together. A single override and overrides of supported releases are rejected,
so production recovery remains bound to its declared digest-pinned set. Before
crossing the destructive boundary, restore also makes `pg_restore` parse all
three custom archives. Each individual database is then replaced in one
transaction, so a failed archive restore cannot commit a partial schema. The
three external databases still cannot share one transaction; retain the full
recovery point until all three restores and subsequent migrations pass.
Quiescence includes application processes, all three schema migrations, Pulp
and execution-proxy registration Jobs, and the S3 object-storage test so none
of those writers can overlap the captured or restored recovery point.
`BOOTSTRAP_RESTORE=1` is accepted only by the restore operation and only when
both Helm releases are absent. It cannot be combined with
`RECOVERY_FROM_QUIESCED=1`; there is no running release to quiesce. For an S3
site-loss restore, restore the bucket first and pass its exact ID through
`OBJECT_STORAGE_RECOVERY_POINT` together with `BOOTSTRAP_RESTORE=1`.

## Required recovery drill

A recovery mechanism is not considered verified until a disposable cluster can:

1. create data in Foreman, Candlepin, and Pulp;
2. create a recovery snapshot;
3. replace all three databases, Pulp storage, execution Dynflow/runner state,
   Ansible content, and release Secrets, using a coordinated bucket recovery
   point in S3 mode;
4. restore the snapshot into a clean namespace;
5. pass Foreman ping, Candlepin status, Pulp content download, and Katello Pulp
   registration checks;
6. run a second Helm revision successfully.

This drill belongs on an amd64 runner because the currently pinned Foreman,
Candlepin, and Pulp images are amd64-only.
