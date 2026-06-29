#!/usr/bin/env bash
# lib/notify.sh — alert notification delivery (Teams webhook + optional SMTP)
# Teams HTTP: curl, then wget fallback.
# Email SMTP: curl, then openssl/bash, then sendmail/msmtp.

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/alerts.sh
source "$(dirname "${BASH_SOURCE[0]}")/alerts.sh"
# shellcheck source=lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
# shellcheck source=lib/smtp_send.sh
source "$(dirname "${BASH_SOURCE[0]}")/smtp_send.sh"

# _json_escape STRING — escape for safe embedding inside a JSON string value
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---------- internal helpers ----------

_severity_color() {
    case "$1" in
        CRITICAL) mcfg notifications teams_color_critical FF0000 ;;
        WARNING)  mcfg notifications teams_color_warning  FFA500 ;;
        *)        mcfg notifications teams_color_info     0078D7 ;;
    esac
}

# Build a Teams MessageCard JSON payload — pure bash string ops, no external tools
_teams_payload() {
    local severity="$1" title="$2" body="$3"
    local color; color=$(_severity_color "$severity")
    local etitle; etitle=$(_json_escape "$title")
    local ebody;  ebody=$(_json_escape  "$body")
    printf '{"@type":"MessageCard","@context":"https://schema.org/extensions","summary":"%s","themeColor":"%s","sections":[{"activityTitle":"%s","text":"%s"}]}' \
        "$etitle" "$color" "$etitle" "$ebody"
}

# ---------- HTTP helper (curl preferred, wget fallback) ----------

# _http_post URL PAYLOAD TIMEOUT_SECONDS → 0 on success; prints HTTP code on failure
# Tries curl first, then wget if curl fails or is unavailable.
_http_post() {
    local url="$1" payload="$2" timeout="${3:-15}"
    local http_code="" tried=0

    if command -v curl &>/dev/null; then
        tried=1
        http_code=$(curl --silent --show-error \
            --max-time "$timeout" \
            -o /dev/null \
            -w '%{http_code}' \
            -X POST \
            -H 'Content-Type: application/json' \
            -d "$payload" \
            "$url" 2>/dev/null) || http_code="000"
        [[ "$http_code" =~ ^2 ]] && return 0
    fi

    if command -v wget &>/dev/null; then
        tried=1
        local http_out
        if http_out=$(wget --quiet \
            --method=POST \
            --header='Content-Type: application/json' \
            --body-data="$payload" \
            --server-response \
            --timeout="$timeout" \
            --tries=1 \
            -O /dev/null \
            "$url" 2>&1); then
            return 0
        fi
        http_code=$(printf '%s\n' "$http_out" | grep 'HTTP/' | tail -1 | awk '{print $2}')
        http_code="${http_code:-000}"
    fi

    [[ $tried -eq 0 ]] && {
        log_warn "notify: curl/wget not found — cannot send HTTP notification"
        return 1
    }

    printf '%s' "${http_code:-000}"
    return 1
}

# ---------- Teams ----------

