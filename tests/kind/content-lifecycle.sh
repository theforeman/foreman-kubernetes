#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 seed|assert TEMPORARY_DIRECTORY STATE_FILE" >&2
  exit 2
fi

mode="$1"
temporary_directory="$2"
state_file="$3"
namespace="foreman"
content_filename="foreman-kubernetes-content.txt"
content_checksum="d527380869e9487a3d860b253a6aa5d454b51c419415264e90f018396e419ac5"
python_package_name="foreman-kubernetes-pkg"
python_package_version="1.0.0"
python_package_filename="foreman_kubernetes_pkg-1.0.0.tar.gz"
deb_package_name="foreman-kubernetes-deb"
deb_package_version="1.0.0"
deb_package_filename="foreman-kubernetes-deb_1.0.0_all.deb"
deb_package_path="pool/main/f/foreman-kubernetes-deb/${deb_package_filename}"
rpm_package_name="squirrel"
rpm_package_version="0.3"
rpm_package_release="0.8"
rpm_package_arch="noarch"
rpm_package_filename="squirrel-0.3-0.8.noarch.rpm"
rpm_package_checksum="251768bdd15f13d78487c27638aa6aecd01551e253756093cde1c0ae878a17d2"
container_upstream_name="foreman-kubernetes-fixture"
container_tag="1.0.0"
container_manifest_digest="sha256:dbb1deb2e285b7d0e8d3f6d00aed58ea5fd7f4b7772862889935f36cc58718bd"
run_id="$(basename "${temporary_directory}" | tr -cd '[:alnum:]')"
organization_name="Kubernetes Integration ${run_id}"
organization_label="Kubernetes_Integration_${run_id}"

foreman_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=foreman \
    --output=json | jq --exit-status --raw-output '
      [.items[] |
       select(.status.phase == "Running") |
       select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] |
      sort_by(.metadata.creationTimestamp) |
      last |
      .metadata.name'
}

foreman_api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local -a curl_args=(
    --fail-with-body
    --silent
    --show-error
    --cacert "${temporary_directory}/ca.crt"
    --resolve foreman.test:8443:127.0.0.1
    --user admin:foreman-test
    --request "${method}"
    --header 'Accept: application/json'
    --header 'Content-Type: application/json'
  )

  if [[ -n "${payload}" ]]; then
    curl_args+=(--data "${payload}")
  fi

  curl "${curl_args[@]}" "https://foreman.test:8443${path}"
}

wait_for_task() {
  local task_id="$1"

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env "TASK_ID=${task_id}" bin/rails runner '
      task = ForemanTasks::Task.find(ENV.fetch("TASK_ID"))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1_800
      loop do
        task.reload
        if task.state == "stopped"
          abort "Task #{task.id} (#{task[:label]}) ended with #{task.result}" unless task.result == "success"
          puts "Task #{task.id} (#{task[:label]}) succeeded"
          break
        end
        abort "Timed out waiting for task #{task.id} (#{task[:label]})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    '
}

task_id_from() {
  jq --exit-status --raw-output '.id // .task.id'
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local description="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "${description} is '${actual}', expected '${expected}'" >&2
    exit 1
  fi
}

assert_public_content() {
  local relative_path="$1"
  local download_path="${temporary_directory}/downloaded-${content_filename}"
  local downloaded_checksum
  local normalized_path

  normalized_path="${relative_path#/}"
  normalized_path="${normalized_path%/}"
  curl --fail --silent --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve content.test:8443:127.0.0.1 \
    --output "${download_path}" \
    "https://content.test:8443/pulp/content/${normalized_path}/${content_filename}"

  downloaded_checksum="$(openssl dgst -sha256 -r "${download_path}" | awk '{print $1}')"
  assert_equal "${downloaded_checksum}" "${content_checksum}" "published content checksum"
}

