# Testing strategy

The project separates application validation from Kubernetes orchestration
qualification. During early development, tests may live here even when they
overlap with application tests: keeping feedback close to the change is more
important than finding the final test home immediately. Once behavior and its
interface stabilize, tests that apply to any Foreman deployment should move to
the owning project or to Smoker so they can be reused.

This document defines the intended layers. The repository does not yet contain
the static or disposable-cluster suites described below; they will arrive as
separate, reviewable changes.

## Upstream component tests

Foreman and its plugins, Candlepin, Pulp, Smart Proxy, and image changes retain
their unit and integration tests in the owning repositories. A local candidate
image may exercise an unpublished commit, but its result is not evidence that
the capability exists in a published image.

## Generic platform validation

Tests for public Foreman behavior that apply to package, `foremanctl`, and
Kubernetes installations should eventually live in
[`theforeman/smoker`](https://github.com/theforeman/smoker) for reuse. Smoker
integration can mature independently of the Kubernetes release schedule.

When Smoker runs against a Kubernetes deployment, CI should retain:

- the Smoker revision and selected markers;
- the tested Foreman URL and compatibility-set identity, without credentials;
- the pass/fail report as release evidence.

Credentials must come from CI secrets and must not be rendered into Helm values,
workflow arguments, or retained artifacts.

## Kubernetes-specific static tests

The static suite will use `pytest` for render assertions, fixtures, and readable
failure output. This matches the surrounding ecosystem, where `foremanctl`,
Smoker, and Robottelo also use pytest. Static tests will run for every pull
request and will not require a cluster.

## Kubernetes-specific runtime tests

[Kind](https://kind.sigs.k8s.io/) runs disposable Kubernetes clusters using
container nodes. It will provide the project's repeatable local and CI environment
for behavior that depends on Kubernetes. Initial coverage includes, but is not
limited to:

- admission and restricted Pod Security;
- dependency preflight and migration-before-rollout ordering;
- restart adoption, leader takeover, and release fencing;
- readiness, endpoint draining, disruption, and workload replacement;
- safe failure and roll-forward after a migration error;
- backup, clean-namespace recovery, and credential rotation;
- NetworkPolicy boundaries, autoscaling configuration, and node scheduling;
- Pulp object-storage, execution-proxy, and optional provider integration.

The pytest runtime suite may send application requests while developing and
proving an end-to-end workflow. Coverage should move to Smoker when it becomes
stable and useful to package, `foremanctl`, and Kubernetes deployments alike;
temporary overlap is acceptable.

## Recording test evidence

Every pull request will run a CI test matrix covering the static suite and
relevant Kind scenarios. Its description will state any relevant validation
that was not run. When the project introduces a machine-readable compatibility manifest,
each tested release entry will link an exact set of image digests and platform
versions to the retained CI run that qualified it.

Test reports and future compatibility entries distinguish:

1. implemented but not run;
2. passed static rendering and contract checks;
3. passed the exact disposable-cluster qualification;
4. passed generic Smoker validation;
5. observed in a sustained environment at operational scale.

An experimental release may stop at the earlier levels when its limitations are
prominent. A support claim requires an explicit platform matrix, retained
evidence, upgrade and recovery coverage, and operational feedback beyond one
successful installation.
