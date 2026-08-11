# AGENTS.md — AI Agent Guide

> This file provides orientation for AI coding agents (Antigravity/AGY, Cursor, OpenCode, Codex,
> and similar tools) working in this repository. Read it before making any changes.

---

## What This Repository Is

This repository is a **production-ready Docker Swarm stack** that runs [GitHub Actions self-hosted runners](https://docs.github.com/en/actions/reference/runners/self-hosted-runners) as ephemeral Docker containers. It is a pure **DevOps/infrastructure project** — there is no application code, no test suite, and no build pipeline of its own. Every file is configuration or shell scripting.

The runner containers:
- Register themselves with GitHub on startup (via REST API token exchange)
- Accept and execute GitHub Actions workflow jobs sent by GitHub
- Deregister themselves cleanly on shutdown (SIGTERM)
- Are designed to be **ephemeral** — each container runs exactly one CI job, then exits so Docker Swarm can restart it fresh

---

## Repository Structure

```
github-self-hosted-runners/
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.yml    # GitHub issue form for bug reports
│   │   └── feature_request.yml # GitHub issue form for feature requests
│   ├── workflows/
│   │   ├── lint.yml          # CI: ShellCheck, Hadolint & Compose validation
│   │   └── publish.yml       # CI/CD: build multi-arch image and publish to GHCR
│   ├── dependabot.yml        # Dependabot configuration for GitHub Actions
│   └── PULL_REQUEST_TEMPLATE.md
├── Dockerfile                # Container image definition
├── entrypoint.sh             # Container startup / lifecycle script
├── docker-compose.yml        # Docker Swarm stack definition
├── manage.sh                 # Operator CLI helper script
├── .env.example              # Environment variable reference (copy → .env)
├── .dockerignore             # Keeps secrets out of the build context
├── .gitignore                # Keeps secrets out of version control
├── AGENTS.md                 # This file
├── LICENSE                   # MIT License
├── README.md                 # Public-facing documentation
└── SECURITY.md               # Vulnerability reporting & security guidelines
```

There are **no package managers**, **no compiled code**, and **no test frameworks** in this repo.

---

## File-by-File Reference

### `.github/workflows/publish.yml`
The CI/CD pipeline. Triggered by:
- Push to `main` → builds and pushes `ghcr.io/OWNER/github-runner:latest`
- Push of a `v*.*.*` tag → pushes semver tags (`2.325.0`, `2.325`, `2`) and `latest`
- Pull request → build-only (validates Dockerfile, no push)

**Architecture:** Uses a 2-job pattern — `build` runs once per platform (`linux/amd64`, `linux/arm64`) in parallel, uploads image digests as artifacts; `merge` assembles them into a single multi-arch manifest. The final image is signed with Cosign (keyless, OIDC-based).

**Key variable**: `RUNNER_VERSION` in the `build-args` block must be kept in sync with `ARG RUNNER_VERSION` in the Dockerfile.

When modifying `publish.yml`:
- Do not change `permissions` — `id-token: write` is required for Cosign signing
- Do not remove the `concurrency` block — it prevents redundant builds
- Test changes in a fork before merging to main


---

## File-by-File Reference

### `Dockerfile`
- **Base image**: `ubuntu:22.04` (pinned LTS — do not change to `latest`)
- **Build arg**: `RUNNER_VERSION` (default `2.325.0`) — controls which GitHub runner binary is downloaded from [actions/runner releases](https://github.com/actions/runner/releases)
- **Key layers** (in order):
  1. System apt packages (curl, git, jq, build-essential, python3, etc.)
  2. Docker CE CLI + buildx + compose plugin (from Docker's official apt repo — **not** Ubuntu's)
  3. Non-root `runner` user (UID 1001, member of `docker` group GID 999)
  4. GitHub Actions runner binary downloaded and extracted to `/home/runner/`
  5. `entrypoint.sh` copied to `/entrypoint.sh`
- **No CMD** — only `ENTRYPOINT ["/entrypoint.sh"]`
- **Working directory**: `/home/runner` (contains `config.sh`, `run.sh`, `bin/`, etc.)

When modifying the Dockerfile, always:
- Keep apt installs in a single `RUN` layer per logical group and clean `apt lists` at the end
- Never add secrets or credentials to any layer
- Test that `runner` user (not root) can still access everything it needs

### `entrypoint.sh`
The most complex file. Written in `bash` with `set -euo pipefail`. It has five responsibilities executed in strict order:

1. **Validate** `GITHUB_URL` is set (hard exit if not)
2. **Configure proxy** — writes `https_proxy`, `http_proxy`, `no_proxy` to `/home/runner/.env` (the runner reads this file before connecting to GitHub; this is the mechanism specified by GitHub docs)
3. **Resolve a registration token** via a 4-level priority chain:
   - `/run/secrets/runner_token` (Docker Swarm secret — raw token)
   - `/run/secrets/github_pat` (Docker Swarm secret — PAT → auto-generates token via GitHub REST API)
   - `RUNNER_TOKEN` env var (raw token, dev only)
   - `GITHUB_PAT` env var (PAT, less secure)
4. **Register** the runner with `config.sh --unattended --disableupdate [--ephemeral]`
5. **Run** `run.sh` in the background, trap `SIGTERM`/`SIGINT`/`SIGQUIT` → call `cleanup()` which gracefully deregisters before exit

Key functions:
- `generate_token_from_pat()` — calls `POST /repos/{owner}/{repo}/actions/runners/registration-token` or the org equivalent; detects scope from path depth of `GITHUB_URL`
- `resolve_registration_token()` — implements the 4-level priority chain
- `configure_proxy()` — writes the runner `.env` file
- `cleanup()` — the SIGTERM handler; waits up to 30s for `run.sh` to finish a step, then deregisters

When modifying `entrypoint.sh`:
- Never log the token value — logs are visible in `docker service logs`
- Preserve the `trap` before any blocking call
- Use `log()` / `warn()` / `err()` helpers (not bare `echo`) so timestamps are consistent
- Run `bash -n entrypoint.sh` to syntax-check after edits

### `docker-compose.yml`
- **Schema version**: `3.8` — required for `deploy`, `secrets`, `rollback_config` in Swarm mode
- **One service**: `github-runner`
- **Secrets block**: `github_pat` marked `external: true` (must be pre-created with `docker secret create`)
- **Volumes**: bind-mounts `/var/run/docker.sock` for Docker-out-of-Docker (DooD)
- **Deploy block** contains:
  - `replicas: ${RUNNER_REPLICAS:-1}` — scalable
  - `restart_policy: condition: on-failure` — Swarm restarts crashed or job-completed ephemeral runners
  - `update_config: order: start-first` — zero-downtime rolling updates
  - `rollback_config` — auto-rollback on failed updates
  - `resources.limits`: 1 CPU, 1 GiB RAM per replica
  - `healthcheck`: `pgrep -f run.sh` every 30s
- **Network**: overlay (attachable) for multi-node Swarm

When modifying `docker-compose.yml`, validate with:
```bash
GITHUB_URL=https://github.com/test/repo docker compose -f docker-compose.yml config --quiet
GITHUB_URL=https://github.com/test/repo docker stack config -c docker-compose.yml
```

### `.env.example`
Documents every variable the stack accepts. Copy to `.env` before deploying. The `.env` file is gitignored and must never be committed.

### `.dockerignore`
Excludes `.env`, `secrets/`, `*.pem`, `*.key`, `*.md`, `.git` from the Docker build context. Always keep secrets-related patterns here.

### `.gitignore`
Excludes `.env`, `secrets/`, and key/token files. If adding new secret file patterns, add them here too.

---

## Environment Variables

| Variable | Required | Default | Source |
|---|---|---|---|
| `GITHUB_URL` | **Yes** | — | `.env` / shell |
| `RUNNER_IMAGE` | No | `github-runner:latest` | `.env` |
| `RUNNER_LABELS` | No | `self-hosted,linux,x64` | `.env` |
| `RUNNER_GROUP` | No | `Default` | `.env` |
| `RUNNER_EPHEMERAL` | No | `true` | `.env` |
| `RUNNER_REPLICAS` | No | `1` | `.env` |
| `RUNNER_TOKEN` | No* | — | env var (dev only) |
| `GITHUB_PAT` | No* | — | env var (prefer secret) |
| `HTTPS_PROXY` | No | — | `.env` |
| `HTTP_PROXY` | No | — | `.env` |
| `NO_PROXY` | No | — | `.env` |

*At least one token source must be present (secret or env var).

---

## Secrets

The canonical approach is a **Docker Swarm external secret** named `github_pat`:

```bash
echo "ghp_yourtoken" | docker secret create github_pat -
```

Inside containers, secrets are available as files at `/run/secrets/<name>`. They are **never** present in environment variables, image layers, or `docker inspect` output.

For local development without Swarm, switch the secret to file-based by editing `docker-compose.yml`:
```yaml
secrets:
  github_pat:
    file: ./secrets/github_pat.txt   # gitignored
```

---

## Common Tasks for Agents

### Upgrade the runner binary version
Edit `Dockerfile`, change the `ARG RUNNER_VERSION` value:
```dockerfile
ARG RUNNER_VERSION="2.326.0"   # check: https://github.com/actions/runner/releases
```
Then rebuild: `docker build -t github-runner:latest .`

### Add a new apt package to the runner image
Add the package name to the existing `apt-get install` block in `Dockerfile` (first `RUN` layer). Keep alphabetical order within each comment group. Do not create a new `RUN apt-get` layer — consolidate to minimise layers.

### Add a new environment variable
1. Document it in `.env.example` with a comment
2. Add it to the `environment:` block in `docker-compose.yml`
3. Handle it in `entrypoint.sh` with a safe default (`${VAR:-default}`)

### Change resource limits
Edit the `resources` block under `deploy` in `docker-compose.yml`. Then redeploy:
```bash
docker stack deploy -c docker-compose.yml runner
```

### Change the number of replicas at runtime
```bash
docker service scale runner_github-runner=4
```
No file edit needed — Swarm handles this dynamically.

### Add support for a new token source (e.g. Vault)
Extend `resolve_registration_token()` in `entrypoint.sh`. Add your new source as priority #3 (before env vars). Document it in the function's comment block at the top of the file.

### Switch from ephemeral to persistent runners
Set `RUNNER_EPHEMERAL=false` in `.env`. Be aware:
- Persistent runners accumulate state between jobs (tool caches, temp files)
- GitHub does not guarantee job isolation — use only with trusted workflows

---

## Constraints and Rules

- **No root**: The runner process must always run as the `runner` user (UID 1001). The GitHub runner binary refuses to start as root. Do not change `USER runner` in the Dockerfile.
- **No secrets in env or layers**: All sensitive values (PATs, tokens) must flow through Docker secrets (`/run/secrets/`) or be passed at runtime — never baked into the image.
- **No auto-update**: `--disableupdate` is passed to `config.sh` intentionally. Runner upgrades happen via image rebuilds, not in-container auto-updates.
- **No `latest` base image**: The `FROM ubuntu:22.04` tag is intentionally pinned. Do not change to `ubuntu:latest` — it would break reproducibility.
- **Preserve signal handling**: The `trap` in `entrypoint.sh` is safety-critical. Any change that moves blocking operations before the `trap` statement will break graceful deregistration.
- **Compose version 3.8 is required**: Do not remove `version: "3.8"` — it is needed by `docker stack deploy` even though `docker compose` treats it as obsolete.
- **`NO_PROXY` accepts hostnames only**: GitHub's runner does not support IP addresses or CIDR in `no_proxy`. Do not add IP-based entries.

---

## Validation Commands

Run these after any change to catch regressions:

```bash
# Bash syntax check on entrypoint
bash -n entrypoint.sh

# Dockerfile lint (if hadolint is available)
hadolint Dockerfile

# Compose schema validation (requires GITHUB_URL to pass required-var check)
GITHUB_URL=https://github.com/test/repo docker compose -f docker-compose.yml config --quiet

# Swarm stack validation
GITHUB_URL=https://github.com/test/repo docker stack config -c docker-compose.yml

# Full build (confirms all download URLs are still valid)
docker build -t github-runner:test .

# Verify non-root user and required binaries exist in the built image
docker run --rm github-runner:test bash -c "
  whoami | grep -q runner || (echo 'FAIL: not runner user' && exit 1)
  for bin in curl jq git docker config.sh run.sh; do
    command -v \$bin 2>/dev/null || ls /home/runner/\$bin 2>/dev/null \
      || (echo \"FAIL: \$bin not found\" && exit 1)
    echo \"OK: \$bin\"
  done
"
```

---

## What This Repository Is NOT

- Not an application — there is no `main.go`, `index.js`, `app.py`, etc.
- Not a library — nothing is published to a package registry
- Not self-contained CI — it *hosts* CI runners for other repositories; it does not have its own GitHub Actions workflows
- Not Kubernetes — this is Docker Swarm only (`deploy` block, `docker stack deploy`). Do not convert to `docker compose up` for production use.
- Not Actions Runner Controller (ARC) — ARC is the Kubernetes equivalent. This project is explicitly for Docker Swarm environments.

---

## External References

- [GitHub Self-Hosted Runners docs](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
- [GitHub Proxy Configuration docs](https://docs.github.com/en/actions/how-tos/manage-runners/use-proxy-servers)
- [actions/runner releases](https://github.com/actions/runner/releases) — check here when bumping `RUNNER_VERSION`
- [Docker Swarm secrets](https://docs.docker.com/engine/swarm/secrets/)
- [Docker Compose v3.8 reference](https://docs.docker.com/compose/compose-file/compose-file-v3/)
