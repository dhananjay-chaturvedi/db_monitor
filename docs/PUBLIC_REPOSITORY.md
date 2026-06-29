# Publishing DB Monitor to a Public Git Repository

This guide describes how to prepare, publish, and maintain **DB Monitor** as an open-source project on GitHub, GitLab, or any public git host.

## What you are publishing

DB Monitor is a **bash-based database resource monitoring system** with:

- Cloud metrics for **AWS RDS/Aurora** and **GCP Cloud SQL**
- **OS metrics** (local and SSH hosts)
- **DB connectivity** checks for on-prem and cloud endpoints
- **Threshold evaluation** with sustained-breach windows
- **Alert delivery** via Microsoft Teams and SMTP email

The repository is structured as a **monorepo** with shared `common/` code and separate `aws/` and `gcp/` provider trees. Consumers deploy only the provider they need.

---

## Pre-publish checklist

Complete these steps **before** pushing to a public remote.

### 1. Remove or exclude secrets and environment-specific data

Never commit:

| Item | Why |
|------|-----|
| `.dbmonitor/` | Runtime logs, PID files, encrypted secrets, `connections.tsv`, `ssh_hosts.tsv` |
| Live `config.ini`, `properties.ini`, `metrics_and_thresholds.ini` | May contain SMTP hosts, email addresses, tuned thresholds |
| `configs/instances/*.ini` (except `example.instance.ini.example`) | Per-environment instance names and overrides |
| `push_to_remote.sh` | Developer deploy script; may contain host credentials |
| Cloud access keys, service account JSON, private keys | Use IAM roles / ADC at runtime instead |

The root [`.gitignore`](../.gitignore) excludes these paths by default. Verify with:

```bash
git status
git diff --cached
```

Run a secret scan before the first public push:

```bash
# ripgrep examples (adjust patterns as needed)
rg -i 'password\s*=\s*[^<\s]' --glob '!*.default' --glob '!.git'
rg -i 'AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH) PRIVATE KEY' .
```

### 2. Confirm only safe examples remain in docs

Documentation and CLI help should use placeholders:

- Passwords: `<PASSWORD>`
- Emails: `*@invalid.example`
- Hosts: `db.example.com` or `smtp.example.com`

### 3. Add license and README

This repository includes:

- [`LICENSE`](../LICENSE) — MIT License
- [`README.md`](../README.md) — project overview for visitors and package indexes

Update the copyright name in `LICENSE` if needed.

### 4. Choose a repository name

Suggested public names:

- `db-monitor`
- `dbx-monitor`
- `bash-db-monitor`

Keep the name short, lowercase, and hyphenated for GitHub compatibility.

---

## Initializing the git repository

From the project root:

```bash
cd /path/to/db-monitor

# Initialize (skip if already a git repo)
git init

# Review what will be tracked
git add -n .

# Stage tracked files (respects .gitignore)
git add .

# First commit
git commit -m "$(cat <<'EOF'
Initial public release of DB Monitor.

Bash-based cloud and on-prem database resource monitoring with
threshold alerts and Teams/SMTP notifications.
EOF
)"
```

---

## Creating the remote repository

### GitHub

1. Create a new repository on GitHub (public, **without** initializing README/license if you already have them locally).
2. Add the remote and push:

```bash
git remote add origin https://github.com/<your-org>/db-monitor.git
git branch -M main
git push -u origin main
```

Or with SSH:

```bash
git remote add origin git@github.com:<your-org>/db-monitor.git
git branch -M main
git push -u origin main
```

### GitLab / other hosts

Same flow — create an empty public project, add `origin`, push `main`.

---

## Recommended repository settings

### Branch protection (GitHub)

- Require pull request reviews before merging to `main`
- Require status checks if you add CI later
- Disallow force-push to `main`

### Repository topics (GitHub)

Add topics to improve discoverability:

```
database-monitoring, aws-rds, gcp-cloud-sql, bash, cloudwatch,
alerting, devops, sre, monitoring, aurora, postgresql, mysql
```

### About section

Short description:

> Bash monitoring for cloud and on-prem database resources with threshold alerts and Teams/SMTP notifications.

### Security

- Enable **Dependabot** or equivalent if you add GitHub Actions later
- Enable **secret scanning** (GitHub) for pushed credentials
- Add a `SECURITY.md` policy if you accept external reports (optional)

---

## What to commit vs. what stays local

| Commit to git | Keep local only |
|---------------|-----------------|
| `*.ini.default` templates | `*.ini` live files |
| `example.instance.ini.example` | `configs/instances/<real-id>.ini` |
| `common/lib/`, `aws/lib/`, `gcp/lib/` | `.dbmonitor/` |
| `docs/`, `README.md`, `LICENSE` | Encrypted secrets under `.dbmonitor/secrets/` |
| `installer/install.sh` | `push_to_remote.sh` (if it contains credentials) |
| Test scripts under `aws/tests/`, `gcp/tests/` | Local e2e credentials / instance IDs |

---

## Installing from a public clone

Users clone and install:

```bash
git clone https://github.com/<your-org>/db-monitor.git
cd db-monitor
bash installer/install.sh
```

Install creates `.dbmonitor/` and copies default configs when live files are missing. Users then:

1. Configure cloud authentication (IAM role on EC2, ADC on GCE, or `aws configure` / `gcloud auth`)
2. Add instances: `bash aws/monitor.sh instances add ...` or GCP equivalent
3. Set notification credentials: `bash monitor.sh notify config set ...`
4. Start the daemon: `bash monitor.sh daemon start`

---

## Versioning and releases

The current version is stored in [`VERSION`](../VERSION).

For tagged releases:

```bash
VERSION=$(cat VERSION)
git tag -a "v${VERSION}" -m "Release v${VERSION}"
git push origin "v${VERSION}"
```

On GitHub, create a **Release** from the tag and attach optional `tar.gz` artifacts. Users can also install directly from `main` for bleeding-edge changes.

---

## Continuous integration (optional)

No CI is required for the project to function. If you add it later, useful checks:

```bash
# Syntax-check all shell scripts
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n

# Validate threshold catalog structure
bash aws/tests/validate_thresholds_catalog.sh aws/configs/metrics_and_thresholds.ini.default
bash gcp/tests/validate_thresholds_catalog.sh gcp/configs/metrics_and_thresholds.ini.default
```

Cloud API e2e tests (`aws/tests/e2e_test.sh`, `gcp/tests/e2e_test.sh`) need live credentials and instances — run them manually or in a private CI environment, not as required public PR gates unless you provide test infrastructure.

---

## Maintaining a public fork or downstream copy

When pulling upstream changes:

```bash
git fetch upstream
git merge upstream/main
```

Preserve local-only files via `.gitignore`. After merging, re-run install if new dependencies were added:

```bash
bash installer/install.sh
```

---

## Legal and attribution

- The project is distributed under the **MIT License** — see [`LICENSE`](../LICENSE).
- Third-party tools (AWS CLI, gcloud, openssl, etc.) have their own licenses.
- Do not embed proprietary metric catalog data or internal hostnames in committed files.

---

## Quick reference commands

```bash
# Pre-push verification
git status
bash -n aws/monitor.sh gcp/monitor.sh
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n

# Publish
git remote add origin <url>
git push -u origin main

# Tag release
git tag -a "v$(cat VERSION)" -m "Release v$(cat VERSION)"
git push origin --tags
```

For day-to-day usage after cloning, see [README.md](../README.md) and provider-specific `HOWTOUSE.txt` files.
