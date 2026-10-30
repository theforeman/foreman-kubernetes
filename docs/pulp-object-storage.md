# Pulp object storage

The chart supports two mutually exclusive Pulp artifact backends:

| `pulp.storage.backend` | Authoritative artifact storage | Pod storage |
| --- | --- | --- |
| `filesystem` | shared ReadWriteMany claim | `/var/lib/pulp` from the claim |
| `s3` | S3 or an S3-compatible bucket | per-pod `emptyDir` at `/var/lib/pulp/tmp` |

`filesystem` remains the default. Object storage removes the RWX dependency and
lets Pulp API, content, and worker replicas scale across nodes without mounting
a shared content filesystem. PostgreSQL, Valkey, and
`database_fields.symmetric.key` remain shared dependencies in both modes.

When S3 mode is selected, `helm test` also runs a probe with the exact Pulp
image, ServiceAccount, credentials, trust bundle, and storage settings. It
enables bucket versioning, writes a payload above the multipart threshold,
reads and hashes it both through the SDK and a signed direct-download URL,
creates a delete marker, verifies both versions and delete markers, and then
permanently removes the probe history. The full integration drill also rotates
the endpoint credentials, proves the retired key is rejected, and repeats the
entire transfer with the new Secret. This catches a misconfigured identity,
endpoint, prefix, multipart implementation, signed URL, rotation, or egress
policy before the release is qualified.

## Configuration

Apply [`examples/pulp-s3-values.yaml`](../examples/pulp-s3-values.yaml) after
the normal cluster values. The required setting is the bucket name. `location`
can confine all keys to a dedicated prefix. `region` is normally set for AWS
S3; `endpointUrl` and `addressingStyle: path` are commonly needed for MinIO,
Ceph RGW, and other S3-compatible providers.

The generated Pulp settings use the current Django storage backend:

```yaml
STORAGES:
  default:
    BACKEND: storages.backends.s3.S3Storage
```

`redirectToObjectStorage: true` lets Pulp return signed object-store URLs
instead of proxying every download through content pods. Clients must therefore
be able to resolve, reach, and trust the object-store endpoint. Set it to
`false` when the bucket endpoint is private to the cluster or direct client
access is prohibited.

The implementation follows Pulpcore's
[storage configuration contract](https://pulpproject.org/pulpcore/docs/admin/guides/configure-pulp/configure-storages/).

## Credentials and trust

Prefer workload identity over long-lived access keys. Pulp runtime workloads
have a dedicated ServiceAccount so an AWS IRSA, Azure workload identity, or
equivalent annotation does not grant bucket access to Foreman or Candlepin:

```yaml
pulp:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/foreman-pulp
```

Azure workload identity additionally requires a pod label. Provider-specific
pod labels and admission annotations are confined to the three Pulp runtime
roles:

```yaml
pulp:
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: 11111111-2222-3333-4444-555555555555
    podLabels:
      azure.workload.identity/use: "true"
    podAnnotations:
      azure.workload.identity/service-account-token-expiration: "3600"
```

The chart reserves its selector and release labels and the `checksum/`
annotation namespace so identity configuration cannot break workload ownership
or rollout tracking.

Changing annotations on this chart-managed ServiceAccount automatically rolls
the Pulp API, content, and worker pods so workload-identity admission can inject
the new credentials. If `pulp.serviceAccount.create` is disabled, the chart
cannot observe changes made to the external ServiceAccount; after changing its
identity configuration, change `secretRolloutToken` to deliberately recreate
the Pulp runtime pods.

When workload identity is unavailable, set `storage.s3.existingSecret`. The
Secret keys are configurable and are injected only into the Pulp API, content,
and worker containers. The chart automatically includes that Secret in the
encrypted recovery escrow.

For a private S3-compatible certificate authority, set
`storage.s3.existingCaSecret`. Its selected key is mounted read-only and exposed
to the AWS SDK through `AWS_CA_BUNDLE`. Do not disable TLS verification.

The bucket identity needs object read, write, delete, list, and the multipart
operations used for large uploads. Scope it to one bucket and prefix, enable
server-side encryption, block public access, and retain audit logs. With
`redirectToObjectStorage: true`, signed URLs provide client access without
making the bucket public.

## Network policy

Standard Kubernetes NetworkPolicy cannot match a DNS name. When restricted
egress is enabled, `networkPolicy.egress.external.pulp.peers` must identify the
object-store endpoint with stable CIDRs or namespace/pod selectors and its
ports must include the endpoint listener. Rendering fails when this contract is
missing.

## Recovery boundary

In S3 mode the recovery Job deliberately does not mount or copy
`/var/lib/pulp`. It backs up all three databases and escrows the configured
credential and CA Secrets, while the manifest records `pulp_storage_backend:
s3`. Restore rejects a snapshot made for the other backend.

An S3 backup requires `backup.objectStorageRecoveryPoint` to identify the
provider snapshot or versioning point captured after all writers stopped. That
exact value is stored in the encrypted recovery manifest. Restore requires the
same value in `restore.objectStorageRecoveryPoint`; a generic acknowledgement
or a different provider snapshot ID is rejected before any database changes.

The bucket is an independent authoritative data store. Enable object versioning
or provider snapshots and replication, then coordinate their recovery point
with the maintenance-gated Pulp database dump. Before leaving maintenance mode
after a database restore, restore the bucket to the matching point. A database
snapshot without its matching objects is not a complete Pulp recovery point.
The amd64 qualification drill proves that the configured S3 API can recover
content from one exact older object `VersionId` after a newer write and delete
marker; that provider-level primitive still does not replace the coordinated
database/bucket restore drill.
Use the guarded `quiesce` and `RECOVERY_FROM_QUIESCED=1` flow documented in
[`disaster-recovery.md`](disaster-recovery.md) so the external point is created
or restored while every application writer remains stopped.

The chart does not migrate artifacts from an existing RWX claim into a bucket.
That conversion requires its own maintenance window, verified object copy, and
rollback plan; changing `storage.backend` alone is not a migration procedure.
