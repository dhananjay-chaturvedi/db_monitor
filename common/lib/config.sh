#!/usr/bin/env bash
# lib/config.sh — INI file reader (pure awk, no external deps)

# Per-process INI value cache. Each poll cycle runs in a fresh bash subprocess so
# there is no stale-data risk. Eliminates repeated awk invocations on the same files.
declare -gA _INI_CACHE=()
declare -gA _INI_KEY_CACHE=()
_INI_CACHE_MISS='__DBMON_INI_MISS__'

# ini_get FILE SECTION KEY [DEFAULT]
# Reads a value from an INI file.  Strips inline comments (# and ;),
# trims surrounding whitespace, and returns DEFAULT if the key is absent.
ini_get() {
    local file="$1" section="$2" key="$3" default="${4:-}"
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    local ck="${file}|[${section}]|${key}"
    if [[ -v _INI_CACHE["$ck"] ]]; then
        local cv="${_INI_CACHE[$ck]}"
        [[ "$cv" == "$_INI_CACHE_MISS" ]] && echo "$default" || printf '%s\n' "$cv"
        return
    fi
    local v
    v=$(awk -F= -v section="[$section]" -v key="$key" -v miss="$_INI_CACHE_MISS" '
        /^[[:space:]]*\[/ {
            s=$0; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); cur=s
        }
        cur == section {
            k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
            if (k == key) {
                v=$0; sub(/^[^=]*=/,"",v)
                gsub(/[[:space:]]*[#;].*$/,"",v)
                gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
                print v; found=1; exit
            }
        }
        END { if (!found) print miss }
    ' "$file")
    _INI_CACHE["$ck"]="$v"
    [[ "$v" == "$_INI_CACHE_MISS" ]] && echo "$default" || printf '%s\n' "$v"
}

# ini_get_bool FILE SECTION KEY [DEFAULT]  — returns "true" or "false"
ini_get_bool() {
    local raw; raw=$(ini_get "$1" "$2" "$3" "${4:-false}")
    case "${raw,,}" in
        true|yes|1|on) echo "true" ;;
        *)             echo "false" ;;
    esac
}

# ini_get_int FILE SECTION KEY [DEFAULT]
ini_get_int() {
    local raw; raw=$(ini_get "$1" "$2" "$3" "${4:-0}")
    printf '%d' "$raw" 2>/dev/null || echo "${4:-0}"
}

# ini_sections FILE  — print all section names (without brackets)
ini_sections() {
    [[ -f "$1" ]] || return 0
    grep -E '^\[' "$1" | sed 's/[][]//g' | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print}'
}

# Convenience wrappers for the project config files
MONITOR_ROOT="${MONITOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIGS_DIR="${MONITOR_ROOT}/configs"
_SHARED_CONFIGS_DIR="${MONITOR_ROOT}/../common/configs"

# config.ini: provider-local first, then shared parent
CONFIG_INI="${CONFIGS_DIR}/config.ini"
[[ -f "$CONFIG_INI" ]] || CONFIG_INI="${_SHARED_CONFIGS_DIR}/config.ini"
CONFIG_INI_DEFAULT="${CONFIGS_DIR}/config.ini.default"
[[ -f "$CONFIG_INI_DEFAULT" ]] || CONFIG_INI_DEFAULT="${_SHARED_CONFIGS_DIR}/config.ini.default"

# metrics_and_thresholds.ini stays provider-local (different catalog per provider)
METRICS_AND_THRESHOLDS_INI="${CONFIGS_DIR}/metrics_and_thresholds.ini"
METRICS_AND_THRESHOLDS_INI_DEFAULT="${CONFIGS_DIR}/metrics_and_thresholds.ini.default"

# properties.ini: provider-local first, then shared parent
PROPERTIES_INI="${CONFIGS_DIR}/properties.ini"
[[ -f "$PROPERTIES_INI" ]] || PROPERTIES_INI="${_SHARED_CONFIGS_DIR}/properties.ini"
PROPERTIES_INI_DEFAULT="${CONFIGS_DIR}/properties.ini.default"
[[ -f "$PROPERTIES_INI_DEFAULT" ]] || PROPERTIES_INI_DEFAULT="${_SHARED_CONFIGS_DIR}/properties.ini.default"

# Fall back to shipped .default files when live copies are absent.
if [[ ! -f "$CONFIG_INI" ]]; then
    CONFIG_INI="$CONFIG_INI_DEFAULT"