assert_public_python_content() {
  local relative_path="$1"
  local expected_checksum="$2"
  local normalized_path
  local index_file="${temporary_directory}/python-simple-index.html"
  local index_url
  local package_href
  local package_path
  local download_path="${temporary_directory}/downloaded-${python_package_filename}"
  local downloaded_checksum

  normalized_path="${relative_path#/}"
  normalized_path="${normalized_path%/}"
  index_url="https://content.test:8443/pypi/${normalized_path}/simple/${python_package_name}/"
  curl --fail --silent --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve content.test:8443:127.0.0.1 \
    --output "${index_file}" \
    "${index_url}"

  if ! grep --fixed-strings --quiet "${python_package_filename}" "${index_file}"; then
    echo "published Python simple index does not contain ${python_package_filename}" >&2
    exit 1
  fi

  package_href="$(sed -n 's/.*href="\([^"]*\)".*/\1/p' "${index_file}" | head -n 1)"
  if [[ -z "${package_href}" ]]; then
    echo "published Python simple index has no package link" >&2
    exit 1
  fi
  package_path="$(ruby -ruri -e 'puts URI.join(ARGV.fetch(0), ARGV.fetch(1)).request_uri' \
    "${index_url}" "${package_href}")"
  curl --fail --silent --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve content.test:8443:127.0.0.1 \
    --output "${download_path}" \
    "https://content.test:8443${package_path}"

  downloaded_checksum="$(openssl dgst -sha256 -r "${download_path}" | awk '{print $1}')"
  assert_equal "${downloaded_checksum}" "${expected_checksum}" "published Python package checksum"
}

assert_registry_manifest() {
  local repository_name="$1"
  local description="$2"
  local manifest="${temporary_directory}/container-manifest.json"
  local client_cert="${temporary_directory}/foreman-client.crt"
  local client_key="${temporary_directory}/foreman-client.key"
  local redirect_location
  local redirect_request_uri
  local registry_headers="${temporary_directory}/container-registry-headers"
  local registry_port
  local registry_response
  local registry_service
  local response_digest
  local manifest_digest

  registry_service="$(kubectl --namespace "${namespace}" get service \
    --selector=app.kubernetes.io/component=pulp-control-proxy \
    --output=jsonpath='{.items[0].metadata.name}')"
  registry_port="$(kubectl --namespace "${namespace}" get service "${registry_service}" \
    --output=jsonpath='{.spec.ports[0].port}')"
  registry_response="$(kubectl --namespace "${namespace}" exec --container foreman \
    "$(foreman_pod)" -- env \
    "REGISTRY_URL=https://${registry_service}:${registry_port}/pulpcore_registry/v2/${repository_name}/manifests/${container_tag}" \
    ruby -rbase64 -rjson -rnet/http -ropenssl -ruri -e '
      uri = URI(ENV.fetch("REGISTRY_URL"))
      client = Net::HTTP.new(uri.host, uri.port)
      client.use_ssl = true
      client.verify_mode = OpenSSL::SSL::VERIFY_PEER
      client.ca_file = "/etc/foreman/katello-default-ca.crt"
      client.cert = OpenSSL::X509::Certificate.new(File.read("/etc/foreman/client_cert.pem"))
      client.key = OpenSSL::PKey.read(File.read("/etc/foreman/client_key.pem"))
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.oci.image.manifest.v1+json"
      response = client.request(request)
      case response
      when Net::HTTPSuccess
        puts JSON.generate(body: Base64.strict_encode64(response.body), digest: response["Docker-Content-Digest"])
      when Net::HTTPRedirection
        puts JSON.generate(location: response["Location"])
      else
        abort "Registry returned HTTP #{response.code}: #{response.body}"
      end
    ')"

  redirect_location="$(jq --raw-output '.location // empty' <<<"${registry_response}")"
  if [[ -n "${redirect_location}" ]]; then
    redirect_request_uri="$(ruby -ruri -e '
      uri = URI(ARGV.fetch(0))
      abort "unexpected registry redirect: #{uri}" unless uri.scheme == "https" && uri.host == "content.test"
      abort "unexpected registry redirect path: #{uri.path}" unless uri.path.start_with?("/pulp/container/")
      puts uri.request_uri
    ' "${redirect_location}")"
    if [[ ! -s "${client_cert}" || ! -s "${client_key}" ]]; then
      kubectl --namespace "${namespace}" get secret foreman-certificates \
        --output=jsonpath='{.data.client_cert\.pem}' | base64 --decode >"${client_cert}"
      kubectl --namespace "${namespace}" get secret foreman-certificates \
        --output=jsonpath='{.data.client_key\.pem}' | base64 --decode >"${client_key}"
      chmod 0600 "${client_key}"
    fi
    curl --fail --silent --show-error \
      --cacert "${temporary_directory}/ca.crt" \
      --cert "${client_cert}" \
      --key "${client_key}" \
      --resolve content.test:8443:127.0.0.1 \
      --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
      --dump-header "${registry_headers}" \
      --output "${manifest}" \
      "https://content.test:8443${redirect_request_uri}"
    response_digest="$(awk -F ': ' '
      tolower($1) == "docker-content-digest" { gsub("\r", "", $2); digest = $2 }
      END { print digest }
    ' "${registry_headers}")"
  else
    response_digest="$(jq --exit-status --raw-output '.digest' <<<"${registry_response}")"
    jq --exit-status --raw-output '.body' <<<"${registry_response}" | base64 --decode >"${manifest}"
  fi
  assert_equal "${response_digest}" "${container_manifest_digest}" \
    "${description} registry response digest"
  manifest_digest="sha256:$(openssl dgst -sha256 -r "${manifest}" | awk '{print $1}')"
  assert_equal "${manifest_digest}" "${container_manifest_digest}" \
    "${description} registry manifest checksum"
}

seed_content_lifecycle() {
  local activation_key
  local activation_key_id
  local content_view
  local content_view_environment
  local content_view_environment_id
  local content_view_id
  local content_view_version
  local content_view_version_id
  local container_manifests
  local container_repository
  local container_repository_id
  local container_repository_name
  local container_tags
  local deb_package_checksum
  local deb_packages
  local deb_repository
  local deb_repository_id
  local environment_repositories
  local files
  local library_environment
  local library_environment_id
  local organization
  local organization_id
  local product
  local product_id
  local publish_task
  local published_python_repository
  local published_python_repository_id
  local published_python_relative_path
  local published_deb_repository_id
  local published_container_repository
  local published_container_repository_id
  local published_container_repository_name
  local published_rpm_repository_id
  local published_repository
  local published_repository_id
  local published_relative_path
  local python_package_checksum
  local python_packages
  local python_relative_path
  local python_repository
  local python_repository_id
  local relative_path
  local repository
  local repository_id
  local rpm_packages
  local rpm_repository
  local rpm_repository_id
  local sync_task

  organization="$(foreman_api POST /katello/api/organizations "$(
    jq --compact-output --null-input \
      --arg name "${organization_name}" \
      --arg label "${organization_label}" '{
      organization: {
        name: $name,
        label: $label
      }
    }'
  )")"
  organization_id="$(jq --exit-status --raw-output '.id' <<<"${organization}")"

  product="$(foreman_api POST /katello/api/products "$(
    jq --compact-output --null-input --argjson organization_id "${organization_id}" '{
      organization_id: $organization_id,
      product: {
        name: "Kubernetes Integration Product",
        label: "Kubernetes_Integration_Product"
      }
    }'
  )")"
  product_id="$(jq --exit-status --raw-output '.id' <<<"${product}")"

  repository="$(foreman_api POST /katello/api/repositories "$(
    jq --compact-output --null-input --argjson product_id "${product_id}" '{
      product_id: $product_id,
      repository: {
        name: "Kubernetes Integration Files",
        label: "Kubernetes_Integration_Files",
        content_type: "file",
        download_policy: "immediate",
        url: "http://content-source"
      }
    }'
  )")"
  repository_id="$(jq --exit-status --raw-output '.id' <<<"${repository}")"
  relative_path="$(jq --exit-status --raw-output '.relative_path' <<<"${repository}")"

  sync_task="$(foreman_api POST "/katello/api/repositories/${repository_id}/sync" '{}')"
  wait_for_task "$(task_id_from <<<"${sync_task}")"

  files="$(foreman_api GET "/katello/api/repositories/${repository_id}/files?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${files}")" "1" "synced file count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${files}")" \
    "${content_filename}" "synced file name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${files}")" \
    "${content_checksum}" "synced file checksum"
  assert_public_content "${relative_path}"

  python_repository="$(foreman_api POST /katello/api/repositories "$(
    jq --compact-output --null-input --argjson product_id "${product_id}" \
      --arg package_name "${python_package_name}" '{
      product_id: $product_id,
      repository: {
        name: "Kubernetes Integration Python",
        label: "Kubernetes_Integration_Python",
        content_type: "python",
        download_policy: "immediate",
        url: "http://content-source",
        includes: [$package_name]
      }
    }'
  )")"
  python_repository_id="$(jq --exit-status --raw-output '.id' <<<"${python_repository}")"
  python_relative_path="$(jq --exit-status --raw-output '.relative_path' <<<"${python_repository}")"

  sync_task="$(foreman_api POST "/katello/api/repositories/${python_repository_id}/sync" '{}')"
  wait_for_task "$(task_id_from <<<"${sync_task}")"

  python_packages="$(foreman_api GET \
    "/katello/api/repositories/${python_repository_id}/python_packages?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${python_packages}")" "1" \
    "synced Python package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${python_packages}")" \
    "${python_package_name}" "synced Python package name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].version' <<<"${python_packages}")" \
    "${python_package_version}" "synced Python package version"
  assert_equal "$(jq --exit-status --raw-output '.results[0].filename' <<<"${python_packages}")" \
    "${python_package_filename}" "synced Python package filename"
  python_package_checksum="$(jq --exit-status --raw-output \
    '.results[0].additional_metadata.sha256' <<<"${python_packages}")"
  assert_public_python_content "${python_relative_path}" "${python_package_checksum}"

  deb_repository="$(foreman_api POST /katello/api/repositories "$(
    jq --compact-output --null-input --argjson product_id "${product_id}" '{
      product_id: $product_id,
      repository: {
        name: "Kubernetes Integration Debian",
        label: "Kubernetes_Integration_Debian",
        content_type: "deb",
        download_policy: "immediate",
        mirroring_policy: "mirror_content_only",
        url: "http://content-source/debian/",
        deb_releases: "stable",
        deb_components: "main",
        deb_architectures: "amd64"
      }
    }'
  )")"
  deb_repository_id="$(jq --exit-status --raw-output '.id' <<<"${deb_repository}")"

  sync_task="$(foreman_api POST "/katello/api/repositories/${deb_repository_id}/sync" '{}')"
  wait_for_task "$(task_id_from <<<"${sync_task}")"

  deb_packages="$(foreman_api GET \
    "/katello/api/repositories/${deb_repository_id}/debs?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${deb_packages}")" "1" \
    "synced Debian package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${deb_packages}")" \
    "${deb_package_name}" "synced Debian package name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].version' <<<"${deb_packages}")" \
    "${deb_package_version}" "synced Debian package version"
  assert_equal "$(jq --exit-status --raw-output '.results[0].architecture' <<<"${deb_packages}")" \
    "all" "synced Debian package architecture"
  assert_equal "$(jq --exit-status --raw-output '.results[0].filename' <<<"${deb_packages}")" \
    "${deb_package_path}" "synced Debian package filename"
  deb_package_checksum="$(jq --exit-status --raw-output '.results[0].checksum' <<<"${deb_packages}")"

  rpm_repository="$(foreman_api POST /katello/api/repositories "$(
    jq --compact-output --null-input --argjson product_id "${product_id}" '{
      product_id: $product_id,
      repository: {
        name: "Kubernetes Integration RPM",
        label: "Kubernetes_Integration_RPM",
        content_type: "yum",
        download_policy: "immediate",
        mirroring_policy: "additive",
        url: "http://content-source/rpm/"
      }
    }'
  )")"
  rpm_repository_id="$(jq --exit-status --raw-output '.id' <<<"${rpm_repository}")"

  sync_task="$(foreman_api POST "/katello/api/repositories/${rpm_repository_id}/sync" '{}')"
  wait_for_task "$(task_id_from <<<"${sync_task}")"

  rpm_packages="$(foreman_api GET \
    "/katello/api/repositories/${rpm_repository_id}/packages?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${rpm_packages}")" "1" \
    "synced RPM package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${rpm_packages}")" \
    "${rpm_package_name}" "synced RPM package name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].version' <<<"${rpm_packages}")" \
    "${rpm_package_version}" "synced RPM package version"
  assert_equal "$(jq --exit-status --raw-output '.results[0].release' <<<"${rpm_packages}")" \
    "${rpm_package_release}" "synced RPM package release"
  assert_equal "$(jq --exit-status --raw-output '.results[0].arch' <<<"${rpm_packages}")" \
    "${rpm_package_arch}" "synced RPM package architecture"
  assert_equal "$(jq --exit-status --raw-output '.results[0].filename' <<<"${rpm_packages}")" \
    "${rpm_package_filename}" "synced RPM package filename"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${rpm_packages}")" \
    "${rpm_package_checksum}" "synced RPM package checksum"

  container_repository="$(foreman_api POST /katello/api/repositories "$(
    jq --compact-output --null-input \
      --argjson product_id "${product_id}" \
      --arg upstream_name "${container_upstream_name}" \
      --arg tag "${container_tag}" '{
      product_id: $product_id,
      repository: {
        name: "Kubernetes Integration Container",
        label: "Kubernetes_Integration_Container",
        content_type: "docker",
        download_policy: "immediate",
        unprotected: true,
        url: "http://content-source",
        docker_upstream_name: $upstream_name,
        include_tags: [$tag]
      }
    }'
  )")"
  container_repository_id="$(jq --exit-status --raw-output '.id' <<<"${container_repository}")"
  container_repository_name="$(jq --exit-status --raw-output \
    '.container_repository_name' <<<"${container_repository}")"

  sync_task="$(foreman_api POST "/katello/api/repositories/${container_repository_id}/sync" '{}')"
  wait_for_task "$(task_id_from <<<"${sync_task}")"

  container_tags="$(foreman_api GET \
    "/katello/api/repositories/${container_repository_id}/docker_tags?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${container_tags}")" "1" \
    "synced container tag count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${container_tags}")" \
    "${container_tag}" "synced container tag"
  assert_equal "$(jq --exit-status --raw-output '.results[0].manifest.digest' <<<"${container_tags}")" \
    "${container_manifest_digest}" "synced container tag manifest digest"
  container_manifests="$(foreman_api GET \
    "/katello/api/repositories/${container_repository_id}/docker_manifests?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${container_manifests}")" "1" \
    "synced container manifest count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].digest' <<<"${container_manifests}")" \
    "${container_manifest_digest}" "synced container manifest digest"
  assert_registry_manifest "${container_repository_name}" "library container"

  content_view="$(foreman_api POST /katello/api/content_views "$(
    jq --compact-output --null-input \
      --argjson organization_id "${organization_id}" \
      --argjson repository_id "${repository_id}" \
      --argjson python_repository_id "${python_repository_id}" \
      --argjson deb_repository_id "${deb_repository_id}" \
      --argjson rpm_repository_id "${rpm_repository_id}" \
      --argjson container_repository_id "${container_repository_id}" '{
        organization_id: $organization_id,
        content_view: {
          name: "Kubernetes Integration View",
          label: "Kubernetes_Integration_View",
          repository_ids: [
            $repository_id,
            $python_repository_id,
            $deb_repository_id,
            $rpm_repository_id,
            $container_repository_id
          ]
        }
      }'
  )")"
  content_view_id="$(jq --exit-status --raw-output '.id' <<<"${content_view}")"

  publish_task="$(foreman_api POST "/katello/api/content_views/${content_view_id}/publish" \
    '{"description":"Foreman Kubernetes integration publication"}')"
  wait_for_task "$(task_id_from <<<"${publish_task}")"

  content_view="$(foreman_api GET "/katello/api/content_views/${content_view_id}")"
  content_view_version_id="$(jq --exit-status --raw-output '.latest_version_id' <<<"${content_view}")"
  content_view_version="$(foreman_api GET "/katello/api/content_view_versions/${content_view_version_id}")"

  library_environment="$(foreman_api GET \
    "/katello/api/organizations/${organization_id}/environments?library=true")"
  library_environment_id="$(jq --exit-status --raw-output '.results[0].id' <<<"${library_environment}")"
  content_view_environment="$(foreman_api GET \
    "/katello/api/content_view_environments?organization_id=${organization_id}&lifecycle_environment_id=${library_environment_id}&content_view_id=${content_view_id}")"
  assert_equal "$(jq --raw-output '.total' <<<"${content_view_environment}")" "1" \
    "published content view environment count"
  content_view_environment_id="$(jq --exit-status --raw-output '.results[0].id' \
    <<<"${content_view_environment}")"
  environment_repositories="$(foreman_api GET \
    "/katello/api/repositories?organization_id=${organization_id}&content_view_id=${content_view_id}&environment_id=${library_environment_id}&per_page=1000")"

  published_repository_id="$(jq --exit-status --raw-output \
    --argjson repository_id "${repository_id}" \
    '.results[] | select(.library_instance_id == $repository_id) | .id' \
    <<<"${environment_repositories}")"
  published_repository="$(foreman_api GET "/katello/api/repositories/${published_repository_id}")"
  published_relative_path="$(jq --exit-status --raw-output '.relative_path' <<<"${published_repository}")"
  assert_public_content "${published_relative_path}"
  published_python_repository_id="$(jq --exit-status --raw-output \
    --argjson repository_id "${python_repository_id}" \
    '.results[] | select(.library_instance_id == $repository_id) | .id' \
    <<<"${environment_repositories}")"
  published_python_repository="$(foreman_api GET \
    "/katello/api/repositories/${published_python_repository_id}")"
  published_python_relative_path="$(jq --exit-status --raw-output \
    '.relative_path' <<<"${published_python_repository}")"
  assert_public_python_content "${published_python_relative_path}" "${python_package_checksum}"
  published_deb_repository_id="$(jq --exit-status --raw-output \
    --argjson repository_id "${deb_repository_id}" \
    '.results[] | select(.library_instance_id == $repository_id) | .id' \
    <<<"${environment_repositories}")"
  deb_packages="$(foreman_api GET \
    "/katello/api/repositories/${published_deb_repository_id}/debs?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${deb_packages}")" "1" \
    "published Debian package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${deb_packages}")" \
    "${deb_package_checksum}" "published Debian package checksum"
  published_rpm_repository_id="$(jq --exit-status --raw-output \
    --argjson repository_id "${rpm_repository_id}" \
    '.results[] | select(.library_instance_id == $repository_id) | .id' \
    <<<"${environment_repositories}")"
  rpm_packages="$(foreman_api GET \
    "/katello/api/repositories/${published_rpm_repository_id}/packages?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${rpm_packages}")" "1" \
    "published RPM package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${rpm_packages}")" \
    "${rpm_package_checksum}" "published RPM package checksum"
  published_container_repository_id="$(jq --exit-status --raw-output \
    --argjson repository_id "${container_repository_id}" \
    '.results[] | select(.library_instance_id == $repository_id) | .id' \
    <<<"${environment_repositories}")"
  published_container_repository="$(foreman_api GET \
    "/katello/api/repositories/${published_container_repository_id}")"
  published_container_repository_name="$(jq --exit-status --raw-output \
    '.container_repository_name' <<<"${published_container_repository}")"
  container_tags="$(foreman_api GET \
    "/katello/api/repositories/${published_container_repository_id}/docker_tags?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${container_tags}")" "1" \
    "published container tag count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].manifest.digest' <<<"${container_tags}")" \
    "${container_manifest_digest}" "published container tag manifest digest"
  assert_registry_manifest "${published_container_repository_name}" "published container"

  activation_key="$(foreman_api POST /katello/api/activation_keys "$(
    jq --compact-output --null-input \
      --argjson organization_id "${organization_id}" \
      --argjson content_view_environment_id "${content_view_environment_id}" '{
        organization_id: $organization_id,
        content_view_environment_ids: [$content_view_environment_id],
        activation_key: {
          name: "kubernetes-integration",
          unlimited_hosts: true,
          content_view_environment_ids: [$content_view_environment_id]
        }
      }'
  )")"
  activation_key_id="$(jq --exit-status --raw-output '.id' <<<"${activation_key}")"
  assert_equal "$(jq --exit-status --raw-output \
    '.content_view_environments[0].content_view.content_view_environment_id' <<<"${activation_key}")" \
    "${content_view_environment_id}" "activation key content view environment"

  jq --null-input \
    --argjson organization_id "${organization_id}" \
    --argjson product_id "${product_id}" \
    --argjson repository_id "${repository_id}" \
    --arg relative_path "${relative_path}" \
    --argjson python_repository_id "${python_repository_id}" \
    --arg python_relative_path "${python_relative_path}" \
    --arg python_package_checksum "${python_package_checksum}" \
    --argjson deb_repository_id "${deb_repository_id}" \
    --arg deb_package_checksum "${deb_package_checksum}" \
    --argjson rpm_repository_id "${rpm_repository_id}" \
    --argjson container_repository_id "${container_repository_id}" \
    --arg container_repository_name "${container_repository_name}" \
    --argjson content_view_id "${content_view_id}" \
    --argjson content_view_version_id "${content_view_version_id}" \
    --argjson published_repository_id "${published_repository_id}" \
    --arg published_relative_path "${published_relative_path}" \
    --argjson published_python_repository_id "${published_python_repository_id}" \
    --arg published_python_relative_path "${published_python_relative_path}" \
    --argjson published_deb_repository_id "${published_deb_repository_id}" \
    --argjson published_rpm_repository_id "${published_rpm_repository_id}" \
    --argjson published_container_repository_id "${published_container_repository_id}" \
    --arg published_container_repository_name "${published_container_repository_name}" \
    --argjson library_environment_id "${library_environment_id}" \
    --argjson content_view_environment_id "${content_view_environment_id}" \
    --argjson activation_key_id "${activation_key_id}" '{
      organization_id: $organization_id,
      product_id: $product_id,
      repository_id: $repository_id,
      relative_path: $relative_path,
      python_repository_id: $python_repository_id,
      python_relative_path: $python_relative_path,
      python_package_checksum: $python_package_checksum,
      deb_repository_id: $deb_repository_id,
      deb_package_checksum: $deb_package_checksum,
      rpm_repository_id: $rpm_repository_id,
      container_repository_id: $container_repository_id,
      container_repository_name: $container_repository_name,
      content_view_id: $content_view_id,
      content_view_version_id: $content_view_version_id,
      published_repository_id: $published_repository_id,
      published_relative_path: $published_relative_path,
      published_python_repository_id: $published_python_repository_id,
      published_python_relative_path: $published_python_relative_path,
      published_deb_repository_id: $published_deb_repository_id,
      published_rpm_repository_id: $published_rpm_repository_id,
      published_container_repository_id: $published_container_repository_id,
      published_container_repository_name: $published_container_repository_name,
      library_environment_id: $library_environment_id,
      content_view_environment_id: $content_view_environment_id,
      activation_key_id: $activation_key_id
    }' >"${state_file}"
}

