#!/usr/bin/env bash
# Starts the image, sends one message over UDP and one over TCP, and checks that
# both land in the per-host log file. Runs two cases:
#   volume - logs on a Docker volume
#   bind   - logs on a host folder that Docker creates (root-owned, mode 755),
#            the way a fresh bind mount like /tmp/syslog/remote starts out
# Usage: tests/smoke-test.sh [image]
set -euo pipefail

IMAGE="${1:-syslog:test}"
PORT="${SMOKE_PORT:-15514}"
HOST="smoke-test-host"
NAME=""
CASE=""
BIND_PARENT=""

# Called by the EXIT trap and between cases.
# shellcheck disable=SC2329
cleanup() {
  if [ -n "$NAME" ]; then
    if [ "${FAILED:-0}" = 1 ]; then
      echo "--- container state ---"
      docker inspect -f '{{json .State}}' "$NAME" 2>&1 || true
      echo "--- container logs ---"; docker logs "$NAME" 2>&1 || true
      echo "--- processes, sockets and folders ---"
      docker exec "$NAME" sh -c 'ps; netstat -ltun; ls -lan /var/log/remote /var/lib/rsyslog' 2>&1 || true
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    NAME=""
  fi
}

# Called by the EXIT trap.
# shellcheck disable=SC2329
on_exit() {
  cleanup
  if [ -n "$BIND_PARENT" ]; then
    # Files in the bind folder belong to the container's user; remove them from inside.
    docker run --rm --entrypoint rm -v "$BIND_PARENT:/cleanup" "$IMAGE" -rf /cleanup/remote >/dev/null 2>&1 || true
    rmdir "$BIND_PARENT" 2>/dev/null || true
  fi
}
trap on_exit EXIT

fail() { echo "FAIL ($CASE): $*"; FAILED=1; exit 1; }

run_case() { # case-name, extra docker run args...
  CASE=$1; shift
  NAME="syslog-smoke-$CASE-$$"
  local token
  token="smoke-$CASE-$(date +%s)-$RANDOM"
  echo "=== $CASE ==="

  docker run -d --name "$NAME" \
    -p "127.0.0.1:${PORT}:5514/udp" -p "127.0.0.1:${PORT}:5514/tcp" \
    --read-only --tmpfs /var/lib/rsyslog --tmpfs /tmp \
    --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true \
    --health-interval 3s --health-start-period 5s \
    "$@" "$IMAGE" >/dev/null

  echo "Waiting for the container to report healthy..."
  local status=starting running
  for _ in $(seq 1 30); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)
    [ "$status" = healthy ] && break
    running=$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)
    [ "$running" = true ] || fail "container stopped"
    sleep 2
  done
  [ "$status" = healthy ] || fail "container never became healthy (status: $status)"

  # RFC 3164 messages with a fixed hostname so the file path is predictable.
  local msg
  msg="<134>$(LC_ALL=C date '+%b %e %H:%M:%S') ${HOST} smoketest: ${token}"
  printf '%s via udp' "$msg" > "/dev/udp/127.0.0.1/${PORT}"
  printf '%s via tcp\n' "$msg" > "/dev/tcp/127.0.0.1/${PORT}"

  local file found=0
  file="/var/log/remote/${HOST}/$(docker exec "$NAME" date '+%Y-%m-%d').log"
  for _ in $(seq 1 15); do
    if docker exec "$NAME" grep -q "${token} via udp" "$file" 2>/dev/null \
       && docker exec "$NAME" grep -q "${token} via tcp" "$file" 2>/dev/null; then
      found=1; break
    fi
    sleep 1
  done
  if [ "$found" != 1 ]; then
    docker exec "$NAME" find /var/log/remote || true
    fail "messages not found in ${file}"
  fi
  echo "PASS: UDP and TCP messages written to ${file}"
  docker exec "$NAME" cat "$file"

  # rsyslogd must not run as root.
  local uid
  # shellcheck disable=SC2016
  uid=$(docker exec "$NAME" sh -c 'awk "/^Uid:/{print \$2}" /proc/$(pidof rsyslogd)/status')
  [ "$uid" = 10514 ] || fail "rsyslogd runs as uid ${uid:-unknown}, expected 10514"
  echo "PASS: rsyslogd runs as uid $uid"

  cleanup
}

run_case volume -v "syslog-smoke-$$:/var/log/remote"
docker volume rm "syslog-smoke-$$" >/dev/null 2>&1 || true

# Docker creates the missing host folder itself, owned by root with mode 755.
BIND_PARENT=$(mktemp -d)
chmod 0755 "$BIND_PARENT"
run_case bind -v "$BIND_PARENT/remote:/var/log/remote"
owner=$(stat -c %u "$BIND_PARENT/remote/$HOST" 2>/dev/null || echo missing)
[ "$owner" = 10514 ] || fail "host folder $BIND_PARENT/remote/$HOST is owned by $owner, expected 10514"
echo "PASS: per-host folder created on the host bind mount, owned by uid 10514"
