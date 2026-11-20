#!/bin/sh
# Makes the log folder writable, starts the log-pruning loop, then runs rsyslogd
# in the foreground as an unprivileged user.
set -eu

LOG_DIR=/var/log/remote
WORK_DIR=/var/lib/rsyslog
PUID="${PUID:-10514}"
PGID="${PGID:-10514}"

case "$PUID$PGID" in
  *[!0-9]*) echo "PUID and PGID must be numeric" >&2; exit 1 ;;
esac

# Started as root: take ownership of the log and work folders, then re-run this
# script as PUID:PGID. A host folder that Docker creates for a bind mount is
# owned by root with mode 755, so without this rsyslog could not create the
# per-host folders inside it. Needs the CHOWN, SETUID and SETGID capabilities.
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$LOG_DIR" "$WORK_DIR"
  for dir in "$LOG_DIR" "$WORK_DIR"; do
    [ "$(stat -c %u:%g "$dir")" = "$PUID:$PGID" ] && continue
    if ! chown "$PUID:$PGID" "$dir"; then
      echo "Could not hand $dir to $PUID:$PGID. Give the container the CHOWN," >&2
      echo "SETUID and SETGID capabilities (see docker-compose.yml), or run" >&2
      echo "'chown $PUID:$PGID <host folder>' on the host and start it with --user $PUID:$PGID." >&2
      exit 1
    fi
  done
  # Hand over anything left from an earlier run or another owner.
  find "$LOG_DIR" -xdev \( ! -user "$PUID" -o ! -group "$PGID" \) \
    -exec chown "$PUID:$PGID" {} + 2>/dev/null || true
  exec su-exec "$PUID:$PGID" "$0" "$@"
fi

if ! [ -w "$LOG_DIR" ]; then
  echo "$LOG_DIR is not writable by uid $(id -u). On the host, run:" >&2
  echo "  chown $(id -u):$(id -g) <the folder mounted at $LOG_DIR>" >&2
  exit 1
fi

RETENTION_DAYS="${RETENTION_DAYS:-30}"
COMPRESS_AFTER_DAYS="${COMPRESS_AFTER_DAYS:-1}"

case "$RETENTION_DAYS$COMPRESS_AFTER_DAYS" in
  *[!0-9]*) echo "RETENTION_DAYS and COMPRESS_AFTER_DAYS must be whole numbers" >&2; exit 1 ;;
esac

prune() {
  if [ "$COMPRESS_AFTER_DAYS" -gt 0 ]; then
    # Files rsyslog has not written to for at least that many days.
    find "$LOG_DIR" -type f -name '*.log' -mtime "+$((COMPRESS_AFTER_DAYS - 1))" \
      -exec gzip -f {} \; 2>/dev/null || true
  fi
  if [ "$RETENTION_DAYS" -gt 0 ]; then
    find "$LOG_DIR" -type f \( -name '*.log' -o -name '*.log.gz' \) \
      -mtime "+$((RETENTION_DAYS - 1))" -delete 2>/dev/null || true
    find "$LOG_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
}

# Run once at start, then hourly, in the background.
( while :; do prune; sleep 3600; done ) &

# -n: stay in the foreground. -i NONE: no pid file (the root filesystem may be read-only).
exec /usr/sbin/rsyslogd -n -i NONE -f /etc/rsyslog.conf "$@"
