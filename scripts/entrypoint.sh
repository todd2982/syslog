#!/bin/sh
# Starts the log-pruning loop, then runs rsyslogd in the foreground.
set -eu

LOG_DIR=/var/log/remote
RETENTION_DAYS="${RETENTION_DAYS:-30}"
COMPRESS_AFTER_DAYS="${COMPRESS_AFTER_DAYS:-1}"

if [ ! -d "$LOG_DIR" ]; then
  echo "Creating directory..."
  mkdir -p "$LOG_DIR"
  chmod -R 0775 "$LOG_DIR"
fi

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
