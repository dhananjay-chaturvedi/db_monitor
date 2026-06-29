# Configuration Reference

Complete reference for every key in `config.ini` and `properties.ini`.

- `config.ini` — behavioural settings (poll intervals, thresholds, notifications)
  - Source: `common/configs/config.ini.default` → copied to provider `configs/config.ini` on install
  - Read with: `mcfg SECTION KEY DEFAULT`, `mcfgi` (integer), `mcfgb` (boolean)

- `properties.ini` — low-level runtime paths and infrastructure defaults
  - Source: `common/configs/properties.ini.default` → copied to provider `configs/properties.ini` on install
  - Read with: `pcfg SECTION KEY DEFAULT`, `pcfgi` (integer), `pcfgb` (boolean)

Changes take effect on the next poll cycle — no daemon restart required.

---

## config.ini sections

### [monitoring]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `default_poll_interval` | int | `30` | Poll interval in seconds |
| `default_disk_path` | string | `/` | Filesystem path for OS disk usage metrics |
| `collect_os_metrics` | bool | `true` | Master switch for all OS metric collection (daemon / run_monitor) |
| `collect_cloud_metrics` | bool | `true` | Enable cloud metrics collection (CloudWatch for AWS, Cloud Monitoring for GCP) |
| `collect_db_metrics` | bool | `true` | Enable DB connectivity checks (connections.tsv targets) |
| `collect_localhost_os` | bool | `false` | Collect `/proc` metrics from the monitoring host itself (requires `collect_os_metrics`) |
| `collect_ssh_hosts_os` | bool | `false` | Collect OS metrics from SSH hosts (ssh_hosts.tsv, requires `collect_os_metrics`) |
| `sustained_breach_ttl_seconds` | int | `86400` | Seconds before an idle breach counter is purged from breach_state.tsv |
| `poll_cycle_timeout_seconds` | int | `120` | Maximum seconds for a full poll cycle; cycle is killed after this |
| `daemon_lock_wait_seconds` | int | `300` | Seconds the daemon waits to acquire the poll-cycle lock if another cycle is still running |
| `cli_lock_wait_seconds` | int | `0` | Seconds CLI one-shot commands wait for the poll-cycle lock (0 = skip if held) |
| `ssh_control_persist_seconds` | int | `0` | SSH ControlMaster persist duration for SSH host metrics (0 = disabled) |

### [cloud]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `lookback_minutes` | int | `10` (AWS) / `5` (GCP) | How far back to query for the most recent metric datapoint |
| `metric_fetch_timeout_seconds` | int | `30` | Per-instance API call budget (shared across CloudWatch + PI + DB Insights for AWS; per-metric for GCP) |
| `cluster_lookback_minutes` | int | `180` | Lookback window for Aurora cluster-level CloudWatch metrics (AWS only) |
| `cluster_metric_period_seconds` | int | `3600` | Aggregation period for Aurora cluster metrics (AWS only) |
| `insights_period_seconds` | int | `300` | Aggregation period for Performance Insights / DB Insights metrics (AWS only) |
| `insights_lookback_minutes` | int | `60` | Lookback window for PI / DB Insights metrics (AWS only) |
| `query_id_max_chars` | int | `240` | Maximum characters for a PI query ID string before truncation (AWS only) |

### [notifications]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Master switch — set to `true` to enable all notification delivery |
| `min_severity` | string | `WARNING` | Minimum severity delivered via Teams/SMTP: `INFO`, `WARNING`, or `CRITICAL` |
| `teams_enabled` | bool | `false` | Enable Teams webhook delivery |
| `email_enabled` | bool | `false` | Enable SMTP email delivery |
| `teams_timeout_seconds` | int | `15` | HTTP timeout for Teams webhook POST |
| `teams_max_attempts` | int | `2` | Number of delivery attempts before giving up |
| `teams_max_backoff_seconds` | int | `5` | Maximum retry backoff duration cap (seconds) |
| `teams_backoff_multiplier` | int | `2` | Backoff multiplier between retry attempts |
| `max_message_chars` | int | `20000` | Maximum alert message body length (Teams message limit) |
| `teams_color_critical` | string | `FF0000` | Adaptive card accent colour hex code for CRITICAL severity |
| `teams_color_warning` | string | `FFA500` | Adaptive card accent colour hex code for WARNING severity |
| `teams_color_info` | string | `0078D7` | Adaptive card accent colour hex code for INFO severity |
| `smtp_host` | string | `smtp.gmail.com` | SMTP server hostname |
| `smtp_port` | int | `587` | SMTP server port |
| `smtp_use_tls` | bool | `true` | Use STARTTLS for SMTP connection |
| `smtp_username` | string | _(empty)_ | SMTP account username |
| `email_from` | string | _(empty)_ | Sender address in alert emails |
| `email_to` | string | _(empty)_ | Comma-separated recipient addresses |

### [ssh]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `connect_timeout_seconds` | int | `8` | SSH connection timeout (also in properties.ini `[ssh]`) |
| `server_alive_interval_seconds` | int | `30` | SSH keepalive interval (also in properties.ini `[ssh]`) |
| `server_alive_count_max` | int | `3` | SSH max missed keepalives before disconnect |

