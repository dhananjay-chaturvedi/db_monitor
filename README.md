# DB Monitor

Pure **bash** monitoring for **cloud and on-premises database resources**, with threshold-based alerting and notification delivery. No Python runtime required — only standard Linux tooling plus your cloud provider CLI when collecting cloud metrics.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Overview

DB Monitor watches database and host health across multiple layers:

| Layer | What it monitors | Examples |
|-------|------------------|----------|
| **Cloud SQL** | Managed instance metrics via provider APIs | AWS RDS / Aurora (CloudWatch, PI, DB Insights), GCP Cloud SQL (Cloud Monitoring, Query Insights) |
| **OS metrics** | CPU, memory, disk, network | Local `/proc` and remote hosts over SSH |
| **DB connectivity** | Reachability checks against any target | MySQL, PostgreSQL, Oracle, SQL Server, MongoDB, and more |

When metrics breach configured thresholds for a sustained window, the tool records alerts and can notify teams via **Microsoft Teams webhooks** and/or **SMTP email**.

## Features

- **Multi-provider** — independent `aws/` and `gcp/` deployments sharing `common/` libraries
- **Daemon or session mode** — background polling daemon or explicit `run_monitor.sh` instance lists
- **Configurable thresholds** — global catalog plus per-instance overlays
- **Encrypted credential storage** — webhook URLs, SMTP passwords, and DB passwords under `.dbmonitor/secrets/`
- **Alert history** — persistent plain-text alert log with CLI list/clear filters
- **Bash-native** — no application server; runs on EC2, GCE, or any Linux host with bash 4+

## Quick start

### Install

```bash
git clone https://github.com/<your-org>/db-monitor.git
cd db-monitor
bash installer/install.sh
```

Optional: install DB client tools for connectivity checks:

```bash
INSTALL_DB_CLIENTS=1 bash installer/install.sh
```

### AWS (RDS / Aurora)

```bash
bash aws/monitor.sh instances add --name my-rds --type aurora-mysql
bash aws/monitor.sh cloud --instance my-rds
bash aws/monitor.sh daemon start
bash aws/monitor.sh alerts list
```

### GCP (Cloud SQL)

```bash
bash gcp/monitor.sh instances add --name my-cloudsql --type mysql --project my-gcp-project
bash gcp/monitor.sh cloud --instance my-cloudsql
bash gcp/monitor.sh daemon start
bash gcp/monitor.sh alerts list
```

### Top-level dispatcher

From the project root you can route commands by provider:

```bash
bash monitor.sh aws instances list
bash monitor.sh gcp daemon status
```

## Project layout

```
db-monitor/
├── README.md                 This file
├── LICENSE                   MIT License
├── installer/                Install and uninstall scripts
├── common/                   Shared libraries, default configs, setup helpers
├── aws/                      AWS RDS / Aurora provider (monitor, daemon, configs)
├── gcp/                      GCP Cloud SQL provider (monitor, daemon, configs)
├── docs/                     Architecture, configuration, and publishing guides
├── monitor.sh                Root dispatcher: monitor.sh <aws|gcp> <command>
├── daemon.sh                 Root daemon dispatcher
├── run_monitor.sh            Root run_monitor dispatcher
└── stop_monitor.sh           Root stop_monitor dispatcher
```

Runtime state is created under `.dbmonitor/` on first install (logs, PID files, encrypted secrets, connection registries). This directory is **not** committed to git — see `.gitignore`.

## Configuration

| File | Purpose |
|------|---------|
| `common/configs/config.ini` | Poll interval, collection switches, notifications |
| `common/configs/properties.ini` | Paths, DB ports, SSH timeouts |
| `aws/configs/metrics_and_thresholds.ini` | AWS metric catalog and alert thresholds |
| `gcp/configs/metrics_and_thresholds.ini` | GCP metric catalog and alert thresholds |
| `configs/instances/<id>.ini` | Optional per-instance threshold overrides |

Live `*.ini` files are copied from `*.ini.default` on install when missing. Edit the live files, not the defaults.

Full reference: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

## Notifications

Store credentials securely (never in config files):

```bash
bash monitor.sh notify config set --key teams_webhook_url --value "<WEBHOOK_URL>"
bash monitor.sh notify config set --key smtp_password --value "<PASSWORD>"
bash monitor.sh notify test --severity WARNING
```

Enable channels in `config.ini` under `[notifications]`.

## Documentation

| Document | Description |
|----------|-------------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Daemon, poll cycle, locks, alert flow |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Config key reference |
| [docs/SETUP_MAINTENANCE.md](docs/SETUP_MAINTENANCE.md) | Catalog generators and threshold scaffolding |
| [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md) | How to publish and maintain a public git repository |
| [aws/docs/HOWTOUSE.txt](aws/docs/HOWTOUSE.txt) | AWS command reference |
| [gcp/docs/HOWTOUSE.txt](gcp/docs/HOWTOUSE.txt) | GCP command reference |
| [aws/docs/README_INSTALL.md](aws/docs/README_INSTALL.md) | AWS install dependencies |
| [gcp/docs/README_INSTALL.md](gcp/docs/README_INSTALL.md) | GCP install dependencies |

## Requirements

- **bash** 4+
- **Linux** (Debian/Ubuntu, Amazon Linux, RHEL-family)
- **AWS**: `aws` CLI v2 with IAM permissions for CloudWatch / RDS (and PI/DB Insights if enabled)
- **GCP**: `gcloud` CLI with `roles/monitoring.viewer` and `roles/cloudsql.viewer`
- **Optional**: `curl`, `sshpass`, `mysql`/`psql` clients, `sendmail`/`msmtp`

## Security notes

- Do **not** commit `.dbmonitor/`, live config overrides, or per-environment instance overlays.
- Use IAM roles / ADC on cloud VMs instead of long-lived access keys when possible.
- Rotate any credential that was ever stored in a tracked file before making the repository public.

See [docs/PUBLIC_REPOSITORY.md](docs/PUBLIC_REPOSITORY.md) for a pre-publish checklist.

## Contributing

Contributions are welcome. Please open an issue or pull request with a clear description of the change. Keep diffs focused and match existing bash style in `common/lib/`.

## License

This project is licensed under the [MIT License](LICENSE).
