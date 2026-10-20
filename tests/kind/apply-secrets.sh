#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 TEMPORARY_DIRECTORY" >&2
  exit 2
fi

workdir="$1"
namespace="foreman"

issue_server_certificate() {
  local name="$1"
  local common_name="$2"
  local subject_alt_names="$3"

  openssl req -new -newkey rsa:2048 -nodes \
    -subj "/CN=${common_name}" \
    -keyout "${workdir}/${name}.key" \
    -out "${workdir}/${name}.csr" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 7 \
    -in "${workdir}/${name}.csr" \
    -CA "${workdir}/ca.crt" \
    -CAkey "${workdir}/ca.key" \
    -CAcreateserial \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "${subject_alt_names}") \
    -out "${workdir}/${name}.crt" >/dev/null 2>&1
}

issue_client_certificate() {
  local name="$1"
  local common_name="$2"

  openssl req -new -newkey rsa:2048 -nodes \
    -subj "/CN=${common_name}" \
    -keyout "${workdir}/${name}.key" \
    -out "${workdir}/${name}.csr" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 7 \
    -in "${workdir}/${name}.csr" \
    -CA "${workdir}/ca.crt" \
    -CAkey "${workdir}/ca.key" \
    -CAcreateserial \
    -extfile <(printf 'extendedKeyUsage=clientAuth\n') \
    -out "${workdir}/${name}.crt" >/dev/null 2>&1
}

if [[ ! -s "${workdir}/ca.crt" ]]; then
  # Keep one identity set for the entire destructive restore drill. The
  # restored Secrets must still match the CA and client files used by curl and
  # the disposable SSH target after the namespace is recreated.
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 7 \
    -subj "/CN=Foreman Kubernetes test CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${workdir}/ca.key" \
    -out "${workdir}/ca.crt" >/dev/null 2>&1

  issue_client_certificate foreman-client foreman.test
  issue_client_certificate execution-proxy-client execution-foreman-execution-proxy

  issue_server_certificate foreman-ingress foreman.test "DNS:foreman.test"
  issue_server_certificate content-ingress content.test "DNS:content.test"
  issue_server_certificate candlepin foreman-foreman-stack-candlepin \
    "DNS:foreman-foreman-stack-candlepin,DNS:foreman-foreman-stack-candlepin.foreman,DNS:foreman-foreman-stack-candlepin.foreman.svc"
  issue_server_certificate pulp-control foreman-foreman-stack-pulp-control \
    "DNS:foreman-foreman-stack-pulp-control,DNS:foreman-foreman-stack-pulp-control.foreman,DNS:foreman-foreman-stack-pulp-control.foreman.svc"
  issue_server_certificate execution-proxy execution-foreman-execution-proxy \
    "DNS:execution-foreman-execution-proxy,DNS:execution-foreman-execution-proxy.foreman,DNS:execution-foreman-execution-proxy.foreman.svc"

  ssh-keygen -q -t ed25519 -N '' \
    -C foreman-kubernetes-integration \
    -f "${workdir}/id_ed25519_foreman_proxy"
fi

encryption_key="$(openssl rand -hex 16)"
secret_key_base="$(openssl rand -hex 64)"
django_secret="$(openssl rand -hex 32)"
symmetric_key="$(openssl rand -base64 32 | tr -d '\n')"

kubectl --namespace "${namespace}" create secret generic foreman-runtime \
  --from-literal=DATABASE_URL='postgresql://foreman:foreman-test@postgresql:5432/foreman' \
  --from-literal=ENCRYPTION_KEY="${encryption_key}" \
  --from-literal=SECRET_KEY_BASE="${secret_key_base}" \
  --from-literal=SEED_ADMIN_USER=admin \
  --from-literal=SEED_ADMIN_PASSWORD=foreman-test \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-shared \
  --from-literal=candlepin-oauth-secret=candlepin-oauth-test \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-valkey \
  --from-literal=foreman-cache-uri-auth='' \
  --from-literal=dynflow-uri-auth='' \
  --from-literal=pulp-password='' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-certificates \
  --from-file=ca.crt="${workdir}/ca.crt" \
  --from-file=client_cert.pem="${workdir}/foreman-client.crt" \
  --from-file=client_key.pem="${workdir}/foreman-client.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic candlepin-runtime \
  --from-literal=database-password=candlepin-test \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic candlepin-certificates \
  --from-file=candlepin-ca.crt="${workdir}/ca.crt" \
  --from-file=candlepin-ca.key="${workdir}/ca.key" \
  --from-file=tomcat.crt="${workdir}/candlepin.crt" \
  --from-file=tomcat.key="${workdir}/candlepin.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic pulp-runtime \
  --from-literal=database-password=pulp-test \
  --from-literal=django-secret-key="${django_secret}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic pulp-config \
  --from-literal=database_fields.symmetric.key="${symmetric_key}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic ingress-client-ca \
  --from-file=ca.crt="${workdir}/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret tls foreman-ingress-tls \
  --cert="${workdir}/foreman-ingress.crt" \
  --key="${workdir}/foreman-ingress.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret tls pulp-content-ingress-tls \
  --cert="${workdir}/content-ingress.crt" \
  --key="${workdir}/content-ingress.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic pulp-control-proxy-certificates \
  --from-file=ca.crt="${workdir}/ca.crt" \
  --from-file=tls.crt="${workdir}/pulp-control.crt" \
  --from-file=tls.key="${workdir}/pulp-control.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-execution-proxy-tls \
  --from-file=ca.crt="${workdir}/ca.crt" \
  --from-file=tls.crt="${workdir}/execution-proxy.crt" \
  --from-file=tls.key="${workdir}/execution-proxy.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-execution-proxy-foreman-client \
  --from-file=ca.crt="${workdir}/ca.crt" \
  --from-file=tls.crt="${workdir}/execution-proxy-client.crt" \
  --from-file=tls.key="${workdir}/execution-proxy-client.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-execution-proxy-ssh \
  --from-file=id_rsa_foreman_proxy="${workdir}/id_ed25519_foreman_proxy" \
  --from-file=id_rsa_foreman_proxy.pub="${workdir}/id_ed25519_foreman_proxy.pub" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic foreman-backup-repository \
  --from-literal=RESTIC_PASSWORD=foreman-recovery-test \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl --namespace "${namespace}" create secret generic recovery-probe \
  --from-literal=value=before-backup \
  --dry-run=client -o yaml | kubectl apply -f -
