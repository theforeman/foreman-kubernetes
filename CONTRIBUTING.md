# Contributing

Follow the Foreman project's general
[contribution guidelines](https://theforeman.org/contribute.html). This file
adds the conventions specific to this repository.

## Start a change

A GitHub issue is not required for every pull request. For a larger change that
would benefit from community feedback, open an issue or start an RFC in the
Foreman community forum's
[Development category](https://community.theforeman.org/c/development/9).

A change that spans repositories does not automatically require an RFC. Link
the related pull requests and explain how the changes depend on each other.
Track cross-repository status and dependencies in the
[Foreman on Kubernetes project](https://github.com/orgs/theforeman/projects/30).

## Repository scope

This repository owns Helm charts, Kubernetes resources, lifecycle tooling, and
Kubernetes-specific tests for running Foreman. Reusable application or
container-runtime capabilities should be contributed to the component that owns
them and then consumed here from a published image.

Do not add application source overlays, patched libraries, replacement
initializers, or private forks of Foreman components to this repository.

## Pull requests

Keep one logical change per pull request. Include:

- the problem and why the change belongs in this repository;
- links to related changes in other repositories;
- the tests run and any relevant tests not run;
- compatibility, upgrade, recovery, and rollback implications when relevant;
- user and developer documentation affected by the change.

Describe the current state accurately. Distinguish planned, implemented, and
tested behavior, and do not present experimental behavior as supported.

## Local validation

Run `git diff --check` and the relevant tests documented for the files being
changed. Pull requests should add or update tests and documentation where
practical.

## Community conduct and review

Use the [Foreman community forum](https://community.theforeman.org/) for
cross-project design discussions and follow the Foreman community code of
conduct. Maintainer review is required before publishing a release.
