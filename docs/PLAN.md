# Plan: `project-infra` — Terraform + GitHub Actions platform for a self-hosted portfolio

## Context
The user is self-hosting a portfolio and a few small side projects on a single Hetzner CAX11 (ARM64, 4 GB) behind Cloudflare. The **hard budget is under €7/month**: only the server and its IPv4 are paid, and everything else uses free tiers. The repo itself is a showcase of DevOps and platform skills, so it must be reproducible, reviewed in CI, secure by default, observable, and documented like a real production repo.

**Goal:** a public GitHub repo `project-infra` where:
1. Terraform (run only from GitHub Actions) manages Hetzner (server, IPs, firewall), Cloudflare (DNS, TLS, WAF, analytics, R2 bucket) and Tailscale (ACL, auth keys).
2. cloud-init sets up the host on first boot: users, SSH reachable **only over Tailscale**, 4 GB swap, Docker, log rotation, fail2ban, unattended upgrades.
3. A "platform" Compose stack (custom Caddy built for arm64 in CI, signed and scanned, then Postgres/Redis/Sablier/Alloy) is deployed by CI over Tailscale.
4. Operations are covered: nightly encrypted backups with an automated restore test, monitoring and alerting, a public status page, drift detection, and a budget guardrail in CI.

---

## Decisions (settled — the executor must not re-ask)
| Area | Decision |
|---|---|
| Server | **Recreate it through Terraform.** Delete the hand-made server after cutover. |
| TF state | Cloudflare R2 bucket `project-infra-tfstate` via the `s3` backend, `use_lockfile = true` (Terraform ≥ 1.10). |
| Edge | All web records proxied by Cloudflare (orange cloud), SSL **Full (strict)**. |
| TLS at origin | Custom Caddy (`xcaddy` + `caddy-dns/cloudflare`) gets a wildcard Let's Encrypt cert via **DNS-01**. |
| Perimeter | The Hetzner Cloud Firewall is primary: 80/443 open **only to Cloudflare IPs**, UDP 41641 open for direct Tailscale connections, and **22 closed to the internet**. UFW on the host is the second layer. Docker-published ports bypass UFW, which is why the cloud firewall is primary. |
| Admin/CI access | **Tailscale** (free Personal plan). The server joins as `tag:server`, and CI runners join as ephemeral `tag:ci` nodes. The tailnet ACL is managed in Terraform. SSH only works on `tailscale0`. |
| Break-glass | The Terraform var `ssh_public_access` (default `false`) opens 22 publicly if Tailscale breaks. The admin user also gets a password hash that only works on the Hetzner web console (SSH password auth stays off). |
| Users | `karan` (sudo, human) and `deployer` (docker group, no sudo, CI key only). |
| Deps | **Renovate** (over Dependabot: it handles Terraform, Compose image digests and Actions in one tool). All Actions pinned by SHA. |
| Supply chain | Images get SBOM + provenance, are signed with **cosign keyless** (GitHub OIDC), and are scanned by **Trivy** with SARIF uploaded to GitHub code scanning. Deploys run `cosign verify` and pin the digest. |
| Cost visibility | **Not Infracost.** It only prices AWS/Azure/GCP and would show €0 for Hetzner/Cloudflare. Instead, `scripts/plan_guard.py` reads the plan JSON plus the live Hetzner `/v1/pricing` API, posts the monthly cost on the PR, and **fails if it is above €7**. |
| Replacement guard | The same script **fails any plan that deletes or replaces** `hcloud_server`, `hcloud_primary_ip` or `cloudflare_r2_bucket`, unless the PR has the `allow-replace` label. App and platform deploys never run Terraform at all. |
| WAF | Free-plan WAF custom rules (max 5) + 1 rate-limit rule, both in Terraform. **No Bot Fight Mode:** the free plan can't exempt paths, so it would challenge the status checks, CI smoke tests and project APIs. |
| Monitoring | Grafana Cloud free tier (10k series, 50 GB logs, 14-day retention) fed by **one Grafana Alloy container** (host + container metrics, Docker logs). Alerting runs in Grafana Cloud, so it works even when the box is down. |
| Status page | **Upptime** in a separate public repo `status`, run by GitHub Actions and served on GitHub Pages at `status.<domain>`. It uses 0 MB on the server and stays up when the server is down. Uptime Kuma is rejected because a status page on the box it monitors is meaningless. |
| Heartbeats | healthchecks.io free (20 checks) as a dead-man switch for backups and a 5-minute server heartbeat. |
| Analytics | Cloudflare Web Analytics with auto-inject (free, cookieless), in Terraform. |
| Backups | `restic` → second R2 bucket `project-infra-backups` (in the same 10 GB free tier). A nightly host systemd timer runs it, and a **monthly GitHub Actions restore drill** proves backups are restorable. |
| Data access | Postgres and Redis are on the `internal` `data` network, plus a small `ops` network that publishes **only on `127.0.0.1`** (5432/6379). You reach them through an SSH tunnel over Tailscale. They are never routed by Caddy or exposed publicly. |
| DB isolation | Postgres: one role + database per project, `REVOKE CONNECT … FROM PUBLIC`, SCRAM auth, and a read-only `karan_ro` role (`pg_read_all_data`) for everyday browsing. Redis: ACL users per project limited to their key prefix, with `default` disabled. |
| Public-repo hygiene | Secrets live only in GitHub Secrets, private R2 state and server `.env` files. Rendered cloud-init is `sensitive()`. A **leak check** scans plan text before it lands in public logs, PR comments or drift issues. Secret scanning + push protection are on. Fork PRs never get secrets (`pull_request` only, never `pull_request_target`). |
| Container containment | Containers can't reach the Hetzner metadata service (`169.254.169.254` blocked in `DOCKER-USER`). No container mounts the raw Docker socket: Sablier and Alloy go through a `docker-socket-proxy` that allows only container read + start/stop. |