# send_teams WEBHOOK_URL SEVERITY TITLE BODY
# Returns 0 on success, 1 after all retries exhausted.
send_teams() {
    local webhook="$1" severity="$2" title="$3" body="$4"
    [[ -z "$webhook" ]] && { log_warn "notify: Teams webhook URL not set — run: bash monitor.sh notify config set --key teams_webhook_url --value <URL>"; return 1; }

    local max_chars; max_chars=$(mcfgi notifications max_message_chars 20000)
    if [[ ${#body} -gt $max_chars ]]; then
        body="${body:0:$max_chars}...(truncated)"
    fi

    local timeout;      timeout=$(mcfgi     notifications teams_timeout_seconds  15)
    local max_attempts; max_attempts=$(mcfgi notifications teams_max_attempts     2)
    local max_backoff;  max_backoff=$(mcfgi  notifications teams_max_backoff_seconds 5)

    local payload; payload=$(_teams_payload "$severity" "$title" "$body")

    local attempt http_code
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        http_code=$(_http_post "$webhook" "$payload" "$timeout")
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            log_info "notify: Teams alert delivered (attempt $attempt)"
            return 0
        fi
        # Retry only on transient server-side errors; give up on client errors
        case "${http_code:-0}" in
            408|429|500|502|503|504) ;;
            *)
                log_warn "notify: Teams delivery failed (HTTP ${http_code:-unknown}) — not retrying"
                return 1
                ;;
        esac
        if [[ $attempt -lt $max_attempts ]]; then
            local _bm; _bm=$(mcfgi notifications teams_backoff_multiplier 2)
            local backoff=$(( attempt * _bm ))
            [[ $backoff -gt $max_backoff ]] && backoff=$max_backoff
            sleep "$backoff"
        fi
    done
    log_warn "notify: Teams delivery failed after $max_attempts attempts"
    return 1
}

# ---------- SMTP ----------

# send_email SEVERITY TITLE BODY
# Order: curl SMTP → openssl SMTP → sendmail/msmtp (when smtp_host unset)
send_email() {
    local severity="$1" title="$2" body="$3"
    local from;   from=$(mcfg notifications email_from)
    local to_csv; to_csv=$(mcfg notifications email_to)

    [[ -z "$to_csv" || -z "$from" ]] && {
        log_warn "notify: email_from or email_to not configured in config.ini"
        return 1
    }

    local subject="[$severity] $title"

    if smtp_direct_available; then
        smtp_send_message "$from" "$to_csv" "$subject" "$body" && return 0
        if email_mailer_available; then
            log_warn "notify: direct SMTP failed — trying sendmail/msmtp"
            send_email_via_mailer "$from" "$to_csv" "$subject" "$body" && {
                log_info "notify: email delivered via sendmail/msmtp"
                return 0
            }
        fi
        return 1
    fi

    if email_mailer_available; then
        send_email_via_mailer "$from" "$to_csv" "$subject" "$body" && {
            log_info "notify: email delivered via sendmail/msmtp"
            return 0
        }
        log_warn "notify: sendmail/msmtp delivery failed"
        return 1
    fi

    log_warn "notify: email not sent — set smtp_host or install sendmail/msmtp"
    return 1
}

# ---------- dispatch ----------

# _notify_teams_available → 0 when Teams webhook is configured and not disabled
_notify_teams_available() {
    [[ "$(mcfgb notifications teams_enabled true)" == "false" ]] && return 1
    local webhook; webhook=$(get_cred "teams_webhook_url")
    [[ -n "$webhook" ]]
}

# _notify_email_available → 0 when email recipients and delivery path are configured
_notify_email_available() {
    [[ "$(mcfgb notifications email_enabled true)" == "false" ]] && return 1
    local to from
    to=$(mcfg notifications email_to)
    from=$(mcfg notifications email_from)
    [[ -n "$to" && -n "$from" ]] || return 1
    smtp_direct_available && return 0
    email_mailer_available
}

# dispatch_alert SEVERITY SOURCE INSTANCE MESSAGE
# Always writes to alerts.log, then delivers to every configured channel.
dispatch_alert() {
    local severity="$1" source="$2" instance="$3" message="$4"

    log_alert "$severity" "$source" "$instance" "$message"

    [[ "$(mcfgb notifications enabled true)" == "false" ]] && return 0

    local sev_rank min_rank
    case "$severity" in
        CRITICAL) sev_rank=3 ;; WARNING) sev_rank=2 ;; INFO) sev_rank=1 ;; *) sev_rank=0 ;;
    esac
    case "$(mcfg notifications min_severity WARNING)" in
        CRITICAL) min_rank=3 ;; WARNING) min_rank=2 ;; *) min_rank=1 ;;
    esac
    [[ $sev_rank -lt $min_rank ]] && return 0

    local title="[$source] $instance"

    if _notify_teams_available; then
        local webhook; webhook=$(get_cred "teams_webhook_url")
        send_teams "$webhook" "$severity" "$title" "$message" || true
    fi

    if _notify_email_available; then
        send_email "$severity" "$title" "$message" || true
    fi
}
