# dbx_monitor — DB Monitoring Tool

Pure bash monitoring for AWS RDS and GCP Cloud SQL. No Python, no external
dependencies beyond the cloud provider CLI. Runs on any Linux host with bash 4+.

## What it does

- Polls AWS CloudWatch / Performance Insights / Database Insights **or** GCP Cloud Monitoring on a configurable interval
- Collects OS metrics from the monitoring host (`/proc`) and from remote hosts over SSH
- Tests DB connectivity for any target in `connections.tsv`
- Evaluates metric values against threshold rules; fires alerts after N consecutive breaches
- Delivers alerts via Microsoft Teams webhook and/or SMTP email
- Stores full alert history in a plain-text log

## Provider split

The tool ships with two completely independent provider deployments:

| Directory | Provider | CLI tool |
|-----------|---------|---------|
| `aws/` | AWS RDS / Aurora | `aws` CLI |
| `gcp/` | GCP Cloud SQL | `gcloud` CLI |

`common/` holds shared library code used by both providers. Each provider has its
own `configs/`, `lib/`, `setup/`, and `docs/` directories. You deploy only the
provider you need — there is no shared daemon or shared config between aws/ and gcp/.

## Top-level dispatcher scripts

The project root contains thin dispatcher scripts that forward to the correct
provider directory. Use these when calling from outside the provider directory:

```bash
bash monitor.sh aws <command>          # → aws/monitor.sh <command>
bash monitor.sh gcp <command>          # → gcp/monitor.sh <command>
bash daemon.sh aws <command>           # → aws/daemon.sh <command>
bash daemon.sh gcp <command>           # → gcp/daemon.sh <command>
bash run_monitor.sh aws [instances]    # → aws/run_monitor.sh [instances]
bash stop_monitor.sh aws [options]     # → aws/stop_monitor.sh [options]
```

Or call the provider script directly from within its directory:
```bash
cd aws && bash monitor.sh <command>
cd gcp && bash monitor.sh <command>
```

## Architecture in brief

The daemon forks a fresh `monitor.sh _poll` subprocess each cycle. That subprocess
runs `poll_cycle()` which spawns one background subshell per resource (instance /
SSH host / DB target / localhost) — they collect concurrently. Each resource holds
a pipeline lock while it collects so a slow resource never blocks others. After
collection, threshold rules are evaluated and alerts dispatched.

`run_monitor.sh` is an alternative to the daemon: it spawns one persistent loop
subshell per resource that runs indefinitely, sleeping between polls. No subprocess
fork per cycle — all loops run in parallel as long as the session is alive.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full internal design.

## Quick start — AWS

```bash
# 1. Install
bash installer/install.sh

# 2. Add an RDS instance
bash aws/monitor.sh instances add --name my-rds-instance --type aurora-mysql

# 3. One-shot check
bash aws/monitor.sh cloud --instance my-rds-instance

# 4. Start daemon
bash aws/monitor.sh daemon start
bash aws/monitor.sh alerts list
```

Full guide: [aws/docs/HOWTOUSE.txt](../aws/docs/HOWTOUSE.txt)
Install guide: [aws/docs/README_INSTALL.md](../aws/docs/README_INSTALL.md)

## Quick start — GCP

```bash
# 1. Install
bash installer/install.sh

# 2. Add a Cloud SQL instance
bash gcp/monitor.sh instances add --name my-cloudsql --type mysql --project my-project

# 3. One-shot check
bash gcp/monitor.sh cloud --instance my-cloudsql

# 4. Start daemon
bash gcp/monitor.sh daemon start
bash gcp/monitor.sh alerts list
```

Full guide: [gcp/docs/HOWTOUSE.txt](../gcp/docs/HOWTOUSE.txt)
Install guide: [gcp/docs/README_INSTALL.md](../gcp/docs/README_INSTALL.md)

## Documentation index

| Document | Contents |
|----------|---------|
| [docs/ARCHITECTURE.md](ARCHITECTURE.md) | Execution model, poll cycle, lock hierarchy, config system, threshold evaluation, alert flow |
| [docs/CONFIGURATION.md](CONFIGURATION.md) | Full reference for every key in config.ini and properties.ini |
| [docs/SETUP_MAINTENANCE.md](SETUP_MAINTENANCE.md) | Setup scripts: catalog generators, threshold scaffold, PI refresh |
| [docs/PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md) | Publish to a public git repo: checklist, git init, push, releases |
| [aws/docs/HOWTOUSE.txt](../aws/docs/HOWTOUSE.txt) | AWS command reference, config guide, troubleshooting |
| [aws/docs/README_INSTALL.md](../aws/docs/README_INSTALL.md) | AWS install guide and dependency table |
| [gcp/docs/HOWTOUSE.txt](../gcp/docs/HOWTOUSE.txt) | GCP command reference, config guide, troubleshooting |
| [gcp/docs/README_INSTALL.md](../gcp/docs/README_INSTALL.md) | GCP install guide and dependency table |

## Directory layout

```
dbx_monitor/
├── monitor.sh              Top-level dispatcher (monitor.sh <provider> <cmd>)
├── daemon.sh               Top-level daemon dispatcher
├── run_monitor.sh          Top-level run_monitor dispatcher
├── stop_monitor.sh         Top-level stop_monitor dispatcher
├── installer/
│   ├── install.sh          OS packages + CLI + runtime dirs
│   └── uninstall.sh        Stop + remove .dbmonitor/
├── common/
│   ├── lib/                Shared bash libraries (util, config, alerts, notify, …)
│   ├── configs/            config.ini.default, properties.ini.default
│   └── setup/              generate_os_thresholds.sh, generate_db_thresholds.sh
├── aws/
│   ├── monitor.sh          AWS CLI entry point
│   ├── daemon.sh           AWS daemon lifecycle
│   ├── run_monitor.sh      AWS continuous monitor
│   ├── stop_monitor.sh     AWS loop stop controller
│   ├── lib/                aws.sh, instances.sh, poll.sh
│   ├── configs/            metrics_and_thresholds.ini(.default)
│   ├── setup/              Catalog generators + scaffold scripts
│   └── docs/               HOWTOUSE.txt, README_INSTALL.md
└── gcp/
    ├── monitor.sh          GCP CLI entry point
    ├── daemon.sh           GCP daemon lifecycle
    ├── run_monitor.sh      GCP continuous monitor
    ├── stop_monitor.sh     GCP loop stop controller
    ├── lib/                gcp.sh, instances.sh, poll.sh
    ├── configs/            metrics_and_thresholds.ini(.default)
    ├── setup/              Catalog generators + scaffold scripts
    └── docs/               HOWTOUSE.txt, README_INSTALL.md
```
