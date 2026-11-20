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
# rsyslog must not run as root, and PUID=0 would make the root branch below
# re-run this script as root forever.
if [ "$PUID" -eq 0 ]; then
  echo "PUID must not be 0 (root)" >&2; exit 1
fi

# Started as root: take ownership of the log and work folders, then re-run this
# script as PUID:PGID under tini, so PID 1 doesn't stay root either. A host folder that Docker creates for a bind mount is
# owned by root with mode 755, so without this rsyslog could not create the
# per-host folders inside it. Needs the CHOWN, SETUID and SETGID capabilities.
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$LOG_DIR" "$WORK_DIR"
  for dir in "$LOG_DIR" "$WORK_DIR"; do
    [ "$(stat -c %u:%g "$dir")" = "$PUID:$PGID" ] && continue
    if ! chown -h "$PUID:$PGID" "$dir"; then
      echo "Could not hand $dir to $PUID:$PGID. Give the container the CHOWN," >&2
      echo "SETUID and SETGID capabilities (see docker-compose.yml), or run" >&2
      echo "'chown $PUID:$PGID <host folder>' on the host and start it with --user $PUID:$PGID." >&2
      exit 1
    fi
  done
  # Hand over anything left from an earlier run or another owner. Anything this
  # can't reach or change is reported below, once running as PUID:PGID.
  # Symlinks are skipped and -h never follows one, so a link in the log folder
  # can't hand a file outside it (for example this script) to PUID.
  find "$LOG_DIR" -xdev ! -type l \( ! -user "$PUID" -o ! -group "$PGID" \) \
    -exec chown -h "$PUID:$PGID" {} + 2>/dev/null || true
  exec su-exec "$PUID:$PGID" /sbin/tini -- "$0" "$@"
fi

# Started directly as a non-root user (for example with --user): put tini in
# front as PID 1 to reap children and pass signals on.
if [ "$$" = 1 ]; then
  exec /sbin/tini -- "$0" "$@"
fi

if ! [ -w "$LOG_DIR" ]; then
  echo "$LOG_DIR is not writable by uid $(id -u). On the host, run:" >&2
  echo "  chown $(id -u):$(id -g) <the folder mounted at $LOG_DIR>" >&2
  exit 1
fi

# Warn about anything rsyslog may not be able to write to: entries owned by
# someone else (for example on an NFS export that squashes root) or folders
# it can't read. Messages for those hosts would otherwise be lost silently.
stray=$(find "$LOG_DIR" -xdev ! -user "$(id -u)" 2>&1 | head -n 20)
if [ -n "$stray" ]; then
  echo "Warning: rsyslog (uid $(id -u)) may not be able to write to these under $LOG_DIR:" >&2
  echo "$stray" >&2
  echo "Fix on the host with: chown -R $(id -u):$(id -g) <the folder mounted at $LOG_DIR>" >&2
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
