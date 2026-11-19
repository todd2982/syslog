#!/usr/bin/env bash
# Starts the image, sends one message over UDP and one over TCP, and checks that
# both land in the per-host log file. Usage: tests/smoke-test.sh [image]
set -euo pipefail

IMAGE="${1:-syslog:test}"
NAME="syslog-smoke-$$"
PORT="${SMOKE_PORT:-15514}"
TOKEN="smoke-$(date +%s)-$RANDOM"
HOST="smoke-test-host"

# Called by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  if [ "${FAILED:-0}" = 1 ]; then
    echo "--- container logs ---"; docker logs "$NAME" 2>&1 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$NAME" \
  -p "127.0.0.1:${PORT}:5514/udp" -p "127.0.0.1:${PORT}:5514/tcp" \
  --read-only --tmpfs /var/lib/rsyslog:uid=10514,gid=10514 --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges:true \
  "$IMAGE" >/dev/null

echo "Waiting for the container to report healthy..."
for _ in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)
  [ "$status" = healthy ] && break
  sleep 2
done
if [ "$status" != healthy ]; then
  echo "Container never became healthy (status: $status)"; FAILED=1; exit 1
fi

# RFC 3164 messages with a fixed hostname so the file path is predictable.
send() { # proto
  local proto=$1 msg
  msg="<134>$(LC_ALL=C date '+%b %e %H:%M:%S') ${HOST} smoketest: ${TOKEN} via ${proto}"
  if [ "$proto" = udp ]; then
    printf '%s' "$msg" > "/dev/udp/127.0.0.1/${PORT}"
  else
    printf '%s\n' "$msg" > "/dev/tcp/127.0.0.1/${PORT}"
  fi
}
send udp
send tcp

FILE="/var/log/remote/${HOST}/$(docker exec "$NAME" date '+%Y-%m-%d').log"
for _ in $(seq 1 15); do
  if docker exec "$NAME" grep -q "${TOKEN} via udp" "$FILE" 2>/dev/null \
     && docker exec "$NAME" grep -q "${TOKEN} via tcp" "$FILE" 2>/dev/null; then
    echo "PASS: UDP and TCP messages written to ${FILE}"
    docker exec "$NAME" cat "$FILE"
    # The process must not be running as root.
    uid=$(docker exec "$NAME" id -u)
    if [ "$uid" = 0 ]; then echo "FAIL: container runs as root"; FAILED=1; exit 1; fi
    exit 0
  fi
  sleep 1
done

echo "FAIL: messages not found in ${FILE}"
docker exec "$NAME" find /var/log/remote -type f || true
FAILED=1
exit 1