assert_content_lifecycle() {
  local activation_key
  local activation_key_id
  local content_view
  local content_view_environment_id
  local content_view_id
  local content_view_version
  local content_view_version_id
  local container_manifests
  local container_repository
  local container_repository_id
  local container_repository_name
  local container_tags
  local deb_package_checksum
  local deb_packages
  local deb_repository
  local deb_repository_id
  local files
  local library_environment_id
  local organization_id
  local product_id
  local published_python_repository
  local published_python_repository_id
  local published_python_relative_path
  local published_deb_repository_id
  local published_rpm_repository_id
  local published_container_repository
  local published_container_repository_id
  local published_container_repository_name
  local published_repository
  local published_repository_id
  local published_relative_path
  local python_package_checksum
  local python_packages
  local python_relative_path
  local python_repository
  local python_repository_id
  local relative_path
  local repository
  local repository_id
  local rpm_packages
  local rpm_repository
  local rpm_repository_id

  jq --exit-status '
    .organization_id and .product_id and .repository_id and .relative_path and
    .python_repository_id and .python_relative_path and .python_package_checksum and
    .deb_repository_id and .deb_package_checksum and
    .rpm_repository_id and .container_repository_id and .container_repository_name and
    .content_view_id and .content_view_version_id and .published_repository_id and
    .published_relative_path and .published_python_repository_id and
    .published_python_relative_path and .published_deb_repository_id and
    .published_rpm_repository_id and .published_container_repository_id and
    .published_container_repository_name and
    .library_environment_id and .content_view_environment_id and .activation_key_id
  ' "${state_file}" >/dev/null

  organization_id="$(jq --raw-output '.organization_id' "${state_file}")"
  product_id="$(jq --raw-output '.product_id' "${state_file}")"
  repository_id="$(jq --raw-output '.repository_id' "${state_file}")"
  relative_path="$(jq --raw-output '.relative_path' "${state_file}")"
  python_repository_id="$(jq --raw-output '.python_repository_id' "${state_file}")"
  python_relative_path="$(jq --raw-output '.python_relative_path' "${state_file}")"
  python_package_checksum="$(jq --raw-output '.python_package_checksum' "${state_file}")"
  deb_repository_id="$(jq --raw-output '.deb_repository_id' "${state_file}")"
  deb_package_checksum="$(jq --raw-output '.deb_package_checksum' "${state_file}")"
  rpm_repository_id="$(jq --raw-output '.rpm_repository_id' "${state_file}")"
  container_repository_id="$(jq --raw-output '.container_repository_id' "${state_file}")"
  container_repository_name="$(jq --raw-output '.container_repository_name' "${state_file}")"
  content_view_id="$(jq --raw-output '.content_view_id' "${state_file}")"
  content_view_version_id="$(jq --raw-output '.content_view_version_id' "${state_file}")"
  published_repository_id="$(jq --raw-output '.published_repository_id' "${state_file}")"
  published_relative_path="$(jq --raw-output '.published_relative_path' "${state_file}")"
  published_python_repository_id="$(jq --raw-output \
    '.published_python_repository_id' "${state_file}")"
  published_python_relative_path="$(jq --raw-output \
    '.published_python_relative_path' "${state_file}")"
  published_deb_repository_id="$(jq --raw-output \
    '.published_deb_repository_id' "${state_file}")"
  published_rpm_repository_id="$(jq --raw-output \
    '.published_rpm_repository_id' "${state_file}")"
  published_container_repository_id="$(jq --raw-output \
    '.published_container_repository_id' "${state_file}")"
  published_container_repository_name="$(jq --raw-output \
    '.published_container_repository_name' "${state_file}")"
  library_environment_id="$(jq --raw-output '.library_environment_id' "${state_file}")"
  content_view_environment_id="$(jq --raw-output '.content_view_environment_id' "${state_file}")"
  activation_key_id="$(jq --raw-output '.activation_key_id' "${state_file}")"

  assert_equal "$(foreman_api GET "/katello/api/organizations/${organization_id}" | jq --raw-output '.id')" \
    "${organization_id}" "restored organization"
  assert_equal "$(foreman_api GET "/katello/api/products/${product_id}" | jq --raw-output '.id')" \
    "${product_id}" "restored product"

  repository="$(foreman_api GET "/katello/api/repositories/${repository_id}")"
  assert_equal "$(jq --raw-output '.id' <<<"${repository}")" "${repository_id}" "restored repository"
  assert_equal "$(jq --raw-output '.relative_path' <<<"${repository}")" \
    "${relative_path}" "restored repository path"

  files="$(foreman_api GET "/katello/api/repositories/${repository_id}/files?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${files}")" "1" "restored file count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${files}")" \
    "${content_checksum}" "restored file checksum"
  assert_public_content "${relative_path}"

  python_repository="$(foreman_api GET "/katello/api/repositories/${python_repository_id}")"
  assert_equal "$(jq --raw-output '.id' <<<"${python_repository}")" \
    "${python_repository_id}" "restored Python repository"
  assert_equal "$(jq --raw-output '.relative_path' <<<"${python_repository}")" \
    "${python_relative_path}" "restored Python repository path"
  python_packages="$(foreman_api GET \
    "/katello/api/repositories/${python_repository_id}/python_packages?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${python_packages}")" "1" \
    "restored Python package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${python_packages}")" \
    "${python_package_name}" "restored Python package name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].version' <<<"${python_packages}")" \
    "${python_package_version}" "restored Python package version"
  assert_equal "$(jq --exit-status --raw-output \
    '.results[0].additional_metadata.sha256' <<<"${python_packages}")" \
    "${python_package_checksum}" "restored Python package checksum metadata"
  assert_public_python_content "${python_relative_path}" "${python_package_checksum}"

  deb_repository="$(foreman_api GET "/katello/api/repositories/${deb_repository_id}")"
  assert_equal "$(jq --raw-output '.id' <<<"${deb_repository}")" \
    "${deb_repository_id}" "restored Debian repository"
  deb_packages="$(foreman_api GET \
    "/katello/api/repositories/${deb_repository_id}/debs?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${deb_packages}")" "1" \
    "restored Debian package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${deb_packages}")" \
    "${deb_package_name}" "restored Debian package name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].version' <<<"${deb_packages}")" \
    "${deb_package_version}" "restored Debian package version"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${deb_packages}")" \
    "${deb_package_checksum}" "restored Debian package checksum"

  rpm_repository="$(foreman_api GET "/katello/api/repositories/${rpm_repository_id}")"
  assert_equal "$(jq --raw-output '.id' <<<"${rpm_repository}")" \
    "${rpm_repository_id}" "restored RPM repository"
  rpm_packages="$(foreman_api GET \
    "/katello/api/repositories/${rpm_repository_id}/packages?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${rpm_packages}")" "1" \
    "restored RPM package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${rpm_packages}")" \
    "${rpm_package_name}" "restored RPM package name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].version' <<<"${rpm_packages}")" \
    "${rpm_package_version}" "restored RPM package version"
  assert_equal "$(jq --exit-status --raw-output '.results[0].release' <<<"${rpm_packages}")" \
    "${rpm_package_release}" "restored RPM package release"
  assert_equal "$(jq --exit-status --raw-output '.results[0].arch' <<<"${rpm_packages}")" \
    "${rpm_package_arch}" "restored RPM package architecture"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${rpm_packages}")" \
    "${rpm_package_checksum}" "restored RPM package checksum"

  container_repository="$(foreman_api GET "/katello/api/repositories/${container_repository_id}")"
  assert_equal "$(jq --raw-output '.id' <<<"${container_repository}")" \
    "${container_repository_id}" "restored container repository"
  assert_equal "$(jq --raw-output '.container_repository_name' <<<"${container_repository}")" \
    "${container_repository_name}" "restored container repository name"
  container_tags="$(foreman_api GET \
    "/katello/api/repositories/${container_repository_id}/docker_tags?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${container_tags}")" "1" \
    "restored container tag count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${container_tags}")" \
    "${container_tag}" "restored container tag"
  assert_equal "$(jq --exit-status --raw-output '.results[0].manifest.digest' <<<"${container_tags}")" \
    "${container_manifest_digest}" "restored container tag manifest digest"
  container_manifests="$(foreman_api GET \
    "/katello/api/repositories/${container_repository_id}/docker_manifests?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${container_manifests}")" "1" \
    "restored container manifest count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].digest' <<<"${container_manifests}")" \
    "${container_manifest_digest}" "restored container manifest digest"
  assert_registry_manifest "${container_repository_name}" "restored library container"

  content_view="$(foreman_api GET "/katello/api/content_views/${content_view_id}")"
  assert_equal "$(jq --raw-output '.latest_version' <<<"${content_view}")" "1.0" \
    "restored content view version"
  assert_equal "$(jq --argjson repository_id "${repository_id}" \
    '[.repository_ids[] | select(. == $repository_id)] | length' <<<"${content_view}")" \
    "1" "restored content view repository count"
  assert_equal "$(jq --argjson repository_id "${python_repository_id}" \
    '[.repository_ids[] | select(. == $repository_id)] | length' <<<"${content_view}")" \
    "1" "restored content view Python repository count"
  assert_equal "$(jq --argjson repository_id "${deb_repository_id}" \
    '[.repository_ids[] | select(. == $repository_id)] | length' <<<"${content_view}")" \
    "1" "restored content view Debian repository count"
  assert_equal "$(jq --argjson repository_id "${rpm_repository_id}" \
    '[.repository_ids[] | select(. == $repository_id)] | length' <<<"${content_view}")" \
    "1" "restored content view RPM repository count"
  assert_equal "$(jq --argjson repository_id "${container_repository_id}" \
    '[.repository_ids[] | select(. == $repository_id)] | length' <<<"${content_view}")" \
    "1" "restored content view container repository count"

  content_view_version="$(foreman_api GET "/katello/api/content_view_versions/${content_view_version_id}")"
  assert_equal "$(jq --argjson repository_id "${repository_id}" \
    '[.repositories[] | select(.library_instance_id == $repository_id)] | length' \
    <<<"${content_view_version}")" "1" "restored published repository count"
  published_repository="$(foreman_api GET "/katello/api/repositories/${published_repository_id}")"
  assert_equal "$(jq --raw-output '.environment.id' <<<"${published_repository}")" \
    "${library_environment_id}" "restored published repository environment"
  assert_equal "$(jq --raw-output '.relative_path' <<<"${published_repository}")" \
    "${published_relative_path}" "restored published repository path"
  assert_public_content "${published_relative_path}"
  assert_equal "$(jq --argjson repository_id "${python_repository_id}" \
    '[.repositories[] | select(.library_instance_id == $repository_id)] | length' \
    <<<"${content_view_version}")" "1" "restored published Python repository count"
  published_python_repository="$(foreman_api GET \
    "/katello/api/repositories/${published_python_repository_id}")"
  assert_equal "$(jq --raw-output '.environment.id' <<<"${published_python_repository}")" \
    "${library_environment_id}" "restored published Python repository environment"
  assert_equal "$(jq --raw-output '.relative_path' <<<"${published_python_repository}")" \
    "${published_python_relative_path}" \
    "restored published Python repository path"
  assert_public_python_content "${published_python_relative_path}" "${python_package_checksum}"
  assert_equal "$(jq --argjson repository_id "${deb_repository_id}" \
    '[.repositories[] | select(.library_instance_id == $repository_id)] | length' \
    <<<"${content_view_version}")" "1" "restored published Debian repository count"
  deb_packages="$(foreman_api GET \
    "/katello/api/repositories/${published_deb_repository_id}/debs?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${deb_packages}")" "1" \
    "restored published Debian package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${deb_packages}")" \
    "${deb_package_checksum}" "restored published Debian package checksum"
  assert_equal "$(jq --argjson repository_id "${rpm_repository_id}" \
    '[.repositories[] | select(.library_instance_id == $repository_id)] | length' \
    <<<"${content_view_version}")" "1" "restored published RPM repository count"
  rpm_packages="$(foreman_api GET \
    "/katello/api/repositories/${published_rpm_repository_id}/packages?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${rpm_packages}")" "1" \
    "restored published RPM package count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${rpm_packages}")" \
    "${rpm_package_checksum}" "restored published RPM package checksum"
  assert_equal "$(jq --argjson repository_id "${container_repository_id}" \
    '[.repositories[] | select(.library_instance_id == $repository_id)] | length' \
    <<<"${content_view_version}")" "1" "restored published container repository count"
  published_container_repository="$(foreman_api GET \
    "/katello/api/repositories/${published_container_repository_id}")"
  assert_equal "$(jq --raw-output '.environment.id' <<<"${published_container_repository}")" \
    "${library_environment_id}" "restored published container repository environment"
  assert_equal "$(jq --raw-output '.container_repository_name' <<<"${published_container_repository}")" \
    "${published_container_repository_name}" "restored published container repository name"
  container_tags="$(foreman_api GET \
    "/katello/api/repositories/${published_container_repository_id}/docker_tags?per_page=1000")"
  assert_equal "$(jq --raw-output '.total' <<<"${container_tags}")" "1" \
    "restored published container tag count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].manifest.digest' <<<"${container_tags}")" \
    "${container_manifest_digest}" "restored published container tag manifest digest"
  assert_registry_manifest "${published_container_repository_name}" "restored published container"

  activation_key="$(foreman_api GET "/katello/api/activation_keys/${activation_key_id}")"
  assert_equal "$(jq --exit-status --raw-output \
    '.content_view_environments[0].content_view.content_view_environment_id' <<<"${activation_key}")" \
    "${content_view_environment_id}" "restored activation key content view environment"
}

case "${mode}" in
  seed)
    seed_content_lifecycle
    assert_content_lifecycle
    ;;
  assert)
    assert_content_lifecycle
    ;;
  *)
    echo "mode must be seed or assert" >&2
    exit 2
    ;;
esac
