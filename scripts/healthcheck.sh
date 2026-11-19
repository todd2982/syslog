#!/bin/sh
# Healthy when rsyslogd is running and listening on 5514 for both UDP and TCP.
pgrep -x rsyslogd >/dev/null || exit 1
netstat -ltn 2>/dev/null | grep -q ':5514 ' || exit 1
netstat -lun 2>/dev/null | grep -q ':5514 ' || exit 1
exit 0
