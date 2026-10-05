# Image compatibility sets

The chart keeps component ownership separate and does not assume that independently published moving tags are compatible. A profile pins one candidate combination by OCI digest. Promotion to a supported set requires the disposable install, mTLS registration, scale, and upgrade test to pass.

`compatibility/release-sets.json` is the machine-readable pairing contract. A
set names both the application profile (Foreman/Katello, Candlepin, and Pulp)
and the execution-proxy profile, plus their common target platform and maturity
state. The integration harness resolves its default profiles through this file
and rejects one-sided profile overrides, preventing a proxy candidate from
being qualified accidentally against an unrelated application candidate. Every
image reference in a declared set must be pinned by OCI digest.

Before creating the disposable cluster, the integration harness reads the OCI
configuration for every pinned Foreman/Katello, Candlepin, Pulp, and execution
Smart Proxy image and verifies its declared operating system and architecture.
Only registry metadata is fetched; image layers are not downloaded. The
resulting `image-platform-contract.json` is retained with the integration
evidence, so an ARM release set cannot qualify while any application image is
still an amd64 build.

Each set also selects one or more contract profiles from
`compatibility/upstream-contracts.json`. A set cannot become `supported` merely
because its runtime drill passes: every upstream contract required by those
profiles must be recorded as present in that exact image set. This prevents a
locally prepared Foreman, Katello, Candlepin, Pulp, or plugin fix from being
mistaken for published image capability.

Each set also declares `upgradeFrom`. Every installed application and
execution-proxy set must appear in that list before the target can be applied.
The target itself is always included so a same-set reconcile, credential
rotation, or drift repair remains possible. Old and retired sets stay in the
catalog while they are valid upgrade sources; retirement prevents a new
installation but does not implicitly create an unsafe upgrade jump.

Set states have deliberately narrow meanings:

- `candidate`: statically valid and manifest-verified, but the complete runtime
  drill has not passed;
- `supported`: the complete pinned integration and upgrade drill has retained
  evidence for that exact set;
- `retired`: retained for upgrade-path or historical evidence, not new installs.

No set is promoted automatically from a successful render. Runtime evidence is
still required.

## Kubernetes node platform boundary

The release-set `platform` identifies the OCI image platform, not a required
node distribution. The current candidate is `linux/amd64`; its application
dependencies live in the pinned images and do not require Foreman, Katello,
Candlepin, or Pulp packages on the Kubernetes node.

Both authoritative image profiles also add
`kubernetes.io/arch: amd64` to the global workload node selector. Helm merges
that architecture constraint with deployment-specific pool labels and
tolerations, so mixed-architecture clusters cannot schedule a single-platform
image onto an incompatible node. This selector is derived from the release
set, not a runtime-mode choice exposed to the user.

Static tests reject host namespaces, `hostPath`, `hostPort`, privileged
containers, runtime sockets, kubelet paths, node package managers, systemd
commands, and node distribution detection in all three charts. A future
supported matrix must additionally retain real-cluster evidence for each
claimed Kubernetes version, architecture, container runtime, ingress class,
storage implementation, and host security configuration. Distribution
independence therefore means no application packaging dependency on the node;
it does not turn an untested cluster combination into a supported target.

The machine-readable qualification target is
`compatibility/cluster-platforms.json`. The initial `kind-v1.34-amd64` target
pins the kind node image, Kubernetes version, container runtime,
ingress-nginx chart, Pod Security version, and native runner platform used by
the full integration workflow. Its `implemented-unrun` state means the harness
exists but no retained successful run has established support. The static
hostPath volumes and SeaweedFS service named there are disposable storage
fixtures, not recommended production providers.

`KIND_NODE_IMAGE` can still replace the node image for exploratory testing.
Evidence from such a run records the actual image and is deliberately
ineligible for promotion unless it exactly matches a declared qualification
target. A new Kubernetes version, architecture, runtime, ingress
implementation, or security policy therefore gets a new reviewed target
instead of silently reusing evidence from a different environment.

> **No supported image set exists yet.** The current nightly candidate predates
> the upstream runtime contracts listed in
> `compatibility/upstream-contracts.json`. It is retained for manifest and
> integration-harness development, but it is not expected to complete the
> current default installation until new official images contain those
> contracts.

## Runtime evidence and promotion

The complete integration contract is versioned in
`compatibility/required-integration-checks.json`. A successful manual `Full
integration` workflow writes `integration-result.json` only after every test
has completed, then retains it as the `foreman-stack-integration-evidence`
artifact. The record binds the run to:

- the tested Git commit and compatibility-set name;
- the target and native runner platforms;
- the registry-reported platform of every digest-pinned runtime image;
- SHA-256 hashes of the candidate manifest, both image profiles, the test
  contract, upstream contracts, and cluster-platform registry;
- the declared cluster-platform identity and exact node image, Kubernetes,
  container-runtime, ingress-chart, and Pod Security versions;
- the GitHub Actions run and attempt;
- every completed runtime check.

The same artifact also contains `image-runtime-contract.json`. Before any
content or execution workflow is accepted, the drill compares every running
Foreman, Pulp, Candlepin, and execution-proxy container with the exact digest
from the selected profiles. It records the kubelet image ID, non-root runtime
identity, installed package versions, enabled plugin allow-lists, and the Pulp
component versions reported by the live API. This closes the gap between a
registry manifest lookup and proving what was actually started in Kubernetes.

A local run or a run with `SKIP_RECOVERY_TEST=1` may still write diagnostic
evidence, but it is marked ineligible for promotion. Low-level profile
overrides cannot produce evidence for a declared set unless both resolved files
are exactly the profiles named by that set.

After downloading the artifact, check out the exact recorded commit and run:

```sh
ruby scripts/promote-release-set.rb \
  nightly-candidate-2026-09-24 \
  /path/to/integration-result.json
ruby tests/release-sets.rb
```

Promotion rejects missing checks, a runner that does not match the selected
qualification target, stale inputs, another commit, or non-GitHub provenance.
It copies the evidence into `compatibility/evidence/`, records its digest and
workflow URL in the set, and changes only that set from `candidate` to
`supported`. The resulting manifest and retained evidence are reviewed and
committed together; CI never promotes a set by itself.

## Nightly candidate from 2026-09-23

| Component | Published tag | OCI digest | Platform | Status |
| --- | --- | --- | --- | --- |
| Foreman with Katello | `quay.io/foreman/foreman:nightly` | `sha256:9c77128c7acd629c62686a9119816d6f6b7726cd6492d9eaa894d54c345c4941` | `linux/amd64` | Manifest verified; required Foreman and Katello contracts not yet published |
| Candlepin | `quay.io/foreman/candlepin:foreman-nightly` | `sha256:b9fe6c5f161132b39982e1951e8b4a16bf00d2565ecb17e53b13b56196a1f280` | `linux/amd64` | Manifest verified; required container runtime contract not yet published |
| Pulp | `quay.io/foreman/pulp:foreman-nightly` | `sha256:c3d32a385d09225c40f70d60128fcf62c94cb669536b10ccbadc0ec8ac4afa6b` | `linux/amd64` | Manifest verified; required object-storage packages not yet published |
| Execution Smart Proxy | `quay.io/foreman/foreman-proxy:nightly` | `sha256:244c756844a137990779ad153998c426eb0326d8d6f376192ea6e84947affd47` | `linux/amd64` | Manifest verified; runtime and execution drills implemented but unrun |

The manifests were read from the official Quay repositories on 2026-09-24. No layers were downloaded. The current images are single-platform, so an ARM cluster needs explicit emulation and is not a release target until upstream publishes multi-architecture manifests.

The execution contract was reviewed against Foreman Remote Execution commit
`be391fd9ef3140df707eed4f320ce2ebd572648d` and Foreman Ansible commit
`7ffc9e37344011554347ca9429fffdcf1f81816e`. These are source snapshots for
contract review, not container provenance claims. The disposable SSH target
uses the verified Alpine 3.22 amd64 manifest
`sha256:3e9b4b680bfc9fb5269227cffbd6d42be39fbf7c0b908123913864aa4447e764`.

Use the candidate with an environment values file first and the compatibility
profile last. The profile must win for image fields so environment-specific
configuration cannot silently replace a reviewed digest with a moving tag:

```sh
helm upgrade --install foreman charts/foreman-stack \
  --values /secure/path/production-values.yaml \
  --values profiles/nightly-candidate-2026-09-23.yaml
```

The disposable drill uses the manifest default. Select another declared set
with `COMPATIBILITY_SET`. Low-level profile overrides remain available for
candidate development, but both sides must be supplied together:

```sh
COMPATIBILITY_SET=nightly-candidate-2026-09-24 tests/kind/run.sh

IMAGE_PROFILE=/absolute/application-profile.yaml \
EXECUTION_PROXY_IMAGE_PROFILE=/absolute/execution-profile.yaml \
  tests/kind/run.sh
```