fi
if [[ ! -f "$METRICS_AND_THRESHOLDS_INI" ]]; then
    METRICS_AND_THRESHOLDS_INI="$METRICS_AND_THRESHOLDS_INI_DEFAULT"
fi
if [[ ! -f "$PROPERTIES_INI" ]]; then
    PROPERTIES_INI="$PROPERTIES_INI_DEFAULT"
fi

mcfg()  { ini_get      "$CONFIG_INI" "$1" "$2" "${3:-}"; }
mcfgb() { ini_get_bool "$CONFIG_INI" "$1" "$2" "${3:-false}"; }
mcfgi() { ini_get_int  "$CONFIG_INI" "$1" "$2" "${3:-0}"; }

pcfg()  { ini_get      "$PROPERTIES_INI" "$1" "$2" "${3:-}"; }
pcfgi() { ini_get_int  "$PROPERTIES_INI" "$1" "$2" "${3:-0}"; }

# _path_setting KEY — reads from properties.ini [paths]
_path_setting() {
    pcfg paths "$1" ""
}

# _sanitize_instance_name NAME — safe filename stem
_sanitize_instance_name() {
    sanitize_name "${1:-unknown}"
}

# _instance_thresholds_dir — directory for per-instance overlay INI files
_instance_thresholds_dir() {
    local dir; dir=$(_path_setting instance_thresholds_dir)
    [[ -n "$dir" ]] || dir="${CONFIGS_DIR}/instances"
    printf '%s' "$dir"
}

# instance_thresholds_ini INSTANCE — path to optional per-instance overlay (may not exist)
instance_thresholds_ini() {
    local instance="$1" safe dir
    safe=$(_sanitize_instance_name "$instance")
    dir=$(_instance_thresholds_dir)
    printf '%s/%s.ini' "$dir" "$safe"
}

