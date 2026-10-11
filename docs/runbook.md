# Runbook

Operational procedures for the `karan-s.com` platform. Server: `core-01` (Hetzner CAX11, Ubuntu 24.04 ARM64), reachable **only over Tailscale**.

| Thing | Where |
|---|---|
| Platform stack | `/opt/platform` (`compose.yaml` + `compose.data.yaml` + `compose.ops.yaml`) |
| Apps | `/opt/apps/<app>` (one compose project each) |
| Secrets on the server | `/opt/platform/.env`, `/opt/platform/backup/.env`, `/opt/platform/redis/users.acl` (all mode 600, owner `deployer`) |
| Logs and metrics | Grafana Cloud (Alloy) |
| Uptime | `status.karan-s.com` (Upptime), healthchecks.io |

---

## Accessing data

Prerequisite: Tailscale is running on your machine (Windows and/or WSL) and logged in to the same tailnet. If `core-01` doesn't resolve inside WSL2, use `core-01.<tailnet>.ts.net` or install Tailscale in WSL as well.

`~/.ssh/config`:

```
Host core-01
  User karan
  IdentityFile ~/.ssh/id_ed25519
  LocalForward 5432 127.0.0.1:5432
  LocalForward 6379 127.0.0.1:6379
```

`ssh -N core-01` (or `make tunnel`) opens both tunnels. Postgres and Redis listen on the server's `127.0.0.1` only; nothing is exposed publicly.

**Postgres**

| Task | Command |
|---|---|
| Quick query (read-only) | `ssh core-01 docker exec -it postgres psql -U karan_ro portfolio` |
| Admin shell | `ssh core-01 docker exec -it postgres psql -U postgres` |
| GUI (DBeaver / pgAdmin) | Host `127.0.0.1`, port `5432`, user `karan_ro`. Either run `ssh -N core-01` first, or use the tool's built-in **SSH tunnel** (host `core-01`, user `karan`, your key) |

Use `karan_ro` by default (`pg_read_all_data`, no writes). Use `postgres` only for migrations and fixes.

**Redis**

| Task | Command |
|---|---|
| CLI | `ssh -t core-01 docker exec -it redis redis-cli --user admin --askpass` |
| GUI (Redis Insight) | `127.0.0.1:6379`, user `admin`, through the tunnel |

Project users can only touch keys prefixed `<project>:`; the `default` user is disabled.

**Live state**

```bash
ssh core-01 docker ps
ssh core-01 docker stats --no-stream
make logs s=caddy              # docker logs -f for one service
ssh core-01 free -h && swapon --show
```

---

## Onboarding a new project

1. Pick a name matching `^[a-z][a-z0-9_]*$` (e.g. `notes`). Postgres/Redis names use `_`, subdomains use `-`.
2. Generate credentials with `openssl rand -base64 32` and add them as project-infra secrets: `PG_PASS_NOTES`, plus `REDIS_PASS_NOTES` if the app needs Redis.
3. Add the name to the `PROJECTS` repo variable (`portfolio,notes`).
4. Add `PG_PASS_NOTES: ${{ secrets.PG_PASS_NOTES }}` (and `REDIS_PASS_NOTES` if used) to the *Write env files* step env in `.github/workflows/deploy-platform.yml`. Secrets are listed explicitly; the workflow never loads `toJSON(secrets)`.
5. Add a route in `platform/Caddyfile` (`@notes host notes.{$DOMAIN}` → Sablier → `reverse_proxy notes:<port>`) and open a PR. Merging redeploys the platform; the init script creates the role and database, and `render-acl.sh` adds the Redis user.
6. In the app repo, add `deploy/compose.yaml`:
   - `image: ${IMAGE}`
   - networks `edge` (external) and, if needed, `data`
   - a `mem_limit`
   - labels `sablier.enable=true` and `sablier.group=notes`
   - **no `ports:`, no Docker socket**
7. In the app repo, add a workflow that calls `karan-sss/project-infra/.github/workflows/reusable-deploy-app.yml@main` with `app_name: notes`. Give the app repo the secrets `TS_CI_OAUTH_CLIENT_ID`, `TS_CI_OAUTH_SECRET`, `DEPLOY_SSH_PRIVATE_KEY`, `DEPLOY_KNOWN_HOSTS` and `APP_ENV` (e.g. `DATABASE_URL=postgres://notes:<pw>@postgres:5432/notes`), plus a `production` environment.

---

## Break-glass access (Tailscale is down)

Pick one:

1. **Temporary public SSH:** open a PR setting `ssh_public_access = true` in `terraform/terraform.tfvars`, merge, and approve `production`. Port 22 opens in the Hetzner firewall, but UFW still only allows 22 on `tailscale0`, so also run `sudo ufw allow 22/tcp` from the console (option 2). **Revert both afterwards.**
2. **Hetzner web console:** Cloud Console → server `core-01` → Console. Log in as `karan` with the break-glass password (its hash is the `ADMIN_PASSWORD_HASH` secret). Then fix Tailscale: `sudo systemctl status tailscaled`, `sudo tailscale up --advertise-tags=tag:server`. You may need a new auth key from the Tailscale admin console.

---

## Rebuilding the server

The IPs survive a rebuild (separate `hcloud_primary_ip` resources), so DNS doesn't change.

