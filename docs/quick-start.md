# Minimal Foreman quick start

This milestone installs a single core Foreman web pod backed by PostgreSQL. It
does not enable Katello, Foreman Tasks, Candlepin, Pulp, Smart Proxy features,
high availability, or production ingress. Those capabilities remain separate
follow-up work.

The test environment requires Docker, Kind, kubectl, and Helm 4. From the
repository root, run:

```console
tests/kind/run-minimal.sh
```

The script creates a disposable Kind cluster, installs PostgreSQL, runs the
Foreman database migration and seeds, waits for the Foreman API to become
ready, and verifies `/api/v2/ping` through `helm test`. It deletes a cluster it
created when the test finishes.

Set `KEEP_CLUSTER=1` to retain the cluster for inspection. With the cluster
running, expose Foreman locally with:

```console
kubectl --namespace foreman port-forward service/foreman-foreman 3000:3000
```

Then open `http://foreman.test:3000` after mapping `foreman.test` to
`127.0.0.1`, or send the host header explicitly:

```console
curl --header 'Host: foreman.test' http://127.0.0.1:3000/api/v2/ping
```

The test credentials are `admin` / `foreman-test` and are only suitable for
the disposable Kind environment.

