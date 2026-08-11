<div align="center">

# 🏃 GitHub Actions Self-Hosted Runners

**Ephemeral, production-ready GitHub Actions runners on Docker Swarm.**

Deploy a scalable pool of self-hosted runners in minutes. Runners auto-register, execute one job each, and self-destruct — keeping your CI environment clean and your secrets safe.

[![Build & Publish](https://github.com/miguelenes/github-self-hosted-runners/actions/workflows/publish.yml/badge.svg)](https://github.com/miguelenes/github-self-hosted-runners/actions/workflows/publish.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-github--runner:edge-blue?logo=docker)](https://ghcr.io/miguelenes/github-runner)
[![Ubuntu 24.04](https://img.shields.io/badge/base-ubuntu%3A24.04-E95420?logo=ubuntu&logoColor=white)](https://hub.docker.com/_/ubuntu)
[![Runner v2.336.0](https://img.shields.io/badge/runner-v2.336.0-2ea44f?logo=github)](https://github.com/actions/runner/releases/tag/v2.336.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

</div>

---

## Why This?

GitHub's hosted runners are convenient but can be expensive at scale, slow for large builds, and unable to access private network resources. Self-hosted runners solve all three — but setting them up cleanly in Docker has sharp edges:

- Raw registration tokens expire after **1 hour** — useless for persistent deployments
- Persistent runners **leak state** between jobs (cached credentials, temp files)
- Containers need **Docker-in-Docker** for CI workflows that build images
- Shutting down a runner incorrectly leaves **zombie entries** in GitHub's UI

This project solves every one of those problems out of the box.

---

## Deploy from GHCR (No Clone)

> Don't want to clone the repo? Deploy directly from the published image.

```bash
# 1. Download only the compose file
curl -O https://raw.githubusercontent.com/miguelenes/github-self-hosted-runners/main/docker-compose.yml

# 2. Create your .env file
cat > .env << 'EOF'
GITHUB_URL=https://github.com/YOUR_ORG_OR_USER/YOUR_REPO
RUNNER_LABELS=self-hosted,linux,x64
RUNNER_REPLICAS=2
RUNNER_IMAGE=ghcr.io/miguelenes/github-runner:edge
EOF

# 3. Store your GitHub PAT as a Docker secret
echo "ghp_yourPersonalAccessTokenHere" | docker secret create github_pat -

# 4. Initialise Swarm (skip if already done)
docker swarm init

# 5. Export variables and deploy
set -o allexport && source .env && set +o allexport
docker stack deploy -c docker-compose.yml runner
```

> [!IMPORTANT]
> `docker stack deploy` does **not** auto-load `.env` files. You must export the variables first (step 5 above) or the `GITHUB_URL` interpolation in `docker-compose.yml` will fail.

**That's it.** Your runners will appear at your [repository runners page](https://github.com/YOUR_ORG_OR_USER/YOUR_REPO/settings/actions/runners) within ~30 seconds.

> [!TIP]
> Replace `miguelenes` in `RUNNER_IMAGE` above with your own GitHub username or org if you've forked this repo and published your own image.

Want the full operator CLI with `./manage.sh` for secret creation, scaling, and log following? See [Option A](#option-a--use-the-operator-cli-recommended) below.

---

## Features

| 🛠️ **Operator CLI** | `./manage.sh` wrapper script for zero-friction deployment, secret creation, scaling, and status checks. |
| 🔄 **Truly ephemeral** | Each runner processes exactly one job, then exits. Swarm brings up a fresh clean replacement automatically. |
| 🔑 **Auto-token generation** | Provide a long-lived PAT once; runners generate fresh registration tokens on every start via the GitHub REST API. |
| 🐳 **Docker-out-of-Docker** | Build and run containers from within your CI jobs by sharing the host Docker socket. |
| 📦 **Multi-arch** | Pre-built images for `linux/amd64` and `linux/arm64`. Pull and run — no local build needed. |
| 🔒 **Secrets-first** | PATs are stored as Docker Swarm secrets — never in environment variables, image layers, or `docker inspect` output. |
| 🌐 **Proxy-aware** | Corporate proxy? Set `HTTPS_PROXY` and the runner configures itself before connecting to GitHub. |
| 🔁 **Zero-downtime updates** | Rolling updates with `start-first` ordering — a new runner registers before the old one is removed. |
| 📈 **Instantly scalable** | `docker service scale runner_github-runner=8` (or `./manage.sh scale 8`) — that's it. |
| ✅ **Signed images** | Every published image is signed with [Cosign](https://docs.sigstore.dev/) for supply-chain verification. |

---

## Quick Start

### Option A — Use the Operator CLI (recommended)

```bash
# 1. Clone and configure
git clone https://github.com/miguelenes/github-self-hosted-runners.git
cd github-self-hosted-runners
cp .env.example .env
nano .env   # Set GITHUB_URL

# 2. Store your GitHub PAT as a Swarm secret
./manage.sh secret-create

# 3. Deploy stack
./manage.sh deploy

# 4. Check status & follow logs
./manage.sh status
./manage.sh logs
```

---

### Option B — Manual deployment

```bash
# 1. Initialise Swarm (skip if already in a Swarm)
docker swarm init

# 2. Store your GitHub PAT as a Docker secret
echo "ghp_yourPersonalAccessTokenHere" | docker secret create github_pat -

# 3. Deploy
export $(grep -v '^#' .env | xargs)
docker stack deploy -c docker-compose.yml runner

# 4. Watch it register
docker service logs runner_github-runner --follow
```

After a few seconds, visit your runner settings page and see the runner appear as **Idle** ✅

- **Repository runners:** `https://github.com/OWNER/REPO/settings/actions/runners`
- **Organisation runners:** `https://github.com/orgs/ORG/settings/actions/runners`

---

### Option C — Build locally

```bash
# Build the image (pin a specific runner version with --build-arg)
docker build -t github-runner:latest .
docker build --build-arg RUNNER_VERSION=2.336.0 -t github-runner:2.336.0 .

# Multi-arch build
docker buildx build --platform linux/amd64,linux/arm64 \
  -t github-runner:latest --push .
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Docker Swarm Cluster                         │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Stack: runner                                                │  │
│  │                                                               │  │
│  │   ┌─────────────────┐        ┌─────────────────┐             │  │
│  │   │  github-runner  │        │  github-runner  │   × N       │  │
│  │   │   replica 1     │  ···   │   replica N     │  replicas   │  │
│  │   │                 │        │                 │             │  │
│  │   │  1. Register    │        │  1. Register    │             │  │
│  │   │  2. Wait        │        │  2. Wait        │             │  │
│  │   │  3. Run job     │        │  3. Run job     │             │  │
│  │   │  4. Deregister  │        │  4. Deregister  │             │  │
│  │   │  5. Exit →      │        │  5. Exit →      │             │  │
│  │   │     Swarm       │        │     Swarm       │             │  │
│  │   │     restarts ↺  │        │     restarts ↺  │             │  │
│  │   └────────┬────────┘        └────────┬────────┘             │  │
│  │            │                          │                       │  │
│  │            └──────────┬───────────────┘                       │  │
│  │                       │  Docker socket (DooD)                 │  │
│  │            ┌──────────▼───────────────┐                       │  │
│  │            │   /var/run/docker.sock   │                       │  │
│  │            │   (host Docker daemon)   │                       │  │
│  │            └──────────────────────────┘                       │  │
│  │                                                               │  │
│  │  🔐 Docker Secret: github_pat (PAT → fresh token per start)  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
└────────────────────────────┬────────────────────────────────────────┘
                             │  HTTPS port 443
                   ┌─────────▼──────────────┐
                   │      GitHub.com        │
                   │   api.github.com       │
                   │   GitHub Actions Jobs  │
                   └────────────────────────┘
```

**Lifecycle of one ephemeral runner:**

1. Container starts → reads PAT from Docker secret at `/run/secrets/github_pat`
2. Calls `POST /repos/{owner}/{repo}/actions/runners/registration-token` → gets a fresh token
3. Runs `config.sh --ephemeral --disableupdate` → runner appears in GitHub as **Idle**
4. GitHub dispatches a job → runner executes it
5. `run.sh` exits with code 0 → `entrypoint.sh` calls `config.sh remove` → runner deregisters cleanly
6. Container exits → Docker Swarm `restart_policy: on-failure` restarts it → goto step 1

---

## Using the Runner in Your Workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64]   # matches default RUNNER_LABELS
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t my-app .     # works! Docker socket is mounted
```

Custom labels (`RUNNER_LABELS=self-hosted,linux,x64,gpu`):

```yaml
    runs-on: [self-hosted, gpu]
```

---

## Configuration

All configuration is provided via environment variables in your `.env` file. See [`.env.example`](.env.example) for the full reference.

| Variable | Required | Default | Description |
|---|---|---|---|
| `GITHUB_URL` | **Yes** | — | Full repo URL (`https://github.com/owner/repo`) or org URL (`https://github.com/owner`) |
| `RUNNER_IMAGE` | No | see `.env.example` | Docker image to pull for the service |
| `RUNNER_LABELS` | No | `self-hosted,linux,x64` | Comma-separated labels for job routing |
| `RUNNER_GROUP` | No | `Default` | Runner group (must exist in GitHub settings) |
| `RUNNER_EPHEMERAL` | No | `true` | Exit after one job (strongly recommended) |
| `RUNNER_REPLICAS` | No | `1` | Number of concurrent runner containers |
| `HTTPS_PROXY` | No | — | Proxy URL for HTTPS traffic |
| `HTTP_PROXY` | No | — | Proxy URL for HTTP traffic |
| `NO_PROXY` | No | — | Comma-separated bypass list (hostnames only) |

> [!NOTE]
> `RUNNER_NAME` is auto-generated per-replica as `runner-<hostname>-<random>` to ensure uniqueness when scaling. Override only for single-replica deployments.

---

## Token Strategies

The entrypoint resolves a registration token from the following sources, in priority order:

### 1. Docker Swarm secret: `github_pat` — Recommended ✅

Store a **long-lived PAT** as a Swarm secret. The runner auto-generates a fresh registration token on every container start. The PAT is never visible in environment variables or logs.

```bash
# Required PAT scopes:
#   Repository-level runners: repo  (or public_repo for public repos)
#   Organisation-level runners: admin:org

echo "ghp_yourPAThere" | docker secret create github_pat -
```

> [!TIP]
> This is the only approach that works reliably at scale with multiple ephemeral replicas. Raw registration tokens expire after ~1 hour and cannot be reused.

### 2. Docker Swarm secret: `runner_token` — For pre-generated tokens

```bash
TOKEN=$(curl -sX POST \
  -H "Authorization: Bearer ghp_yourPAT" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/OWNER/REPO/actions/runners/registration-token \
  | jq -r '.token')

echo "$TOKEN" | docker secret create runner_token -
```

Uncomment the `runner_token` lines in `docker-compose.yml` to use this approach.

### 3 & 4. Environment variables — Development only

```bash
GITHUB_PAT=ghp_yourPAThere    # generates token via API on each start
RUNNER_TOKEN=ABCDEF...         # raw token, expires in ~1 hour
```

> [!WARNING]
> Environment variables are visible via `docker inspect`. Use Docker secrets in any environment beyond local development.

---

## Proxy Configuration

```bash
# In .env
HTTPS_PROXY=http://proxy.example.com:8080
HTTP_PROXY=http://proxy.example.com:8080
NO_PROXY=localhost,127.0.0.1,.internal.example.com

# Authenticated proxies are supported
HTTPS_PROXY=http://username:password@proxy.example.com:8080
```

The entrypoint writes these values to `/home/runner/.env` before starting the runner process — the [mechanism specified by GitHub's proxy documentation](https://docs.github.com/en/actions/how-tos/manage-runners/use-proxy-servers).

> [!WARNING]
> GitHub's runner does not support IP addresses or CIDR ranges in `NO_PROXY`. Use hostnames only.

---

## Scaling

```bash
# Scale to 8 concurrent runners
docker service scale runner_github-runner=8

# Or set replicas in .env before deploying
RUNNER_REPLICAS=8
```

Each replica registers independently as `runner-<hostname>-<random>`, ensuring unique names automatically. GitHub dispatches jobs across all idle runners in the pool.

---

## Updating the Runner Version

The runner version is pinned via the `RUNNER_VERSION` build arg in the Dockerfile. To upgrade:

1. Check the [latest release](https://github.com/actions/runner/releases) on `actions/runner`
2. Update `ARG RUNNER_VERSION` in `Dockerfile`
3. Update `RUNNER_VERSION` in `.github/workflows/publish.yml`
4. Push — the CI workflow builds and publishes the new image automatically
5. Redeploy: `docker stack deploy -c docker-compose.yml runner`

> [!IMPORTANT]
> `--disableupdate` is passed intentionally. Runner upgrades happen via image rebuilds, not in-container auto-updates. You have **30 days** to upgrade after a new runner version is released before GitHub stops dispatching jobs.

---

## Rolling Updates (Zero Downtime)

```bash
# After updating RUNNER_IMAGE in .env
export $(grep -v '^#' .env | xargs)
docker stack deploy -c docker-compose.yml runner
```

Swarm starts a new runner and waits for it to pass the healthcheck before removing the old one (`start-first` update order). No runner capacity is lost during updates.

```bash
# Monitor progress
docker service ps runner_github-runner

# Roll back if needed
docker service rollback runner_github-runner
```

---

## Security

| Area | Approach |
|---|---|
| **Token storage** | Docker Swarm secrets — never in env vars or image layers |
| **Non-root runner** | `runner` user (UID 1001); the GitHub runner binary refuses to start as root |
| **Docker socket** | DooD grants host-equivalent Docker access — restrict to trusted workflows via [runner groups](https://docs.github.com/en/actions/concepts/runners/runner-groups) |
| **Ephemeral isolation** | Each job gets a fresh container; no state carries over between jobs |
| **Image provenance** | Images signed with [Cosign](https://docs.sigstore.dev/) — verify with the command below |
| **No auto-update** | Runner upgrades are explicit and auditable (image rebuild → redeploy) |

### Verify image signature

```bash
cosign verify ghcr.io/miguelenes/github-runner:latest \
  --certificate-identity-regexp "https://github.com/miguelenes/github-self-hosted-runners/.*" \ 
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

### Rotating the PAT

```bash
echo "ghp_newPAT" | docker secret create github_pat_v2 -
# Update docker-compose.yml: secrets.github_pat → secrets.github_pat_v2
docker stack deploy -c docker-compose.yml runner
docker secret rm github_pat   # after verifying runners are healthy
```

---

## Troubleshooting

<details>
<summary><strong>Runners not appearing in GitHub</strong></summary>

```bash
docker service ps runner_github-runner --no-trunc
docker service logs runner_github-runner --follow
```

Common causes:
- `GITHUB_URL` is incorrect or has a trailing slash
- PAT has insufficient scopes (`repo` for repos, `admin:org` for orgs)
- PAT has expired — regenerate and `docker secret rm github_pat && echo "new_pat" | docker secret create github_pat -`
- Network cannot reach `api.github.com` (check proxy settings)
</details>

<details>
<summary><strong>Docker socket permission denied</strong></summary>

The `runner` user inside the container must share a GID with the host's Docker socket group. The image uses GID 999, which is the typical value. Check your host:

```bash
stat -c '%g' /var/run/docker.sock
```

If it's different (e.g. 998 or 1001), edit the `groupadd --gid 999 docker` line in `Dockerfile` to match and rebuild.
</details>

<details>
<summary><strong>Runners appear offline after a redeploy</strong></summary>

This is expected briefly during a rolling update — the old runner deregisters and the new one registers. If runners stay offline for more than ~60 seconds:

```bash
docker service update --force runner_github-runner
```
</details>

<details>
<summary><strong>Proxy not working</strong></summary>

Verify the runner's `.env` file was written correctly:

```bash
# Get a container ID
docker ps --filter name=runner_github-runner

docker exec <container_id> cat /home/runner/.env
```

The file should contain `https_proxy=...` etc. If empty, confirm `HTTPS_PROXY` is set in your `.env` and that you re-exported it before deploying.
</details>

---

## Prerequisites

| Requirement | Version |
|---|---|
| Docker Engine | 20.10+ (Swarm mode enabled) |
| Outbound HTTPS | Port 443 to `github.com`, `api.github.com`, `*.actions.githubusercontent.com` |
| GitHub PAT | `repo` scope (repos) or `admin:org` scope (orgs) |

---

## Contributing

Contributions are welcome! Please read [`AGENTS.md`](AGENTS.md) before making changes — it documents all constraints, validation commands, and common tasks for this repository.

```bash
# After any change, validate with:
bash -n entrypoint.sh
GITHUB_URL=https://github.com/test/repo docker stack config -c docker-compose.yml
```

---

## References

- [GitHub Self-Hosted Runners Reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
- [Using Proxy Servers with Runners](https://docs.github.com/en/actions/how-tos/manage-runners/use-proxy-servers)
- [actions/runner releases](https://github.com/actions/runner/releases)
- [Docker Swarm Secrets](https://docs.docker.com/engine/swarm/secrets/)
- [Cosign Keyless Signing](https://docs.sigstore.dev/cosign/signing/overview/)

---

<div align="center">

Made with ❤️ for teams running GitHub Actions on their own infrastructure.

</div>
