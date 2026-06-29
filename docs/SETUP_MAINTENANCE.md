# Setup & Maintenance Scripts

The `setup/` directory in each provider (and in `common/`) contains scripts for
building and maintaining the metric threshold catalog. These are **not** run during
normal monitoring — they are developer/admin tools for managing the catalog files.

---

## When do you need these?

| Scenario | Scripts to run |
|----------|---------------|
| First-time setup or adding a new provider | `assemble_thresholds_ini.sh` |
| Add per-instance threshold overrides | `scaffold_instance_thresholds.sh INSTANCE` |
| Enable or disable specific metrics | `patch_enabled_metrics.sh` |
| Discover new PI metrics available on a live instance | `refresh_pi_catalog_from_aws.sh` (AWS only) |
| Rebuild catalog after editing TSV source files | `assemble_thresholds_ini.sh` |
| Validate catalog structure after manual edits | `tests/validate_thresholds_catalog.sh` |

---

## Common setup scripts

### `common/setup/generate_os_thresholds.sh`

Generates the OS metric threshold INI sections (CPU, memory, disk, load, swap,
network) and prints them to stdout. Called internally by `assemble_thresholds_ini.sh`.

```bash
bash common/setup/generate_os_thresholds.sh
```

Not normally run directly.

---

### `common/setup/generate_db_thresholds.sh`

Generates generic DB connectivity threshold sections (`metric.db.*`) and prints
them to stdout. Called internally by `assemble_thresholds_ini.sh`.

```bash
bash common/setup/generate_db_thresholds.sh
```

Not normally run directly.

---

## AWS setup scripts (`aws/setup/`)

### `assemble_thresholds_ini.sh`

**Main rebuild script.** Assembles `configs/metrics_and_thresholds.ini.default`
from all generator scripts, then syncs the live `configs/metrics_and_thresholds.ini`
with the default set of production metrics enabled.

Run this whenever the metric catalog changes (e.g. after editing a TSV catalog
file or after running `refresh_pi_catalog_from_aws.sh`).

```bash
cd aws
bash setup/assemble_thresholds_ini.sh --help
bash setup/assemble_thresholds_ini.sh
```

Assembly order:
1. File header (preserved from existing `.default` or live ini)
2. OS threshold rules (`common/setup/generate_os_thresholds.sh`)
3. DB connectivity rules (`common/setup/generate_db_thresholds.sh`)
4. CloudWatch RDS/Aurora rules (`setup/generate_cloudwatch_thresholds.sh`)
5. Performance Insights rules (`setup/generate_pi_thresholds.sh`)
6. Database Insights rules (`setup/generate_dbinsights_thresholds.sh`)

---

### `export_catalog_tsv.sh`

Exports the bundled metric catalog definitions to TSV files under `setup/catalog/`.
These TSV files are the source-of-truth for the threshold generators. Run this to
regenerate the TSV files from the embedded catalog data.

```bash
bash setup/export_catalog_tsv.sh --help
bash setup/export_catalog_tsv.sh
```

After exporting, run `assemble_thresholds_ini.sh` to rebuild the INI from the
updated TSV files.

---

### `generate_cloudwatch_thresholds.sh`

Generates `[metric.aws.cloudwatch.RDS.*]` and `[metric.aws.cloudwatch.Aurora.*]`
sections from the CloudWatch catalog TSV and prints them to stdout. Called by
`assemble_thresholds_ini.sh`.

```bash
bash setup/generate_cloudwatch_thresholds.sh --help
bash setup/generate_cloudwatch_thresholds.sh
```

---

### `generate_pi_thresholds.sh`

Generates `[metric.aws.pi.RDS.*]` sections (Performance Insights API metrics)
from the PI catalog TSV and prints to stdout. Called by `assemble_thresholds_ini.sh`.

```bash
bash setup/generate_pi_thresholds.sh --help
bash setup/generate_pi_thresholds.sh
```

---

### `generate_dbinsights_thresholds.sh`

Generates `[metric.aws.dbinsights.RDS.*]` sections (same PI counters available
via CloudWatch DB_PERF_INSIGHTS namespace — use these when the PI API endpoint
is blocked on your network). Called by `assemble_thresholds_ini.sh`.

```bash
bash setup/generate_dbinsights_thresholds.sh --help
bash setup/generate_dbinsights_thresholds.sh
```

---