### Free-tier check summary
| Idea | Free? | Notes |
|---|---|---|
| Tailscale CI SSH | ✅ | Personal plan: 3 users, 100 devices; CI nodes are ephemeral. |
| Backups to R2 | ✅ | 10 GB storage, 1M writes / 10M reads per month. **R2 needs a payment card on file** even on the free tier. Set a Cloudflare billing notification. |
| cosign / SBOM / Trivy | ✅ | Sigstore public good; code scanning is free for public repos. |
| Renovate + SHA pins | ✅ | Mend Renovate GitHub App. |
| Grafana Cloud + Alloy | ✅ | Costs ~150–250 MB of RAM on the box; drop cAdvisor high-cardinality labels to stay under 10k series. Fallback: Beszel (~30 MB). |
| healthchecks.io | ✅ | Hobbyist plan, 20 checks. |
| CF Web Analytics | ✅ | |
| Infracost | ⚠️ replaced | Doesn't support Hetzner/Cloudflare; a custom cost-check script does the job instead. |
| Drift detection | ✅ | Actions minutes are unlimited on public repos. |
| CF WAF / rate limit | ✅ | Free plan: 5 custom rules, 1 rate-limit rule (10s period/10s timeout). Bot Fight Mode excluded (see above). |
| Status page | ✅ | Upptime on GitHub Pages instead of Uptime Kuma. |
| Docs | ✅ | |

### RAM budget (4 GB + 4 GB swap)
| Component | Limit |
|---|---|
| OS + dockerd + containerd + tailscaled + fail2ban | ~450 MB (no limit) |
| Caddy | 128 MB |
| Postgres 16 | 512 MB |
| Redis 7 | 96 MB |
| Sablier | 32 MB |
| Alloy | 256 MB |
| restic (03:00 only, transient) | ~200 MB |
| **Platform total** | **~1.5 GB → ~2.5 GB left for apps (scaled to zero when idle)** |

---

## Manual prerequisites — the HUMAN must do these (the executor lists them, then waits)
1. **Cloudflare:** add the domain (Free plan) and switch the registrar's nameservers to Cloudflare. Note the **Zone ID** and **Account ID**. Add a payment method and enable R2. Create bucket `project-infra-tfstate` by hand (it's the bootstrap bucket; Terraform creates the backups bucket). Set a billing notification.
2. **Cloudflare API tokens:** use **Account API tokens** (Manage Account → Account API Tokens). They belong to the account, not your user, so they keep working if your login changes; that's the pattern for CI service credentials. Permissions are picked as *Scope → Group → Level*. The UI may say "Edit" or "Write"; they mean the same thing.
   - `terraform`:
     - Zone resources: *Include → Specific zone → <domain>*.
     - Zone → Zone → Read
     - Zone → DNS → Edit
     - Zone → Zone Settings → Edit
     - Zone → SSL and Certificates → Edit
     - Zone → Zone WAF → Edit (WAF custom rules + rate-limit ruleset; if the rate-limit apply gets a 403, also add Zone → Firewall Services → Edit)
     - Account → Account Settings → Edit (+ Read). This one is for **Web Analytics**; there is no separate "Web Analytics" permission.
     - Account → Workers R2 Storage → Edit (creates the backups bucket)
   - `caddy-dns`: Zone → Zone → Read + Zone → DNS → Edit, for this zone only. The `caddy-dns/cloudflare` plugin needs both.
   - If a permission can't be found, type its name in the permission search box. If one truly doesn't exist for account tokens, create that single token as a User API token and note it in an ADR.
   - R2 S3 credentials: one pair for `project-infra-tfstate` (CI) and one pair for `project-infra-backups` (server + restore drill). Create the backups pair after Terraform makes the bucket.
3. **Hetzner:** a project API token (Read & Write).
4. **Tailscale:** create an account (log in with GitHub). In the admin console create two **OAuth clients**:
   - `terraform`: scopes `policy_file`, `auth_keys`, `devices:core`.
   - `github-ci`: scope `auth_keys`, tag `tag:ci`.
   - Enable MagicDNS. **Warning:** Terraform will own the whole tailnet ACL, so the ACL in Task 3 includes the user's own devices.
5. **Grafana Cloud:** create a free stack. Note the Prometheus remote-write URL + user ID, the Loki URL + user ID, and an access-policy token with `metrics:write` and `logs:write`.
6. **healthchecks.io:** create a free account with checks `backup-nightly` (period 1 day, grace 2 h), `server-heartbeat` (period 5 min, grace 5 min) and `restore-drill` (period 31 days). Wire the email/Telegram integration.
7. **Keys and passwords (WSL):**
   - `ssh-keygen -t ed25519 -f ~/.ssh/project_infra_ci -C github-actions-deployer -N ""`
   - A restic repo password (store it in a password manager too, because **losing it makes the backups unusable**).
   - An admin console password hash: `openssl passwd -6`.
8. **GitHub:** install `gh` and run `gh auth login`. Install the **Renovate** GitHub App on the repo after Task 1.
9. **GitHub secrets:** `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_DNS_TOKEN`, `R2_STATE_ACCESS_KEY_ID`, `R2_STATE_SECRET_ACCESS_KEY`, `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY`, `RESTIC_PASSWORD`, `TS_TF_OAUTH_CLIENT_ID`, `TS_TF_OAUTH_SECRET`, `TS_CI_OAUTH_CLIENT_ID`, `TS_CI_OAUTH_SECRET`, `DEPLOY_SSH_PRIVATE_KEY`, `DEPLOY_KNOWN_HOSTS` (set after first boot), `ADMIN_PASSWORD_HASH`, `GRAFANA_CLOUD_TOKEN`, `HC_PING_KEY`.
10. **GitHub variables:** `DOMAIN`, `CF_ACCOUNT_ID`, `CF_ZONE_ID`, `ADMIN_EMAIL`, `GRAFANA_PROM_URL`, `GRAFANA_PROM_USER`, `GRAFANA_LOKI_URL`, `GRAFANA_LOKI_USER`, `SERVER_TS_HOST` (default `core-01`).
11. **GitHub Environment** `production` with required reviewer = self and **deployment branches = `main` only**.
12. **GitHub repo security settings:**
    - Settings → Code security: enable **Secret scanning** + **Push protection** + Dependabot alerts.
    - Settings → Actions → General: "Require approval for all external contributors", Workflow permissions = **Read repository contents** (workflows ask for more explicitly).
13. **Postgres/Redis passwords** as GitHub secrets: `PG_SUPERUSER_PASSWORD`, `PG_RO_PASSWORD`, `PG_PASS_<PROJECT>` per project, `REDIS_ADMIN_PASSWORD`, `REDIS_PASS_<PROJECT>` per project. Generate each with `openssl rand -base64 32`.
14. **On your Windows machine:** install Tailscale and log in with the same account. If MagicDNS names don't resolve inside WSL2, use `core-01.<tailnet>.ts.net` or also install Tailscale in WSL.

