FROM alpine:3.22@sha256:3e9b4b680bfc9fb5269227cffbd6d42be39fbf7c0b908123913864aa4447e764

RUN apk add --no-cache openssh-server openssh-sftp-server python3 \
    && adduser -D -u 1000 -s /bin/sh foreman \
    && passwd -d foreman \
    && ssh-keygen -A \
    && chown foreman:foreman /etc/ssh/ssh_host_*_key \
    && printf '%s\n' \
      'Port 2222' \
      'ListenAddress 0.0.0.0' \
      'AuthorizedKeysFile /keys/authorized_key' \
      'StrictModes no' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers foreman' \
      'PidFile /tmp/sshd.pid' \
      > /etc/ssh/sshd_config.d/10-foreman-kubernetes.conf

COPY --chmod=0755 images/ssh-target/entrypoint.sh /usr/local/bin/ssh-target-entrypoint

USER 1000:1000

EXPOSE 2222

ENTRYPOINT ["/usr/local/bin/ssh-target-entrypoint"]
