# Capacity planning

The chart does not own PostgreSQL, Valkey, or an object store. Their capacity
must therefore be sized from the largest allowed application topology, not only
from the initial replica count.

## Foreman PostgreSQL connections

Every Puma worker and every Rails background process owns a separate Active
Record connection pool. The chart mounts an explicit `database.yml` and assigns
the following pools rather than inheriting Foreman's fixed upstream default:

| Process | Pool value | Required lower bound |
| --- | ---: | ---: |
| one Puma worker | `foreman.databasePools.web` | `foreman.puma.threadsMax` |
| one general Dynflow worker | `foreman.databasePools.dynflowWorker` | `foreman.dynflow.workerConcurrency` |
| one hosts-queue worker | `foreman.databasePools.dynflowHostsQueue` | `foreman.dynflow.hostsQueueConcurrency` |
| orchestrator or one-shot Job | `foreman.databasePools.utility` | 1 |

For the hard ceiling, use the HPA maximum when autoscaling is enabled:

```text
web = web_max_replicas * puma_workers * web_pool
background = dynflow_workers * dynflow_worker_pool
           + hosts_queue_workers * hosts_queue_pool
           + utility_pool
steady_state_foreman = web + background
```

During a Helm revision, Foreman web, general Dynflow, and hosts-queue Dynflow
Deployments can each add one surge Pod. Reserve an additional
`puma_workers * web_pool + dynflow_worker_pool + hosts_queue_pool` connections
for the worst case in which those rollouts overlap. The Helm notes report both
steady-state and rolling-update ceilings.

The fixed utility process is the Dynflow orchestrator. Add one utility pool for
every migration, Pulp-registration, or
recurring-task Job that may overlap. Pools are lazy ceilings, not a promise
that every connection is open continuously, but PostgreSQL and any PgBouncer
layer must be able to absorb the declared concurrency without starvation.

The Helm post-install notes calculate this Foreman ceiling from the rendered
profile. Reducing a pool below Puma or Sidekiq concurrency is rejected because
it can starve application threads while they wait for database connections.

## Other databases

Candlepin's upstream Hibernate configuration permits 20 connections for its
single application pod. Reserve migration connections on top of that during
upgrades. Do not size for multiple replicas until upstream supplies and the
project qualifies a shared messaging and scheduler ownership contract.

Pulp API and content replicas contain the configured number of Gunicorn worker
processes, while each Pulp worker is a database-backed task executor. Exact
connection reuse depends on the Pulpcore/Django versions in the selected image,
so size Pulp PostgreSQL from observed saturation in the full integration
environment and retain headroom for migrations and task bursts. Do not infer a
safe production maximum from the chart's development defaults alone.

## Valkey roles

`valkey.foremanCache`, `valkey.dynflow`, and `valkey.pulp` are independent
endpoint contracts. They can share one host in a development environment, but
their production failure and eviction semantics differ:

- Foreman cache data is disposable and may use a bounded cache policy.
- Dynflow carries the Sidekiq transport and singleton lock. Give it durable
  storage, failover, sufficient client connections for every Foreman and
  Dynflow process, and `maxmemory-policy noeviction`.
- Pulp uses Valkey for its cache and must retain enough connections for every
  API, content, worker, and migration process.

All three production endpoints use authenticated `rediss` URLs and verify the
configured private CA. Monitor memory, rejected connections, evictions, and
failover latency; an eviction count above zero on Dynflow is a correctness
incident rather than an ordinary cache-capacity signal.

## CPU autoscaling and node capacity

Resource-based HPAs require a healthy `v1beta1.metrics.k8s.io` APIService. The
guarded install and upgrade scripts verify it before changing a release. The
Foreman web, Dynflow worker, Dynflow hosts-queue worker, Pulp API, and Pulp
content autoscalers are independent. Dynflow never scales the singleton
orchestrator, and its ten-minute scale-down stabilization gives active Sidekiq
work time to finish during normal load reduction. Size PostgreSQL and durable
Valkey for each worker HPA maximum multiplied by that worker's configured
concurrency; minimum replicas are the availability floor, not the capacity
ceiling.

The production example also makes topology spread hard: if the cluster cannot
place the minimum replicas across `topology.kubernetes.io/zone` and
`kubernetes.io/hostname` domains, workloads remain Pending rather than
silently giving up the requested failure separation. Ensure every eligible
production node carries the configured topology labels. Installations with
custom failure-domain labels can replace `affinity.topologyKeys`; keeping both
a zone-level and node-level key is recommended.

The prepared amd64 integration drill temporarily runs two Foreman web replicas,
sends concurrent dependency-aware health requests through the public ingress,
deletes one ready Pod, requires a distinct replacement, and rejects every
connection error, non-200 response, inactive database result, or unhealthy
Katello result. This validates the Service, readiness, endpoint removal, and
graceful shutdown contract together. It is not a throughput benchmark and must
not be used to derive production request-per-second capacity.

Pulp API and content have a matching prepared drill because their independent
HPAs and Gunicorn lifecycles create two separate availability boundaries. An
in-cluster restricted probe checks the private API health response while host
clients repeatedly download and checksum an already published artifact through
the public ingress. One API and one content Pod are removed together; all
requests must remain valid while both Deployments return to two ready replicas.

For a dedicated node pool, set all three fields under `scheduling`: a selector
for the pool label, tolerations matching only its intentional taints, and an
existing PriorityClass when Foreman must preempt lower-priority workloads.
Capacity the selected pool for rollout surges plus simultaneous migration or
smoke Jobs; scheduling policy applies to those Jobs as well as Deployments.
Keep the release operator on a separately configured pool so it can diagnose a
mislabelled or exhausted application pool. The execution proxy is a singleton
with RWO storage and `Recreate` rollout semantics, so its eligible nodes must
all be able to attach both the state and Ansible content claims.
