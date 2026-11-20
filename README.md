# syslog

A small syslog server in a container. It receives syslog from other devices over
**UDP and TCP on port 514** and writes **one log file per sending host per day**.

- **Base image:** `alpine:3.24` with **rsyslog**. Alpine keeps the image small
  (a few MB plus rsyslog), and rsyslog is the standard Linux syslog daemon. It
  handles UDP, TCP and TLS, and its per-host file templates need no extra tooling.
- **rsyslog runs as a non-root user** (UID 10514 by default). The container
  starts as root only long enough to hand the log folder to that user, then drops
  to it. Compose keeps just the three capabilities that needs (`CHOWN`, `SETUID`,
  `SETGID`). Inside the container rsyslog listens on 5514, and Compose maps host
  port 514 to it.
- **Log layout:** `/var/log/remote/<hostname>/YYYY-MM-DD.log` on a named volume.
- **Rotation:** files roll over daily by name. An hourly job gzips files older than
  `COMPRESS_AFTER_DAYS` (default 1) and deletes files older than `RETENTION_DAYS`
  (default 30).
- **Health check:** the container reports healthy when rsyslog is running and
  listening on both UDP and TCP.

## Deploy

On any host with Docker and the Compose plugin:

```sh
git clone https://github.com/todd2982/syslog.git
cd syslog
docker compose up -d --build
```

Check it:

```sh
docker compose ps        # STATUS should show (healthy)
docker compose logs -f   # rsyslog's own messages
```

Allow inbound **514/udp and 514/tcp** on the host firewall, then point your
devices at the host's IP address on port 514.

Once an image has been published to GHCR (see Image tags below), you can skip
the build and pull it instead: `docker compose pull && docker compose up -d`.
`docker-compose.yml` uses `:latest`, the newest release. Change it to `:dev` to
run whatever is on `main`, or to a version such as `:1.2.3` to pin one.

### Settings

Change these in `docker-compose.yml`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TZ` | `America/Chicago` | Time zone for file names and timestamps |
| `RETENTION_DAYS` | `30` | Delete log files older than this. `0` keeps them forever |
| `COMPRESS_AFTER_DAYS` | `1` | Gzip files older than this. `0` turns compression off |
| `PUID` / `PGID` | `10514` | User and group rsyslog runs as and that own the log files |

### Storing logs in a host folder instead of a volume

Replace the volume line with a bind mount:

```yaml
    volumes:
      - /srv/syslog:/var/log/remote
```

The folder doesn't need any preparation. If it doesn't exist, Docker creates it
owned by root, and the container hands it to `PUID:PGID` at startup. To make the
files readable by your own account on the host, set `PUID` and `PGID` to your
user's IDs (`id -u` and `id -g`).

If you'd rather not give the container `CHOWN`, `SETUID` and `SETGID`, prepare
the folder on the host and start the container as that user instead:

```sh
sudo mkdir -p /srv/syslog && sudo chown 10514:10514 /srv/syslog
```

In `docker-compose.yml`, add the `user` line and **delete the whole `cap_add`
block**, so the service keeps only:

```yaml
    user: "10514:10514"
    cap_drop:
      - ALL
```

If you use a user other than 10514, change the `uid` and `gid` on the
`/var/lib/rsyslog` tmpfs line to match, since nothing chowns it in this setup.

### TLS on 6514 (optional)

1. Add `rsyslog-tls` to the `apk add` line in the `Dockerfile`.
2. Uncomment the TLS block in `config/rsyslog.conf`.
3. Put `ca.pem`, `cert.pem` and `key.pem` in `./certs`, then uncomment the
   `6514` port and the `./certs` volume in `docker-compose.yml`.

## Test

Send a message from another Linux machine:

```sh
logger -n <server-ip> -P 514 -d "hello over UDP"
logger -n <server-ip> -P 514 -T "hello over TCP"
```

From the server itself, with `nc`:

```sh
echo "<134>$(date '+%b %e %H:%M:%S') testhost app: hello" | nc -u -w1 127.0.0.1 514
```

From Windows PowerShell (UDP):

```powershell
$u = New-Object System.Net.Sockets.UdpClient
$b = [Text.Encoding]::ASCII.GetBytes("<134>$(Get-Date -Format 'MMM dd HH:mm:ss') winhost app: hello")
$u.Send($b, $b.Length, "<server-ip>", 514) | Out-Null; $u.Close()
```

Read what arrived:

```sh
docker compose exec syslog find /var/log/remote -type f
docker compose exec syslog sh -c 'tail -n 20 /var/log/remote/*/*.log'
```

Automated end-to-end check:

```sh
docker build -t syslog:test .
tests/smoke-test.sh syslog:test
```

## CI and updates

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `ci.yml` | pushes to `main`, every PR, weekly | Hadolint, ShellCheck, Compose validation, build, smoke test (UDP + TCP messages must land in the per-host file), Trivy scan that fails on fixable HIGH/CRITICAL CVEs |
| `publish.yml` | push to `main`, `v*.*.*` tags | Smoke test, then builds amd64 + arm64 and pushes to `ghcr.io/todd2982/syslog` |

Dependabot opens weekly PRs against `main` for the Alpine base image and for the
GitHub Actions, which are pinned to commit SHAs.

### Image tags

| Event | Tags pushed to `ghcr.io/todd2982/syslog` |
| --- | --- |
| Push or merge to `main` | `dev`, `sha-<short sha>` (`latest` is not changed) |
| Git tag `v1.2.3` | `1.2.3`, `1.2`, `1`, and `latest` moves to this image |
| Git tag `v1.2.3-rc.1` (pre-release) | `1.2.3-rc.1` only, `latest` stays put |

To cut a release from the current `main`:

```sh
git checkout main && git pull
git tag v1.0.0
git push origin v1.0.0
```

## Files

```
Dockerfile               image definition
config/rsyslog.conf      inputs, per-host file template, TLS stub
scripts/entrypoint.sh    starts the compress/retention job, then rsyslogd
scripts/healthcheck.sh   container health check
docker-compose.yml       deployment
tests/smoke-test.sh      end-to-end test used by CI
```