### `refresh_pi_catalog_from_aws.sh`

Queries the AWS Performance Insights API on a live RDS instance to discover any
PI metrics available there that are not yet in the bundled catalog. Merges any new
metrics into `setup/catalog/pi_metrics_api_supplement.json`.

Run this when you suspect your instance exposes PI metrics beyond the shipped set
(e.g. after an RDS engine upgrade).

```bash
bash setup/refresh_pi_catalog_from_aws.sh --help
bash setup/refresh_pi_catalog_from_aws.sh --instance prod-rds-1
bash setup/refresh_pi_catalog_from_aws.sh --instance prod-rds-1 --region us-west-2
```

After running, rebuild the catalog:
```bash
bash setup/assemble_thresholds_ini.sh
```

---

### `patch_enabled_metrics.sh`

Toggle the `enabled` and/or `collect` flags for metrics in the live
`configs/metrics_and_thresholds.ini` without manually editing the file.

Useful for enabling extra metrics for a trial period or disabling metrics that
generate too much noise.

```bash
bash setup/patch_enabled_metrics.sh --help
bash setup/patch_enabled_metrics.sh --live-only   # patch only currently enabled metrics
bash setup/patch_enabled_metrics.sh               # patch all metrics
```

---

### `scaffold_instance_thresholds.sh`

Creates a per-instance threshold overlay INI stub at
`configs/instances/<INSTANCE>.ini`. The stub contains commented-out sections for
each globally-enabled metric, ready to be customised with instance-specific values.

The overlay is NOT created automatically by `instances add` — run this manually
when you want per-instance threshold tuning.

```bash
bash setup/scaffold_instance_thresholds.sh --help
bash setup/scaffold_instance_thresholds.sh prod-rds-1
bash setup/scaffold_instance_thresholds.sh prod-rds-1 --force   # overwrite existing
```

After creating the stub, edit `configs/instances/prod-rds-1.ini` to override any
threshold values, then verify with:

```bash
bash monitor.sh thresholds list --instance prod-rds-1
```

---

## GCP setup scripts (`gcp/setup/`)

### `assemble_thresholds_ini.sh`

Same purpose as the AWS version — rebuilds `configs/metrics_and_thresholds.ini.default`
from GCP generator scripts and syncs the live INI.

```bash
cd gcp
bash setup/assemble_thresholds_ini.sh --help
bash setup/assemble_thresholds_ini.sh
```

Assembly order:
1. File header
2. OS threshold rules
3. DB connectivity rules
4. Cloud Monitoring (Cloud SQL) rules (`setup/generate_gcp_thresholds.sh`)

---

### `generate_gcp_thresholds.sh`

Generates `[metric.gcp.monitoring.CloudSQL.*]` and `[metric.gcp.qi.*]` (Query
Insights) sections from the GCP catalog TSV and prints to stdout. Called by
`assemble_thresholds_ini.sh`.

```bash
bash setup/generate_gcp_thresholds.sh --help
bash setup/generate_gcp_thresholds.sh
```

---

### `patch_enabled_metrics.sh`

Identical function to the AWS version.

```bash
bash setup/patch_enabled_metrics.sh --help
bash setup/patch_enabled_metrics.sh
```

---

### `scaffold_instance_thresholds.sh`

Identical function to the AWS version.

```bash
bash setup/scaffold_instance_thresholds.sh --help
bash setup/scaffold_instance_thresholds.sh my-cloudsql-instance
bash setup/scaffold_instance_thresholds.sh my-cloudsql-instance --force
```

---

## Typical catalog maintenance workflow (AWS)

```bash
cd aws

# 1. (Optional) refresh PI metrics from a live instance
bash setup/refresh_pi_catalog_from_aws.sh --instance prod-rds-1

# 2. Rebuild the full catalog
bash setup/assemble_thresholds_ini.sh

# 3. Validate the result
bash tests/validate_thresholds_catalog.sh configs/metrics_and_thresholds.ini

# 4. (Optional) enable extra metrics
bash setup/patch_enabled_metrics.sh

# 5. (Optional) create per-instance overlays
bash setup/scaffold_instance_thresholds.sh prod-rds-1

# 6. Verify merged thresholds for an instance
bash monitor.sh thresholds list --instance prod-rds-1
```

The daemon picks up the updated `metrics_and_thresholds.ini` on the next poll cycle
automatically — no restart required.
