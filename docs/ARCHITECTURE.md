# Architecture

## Execution modes

The tool has three operating modes:

### 1. Daemon mode (`daemon.sh start`)

```
daemon.sh run-loop
  └── every N seconds:
        forks  monitor.sh _poll  (fresh process)
          └── poll_cycle()
                ├── subshell: poll_os_metrics / poll_ssh_hosts_os_metrics
                ├── subshell: poll_aws_instance (per saved instance)
                │     └── _poll_one_instance → CloudWatch + PI + DB Insights
                └── subshell: poll_db_connectivity (all connections.tsv targets)
```

Each `monitor.sh _poll` subprocess is a completely fresh bash process. When it
finishes, the daemon sleeps for the poll interval and forks a new one. This means:
- A crashed poll process never takes down the daemon
- Config changes in config.ini are picked up on the next cycle (no restart needed)
- Each cycle reads `instances_load_saved()` fresh — adding an instance immediately
  takes effect without any daemon restart

### 2. run_monitor mode (`run_monitor.sh`)

```
run_monitor.sh (parent — sits in `wait`)
  ├── subshell: poll_instance_loop inst-a  (persistent, sleeps between polls)
  ├── subshell: poll_instance_loop inst-b  (persistent, sleeps between polls)
  ├── subshell: poll_localhost_os_loop     (if --include-localhost)
  ├── subshell: poll_ssh_host_loop NAME    (one per saved SSH host)
  └── subshell: poll_db_loop NAME          (one per connections.tsv target)
```

Each loop runs independently. A slow instance loop never blocks other loops.
The parent process just holds the PID files and EXIT/TERM trap. When you
`stop_monitor.sh`, the parent exits and its EXIT trap sends SIGTERM to all loops.

### 3. One-shot CLI mode (`monitor.sh os`, `monitor.sh cloud`, `monitor.sh monitor`)

Runs the requested collection function once, prints results to stdout, and exits.
Does not write to the alert log (display-only mode bypasses threshold evaluation
for alerts). Does not require or conflict with a running daemon.

---

## Poll cycle flow (daemon mode)

```
daemon.sh run-loop
  │
  ├─ acquire daemon_start_lock (FD 203)
  │    (prevents concurrent start/watchdog double-fork at startup only)
  │
  └─ while true:
       │
       ├─ acquire poll_cycle_lock (FD 202)  ← skipped if already held
       │
       ├─ fork subshells concurrently:
       │    ├─ localhost OS metrics
       │    ├─ SSH host OS metrics (fan-out, one subshell per host)
       │    ├─ instance collectors (fan-out, one subshell per instance)
       │    │    ├─ acquire entity_pipeline_lock (FD 201)  ← per-instance
       │    │    └─ acquire entity_fetch_lock (FD 200)     ← per-instance
       │    └─ DB connectivity (fan-out, one subshell per target)
       │
       ├─ wait for all subshells
       ├─ purge_stale_breach_state
       └─ release poll_cycle_lock
```

---

## Lock hierarchy

Four flock-based advisory locks, each on a distinct file descriptor:

| FD | Lock | File | Purpose |
|----|------|------|---------|
| 200 | `entity_fetch_lock` | `.dbmonitor/runtime/lock.fetch.<entity>` | Serialises API fetch for one entity; prevents two subshells calling CloudWatch for the same instance simultaneously |
| 201 | `entity_pipeline_lock` | `.dbmonitor/runtime/lock.pipeline.<entity>` | Held for the entire collect+evaluate+alert pipeline of one entity; Aurora cluster lock prevents duplicate cluster fetch when two instance subshells share the same cluster |
| 202 | `poll_cycle_lock` | `.dbmonitor/runtime/lock.poll_cycle` | Ensures only one poll cycle runs at a time; daemon acquires with `wait=0` (skip if held); CLI commands can be configured to wait or skip |
| 203 | `daemon_start_lock` | `.dbmonitor/runtime/lock.daemon_start` | Prevents two concurrent `daemon start` / `watchdog` calls from both forking a daemon |

**Acquisition order is always 203 → 202 → 201 → 200 (outermost to innermost).**
No code path acquires a lower-numbered lock and then a higher-numbered one, so
deadlock is impossible.

**Aurora cluster pipeline lock** (`entity_pipeline_lock` on the cluster ID): when
two instances belong to the same Aurora cluster, both finish collecting their
instance-level CloudWatch metrics and then attempt to collect cluster-level metrics.
The first to acquire `entity_pipeline_lock(cluster_id)` fetches the cluster metrics;
the second waits, then acquires the lock, and re-fetches. You see the "waiting for
pipeline lock" WARN log for the second instance — this is expected and harmless. The
wait is typically under 2 seconds. Total cluster metric collection happens twice per
cycle (once per instance), which is by design: each instance's log records the
cluster metrics alongside its own.