1. Take a fresh backup: `ssh core-01 sudo systemctl start backup.service`, and check healthchecks.io turns green.
2. Open a PR against `terraform/hetzner.tf` that:
   - sets `delete_protection` and `rebuild_protection` to `false` on `hcloud_server.main`
   - forces the replacement, e.g. temporarily removes `image` from `ignore_changes` and bumps `var.image`
3. Add the **`allow-replace`** label (the plan guard blocks the replacement otherwise), merge, and approve `production`.
4. Remove the old Tailscale device `core-01` from the admin console if a duplicate appears (`core-01-1`).
5. Update the `DEPLOY_KNOWN_HOSTS` secret: `ssh-keyscan core-01`.
6. Re-run `deploy-platform`, then restore data (see below), then redeploy apps.
7. Follow-up PR: restore `delete_protection`/`rebuild_protection = true` and the original `ignore_changes`.

---

## Restoring from backup

Backups are restic snapshots in R2 bucket `project-infra-backups`: `pg_dumpall.sql` (tag `postgres`) and `volumes/<name>.tar` (tag `volume`). Retention: 7 daily, 4 weekly, 6 monthly. **RPO 24 h, RTO target 30 min.**

```bash
ssh core-01
cd /opt/platform
set -a; . backup/.env; set +a
restic snapshots
# Postgres (into a running, empty postgres container):
restic dump --tag postgres latest /pg_dumpall.sql | docker exec -i postgres psql -U postgres -d postgres
docker exec postgres /docker-entrypoint-initdb.d/00-projects.sh   # re-apply current passwords
# A Docker volume:
docker compose -f /opt/apps/<app>/compose.yaml stop
restic dump --tag volume latest /volumes/<vol>.tar \
  | docker run --rm -i -v <vol>:/data postgres:16-alpine tar -C /data -xf -
```

The monthly `restore-drill` workflow does the Postgres restore automatically. If it fails, treat that as an incident.

> The restic password (`RESTIC_PASSWORD`) is also stored in the password manager. **Without it the backups can't be read.**

---

## Rotating secrets

| Secret | Steps |
|---|---|
| Postgres project password | Update `PG_PASS_<NAME>` → re-run `deploy-platform` (the init script runs `ALTER ROLE`) → update the app's `APP_ENV` → redeploy the app |
| Redis project password | Update `REDIS_PASS_<NAME>` → re-run `deploy-platform` (`render-acl.sh` + `ACL LOAD`) → update the app → redeploy |
| Cloudflare / Hetzner / Tailscale OAuth / Grafana service-account tokens | Create the new token → update the GitHub secret → run `terraform` plan → revoke the old token |
| Caddy DNS token | Update `CLOUDFLARE_DNS_TOKEN` → re-run `deploy-platform` |
| CI deploy key | `ssh-keygen -t ed25519 -f ~/.ssh/project_infra_ci_new` → append the `.pub` to `/home/deployer/.ssh/authorized_keys` → update `DEPLOY_SSH_PRIVATE_KEY` → remove the old line. Update `deploy_ssh_pubkey` in `terraform.tfvars` for future rebuilds |
| R2 backup keys | New R2 token → update `/opt/platform/backup/.env` via `deploy-platform` and the `R2_BACKUP_*` secrets → revoke the old one |
| Restic password | `restic key add` / `restic key remove` (the repository is not re-encrypted) → update `RESTIC_PASSWORD` + password manager |

Cloudflare tokens have an expiry date. Set a calendar reminder one week before it.

---

## Memory pressure / OOM

```bash
ssh core-01
journalctl -k | grep -i -E 'oom|killed process'      # kernel OOM kills
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'
docker inspect -f '{{.Name}} OOMKilled={{.State.OOMKilled}} restarts={{.RestartCount}}' $(docker ps -aq)
free -h && swapon --show
```

- A container hitting its own `mem_limit` is killed (`OOMKilled=true`) and restarted. Raise its limit in its compose file only if the host has headroom.
- Host-wide pressure: check swap usage (Grafana alert at more than 1 GiB). Let idle apps sleep (Sablier) or lower Postgres `shared_buffers`.
- JVM apps: set `-XX:MaxRAMPercentage=75` so the heap respects `mem_limit`.

---

## TLS certificates

- **Edge (visitor ↔ Cloudflare):** Cloudflare Universal SSL, automatic. It covers the apex and `*.karan-s.com` (one level only).
- **Origin (Cloudflare ↔ Caddy):** a Let's Encrypt wildcard via the **DNS-01** challenge, using `CLOUDFLARE_DNS_TOKEN`. Caddy renews about 30 days before expiry, and certs persist in the `caddy_data` volume.
- If renewal fails: `make logs s=caddy` and look for `acme`/`dns` errors. Usually the DNS token has expired or lost Zone Read / DNS Edit. Rotate it (see above).
- SSL mode is **Full (strict)**: an invalid origin cert causes Cloudflare error 526.

---

## Incident checklist

1. Check whether it's down for everyone: `status.karan-s.com`, then Cloudflare analytics (5xx?).
2. Check Cloudflare error codes: 521/522 means the origin is down or the firewall is blocking; 526 means an origin cert problem.
3. `ssh core-01` (Tailscale) → `docker ps` → `make logs s=<svc>` → `journalctl -p err -b`.
4. Check disk: `df -h /` (Docker logs are rotated at 3 × 10 MB per container, and the journal is capped at 200 MB).
5. If the fix involves data, take a backup first: `sudo systemctl start backup.service`.