---

## Target repo layout
```
project-infra/
├── README.md                      # mermaid diagram, costs, badges, how it works, "at scale" section
├── SECURITY.md                    # threat model summary + how to report
├── renovate.json
├── Makefile                       # fmt / lint / plan-local / ssh / logs
├── .pre-commit-config.yaml  .gitignore  .tflint.hcl  .yamllint
├── docs/
│   ├── PLAN.md                    # this file
│   ├── runbook.md                 # rebuild, break-glass, rotate secrets, restore, incident checklist
│   └── adr/0001…0014-*.md
├── scripts/
│   ├── leak_check.sh              # fail if plan text / comments contain secret patterns
│   └── plan_guard.py              # plan JSON → monthly cost (Hetzner pricing API) + block replace/delete of stateful resources
├── terraform/
│   ├── versions.tf backend.tf providers.tf variables.tf outputs.tf terraform.tfvars
│   ├── hetzner.tf                 # ssh key, primary IPs, firewall, server
│   ├── cloudflare.tf              # dns, zone settings, waf, rate limit, analytics, r2 backups bucket
│   ├── tailscale.tf               # acl, server auth key, device settings
│   └── templates/cloud-init.yaml.tftpl
├── platform/
│   ├── compose.yaml               # caddy, postgres, redis, sablier, alloy
│   ├── Caddyfile
│   ├── site/index.html
│   ├── alloy/config.alloy
│   ├── postgres/init/00-projects.sh   # idempotent: roles, dbs, grants, karan_ro
│   ├── redis/redis.conf           # users.acl rendered at deploy, never committed
│   ├── backup/backup.sh
│   └── .env.example
├── images/caddy/Dockerfile
└── .github/
    ├── CODEOWNERS
    └── workflows/
        ├── lint.yml               # fmt, tflint, trivy config, actionlint, yamllint, shellcheck
        ├── terraform.yml          # plan+cost comment on PR, apply on main (env production)
        ├── drift.yml              # nightly plan -detailed-exitcode → issue
        ├── build-caddy.yml        # buildx arm64/amd64, sbom, provenance, cosign, trivy
        ├── deploy-platform.yml    # tailscale → cosign verify → rsync → compose up → smoke test
        ├── restore-drill.yml      # monthly: restic restore into throwaway postgres + checks
        └── reusable-deploy-app.yml  # workflow_call for app repos (phase 2)
```

---

## PHASE 1 — Core platform

### Task 1 — Repo bootstrap
- `git init -b main`. Add `.gitignore` (`.terraform/`, `*.tfstate*`, `*.tfplan`, `tfplan*`, `.env`, `*.pem`), `.tflint.hcl` (terraform ruleset recommended), `.yamllint`, `.pre-commit-config.yaml` (terraform_fmt, terraform_validate, terraform_tflint, trailing-whitespace, end-of-file-fixer, check-yaml, detect-private-key, gitleaks).
- `README.md`: move `info.md` content in and fix the broken `[https://…](https://…)` links inside the bash blocks of the Docker step. Delete `info.md`.
- `docs/adr/`: one file per decision in the Decisions table (MADR format: Context / Decision / Consequences).
- `renovate.json`: `extends: ["config:recommended", "helpers:pinGitHubActionDigests", ":semanticCommits"]`, `docker-compose` + `terraform` managers enabled, `pinDigests: true` for Docker, automerge `minor`/`patch` for `github-actions` after CI passes, weekly schedule.
- `CODEOWNERS`: `* @<github-user>`.
- `gh repo create project-infra --public --source=. --push`. Then the human installs the Renovate app.
- **Done when:** the repo is on GitHub, `git ls-files` shows no secrets, and the Renovate onboarding PR appears.

