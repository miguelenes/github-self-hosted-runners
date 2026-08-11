# Security Policy

## Supported Versions

Security updates are applied to the `latest` image release on GitHub Container Registry (`ghcr.io`) and the `main` branch of this repository.

| Version / Tag | Supported |
|---|---|
| `main` / `latest` | :white_check_mark: Yes |
| Release tags (`v*.*.*`) | :white_check_mark: Yes (latest release) |
| Older releases | :x: No (please upgrade to latest) |

---

## Reporting a Vulnerability

If you discover a security vulnerability within this repository or container stack, please report it responsibly.

> **DO NOT** create a public GitHub issue for security vulnerabilities.

### How to Report

1. **GitHub Security Advisories (Preferred)**: Submit a private report via **[Security -> Advisories -> Report a vulnerability](https://github.com/YOUR_USERNAME/github-self-hosted-runners/security/advisories/new)**.
2. If GitHub Security Advisories are unavailable, contact the project maintainers via email at `security@example.com`.

### What to Include
- Clear description of the vulnerability
- Step-by-step reproduction instructions or proof-of-concept
- Potential impact of the issue
- Suggested remediation if available

### Response Timeline
- **Acknowledgement**: Within 48 hours
- **Assessment & Status Update**: Within 7 business days
- **Fix Release**: As soon as practicable depending on severity

---

## Security Best Practices for Self-Hosted Runners

### 1. Docker-out-of-Docker (DooD) Socket Access
Mounting `/var/run/docker.sock` inside the runner container gives CI job steps root-equivalent access to the underlying Docker daemon host.
- **Rule**: Only run trusted workflows from trusted branches/forks on self-hosted runners.
- **Mitigation**: Use GitHub **Runner Groups** to restrict runner access to authorized repositories only. Set pull request execution policies in GitHub repository settings to require approval for external contributors.

### 2. Secret Hygiene
- Always store GitHub Personal Access Tokens (PATs) using **Docker Swarm Secrets** (`docker secret create github_pat -`).
- Never embed PATs, registration tokens, or credentials inside environment variables, container image layers, or git repositories.

### 3. Image Verification
All container images published to GHCR from this repository are signed using [Cosign](https://docs.sigstore.dev/) OIDC keyless signatures. You can verify image authenticity prior to deployment:

```bash
cosign verify ghcr.io/YOUR_USERNAME/github-runner:latest \
  --certificate-identity-regexp "https://github.com/YOUR_USERNAME/github-self-hosted-runners/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```
