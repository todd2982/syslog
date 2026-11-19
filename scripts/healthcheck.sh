#!/bin/sh
# Healthy when something (rsyslogd) is listening on 5514 for both TCP and UDP.
if ! netstat -ltn | grep -q ':5514[[:space:]]'; then
  echo "not listening on 5514/tcp"; exit 1
fi
if ! netstat -lun | grep -q ':5514[[:space:]]'; then
  echo "not listening on 5514/udp"; exit 1
fi
echo "ok"
