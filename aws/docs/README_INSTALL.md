# Monitoring Daemon — Install Guide

**Version:** 1.0.0  
**Runtime:** pure bash + AWS CLI + openssl (no Python required)

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
2. **AWS CLI v2** — downloaded and installed if `aws` is not on PATH
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
| wget | AWS CLI install, HTTP fallback |
| curl | Teams webhooks (recommended; some paths use wget) |
| openssl, xxd | Secret encryption, SMTP TLS |
| perl + Digest::SHA | PBKDF2 key derivation (or compiled `lib/secrets_pbkdf2`) |
| flock | Daemon / poll locking (`util-linux`) |
| column | Metric table display |
| timeout | AWS API budget, Oracle checks (`coreutils` / `util-linux`) |
| unzip | AWS CLI v2 installer |
| df, mktemp, install | OS metrics, temp files |

### Installed automatically (when package manager available)

**Debian / Ubuntu:** `curl`, `wget`, `openssh-client`, `openssl`, `unzip`, `util-linux`, `perl`, `libdigest-sha-perl`, `sshpass`, `msmtp`, plus `xxd` / `column` packages if missing.

**RHEL / Amazon Linux / Fedora:** `curl`, `wget`, `openssh-clients`, `openssl`, `unzip`, `util-linux`, `perl`, `perl-Digest-SHA`, `sshpass`, plus `vim-common` (xxd) if needed.

With `INSTALL_DB_CLIENTS=1`: `default-mysql-client` + `postgresql-client` (Debian) or `mariadb` + `postgresql` (RHEL family).

### Optional (by feature)

| Tool | When needed |
|------|-------------|
| sshpass | SSH hosts with password auth (`monitor.sh hosts add --password`) |
| mysql | DB checks for MySQL / MariaDB / Aurora MySQL |
| psql | DB checks for PostgreSQL / Aurora PostgreSQL |
| sqlcmd | SQL Server connectivity (install Microsoft tools separately) |
| sqlplus | Oracle connectivity (Instant Client + sqlplus) |
| mongosh | MongoDB connectivity |
| sendmail / msmtp | Local mailer for email alerts |
| aws CLI v2 | CloudWatch, RDS, PI, DB Insights (auto-installed) |

### AWS IAM (EC2 instance role)

Attach a role with at least:

- `cloudwatch:GetMetricStatistics`
- `rds:DescribeDBInstances`, `rds:DescribeDBLogFiles`, `rds:DownloadDBLogFilePortion`
- `pi:GetResourceMetrics` (Performance Insights)
- `logs:FilterLogEvents` (CloudWatch Logs)

## Post-install configuration

Edit `configs/config.ini` — key `[monitoring]` switches:

```ini
collect_os_metrics       = true   # master OS switch (daemon / run_monitor)
collect_localhost_os     = false  # local /proc metrics
collect_ssh_hosts_os     = false  # ssh_hosts.tsv
collect_cloud_metrics    = true   # AWS CloudWatch / PI / DB Insights
collect_db_metrics       = true   # connections.tsv DB checks
```

One-shot `monitor.sh monitor` / `os` / `cloud` ignores these flags and always runs the requested source.

## Launching

```bash
bash monitor.sh daemon start
bash monitor.sh monitor --source all --instance YOUR_RDS_INSTANCE_ID
bash monitor.sh db list
bash monitor.sh hosts list
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
**Not removed:** script bundle, `configs/*.ini`, OS packages, AWS CLI

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
| `aws/lib/` | AWS-specific collectors (CloudWatch, PI, DB Insights) |
| `setup/` | Threshold catalog generators (optional) |
| `configs/` | `config.ini`, `metrics_and_thresholds.ini`, `properties.ini` |
| `.dbmonitor/` | Runtime data (created on install) |

See [HOWTOUSE.txt](HOWTOUSE.txt) for full documentation.