### Task 2 — Terraform skeleton
- `versions.tf`: `required_version = ">= 1.10"`. Providers: `hetznercloud/hcloud ~> 1.52`, `cloudflare/cloudflare ~> 5.0` (**v5 names:** `cloudflare_dns_record`, `cloudflare_zone_setting`, `cloudflare_ruleset`; check registry docs before writing), `tailscale/tailscale ~> 0.21`.
- `backend.tf`: `backend "s3"` with `bucket = "project-infra-tfstate"`, `key = "prod/terraform.tfstate"`, `region = "auto"`, `endpoints = { s3 = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" }`, `use_path_style = true`, `use_lockfile = true`, and all five `skip_*` flags (`skip_credentials_validation`, `skip_region_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`, `skip_s3_checksum`) set to `true`. Credentials come from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (mapped from the `R2_STATE_*` secrets).
- `providers.tf`: hcloud via `HCLOUD_TOKEN`, cloudflare via `CLOUDFLARE_API_TOKEN`, tailscale via `TAILSCALE_OAUTH_CLIENT_ID`/`TAILSCALE_OAUTH_CLIENT_SECRET` env (`tailnet = "-"`).
- `variables.tf`: `domain`, `cloudflare_zone_id`, `cloudflare_account_id`, `location` (`fsn1`), `server_type` (`cax11`), `image` (`ubuntu-24.04`), `admin_username` (`karan`), `admin_ssh_pubkey`, `deploy_ssh_pubkey`, `admin_password_hash` (**sensitive**), `hc_ping_key` (**sensitive**), `ssh_public_access` (bool, default false), `admin_tailscale_login` (the user's Tailscale login email, used in the ACL).
- **Rule:** every variable that carries a secret is declared `sensitive = true`, so Terraform prints `(sensitive value)` instead of the value.
- **Done when:** `terraform init` + `validate` pass in CI.

### Task 3 — Hetzner + Tailscale resources (`hetzner.tf`, `tailscale.tf`)
- `tailscale_acl`: `tagOwners` `{ "tag:server": ["autogroup:admin"], "tag:ci": ["autogroup:admin"] }`. Grants:
  - `autogroup:member` → `*:*` (the user's own devices keep working, including laptop → Postgres for debugging).
  - `tag:ci` → `tag:server:22` only.
  - Leave the `ssh` section out (we use OpenSSH over the tailnet, not Tailscale SSH).
- `tailscale_tailnet_key.server`: `reusable = false`, `ephemeral = false`, `preauthorized = true`, `expiry = 3600`, `tags = ["tag:server"]`.
- `hcloud_ssh_key.admin`. Also `hcloud_primary_ip.ipv4` and `.ipv6` (`assignee_type = "server"`, `auto_delete = false`, `datacenter = "${var.location}-dc14"`; check the dc name via `hcloud datacenter list`).
- `data "cloudflare_ip_ranges" "cf"`, then `hcloud_firewall.main` rules:
  - ICMP in.
  - TCP 80 and 443 in from the CF ipv4 + ipv6 CIDRs.
  - UDP 41641 in from any (Tailscale direct connections).
  - A `dynamic` rule for TCP 22 from any **only when** `var.ssh_public_access`.
- `hcloud_server.main`: `name = "core-01"`, the var image/type/location, `ssh_keys`, `firewall_ids`, `public_net { ipv4 = …, ipv6 = … }`, `user_data = sensitive(templatefile(...))` passing `admin_username`, `admin_ssh_pubkey`, `deploy_ssh_pubkey`, `admin_password_hash`, `hc_ping_key`, `ts_authkey = tailscale_tailnet_key.server.key`. Wrapping it in `sensitive()` is **mandatory**: without it, the first plan prints the Tailscale key and password hash into public Actions logs. Labels `{env=prod, managed_by=terraform}`. `delete_protection = true`, `rebuild_protection = true`, `lifecycle { ignore_changes = [user_data, image, ssh_keys] }`.
- `tailscale_device_key`: look up the device with `data "tailscale_device" { hostname = "core-01", wait_for = "5m" }` (depends_on the server) and set `key_expiry_disabled = true`, so the server never drops off the tailnet.
- `outputs.tf`: `ipv4`, `ipv6`, `tailscale_ip`, `ssh_command = "ssh karan@core-01"`.

### Task 4 — cloud-init (`templates/cloud-init.yaml.tftpl`)
- `users`:
  - `${admin_username}`: sudo NOPASSWD, bash, admin key, `hashed_passwd: ${admin_password_hash}`, `lock_passwd: false` (for the Hetzner console only).
  - `deployer`: groups `docker`, deploy key, no sudo.
- `package_update/upgrade: true`. Packages: `ca-certificates curl gnupg ufw fail2ban unattended-upgrades needrestart rsync jq restic`.
- `apt.sources`:
  - `docker` (deb `https://download.docker.com/linux/ubuntu noble stable`, arch arm64, keyid `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`).
  - `tailscale` (`https://pkgs.tailscale.com/stable/ubuntu noble main`, key from `https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg`). Check the keyid at execution time.
  - Then install `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin tailscale`.
- `swap: { filename: /swapfile, size: 4G, maxsize: 4G }`.
- `write_files`:
  - `/etc/sysctl.d/99-tuning.conf`: `vm.swappiness=10`, `vm.vfs_cache_pressure=50`, `net.ipv4.ip_forward=1` (Tailscale).
  - `/etc/ssh/sshd_config.d/10-hardening.conf`: `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AllowUsers ${admin_username} deployer`.
  - `/etc/docker/daemon.json`: json-file logs `max-size 10m`, `max-file 3`, `"live-restore": true`.
  - `/etc/fail2ban/jail.local`: sshd jail.
  - `/etc/systemd/system/backup.service`: `User=deployer`, `ConditionPathExists=/opt/platform/backup/backup.sh`, `EnvironmentFile=/opt/platform/backup/.env`, `ExecStart=/opt/platform/backup/backup.sh`.
  - `/etc/systemd/system/backup.timer`: `OnCalendar=*-*-* 03:00`, `RandomizedDelaySec=15m`, `Persistent=true`.
  - `/etc/systemd/system/block-metadata.service`: `Type=oneshot`, `RemainAfterExit=yes`, `After=docker.service`, `PartOf=docker.service`, `WantedBy=docker.service`. `ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -d 169.254.169.254/32 -j REJECT 2>/dev/null || iptables -I DOCKER-USER -d 169.254.169.254/32 -j REJECT'`. This stops containers from reading cloud-init user data (and its secrets) from the Hetzner metadata service, and re-applies whenever Docker restarts.
  - `/etc/systemd/system/heartbeat.service` + `.timer`: every 5 min, `curl -fsS -m 10 --retry 3 https://hc-ping.com/${hc_ping_key}/server-heartbeat`.
- `runcmd`:
  - `sysctl --system`
  - `tailscale up --authkey=${ts_authkey} --hostname=core-01 --advertise-tags=tag:server`
  - `ufw default deny incoming`; `ufw allow 80,443/tcp`; `ufw allow in on tailscale0 to any port 22 proto tcp`; `ufw allow 41641/udp`; `ufw --force enable`
  - `systemctl enable --now docker fail2ban block-metadata.service backup.timer heartbeat.timer`
  - `systemctl restart ssh`
  - `install -d -o deployer -g deployer /opt/platform /opt/apps`
  - `docker network create edge || true`
- **Done when** (over `ssh karan@core-01` via Tailscale): `cloud-init status --long` is `done` with no errors, `swapon --show` shows 4G, `docker info` reports `aarch64`, `ssh karan@<public-ipv4>` **times out**, `docker version` shows Engine **≥ 28** (needed so `127.0.0.1`-published ports can't be reached from neighbouring hosts), and `docker run --rm curlimages/curl -m 5 http://169.254.169.254/hetzner/v1/userdata` **fails**. Also capture `ssh-keyscan core-01` into the `DEPLOY_KNOWN_HOSTS` secret.

### Task 5 — Cloudflare resources (`cloudflare.tf`)
- `cloudflare_dns_record`: apex + `*` as `A`/`AAAA` → server IPs, `proxied = true`, `ttl = 1`. Also `status` as `CNAME` → `<github-user>.github.io`, **`proxied = false`** (GitHub Pages must issue its own cert).
- `cloudflare_zone_setting`: `ssl=strict`, `always_use_https=on`, `min_tls_version=1.2`, `tls_1_3=on`, `automatic_https_rewrites=on`, `brotli=on`, `security_level=medium`.
- `cloudflare_ruleset` phase `http_request_firewall_custom` (≤ 5 rules):
  1. Block common scanner paths: `/wp-admin`, `/wp-login.php`, `/xmlrpc.php`, `/.env`, `/.git`, `/phpmyadmin`.
  2. Block requests with an empty `User-Agent`.
  3. Managed challenge if `cf.threat_score > 30` (if that field is unavailable on free, skip it).
  4. Leave 2 slots free for app-specific rules.
- `cloudflare_ruleset` phase `http_ratelimit` (1 rule, free limits): `/api/` paths, 50 req per 10 s per IP, block for 10 s.
- `cloudflare_web_analytics_site` with `zone_tag`, `auto_install = true`.
- `cloudflare_r2_bucket` `project-infra-backups` (location `EEUR`).
- **Note:** universal SSL covers only `*.domain` one level deep, so use `app.domain` and never `a.b.domain`.

### Task 6 — Terraform CI + plan guard (cost + replacement protection)
- `scripts/plan_guard.py` (Python stdlib only; input `terraform show -json tfplan > plan.json`). It runs two checks and exits 1 if either fails:
  - **Cost check:**
    1. Collect the planned `hcloud_server` (server_type, location) and `hcloud_primary_ip` (type) resources.
    2. `GET https://api.hetzner.cloud/v1/pricing` with `HCLOUD_TOKEN`.
    3. Sum the `price_monthly.gross` values.
    4. Fail if the total is above `BUDGET_EUR` (default `7.00`).
  - **Replacement check:**
    - Protected types: `hcloud_server`, `hcloud_primary_ip`, `cloudflare_r2_bucket` (holds backups). Keep them in a `PROTECTED_TYPES` constant at the top of the script.
    - For each entry in `resource_changes` whose `type` is protected, look at `change.actions`. If it contains `"delete"` (this covers `["delete"]`, `["delete","create"]` and `["create","delete"]`, so both destroy and replace), record the `address` plus `action_reason` (e.g. `replace_because_cannot_update`).
    - Fail unless env `ALLOW_REPLACE=true`.
  - Output: a markdown report to stdout and to `$GITHUB_STEP_SUMMARY`, with a cost table and a "⛔ Destructive changes" table listing address/action/reason. If the destructive list isn't empty, end with: "add the `allow-replace` label to this PR if this is intentional".
- `.github/workflows/terraform.yml`:
  - Triggers:
    - `pull_request` with `types: [opened, synchronize, reopened, labeled, unlabeled]` (so adding the label re-runs the check).
    - `push` to `main`.
    - Both with paths `terraform/**`, `scripts/**`.
  - `concurrency: { group: terraform-prod, cancel-in-progress: false }`. Permissions: `contents: read`, `pull-requests: write`.
  - Env mapping: `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `TAILSCALE_OAUTH_CLIENT_ID`/`SECRET` ← `TS_TF_*`, `AWS_*` ← `R2_STATE_*`, and `TF_VAR_*` for domain, zone id, account id, admin_password_hash, admin_tailscale_login.
  - Job `plan` (PR):
    1. `fmt -check` → `init` → `validate` → `plan -out=tfplan -no-color` → `terraform show -json tfplan > plan.json`.
    2. Run `plan_guard.py plan.json` with `ALLOW_REPLACE: ${{ contains(github.event.pull_request.labels.*.name, 'allow-replace') }}`.
    3. Post a **single sticky PR comment** (guard report + plan in `<details>`) via `actions/github-script`, updating the existing comment instead of adding new ones. Post it **even if the guard failed** (`if: always()`).
  - Job `apply` (push to main), with `environment: production`:
    1. Find the merged PR's labels: `gh api repos/${{ github.repository }}/commits/${{ github.sha }}/pulls --jq '[.[0].labels[].name] | index("allow-replace") != null'` → `ALLOW_REPLACE`.
    2. `init` → `plan -out=tfplan` → `show -json` → `plan_guard.py` → `apply tfplan`.
    3. The guard runs again here because state may have changed since the PR plan.
- `scripts/leak_check.sh <file>…` (used by terraform.yml **before** posting the PR comment, and by drift.yml **before** writing an issue):
  - Fails if any file matches `tskey-`, `\$6\$`, `\$y\$`, `-----BEGIN`, `hc-ping.com/[A-Za-z0-9_-]{16,}`, `AKIA`, or the value of any env var whose name ends in `_TOKEN`, `_SECRET`, `_PASSWORD` or `_KEY` (exact-string grep, values never echoed).
  - It's needed because values Terraform **generates** (like the tailnet key) are not GitHub secrets, so Actions can't mask them.
  - The PR comment posts only the plan **summary** (`terraform show -no-color tfplan` filtered to resource lines and `Plan:` totals) plus the guard report. The full plan stays as a workflow **artifact** with 7-day retention.
- One-time setup: `gh label create allow-replace --color B60205 --description "Permit Terraform to destroy/replace protected resources"`.
- This is a third layer on top of `lifecycle.ignore_changes` and Hetzner `delete_protection`/`rebuild_protection` (Task 3): **CI blocks it → Hetzner API refuses it → a human must approve `production`**. Record this in an ADR.

### Task 7 — Lint/security workflow (`lint.yml`)
- Runs on every PR and push: `terraform fmt -check -recursive`, tflint, `aquasecurity/trivy-action` (`scan-type: config`, SARIF → `github/codeql-action/upload-sarif`), `actionlint`, `yamllint`, `shellcheck platform/**/*.sh`, gitleaks.
- Branch protection on `main` via `gh api`: require PRs and the checks `lint` + `plan`, no force-push.
- **Workflow rules** (apply to every workflow file; check them in review):
  - Top-level `permissions: {}` or `contents: read`, granting more per job only.
  - Never use `pull_request_target`.
  - Never interpolate `${{ github.event.* }}` text (PR titles, branch names) directly into `run:`; pass it through `env:`.
  - Every job that touches production uses `environment: production`.
  - No `set -x` in steps that handle secrets.
  - `actionlint` + `zizmor` (GitHub Actions security linter) run in `lint.yml`.

### Task 8 — Custom Caddy image + supply chain (`images/caddy/Dockerfile`, `build-caddy.yml`)
- Dockerfile: `FROM caddy:2-builder AS build`, then `RUN xcaddy build --with github.com/caddy-dns/cloudflare --with github.com/sablierapp/sablier/plugins/caddy`; `FROM caddy:2`, then `COPY --from=build /usr/bin/caddy /usr/bin/caddy`. If the sablier plugin path fails, check its README for the current module path.
- Workflow (on `images/caddy/**`, weekly schedule, dispatch). Permissions: `contents: read`, `packages: write`, `id-token: write`, `security-events: write`.
  - Matrix build with **native runners**: `ubuntu-24.04` (amd64) + `ubuntu-24.04-arm` (arm64, free for public repos). Push by digest, then merge into a manifest list in a final job (follow the Docker docs "multi-platform: distribute build across runners" pattern). `provenance: mode=max`, `sbom: true`, `cache-from/to: type=gha,scope=<arch>`.
  - `sigstore/cosign-installer`, then `cosign sign --yes ghcr.io/<owner>/caddy-cloudflare@<digest>`.
  - `aquasecurity/trivy-action` image scan (`severity: CRITICAL,HIGH`, `ignore-unfixed: true`, `exit-code: 1` for CRITICAL), with SARIF uploaded.
  - Tags: `sha-<short>`, `latest`.
- Make the GHCR package public.

### Task 9 — Platform stack + deploy (`platform/`, `deploy-platform.yml`)
- `compose.yaml`: service `caddy` with image `ghcr.io/<owner>/caddy-cloudflare@sha256:…`. Renovate keeps the digest current, and the deploy workflow verifies it.
  - Ports 80/443. Volumes `./Caddyfile:/etc/caddy/Caddyfile:ro`, `./site:/srv/site:ro`, `caddy_data`, `caddy_config`.
  - `env_file: .env`, `mem_limit: 128m`, `restart: unless-stopped`. Network `edge` (external).
  - Healthcheck: `wget -qO- http://localhost:2019/config/ || exit 1`.
- `Caddyfile`:
  - Global `{ email {$ACME_EMAIL} }`.
  - Snippet `(security)` with the HSTS, `X-Content-Type-Options nosniff`, `Referrer-Policy strict-origin-when-cross-origin` and `-Server` headers.
  - Site `{$DOMAIN}, *.{$DOMAIN}` with `tls { dns cloudflare {$CF_DNS_API_TOKEN} }`, `import security`, and `@root host {$DOMAIN}` → `root * /srv/site` + `file_server`. Leave a commented `@app host app.{$DOMAIN}` example. Fallback `respond 404`.
- `deploy-platform.yml` (push to `main` on `platform/**`, `workflow_run` of build-caddy, dispatch; `concurrency: deploy-prod`; `environment: production`):
  1. `tailscale/github-action@v3` with `oauth-client-id`/`oauth-secret` from `TS_CI_*` and `tags: tag:ci`.
  2. Write `DEPLOY_SSH_PRIVATE_KEY` to the ssh agent and `DEPLOY_KNOWN_HOSTS` to `~/.ssh/known_hosts` (no `ssh-keyscan` at deploy time).
  3. Read every image ref with a digest out of `compose.yaml`, then `cosign verify <ref> --certificate-identity-regexp "^https://github.com/<owner>/project-infra/" --certificate-oidc-issuer https://token.actions.githubusercontent.com`. Fail the deploy if verification fails.
  4. `rsync -az --delete --exclude .env platform/ deployer@core-01:/opt/platform/`.
  5. Render `.env` from secrets and vars, then send it with `ssh deployer@core-01 'umask 077; cat > /opt/platform/.env'`. Do the same for `backup/.env` and, once Task 11 exists, `redis/users.acl` (`chmod 600`). Secrets travel only over the SSH stdin pipe; they're never passed as command-line args and never echoed.
  6. `ssh deployer@core-01 'cd /opt/platform && docker compose pull && docker compose up -d --remove-orphans --wait && docker image prune -f'`. Once Task 11 exists, then run `docker exec postgres /docker-entrypoint-initdb.d/00-projects.sh` (idempotent roles/dbs/password rotation) and `docker exec redis redis-cli … ACL LOAD`.
  7. Smoke test: `curl -fsS --retry 5 --retry-delay 5 https://$DOMAIN`.
- **Done when:** `https://<domain>` serves the placeholder through Cloudflare, and `curl -k https://<ipv4>` from outside **times out**.

### Task 10 — Cutover
- Delete the hand-made server in the Hetzner console. **Ask the human first.**
- Update the README roadmap and add badges (lint, terraform, build, drift, restore-drill, Upptime status).

---

## PHASE 2 — Shared data plane, scale-to-zero, app onboarding

### Task 11 — Postgres + Redis + Sablier (secured)
- **Networks** in `compose.yaml`:
  - `edge`: external (Caddy + apps).
  - `data`: `internal: true` (apps ↔ Postgres/Redis).
  - `ops`: a normal bridge, used only for loopback publishing.
  - `socket`: `internal: true` (socket proxy ↔ Sablier/Alloy).
- **`postgres:16-alpine`** (digest-pinned):
  - `mem_limit 512m`, command `-c shared_buffers=128MB -c max_connections=50 -c work_mem=4MB -c password_encryption=scram-sha-256`.
  - `POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256`. `POSTGRES_PASSWORD` comes from `PG_SUPERUSER_PASSWORD` in `.env`.
  - Volume `pg_data`. Networks `data` + `ops`. **`ports: ["127.0.0.1:5432:5432"]`**, loopback only. Never `0.0.0.0`, never attached to `edge`.
  - `postgres/init/00-projects.sh` is **idempotent**. The deploy workflow runs it on every deploy via `docker exec postgres /docker-entrypoint-initdb.d/00-projects.sh`, so adding a project is just a new env var. For each name in `PROJECTS="portfolio,..."`:
    1. Create role `<name>` with LOGIN and password `$PG_PASS_<NAME>` if missing, else `ALTER ROLE … PASSWORD` (this also handles rotation).
    2. Create database `<name>` with OWNER `<name>` if missing.
    3. `REVOKE CONNECT ON DATABASE <name> FROM PUBLIC; GRANT CONNECT ON DATABASE <name> TO <name>;`
  - The script also creates `karan_ro` with LOGIN, `PG_RO_PASSWORD` and `GRANT pg_read_all_data`. Use this role for everyday browsing so a GUI slip can't modify data.
- **`redis:7-alpine`**:
  - Command `redis-server /usr/local/etc/redis/redis.conf`, `mem_limit 96m`. Networks `data` + `ops`, `ports: ["127.0.0.1:6379:6379"]`.
  - `redis/redis.conf` (in git, no secrets): `maxmemory 64mb`, `maxmemory-policy allkeys-lru`, `appendonly no`, `protected-mode yes`, `aclfile /usr/local/etc/redis/users.acl`.
  - `users.acl` is **rendered at deploy time** from secrets (never committed), `chmod 600`:
    ```
    user default off
    user admin on >${REDIS_ADMIN_PASSWORD} ~* &* +@all
    user portfolio on >${REDIS_PASS_PORTFOLIO} ~portfolio:* &portfolio:* +@all -@dangerous
    ```
  - Healthcheck: `redis-cli --user admin --pass "$REDIS_ADMIN_PASSWORD" ping`, with the password passed via env, not the command line, where possible.
- **`tecnativa/docker-socket-proxy`** (digest-pinned, `mem_limit 32m`):
  - Mounts `/var/run/docker.sock:ro`. Network `socket` only. No ports published.
  - Env: `CONTAINERS=1`, `EVENTS=1`, `INFO=1`, `PING=1`, `VERSION=1`, `ALLOW_START=1`, `ALLOW_STOP=1`, **`POST=0`** (blocks container create/exec, i.e. no host takeover).
- **`sablierapp/sablier`** (`mem_limit 32m`):
  - Provider docker with `DOCKER_HOST=tcp://docker-socket-proxy:2375`. Networks `socket` + `edge`. **No socket mount.**
  - If Sablier logs 403s from the proxy, enable only the specific extra section it needs and note it in an ADR.
  - Its API (port 10000) is reachable only by Caddy on `edge` and is never routed publicly.
  - Configure the Caddy sablier directive with a `dynamic` strategy (loading theme page) for sleeping apps.
- **Done when:**
  - From the server: `ss -tlnp | grep -E '5432|6379'` shows only `127.0.0.1`.
  - From your laptop over the SSH tunnel: `psql -h 127.0.0.1 -U karan_ro portfolio` works, and `INSERT` fails as `karan_ro`.
  - Role `portfolio` cannot `\c` another project's db.
  - `redis-cli --user portfolio` cannot `GET otherapp:x`.
  - `docker exec sablier wget -qO- http://docker-socket-proxy:2375/containers/create` is refused.

### Task 12 — Reusable app deploy (`reusable-deploy-app.yml`, `workflow_call`)
- Inputs: `app_name`, `subdomain`, `compose_file`, `image`. Secrets are inherited.
- Steps: native-runner arm64 buildx → GHCR → cosign sign → Trivy → Tailscale → rsync the compose file to `/opt/apps/<app_name>/` → `docker compose up -d`.
- Each app's compose file uses network `edge` (+ `data` if it needs a DB), sets a `mem_limit`, and carries labels `sablier.enable=true`, `sablier.group=<app_name>`.
- **Apps never publish ports** (Caddy reaches them over `edge`) and never mount the Docker socket. They get their own DB/Redis credentials only, through their own `.env`. The reusable workflow rejects any compose file with `ports:` or `docker.sock`, using a simple `grep` check before deploy.
- Routing: add a `@<app> host <subdomain>.{$DOMAIN}` block in the Caddyfile (one PR in this repo per new app, which serves as the audit trail).
- Document "onboarding a new project" in the README.

---

## PHASE 3 — Operations (backups, observability, status, drift)

### Task 13 — Backups + restore drill
- `platform/backup/backup.sh` (`set -euo pipefail`):
  1. `curl hc-ping …/backup-nightly/start`.
  2. `docker exec postgres pg_dumpall -U postgres | restic backup --stdin --stdin-filename pg_dumpall.sql --tag nightly`.
  3. `restic backup /var/lib/docker/volumes/*_app_* --tag volumes` (only if such volumes exist).
  4. `restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
  5. `restic check --read-data-subset=2%`.
  6. Ping success. On error, a trap pings `/fail`.
- `backup/.env` (`chmod 600`, owner deployer, rendered at deploy time) holds `RESTIC_REPOSITORY=s3:https://<acct>.r2.cloudflarestorage.com/project-infra-backups`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (the `R2_BACKUP_*` pair) and `HC_PING_KEY`.
- First run: `ssh deployer@core-01 'set -a; . /opt/platform/backup/.env; restic init'`. The script should run `restic cat config || restic init` to make this idempotent.
- `restore-drill.yml` (cron `0 4 1 * *` + dispatch):
  1. Install restic.
  2. Start a `postgres:16` service container.
  3. `restic dump latest pg_dumpall.sql | psql`.
  4. Sanity checks: `\l` lists each project db, and a row count on a known table is above 0 once the portfolio has data.
  5. Ping `restore-drill` on success or `/fail` on failure.
  6. Write the result to the job summary.
- Document in `docs/runbook.md`: full restore onto a fresh server (apply → deploy → `restic restore` → `psql`), and RPO 24 h / RTO target 30 min.

### Task 14 — Observability (Grafana Cloud + Alloy)
- Add `grafana/alloy` (digest-pinned) to compose:
  - `mem_limit 256m`. Mounts: `/proc`, `/sys`, `/` (all ro, for the node exporter), `/var/log/journal` (ro). **No Docker socket:** set `docker_host = "tcp://docker-socket-proxy:2375"` in `discovery.docker`, `loki.source.docker` and the cadvisor exporter. Networks `socket` + a normal outbound network (for pushing to Grafana Cloud). No ports published.
  - Drop secrets from logs: add a `loki.process` stage with `stage.replace` that masks `password=…`, `Authorization: …` and `tskey-…` patterns before shipping.
- `alloy/config.alloy`:
  - `prometheus.exporter.unix` + `prometheus.exporter.cadvisor`, with `docker_only = true` and a relabel that drops `id`/`name` high-cardinality labels and keeps only the `container_memory_*`, `container_cpu_usage_seconds_total` and `container_network_*` metric families.
  - `prometheus.scrape` → `prometheus.remote_write` (Grafana Cloud URL + basic auth from env).
  - `discovery.docker` + `loki.source.docker` and `loki.source.journal` → `loki.write`.
  - Scrape interval 60 s.
- In Grafana Cloud (manual, then export the JSON into `docs/grafana/` so it's versioned):
  - Import the "Node Exporter Full" dashboard and a container dashboard.
  - Alerts: memory above 85% for 10 min, swap used above 1 GB, disk above 80%, a container restarting more than 3 times in 15 min, and the Caddy target down.
  - Use the email contact point.
- Verify that active series stay under 10k (Grafana Cloud → Usage).

### Task 15 — Status page (Upptime, separate repo)
- `gh repo create <user>/status --public --template upptime/upptime`.
- Edit `.upptimerc.yml`:
  - Sites: `https://<domain>` and each `app.<domain>`.
  - `status-website.cname: status.<domain>`.
- Enable Pages from the `gh-pages` branch. The DNS record already exists from Task 5.
- Add the Upptime badge to the project-infra README.

### Task 16 — Drift detection (`drift.yml`)
- Cron `0 5 * * *` + dispatch. Use the same env as terraform.yml.
- Run `terraform plan -detailed-exitcode -lock-timeout=5m`:
  - Exit 2: run `leak_check.sh` on the plan text, then create or update a single open issue labelled `drift` with the **plan summary** in `<details>` (resource lines + `Plan:` totals only; the full plan goes to a 7-day artifact) (`gh issue list --label drift --state open` → edit, else create).
  - Exit 0: close any open drift issue with a comment.
  - Exit 1: fail the job.
- Permissions: `issues: write`.

---

## PHASE 4 — Docs as showcase

### Task 17 — Documentation polish
- README:
  - One-paragraph pitch, then a **mermaid** architecture diagram (user → Cloudflare → Hetzner FW → Caddy → apps/data; CI → Tailscale → server; backups → R2; Alloy → Grafana Cloud; Upptime → GitHub Pages).
  - A cost table generated from `plan_guard.py` output.
  - Badges, a "how a change reaches production" sequence diagram, the RAM budget table, and a security section (perimeter, no public SSH, signed images, least-privilege tokens).
  - A **"What I'd do at scale"** section: k3s/Kubernetes + Argo CD, multi-node with Hetzner private network + load balancer, managed Postgres with PITR, Vault/External Secrets, OpenTelemetry tracing, policy-as-code (OPA/conftest), multi-region DNS failover.
- `docs/runbook.md` must have an **"Accessing data"** section:
  - `~/.ssh/config` entry:
    ```
    Host core-01
      User karan
      IdentityFile ~/.ssh/id_ed25519
      LocalForward 5432 127.0.0.1:5432
      LocalForward 6379 127.0.0.1:6379
    ```
    `ssh -N core-01` then opens both tunnels.
  - CLI: `ssh core-01 docker exec -it postgres psql -U karan_ro portfolio`, and `ssh core-01 docker exec -it redis redis-cli --user admin --askpass`.
  - GUI on Windows: DBeaver/pgAdmin and Redis Insight using their built-in **SSH tunnel** option (host `core-01`, user `karan`, key file) to `127.0.0.1:5432` / `127.0.0.1:6379`. Use `karan_ro` by default and the superuser only for migrations/fixes.
  - Logs/metrics: Grafana Cloud. Live: `ssh core-01 docker logs -f <svc>` / `docker stats`.
  - Rotating a DB password: update the GitHub secret, then re-run deploy-platform (the init script runs `ALTER ROLE`), then redeploy the app.
- `docs/runbook.md` also covers: rebuild server, break-glass access (`ssh_public_access=true` PR, or Hetzner console + admin password), rotate each secret, restore from backup, OOM investigation (`journalctl -k | grep -i oom`, `docker stats`), and the cert renewal path.
- `SECURITY.md`: what is public vs secret (table), the threat model (internet → Cloudflare → origin; compromised app container; leaked CI log; stolen laptop), the controls for each, and how to report issues. ADRs complete (0001–0014, including "socket proxy" and "loopback-only data access").

---

## Verification (end-to-end)
1. A PR touching `terraform/` makes `lint` + `plan` pass, and the sticky comment shows the plan + a cost of about €6.49 (under €7). A PR that changes `server_type` to `cax21` fails the cost check (an in-place resize, but over budget). A PR that changes `location` to `nbg1` fails the replacement check with `hcloud_server.main` listed as a replace. Adding the `allow-replace` label re-runs the check and it passes the guard. Close that PR without merging.
2. Merge, approve `production`, and apply creates the server, IPs, firewall, DNS, WAF, analytics, R2 bucket and Tailscale ACL/key.
3. `ssh karan@core-01` works over Tailscale, and `ssh karan@<public-ip>` times out. `free -h` shows 4G swap, `/proc/sys/vm/swappiness` returns 10, and `docker run --rm hello-world` works as deployer.
4. `docker buildx imagetools inspect ghcr.io/<owner>/caddy-cloudflare:latest` lists `linux/arm64` + `linux/amd64`, `cosign verify` passes, and Trivy results appear in the Security tab.
5. deploy-platform: `curl -sI https://<domain>` returns 200 with `server: cloudflare`, while a direct `curl -k https://<ipv4>` times out.
6. `curl https://<domain>/.env` returns 403 (blocked by WAF).
7. `sudo systemctl start backup.service` succeeds, a snapshot is visible with `restic snapshots`, and healthchecks.io goes green. A manual restore-drill run passes.
8. Grafana Cloud shows host + container metrics and Caddy logs. A test alert reaches email.
9. `status.<domain>` loads over HTTPS.
10. Making a manual change in the Cloudflare dashboard opens a `drift` issue the next night, and reverting the change closes it.
11. A no-op PR shows "No changes" (idempotent, no server replacement).
12. **Public-repo leak test:**
    - Search the first apply's Actions log and the PR comment for `tskey-`, `$6$` and `hc-ping.com/`: **no hits**. The rendered cloud-init shows as `(sensitive value)`.
    - A test PR that adds `output "x" { value = var.admin_password_hash }` without `sensitive` fails `validate`. Terraform refuses to output a sensitive value without the flag.
13. **Data plane isolation:**
    - From outside, `nc -vz <ipv4> 5432` and `6379` time out.
    - From the laptop over the SSH tunnel, `karan_ro` reads but can't write.
    - Cross-project DB and Redis access is denied.
    - A container can't reach `169.254.169.254`.
    - Sablier can't create containers through the socket proxy.

## Rules for the executing model
- Never commit secrets, `.env`, `users.acl`, `*.tfstate` or `tfplan`. Never print secrets in workflow logs, PR comments or issues; this repo is **public**. Never run `terraform apply` locally; CI owns apply.
- Pin every Action by SHA (Renovate updates them) and every image by digest in compose.
- If a provider attribute or Action input fails validation, look it up in the official docs for the pinned version. Do not guess.
- Work task by task, one PR per task, and keep CI green before moving on.
- **Stop and ask the human** for: the domain and IDs, confirmation that the manual prerequisites are done, anything in the Grafana/Tailscale/Upptime web UIs, and before deleting the old server or any resource with data.
