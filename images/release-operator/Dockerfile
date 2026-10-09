FROM alpine:3.23.6@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0

LABEL org.opencontainers.image.title="Foreman Kubernetes release operator" \
      org.opencontainers.image.description="Restart-safe Helm release sequencing for Foreman, Katello, Candlepin, Pulp, and the execution proxy" \
      org.opencontainers.image.source="https://github.com/theforeman/foreman-kubernetes"

RUN apk add --no-cache \
      ca-certificates \
      helm \
      kubectl \
      ruby \
    && addgroup -S -g 1000 foreman-operator \
    && adduser -S -D -H -u 1000 -G foreman-operator foreman-operator \
    && install -d -o 1000 -g 1000 /opt/foreman-kubernetes /tmp

COPY --chown=1000:1000 charts /opt/foreman-kubernetes/charts
COPY --chown=1000:1000 compatibility /opt/foreman-kubernetes/compatibility
COPY --chown=1000:1000 operator /opt/foreman-kubernetes/operator
COPY --chown=1000:1000 profiles /opt/foreman-kubernetes/profiles

USER 1000:1000
WORKDIR /opt/foreman-kubernetes
ENTRYPOINT ["/opt/foreman-kubernetes/operator/bin/foreman-release-controller"]
