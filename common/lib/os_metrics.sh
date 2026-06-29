#!/usr/bin/env bash
# lib/os_metrics.sh — collect local OS metrics from /proc (Linux only, no psutil)

# get_cpu_percent → float 0-100
# Uses a file-backed /proc/stat snapshot to compute delta since last call (no blocking sleep).
# First call returns 0.0 and saves the snapshot; subsequent calls return real utilisation.
# The measurement window equals the poll interval, which is more representative than 1 second.
get_cpu_percent() {
    [[ -r /proc/stat ]] || { echo "0.0"; return 0; }
    local u2 n2 s2 i2 rest
    read -r _ u2 n2 s2 i2 rest < /proc/stat

    local snap="${DBMONITOR_RUNTIME:-/tmp}/cpu_stat_snapshot.snap"
    if [[ -f "$snap" ]]; then
        local u1 n1 s1 i1
        IFS=$'\t' read -r u1 n1 s1 i1 < "$snap"
        printf '%s\t%s\t%s\t%s\n' "$u2" "$n2" "$s2" "$i2" > "$snap"
        awk -v u1="$u1" -v n1="$n1" -v s1="$s1" -v i1="$i1" \
            -v u2="$u2" -v n2="$n2" -v s2="$s2" -v i2="$i2" \
            'BEGIN {
                total = (u2+n2+s2+i2) - (u1+n1+s1+i1)
                idle  = i2 - i1
                if (total == 0) { print "0.0"; exit }
                printf "%.1f\n", (1 - idle/total) * 100
            }'
    else
        printf '%s\t%s\t%s\t%s\n' "$u2" "$n2" "$s2" "$i2" > "$snap"
        echo "0.0"
    fi
}

# get_mem_free_mb → float MB
get_mem_free_mb() {
    [[ -r /proc/meminfo ]] || { return 0; }
    awk '/MemAvailable/ { printf "%.1f\n", $2/1024 }' /proc/meminfo
}

# get_mem_total_mb → float MB
get_mem_total_mb() {
    [[ -r /proc/meminfo ]] || { return 0; }
    awk '/MemTotal/ { printf "%.1f\n", $2/1024 }' /proc/meminfo
}

# get_mem_pct → float 0-100 (used%)
get_mem_pct() {
    [[ -r /proc/meminfo ]] || { return 0; }
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END {
        if (t==0) { print "0.0"; exit }
        printf "%.1f\n", (1 - a/t) * 100
    }' /proc/meminfo
}

# get_disk_free_gb [PATH]  → float GB
get_disk_free_gb() {
    df -P "${1:-/}" | awk 'NR==2 { printf "%.2f\n", $4/1024/1024 }'
}

# get_disk_pct [PATH]  → integer 0-100 (used%)
get_disk_pct() {
    df -P "${1:-/}" | awk 'NR==2 { gsub(/%/,"",$5); print $5+0 }'
}

# get_load_1m  → float
get_load_1m()  { [[ -r /proc/loadavg ]] || { return 0; }; awk '{print $1}' /proc/loadavg; }
# get_load_5m  → float
get_load_5m()  { [[ -r /proc/loadavg ]] || { return 0; }; awk '{print $2}' /proc/loadavg; }
# get_load_15m → float
get_load_15m() { [[ -r /proc/loadavg ]] || { return 0; }; awk '{print $3}' /proc/loadavg; }

# get_swap_used_mb → float MB
get_swap_used_mb() {
    [[ -r /proc/meminfo ]] || { return 0; }
    awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END {
        printf "%.1f\n", (t-f)/1024
    }' /proc/meminfo
}

# _default_iface → name of the first non-loopback interface that is UP
# Works on Amazon Linux (ens5, eth0) and most other Linux distros.
_default_iface() {
    local iface
    iface=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
    if [[ -z "$iface" ]]; then
        iface=$(awk 'NR>2 && $1!~/^lo:/ { gsub(/:/, "", $1); print $1; exit }' /proc/net/dev 2>/dev/null)
    fi
    echo "${iface:-eth0}"
}

# get_net_rx_bytes [IFACE]  → integer bytes (cumulative)
get_net_rx_bytes() {
    local iface="${1:-$(_default_iface)}"
    [[ -r /proc/net/dev ]] || { return 0; }
    awk -v i="${iface}:" '$1==i { print $2 }' /proc/net/dev
}

