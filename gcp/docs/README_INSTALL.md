# Monitoring Daemon — Install Guide (GCP)

**Version:** 1.0.0  
**Runtime:** pure bash + gcloud CLI + openssl (no Python required)

## Quick install

```bash
bash installer/install.sh
```

Run as a user with `sudo` (or as root) so missing OS packages can be installed automatically.

Optional: also install MySQL and PostgreSQL clients for DB connectivity checks:

```bash
INSTALL_DB_CLIENTS=1 bash installer/install.sh
```

Skip OS package installation (verify-only, useful on locked-down hosts):

```bash
INSTALL_PACKAGES=0 bash installer/install.sh
```

## What install.sh does

1. **OS packages** (apt / yum / dnf when available and `INSTALL_PACKAGES=1`)
2. **gcloud CLI** — checks if `gcloud` is on PATH; installs Google Cloud SDK if missing
3. **Secret encryption** — uses perl `Digest::SHA`; compiles `lib/secrets_pbkdf2` if needed
4. **Runtime dirs** — creates `.dbmonitor/runtime/` and `.dbmonitor/secrets/` (mode 700)
5. **Default configs** — copies `*.ini.default` → live `*.ini` only when missing
6. **Permissions** — marks scripts executable

## Dependencies

### Required (core monitoring)

| Tool | Purpose |
|------|---------|
| bash, awk, grep, sed | Script runtime |
| ssh | SSH host OS metrics |
| wget | gcloud SDK download, HTTP fallback |
| curl | Teams webhooks (recommended; some paths use wget) |
| openssl, xxd | Secret encryption, SMTP TLS |
| perl + Digest::SHA | PBKDF2 key derivation (or compiled `lib/secrets_pbkdf2`) |
| flock | Daemon / poll locking (`util-linux`) |
| column | Metric table display |
| timeout | GCP API budget, Oracle checks (`coreutils` / `util-linux`) |
| df, mktemp, install | OS metrics, temp files |

### Installed automatically (when package manager available)

**Debian / Ubuntu:** `curl`, `wget`, `openssh-client`, `openssl`, `util-linux`, `perl`, `libdigest-sha-perl`, `sshpass`, `msmtp`, plus `xxd` / `column` packages if missing.

**RHEL / CentOS / Fedora:** `curl`, `wget`, `openssh-clients`, `openssl`, `util-linux`, `perl`, `perl-Digest-SHA`, `sshpass`, plus `vim-common` (xxd) if needed.

With `INSTALL_DB_CLIENTS=1`: `default-mysql-client` + `postgresql-client` (Debian) or `mariadb` + `postgresql` (RHEL family).

### Optional (by feature)

| Tool | When needed |
|------|-------------|
| sshpass | SSH hosts with password auth (`monitor.sh hosts add --password`) |
| mysql | DB checks for MySQL / MariaDB / Cloud SQL MySQL |
| psql | DB checks for PostgreSQL / Cloud SQL PostgreSQL |
| sqlcmd | SQL Server connectivity (install Microsoft tools separately) |
| sqlplus | Oracle connectivity (Instant Client + sqlplus) |
| mongosh | MongoDB connectivity |
| sendmail / msmtp | Local mailer for email alerts |
| gcloud CLI | Cloud Monitoring timeseries + Cloud SQL API (auto-installed) |

### GCP Authentication

The monitor uses **Application Default Credentials (ADC)** for all GCP API calls.

**On a GCE VM (recommended):** Attach a service account with the required IAM roles to the VM instance. ADC is picked up automatically from the instance metadata server — no `gcloud auth login` or key files required.

**On non-GCE hosts:** Run once before starting the daemon:

```bash
gcloud auth application-default login
```

Or set `GOOGLE_APPLICATION_CREDENTIALS` to a downloaded service account JSON key file:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json
```

**Required IAM roles for the service account:**

| Role | Used for |
|------|---------|
| `roles/monitoring.viewer` | Read Cloud Monitoring timeseries |
| `roles/cloudsql.viewer` | Read Cloud SQL instance metadata |

**Minimum custom-role permissions (if not using predefined roles):**

- `monitoring.timeSeries.list`
- `cloudsql.instances.get`, `cloudsql.instances.list`

## Post-install configuration

Edit `configs/config.ini` — key `[monitoring]` switches:

```ini
collect_os_metrics       = true   # master OS switch (daemon / run_monitor)
collect_localhost_os     = true   # local /proc metrics
collect_ssh_hosts_os     = false  # ssh_hosts.tsv
collect_cloud_metrics    = true   # GCP Cloud Monitoring metrics
collect_db_metrics       = true   # connections.tsv DB checks
```

One-shot `monitor.sh monitor` / `os` / `cloud` ignores these flags and always runs the requested source.

## Launching

```bash
bash monitor.sh daemon start
bash monitor.sh monitor --source all --instance YOUR_CLOUD_SQL_INSTANCE_ID
bash monitor.sh db list
bash monitor.sh hosts list
```

Or via the top-level dispatcher (from the project root):

```bash
bash /path/to/dbx_monitor/monitor.sh gcp daemon start
bash /path/to/dbx_monitor/monitor.sh gcp instances list
```

## Uninstalling

```bash
bash installer/uninstall.sh
# or
bash monitor.sh uninstall
```

Options:

- `--yes` — no confirmation prompt
- `--keep-config` — stop agents only; keep `.dbmonitor/`

**Removed:** `.dbmonitor/` (secrets, logs, state), `alerts.log`  
**Not removed:** script bundle, `configs/*.ini`, OS packages, gcloud SDK

To restore runtime directories after uninstall:

```bash
bash installer/install.sh
```

## Bundle layout

| Path | Role |
|------|------|
| `monitor.sh` | CLI entry point |
| `daemon.sh` | Background polling loop |
| `run_monitor.sh` | Continuous poll for explicit instance list |
| `stop_monitor.sh` | Stop run_monitor.sh sessions and individual loops |
| `common/lib/` | Shared collectors, thresholds, alerts, secrets, notify |
| `gcp/lib/gcp.sh` | Cloud Monitoring timeseries fetch via gcloud |
| `gcp/lib/instances.sh` | Cloud SQL instance registry |
| `setup/` | Threshold catalog generators (optional) |
| `configs/` | `config.ini`, `metrics_and_thresholds.ini`, `properties.ini` |
| `.dbmonitor/` | Runtime data (created on install) |

See [HOWTOUSE.txt](HOWTOUSE.txt) for full documentation.
