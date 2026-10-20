# Local candidate images

The default release set points only at published, digest-pinned images. Some
runtime contracts required by this project currently exist as independent
local upstream commits. A chart render cannot prove those commits work together,
and rebuilding an OCI repository that installs released RPMs would not include
the local application source.

`scripts/build-local-candidate-images.rb` therefore creates four temporary,
unpublished derivative images for the amd64 integration environment:

- Foreman receives only the runtime files from the recorded Foreman and Katello
  commits. Katello files are copied into the installed gem discovered by Ruby,
  rather than assuming a versioned filesystem path.
- Candlepin receives the recorded migration entry point and keeps the numeric
  packaged Tomcat identity.
- The execution proxy receives the Remote Execution action load-order fix so
  Dynflow can deserialize persisted plans immediately after a Pod restart.
- Pulp receives the exact `django-storages`, boto3, botocore, jmespath, and
  s3transfer versions needed by the prepared object-storage image change. Every
  wheel is hash-pinned; already packaged dateutil, urllib3, and six remain in
  use. This is a qualification bridge only because `django-storages` is not yet
  published in the current EL10 repository. The supported image must ultimately
  install the dependency chain from the Pulpcore RPM repository.

Every base is the immutable digest from the normal candidate profile. The
generated evidence records each upstream commit, a deterministic context hash,
the resulting image ID, and its platform. Images are labelled
`org.theforeman.kubernetes.unpublished=true`, use local names, and the script
has no push operation.

Prepare contexts on the workstation that contains the independent upstream
clones:

```bash
ruby scripts/build-local-candidate-images.rb --prepare-only \
  artifacts/local-candidate-prepared.json
```

Transfer the repository plus `artifacts/local-candidate-contexts` and the
prepared JSON to a native amd64 integration host. Build and load them into the
existing Kind cluster without transferring the upstream Git repositories:

```bash
ruby scripts/build-local-candidate-images.rb \
  --build-prepared artifacts/local-candidate-prepared.json \
  --kind foreman-stack-e2e \
  artifacts/local-candidate-images.json
```

Run the integration harness with the local application profile and retain the
candidate evidence for image-ID verification:

```bash
REUSE_CLUSTER=1 \
KEEP_CLUSTER=1 \
IMAGE_PROFILE=profiles/local-amd64-candidate.yaml \
EXECUTION_PROXY_IMAGE_PROFILE=profiles/execution-proxy-local-amd64-candidate.yaml \
LOCAL_CANDIDATE_EVIDENCE_FILE=artifacts/local-candidate-images.json \
tests/kind/run.sh
```

The evidence retains the Docker image ID, the ordered rootfs diff IDs, and the
Kind/containerd identity observed immediately after import. The live runtime
report re-reads the node metadata, requires the same rootfs identity, and
requires the Pod's kubelet image ID to be one of the evidenced containerd
manifest digests. This remains valid even though Kind rewrites the OCI manifest
during import.

The platform report marks this run `qualificationEligible: false`: it can find
runtime defects before publication, but it cannot promote a compatibility set.
Promotion still requires published, digest-pinned upstream images.