# get_net_tx_bytes [IFACE]  → integer bytes (cumulative)
get_net_tx_bytes() {
    local iface="${1:-$(_default_iface)}"
    [[ -r /proc/net/dev ]] || { return 0; }
    awk -v i="${iface}:" '$1==i { print $10 }' /proc/net/dev
}

# get_net_rx_errors [IFACE]  → integer (cumulative)
get_net_rx_errors() {
    local iface="${1:-$(_default_iface)}"
    [[ -r /proc/net/dev ]] || { return 0; }
    awk -v i="${iface}:" '$1==i { print $4 }' /proc/net/dev
}

# get_net_tx_errors [IFACE]  → integer (cumulative)
get_net_tx_errors() {
    local iface="${1:-$(_default_iface)}"
    [[ -r /proc/net/dev ]] || { return 0; }
    awk -v i="${iface}:" '$1==i { print $12 }' /proc/net/dev
}

# collect_os_metrics [DISK_PATH] [IFACE]
# Prints metrics as KEY<TAB>VALUE<TAB>UNIT (UNIT may be empty).
# Reads each /proc file once per collect call to minimise fork overhead.
collect_os_metrics() {
    local disk_path="${1:-/}"
    local iface="${2:-$(_default_iface)}"

    # CPU — independent snapshot logic
    printf 'cpu_utilization\t%s\t%%\n' "$(get_cpu_percent)"

    # /proc/meminfo — single read for all memory and swap metrics
    if [[ -r /proc/meminfo ]]; then
        local mem_total=0 mem_avail=0 swap_total=0 swap_free=0
        while IFS=': ' read -r key val _; do
            case "$key" in
                MemTotal)     mem_total="$val" ;;
                MemAvailable) mem_avail="$val" ;;
                SwapTotal)    swap_total="$val" ;;
                SwapFree)     swap_free="$val" ;;
            esac
        done < /proc/meminfo
        printf 'memory_utilization\t%s\t%%\n' \
            "$(awk -v t="$mem_total" -v a="$mem_avail" 'BEGIN{ if(t==0){print "0.0"}else{printf "%.1f\n",(1-a/t)*100} }')"
        printf 'free_memory_mb\t%s\tMB\n' \
            "$(awk -v a="$mem_avail" 'BEGIN{ printf "%.1f\n", a/1024 }')"
        printf 'swap_used_mb\t%s\tMB\n' \
            "$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN{ printf "%.1f\n",(t-f)/1024 }')"
    else
        printf 'memory_utilization\t0.0\t%%\n'
        printf 'free_memory_mb\t0.0\tMB\n'
        printf 'swap_used_mb\t0.0\tMB\n'
    fi

    # df — single call for both disk metrics
    local df_out; df_out=$(df -P "$disk_path" 2>/dev/null | awk 'NR==2{print $4, $5}')
    printf 'free_disk_gb\t%s\tGB\n' \
        "$(awk '{printf "%.2f\n", $1/1024/1024}' <<< "$df_out")"
    printf 'disk_utilization\t%s\t%%\n' \
        "$(awk '{gsub(/%/,"",$2); print $2+0}' <<< "$df_out")"

    # /proc/loadavg — single read for all three load averages
    if [[ -r /proc/loadavg ]]; then
        local la1 la5 la15 _rest
        read -r la1 la5 la15 _rest < /proc/loadavg
        printf 'load_avg_1m\t%s\t\n'   "$la1"
        printf 'load_avg_5m\t%s\t\n'   "$la5"
        printf 'load_avg_15m\t%s\t\n'  "$la15"
    else
        printf 'load_avg_1m\t0.0\t\nload_avg_5m\t0.0\t\nload_avg_15m\t0.0\t\n'
    fi

    # /proc/net/dev — single awk pass for all four network metrics
    if [[ -r /proc/net/dev ]]; then
        awk -v iface="${iface}:" '
            $1 == iface {
                printf "net_rx_bytes\t%s\tbytes\n", $2
                printf "net_tx_bytes\t%s\tbytes\n", $10
                printf "net_rx_errors\t%s\t\n",     $4
                printf "net_tx_errors\t%s\t\n",     $12
            }
        ' /proc/net/dev
    else
        printf 'net_rx_bytes\t0\tbytes\nnet_tx_bytes\t0\tbytes\nnet_rx_errors\t0\t\nnet_tx_errors\t0\t\n'
    fi
}
