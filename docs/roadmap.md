# Roadmap

This document records the intended implementation order and the outcome of each
phase. It is not a live task tracker.

- [GitHub issues](https://github.com/theforeman/foreman-kubernetes/issues)
  describe individual changes and design decisions.
- The [Foreman on Kubernetes project](https://github.com/orgs/theforeman/projects/30)
  tracks current status, review order, and dependencies.
- This roadmap changes only when the high-level sequence or phase goals change.

## 1. Application foundation

- Define the Foreman Helm chart API and runtime workloads.
- Run database migrations before application rollouts.
- Keep PostgreSQL, Valkey, credentials, and persistent content outside
  replaceable application pods.
- Document component limitations and supported replica counts.

## 2. Lifecycle safety

- Validate compatible, digest-pinned application images before deployment.
- Provide guarded installation and upgrade workflows.
- Stop safely after failed migrations and require roll-forward recovery.
- Add backup and clean-namespace restore workflows.

## 3. Integration qualification

- Exercise installation, upgrade, failure, and recovery in disposable Kind
  clusters.
- Qualify Pulp filesystem and S3-compatible storage.
- Test Foreman, Candlepin, Pulp, and execution-proxy integration against exact
  image sets.
- Retain enough CI evidence to reproduce each qualified result.

## 4. Operations and scale

- Verify supported replicated workloads during disruption and node failure.
- Add monitoring for rollout, migration, certificate, and recovery failures.
- Qualify security policies, restricted Pod Security, and deployment-specific
  network isolation.
- Publish compatibility and operational guidance backed by completed tests.

## 5. Extended integrations

- Qualify additional Foreman plugins and compute providers individually.
- Add public Pulp plugin routes only with tested authentication and lifecycle
  behavior.
- Extend the supported platform matrix only after installation, upgrade, and
  recovery pass on the new target.