---

## Config system

Two INI files, two reader functions:

| File | Reader | Typical use |
|------|--------|-------------|
| `common/configs/config.ini` | `mcfgi SECTION KEY DEFAULT` | Behavioural settings (poll interval, thresholds, notifications) |
| `common/configs/properties.ini` | `pcfgi SECTION KEY DEFAULT` | Low-level runtime paths, timeouts, process lifecycle |

Both readers (`mcfgi` = "monitor config integer", `mcfg` = string, `mcfgb` = bool;
same prefixes with `p` for properties) are defined in `common/lib/config.sh`. They
fall back to `DEFAULT` when the key is absent, so the code always has a safe value
even on a fresh install before the user has edited any config.

Config files are read on every poll cycle (daemon) or on every loop iteration
(run_monitor). Changes take effect on the next poll without any restart.

---

## Threshold evaluation

### Rule file

`configs/metrics_and_thresholds.ini` contains one `[metric.<source>.<key>]` section
per rule. Each section defines:

```ini
[metric.aws.cloudwatch.RDS.CPUUtilization]
operator  = >        # alert when value exceeds threshold
critical  = 90
warning   = 80
window    = 3        # consecutive breach count before alert fires
enabled   = true
collect   = true     # fetch from API (AWS/GCP metrics only)
```

### Breach counter

`breach_state.tsv` in `.dbmonitor/runtime/` tracks the consecutive-breach count
for every (entity, metric_key) pair:

```
entity_name   metric_key   breach_count   last_seen_ts
```

On each poll:
1. If `value OP threshold` is true: increment counter
2. If counter reaches `window`: fire alert, reset counter to 0
3. If `value OP threshold` is false: reset counter to 0
4. Entries older than `sustained_breach_ttl_seconds` (default 86400) are purged by
   `purge_stale_breach_state()` at the end of each cycle

### Instance overlay

Per-instance overlay files (`configs/instances/<instance-id>.ini`) can override
individual keys in any rule without touching the global catalog. Lookup order:
instance file → global catalog. Only keys explicitly set in the overlay take effect;
unset keys fall through to the global value.

Create an overlay stub with: `bash setup/scaffold_instance_thresholds.sh INSTANCE`

---

## Alert flow

```
evaluate_metric (thresholds.sh)
  └── breach_state increments / window reached
        └── dispatch_alert (notify.sh)
              ├── append_alert (alerts.sh) → .dbmonitor/runtime/alerts.log
              ├── teams_send_alert         → Teams webhook (curl/wget POST)
              └── smtp_send_alert          → SMTP email (openssl s_client)
```

Alert severity levels: `INFO`, `WARNING`, `CRITICAL`.  
`min_severity` in config.ini controls the minimum level actually delivered via
Teams/SMTP (e.g. `WARNING` = skip INFO deliveries; all still written to alerts.log).

---

## Signal handling

**Daemon:**

```
SIGTERM / SIGINT → _on_signal()
  ├── if auto_restart_enabled=true AND not intentional stop (no sentinel file):
  │     kill POLL_PID → wait → exec daemon.sh run-loop  (re-exec in same process)
  └── else:
        kill POLL_PID → wait signal_stop_max_wait_seconds → SIGKILL if still running
        exit 0
```

The sentinel file `.dbmonitor/runtime/daemon.stop` is written by `daemon stop`
before sending SIGTERM. The signal handler checks for it to distinguish intentional
stops (no restart) from crashes or external kills (restart if configured).

**run_monitor loop subshells:**

Each loop subshell has `trap '_poll_loop_shutdown' TERM`. The shutdown handler sends
SIGTERM to the current poll child (if any) and then exits. The parent's EXIT trap
iterates all `loop.<SESSION>.*.pid` files and sends SIGTERM to each loop PID.

---

## PID file layout

```
.dbmonitor/runtime/
  daemon.pid                           Daemon run-loop PID
  poll.pid                             Current poll subprocess PID (daemon mode)
  run_monitor.<SESSION>.pid            run_monitor.sh parent PID (session-scoped)
  loop.<SESSION>.instance.<name>.pid   Per-instance loop PID
  loop.<SESSION>.sshhost.<name>.pid    Per-SSH-host loop PID
  loop.<SESSION>.db.<name>.pid         Per-DB loop PID
  loop.<SESSION>.localhost_os.pid      Localhost OS loop PID
```

`<SESSION>` is the PID of the `run_monitor.sh` parent process. Multiple concurrent
`run_monitor.sh` sessions (e.g. watching different instances) each get a unique
session PID, so their PID files never collide.