### [daemon]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `auto_restart_enabled` | bool | `false` | Auto-restart daemon after unexpected SIGTERM. Does NOT restart after intentional `daemon stop` |
| `auto_restart_delay_seconds` | int | `10` | Seconds to wait before re-executing the daemon run-loop |

### [logs.daemon]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `keep_days` | int | `5` | Delete daemon log files older than this many days |

### [logs.metrics]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `keep_days` | int | `5` | Delete per-entity metric log files older than this many days |
| `archive_on_start` | bool | `false` | Rotate metric logs to `Archive_<YYYYMMDD>.log` on daemon start |
| `archive_keep_days` | int | `0` | Delete archived metric logs older than this (0 = keep forever) |

---

## properties.ini sections

### [paths]

All path overrides are optional. Leave blank to use the default location relative
to the provider script directory.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `runtime_dir` | string | `<provider_dir>/.dbmonitor/runtime` | Override the runtime directory |
| `secrets_dir` | string | `<provider_dir>/.dbmonitor/secrets` | Override the secrets directory |
| `alerts_log_file` | string | `<runtime_dir>/alerts.log` | Override the alerts log file path |
| `instance_thresholds_dir` | string | `<provider_dir>/configs/instances` | Override the per-instance threshold overlays directory |
| `oracle_client_path` | string | _(empty)_ | Oracle Instant Client directory path (required for Oracle DB checks) |

### [database.connection]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `connection_timeout_seconds` | int | `10` | Timeout for DB connectivity test connections |

### [database.ports]

Default port numbers used when the `connections.tsv` entry omits the port field.

| Key | Type | Default |
|-----|------|---------|
| `mysql` | int | `3306` |
| `postgresql` | int | `5432` |
| `oracle` | int | `1521` |
| `sqlserver` | int | `1433` |
| `mongodb` | int | `27017` |

### [ssh]

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `connect_timeout_seconds` | int | `8` | SSH connection timeout for OS metric collection over SSH |
| `server_alive_interval_seconds` | int | `30` | SSH keepalive interval |

### [cloud.metadata] (AWS only)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `metadata_connect_timeout_seconds` | int | `1` | Timeout for EC2 IMDS metadata endpoint queries |
| `metadata_token_ttl_seconds` | int | `60` | IMDSv2 token TTL |

### [lifecycle]

Controls timing for process start, stop, and signal escalation.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `signal_escalation_delay_seconds` | int | `2` | Wait after SIGTERM before escalating to SIGKILL when stopping a subprocess |
| `daemon_start_verify_delay_seconds` | int | `1` | Wait after forking the daemon before checking whether its PID is alive |
| `daemon_restart_delay_seconds` | int | `2` | Wait between the stop and start phases of `daemon restart` |
| `signal_stop_max_wait_seconds` | int | `15` | Maximum seconds to wait for a process to exit after SIGTERM before sending SIGKILL |

---

## Environment variable overrides

These variables override the corresponding config/properties values when set in
the shell before running any script.

| Variable | Overrides | Description |
|----------|-----------|-------------|
| `DBMONITOR_HOME` | `[paths] runtime_dir` base | Override the base `.dbmonitor/` directory |
| `DBMONITOR_RUNTIME` | `[paths] runtime_dir` | Override runtime directory directly |
| `DBMONITOR_SECRETS` | `[paths] secrets_dir` | Override secrets directory directly |
| `MONITOR_STDOUT` | _(code flag)_ | `false` = suppress log output to stdout (daemon sets this) |
| `MONITOR_DEBUG` | _(code flag)_ | `true` = enable verbose debug logging |
| `MONITOR_INCLUDE_OS` | `collect_os_metrics` | `true`/`false` — override OS metric collection gate |
| `MONITOR_INCLUDE_LOCALHOST` | `collect_localhost_os` | `true`/`false` — override localhost OS gate |
| `MONITOR_INCLUDE_SSH_HOSTS` | `collect_ssh_hosts_os` | `true`/`false` — override SSH hosts gate |
| `MONITOR_INCLUDE_DB` | `collect_db_metrics` | `true`/`false` — override DB check gate |
| `MONITOR_INCLUDE_CLOUD` | `collect_cloud_metrics` | `true`/`false` — override cloud metrics gate |
| `CLOUDSDK_CORE_PROJECT` | _(GCP only)_ | Active GCP project for all gcloud calls |
| `GOOGLE_APPLICATION_CREDENTIALS` | _(GCP only)_ | Path to service account JSON key file |

---

## Reading config values at runtime

```bash
bash monitor.sh config get SECTION KEY

# Examples:
bash monitor.sh config get monitoring default_poll_interval
bash monitor.sh config get lifecycle signal_stop_max_wait_seconds
bash monitor.sh config get notifications min_severity
bash monitor.sh config get database.connection connection_timeout_seconds
bash monitor.sh config get cloud lookback_minutes
```

`config get` checks `properties.ini` first, then `config.ini`. This mirrors the
runtime lookup order used by the code.
