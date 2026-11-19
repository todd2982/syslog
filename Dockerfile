# syntax=docker/dockerfile:1
# Lightweight syslog receiver: Alpine Linux + rsyslog.
FROM alpine:3.24

LABEL org.opencontainers.image.title="syslog" \
      org.opencontainers.image.description="Lightweight rsyslog server that receives remote syslog over UDP and TCP and writes one log file per sending host." \
      org.opencontainers.image.source="https://github.com/todd2982/syslog"

# rsyslog: the receiver. tini: tiny init for clean signal handling and zombie reaping.
# tzdata: lets the TZ variable set the time zone used in file names and timestamps.
# hadolint ignore=DL3018
RUN apk add --no-cache rsyslog tini tzdata \
    && addgroup -S -g 10514 syslog \
    && adduser -S -D -H -u 10514 -G syslog -s /sbin/nologin syslog \
    && mkdir -p /var/log/remote /var/lib/rsyslog \
    && chown -R syslog:syslog /var/log/remote /var/lib/rsyslog \
    && rm -f /etc/rsyslog.conf /etc/rsyslog.d/*.conf

COPY --chmod=0644 config/rsyslog.conf /etc/rsyslog.conf
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

# Days to keep log files, and age in days after which files are gzipped (0 turns compression off).
ENV RETENTION_DAYS=30 \
    COMPRESS_AFTER_DAYS=1 \
    TZ=UTC

# The container listens on unprivileged port 5514 so it can run without root.
# Map host port 514 to it (see docker-compose.yml).
EXPOSE 5514/udp 5514/tcp

VOLUME ["/var/log/remote"]

USER syslog:syslog

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
