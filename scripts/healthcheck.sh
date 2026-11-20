#!/bin/sh
# Healthy when something (rsyslogd) is listening on 5514 for both TCP and UDP.

# Docker runs health checks as the image's default user, which is root here.
# Drop to the same unprivileged user as rsyslog before doing anything.
if [ "$(id -u)" = 0 ]; then
  exec su-exec "${PUID:-10514}:${PGID:-10514}" "$0" "$@"
fi

if ! netstat -ltn | grep -q ':5514[[:space:]]'; then
  echo "not listening on 5514/tcp"; exit 1
fi
if ! netstat -lun | grep -q ':5514[[:space:]]'; then
  echo "not listening on 5514/udp"; exit 1
fi
echo "ok (uid $(id -u))"