# ini_section_present FILE SECTION — exit 0 when [SECTION] exists in FILE
ini_section_present() {
    local file="$1" section="$2"
    [[ -f "$file" ]] || return 1
    awk -v section="[$section]" '
        /^[[:space:]]*\[/ {
            s=$0; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
            if (s == section) { found=1; exit }
        }
        END { exit !found }
    ' "$file"
}

# ini_key_present FILE SECTION KEY — exit 0 when KEY is explicitly set in SECTION
ini_key_present() {
    local file="$1" section="$2" key="$3"
    [[ -f "$file" ]] || return 1
    local ck="${file}|[${section}]|${key}"
    if [[ -v _INI_KEY_CACHE["$ck"] ]]; then
        return "${_INI_KEY_CACHE[$ck]}"
    fi
    local rc=0
    awk -F= -v section="[$section]" -v key="$key" '
        /^[[:space:]]*\[/ {
            s=$0; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); cur=s
        }
        cur == section {
            k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
            if (k == key) { found=1; exit }
        }
        END { exit !found }
    ' "$file" || rc=$?
    _INI_KEY_CACHE["$ck"]=$rc
    return $rc
}

# thresh_section_exists INSTANCE SECTION — section in instance overlay or global catalog
thresh_section_exists() {
    local instance="$1" section="$2" inst_file
    inst_file=$(instance_thresholds_ini "$instance")
    ini_section_present "$inst_file" "$section" && return 0
    ini_section_present "$METRICS_AND_THRESHOLDS_INI" "$section"
}

# thresh_ini_key_present INSTANCE SECTION KEY — key overridden in instance overlay
thresh_ini_key_present() {
    local instance="$1" section="$2" key="$3" inst_file
    inst_file=$(instance_thresholds_ini "$instance")
    ini_key_present "$inst_file" "$section" "$key"
}

# thresh_ini_get INSTANCE SECTION KEY DEFAULT — instance overlay first, then global catalog
thresh_ini_get() {
    local instance="$1" section="$2" key="$3" default="${4:-}"
    local inst_file; inst_file=$(instance_thresholds_ini "$instance")
    if ini_key_present "$inst_file" "$section" "$key"; then
        ini_get "$inst_file" "$section" "$key" "$default"
    else
        ini_get "$METRICS_AND_THRESHOLDS_INI" "$section" "$key" "$default"
    fi
}

# thresh_ini_sections INSTANCE — union of section names from global + instance overlay
thresh_ini_sections() {
    local instance="$1" inst_file
    inst_file=$(instance_thresholds_ini "$instance")
    {
        ini_sections "$METRICS_AND_THRESHOLDS_INI"
        ini_sections "$inst_file"
    } | awk 'NF && !seen[$0]++'
}

# scaffold_instance_thresholds_overlay INSTANCE [FORCE]
# Creates per-instance threshold stub. Prints "created" or "exists" on stdout; returns 0.
scaffold_instance_thresholds_overlay() {
    local instance="$1" force="${2:-0}" out section enabled collect desc
    out=$(instance_thresholds_ini "$instance")
    mkdir -p "$(dirname "$out")"

    if [[ -f "$out" && "$force" != "1" ]]; then
        echo "exists"
        return 0
    fi

    {
        echo "# Per-instance threshold overlay for: ${instance}"
        echo "# Uncomment and edit keys below; absent keys fall back to:"
        echo "#   ${METRICS_AND_THRESHOLDS_INI}"
        echo "#"
        echo "# Example (AWS):"
        echo "# [metric.aws.cloudwatch.RDS.CPUUtilization]"
        echo "# critical = 85"
        echo "# warning  = 70"
        echo
        while IFS= read -r section; do
            [[ "$section" == metric.* ]] || continue
            enabled=$(ini_get "$METRICS_AND_THRESHOLDS_INI" "$section" "enabled" "false")
            collect=$(ini_get "$METRICS_AND_THRESHOLDS_INI" "$section" "collect" "false")
            [[ "${enabled,,}" != "true" && "${collect,,}" != "true" ]] && continue
            desc=$(ini_get "$METRICS_AND_THRESHOLDS_INI" "$section" "description" "")
            echo "[${section}]"
            echo "# description = ${desc}"
            echo "# critical ="
            echo "# warning  ="
            echo
        done < <(ini_sections "$METRICS_AND_THRESHOLDS_INI")
    } > "$out"

    echo "created"
    return 0
}

# remove_instance_thresholds_overlay INSTANCE
# Deletes overlay file when present. Prints path removed; returns 0 if deleted, 1 if absent.
remove_instance_thresholds_overlay() {
    local instance="$1" out
    out=$(instance_thresholds_ini "$instance")
    [[ -f "$out" ]] || return 1
    rm -f "$out"
    printf '%s' "$out"
    return 0
}

# ---------- global metrics INI file-backed cache ----------
# Converts metrics_and_thresholds.ini into a flat TSV once per mtime change.
# Each poll subprocess calls _ini_load_global_cache() to pre-populate _INI_CACHE,
# making all subsequent ini_get() calls for that file zero-awk hot-path reads.
# Per-instance overlay files are NOT cached here — they remain on-demand reads.

# _ini_global_cache_path → path of the generated TSV cache
_ini_global_cache_path() {
    printf '%s/metrics_ini_cache.tsv' "${DBMONITOR_RUNTIME:-/tmp}"
}

# _ini_file_mtime FILE → modification timestamp as integer (Linux or macOS)
_ini_file_mtime() {
    local file="$1"
    if stat -c %Y "$file" 2>/dev/null; then return; fi   # GNU/Linux
    stat -f %m "$file" 2>/dev/null || echo "0"            # macOS/BSD
}

# _ini_generate_global_cache — single awk pass over metrics_and_thresholds.ini → TSV
# Format: [section]|key <TAB> value   (comment line 1: # mtime=<stamp>)
# Atomic write via tmp file + mv.
_ini_generate_global_cache() {
    local src="$METRICS_AND_THRESHOLDS_INI"
    [[ -f "$src" ]] || return 0
    local cache; cache=$(_ini_global_cache_path)
    local mtime; mtime=$(_ini_file_mtime "$src")
    local tmp="${cache}.tmp"
    mkdir -p "$(dirname "$cache")" 2>/dev/null || true
    {
        printf '# mtime=%s\n' "$mtime"
        awk -F= '
            /^[[:space:]]*\[/ {
                s=$0; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); cur=s; next
            }
            /^[[:space:]]*[#;]/ { next }
            cur != "" && /=/ {
                k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
                v=$0; sub(/^[^=]*=/,"",v)
                gsub(/[[:space:]]*[#;].*$/,"",v)
                gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
                printf "%s|%s\t%s\n", cur, k, v
            }
        ' "$src"
    } > "$tmp"
    mv "$tmp" "$cache"
}

# _ini_load_global_cache — load (or regenerate) the metrics INI cache into _INI_CACHE.
# Call once per poll invocation before any threshold evaluation.
# Safe to call multiple times; no-ops when _INI_CACHE already contains the metrics file keys.
_ini_load_global_cache() {
    local src="$METRICS_AND_THRESHOLDS_INI"
    [[ -f "$src" ]] || return 0
    local cache; cache=$(_ini_global_cache_path)
    local cur_mtime; cur_mtime=$(_ini_file_mtime "$src")

    # Read the mtime stamp from the first line of an existing cache
    local cached_mtime=""
    if [[ -f "$cache" ]]; then
        IFS= read -r cached_mtime < "$cache"
        cached_mtime="${cached_mtime#\# mtime=}"
    fi

    if [[ "$cached_mtime" != "$cur_mtime" ]]; then
        _ini_generate_global_cache
    fi

    # Pre-populate _INI_CACHE with key format matching ini_get(): "${file}|[section]|key"
    while IFS=$'\t' read -r ck v; do
        [[ "$ck" =~ ^# ]] && continue
        [[ -z "$ck" ]] && continue
        _INI_CACHE["${src}|${ck}"]="$v"
    done < "$cache"
}

# config_apply_runtime_paths — apply path overrides from properties.ini / config.ini
# Call once after sourcing util.sh + config.sh (monitor.sh, daemon.sh, run_monitor.sh).
config_apply_runtime_paths() {
    local rt sec alerts
    rt=$(_path_setting runtime_dir)
    sec=$(_path_setting secrets_dir)
    alerts=$(_path_setting alerts_log_file)

    if [[ -n "$rt" ]]; then
        export DBMONITOR_RUNTIME="$rt"
        export DBMONITOR_HOME="${DBMONITOR_HOME:-$(dirname "$rt")}"
        export DBMONITOR_LOGS_ROOT="${DBMONITOR_RUNTIME}/logs"
        # Re-derive path variables that were frozen at source time
        PID_FILE="${DBMONITOR_RUNTIME}/daemon.pid"
        POLL_PID_FILE="${DBMONITOR_RUNTIME}/poll.pid"
        DAEMON_STOP_FLAG="${DBMONITOR_RUNTIME}/daemon.stop"
        # INSTANCES_FILE is provider-specific (rds_instances.tsv / cloudsql_instances.tsv);
        # instances.sh re-derives it by checking the existing variable suffix.
        if [[ -n "${INSTANCES_FILE:-}" ]]; then
            local _inst_base; _inst_base=$(basename "${INSTANCES_FILE}")
            INSTANCES_FILE="${DBMONITOR_RUNTIME}/${_inst_base}"
        fi
    fi
    if [[ -n "$sec" ]]; then
        export DBMONITOR_SECRETS="$sec"
        [[ -z "$rt" ]] && export DBMONITOR_HOME="${DBMONITOR_HOME:-$(dirname "$sec")}"
        # Re-derive path variables frozen at source time in db_connections.sh and hosts.sh
        CONN_FILE="${DBMONITOR_SECRETS}/connections.tsv"
        HOSTS_FILE="${DBMONITOR_SECRETS}/ssh_hosts.tsv"
    fi
    if [[ -n "$alerts" ]]; then
        export MONITOR_ALERTS_LOG_FILE="$alerts"
    fi
}

# db_default_port TYPE → default TCP port from properties.ini [database.ports]
db_default_port() {
    local t="${1,,}"
    case "$t" in
        postgres) t="postgresql" ;;
        mssql) t="sqlserver" ;;
    esac
    pcfgi database.ports "$t" 0
}

# db_connection_timeout_seconds → timeout for DB CLI checks
db_connection_timeout_seconds() {
    pcfgi database.connection connection_timeout_seconds 10
}

# oracle_client_path_prefix — prepend Oracle Instant Client to PATH when configured
oracle_client_path_prefix() {
    local ocx; ocx=$(_path_setting oracle_client_path)
    [[ -n "$ocx" && -d "$ocx" ]] || return 0
    export PATH="${ocx}:${PATH}"
    [[ -d "${ocx}/lib" ]] && export LD_LIBRARY_PATH="${ocx}/lib:${LD_LIBRARY_PATH:-}"
}
