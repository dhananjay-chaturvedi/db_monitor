#!/usr/bin/env bash
# lib/smtp_send.sh — direct SMTP: curl, then openssl/bash, then caller may use sendmail/msmtp

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
# shellcheck source=lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

SMTP_IN=""
SMTP_OUT=""
SMTP_TIMEOUT=30
SMTP_LAST_CODE=""
SMTP_LAST_LINE=""

# _smtp_envelope_addr HEADER_VALUE → bare address for MAIL FROM / RCPT TO
_smtp_envelope_addr() {
    local addr="$1"
    if [[ "$addr" =~ \<([^>]+)\> ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        addr="${addr#"${addr%%[![:space:]]*}"}"
        addr="${addr%"${addr##*[![:space:]]}"}"
        printf '%s' "$addr"
    fi
}

# _smtp_build_message FROM TO_CSV SUBJECT BODY → RFC 2822 message on stdout
_smtp_build_message() {
    local from="$1" to_csv="$2" subject="$3" body="$4"
    printf 'From: %s\r\n' "$from"
    printf 'To: %s\r\n' "$to_csv"
    printf 'Subject: %s\r\n' "$subject"
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: text/plain; charset=UTF-8\r\n'
    printf '\r\n'
    printf '%s' "$body"
}

# smtp_direct_available → 0 when smtp_host is configured
smtp_direct_available() {
    local host; host=$(mcfg notifications smtp_host)
    [[ -n "$host" ]]
}

# ---------- curl SMTP ----------

_smtp_send_curl() {
    local from="$1" to_csv="$2" subject="$3" body="$4"
    local host port use_tls use_ssl user pass timeout
    host=$(mcfg notifications smtp_host)
    port=$(mcfgi notifications smtp_port 587)
    use_tls=$(mcfgb notifications smtp_use_tls true)
    use_ssl=$(mcfgb notifications smtp_use_ssl false)
    user=$(mcfg notifications smtp_username)
    pass=$(get_cred smtp_password)
    timeout=$(mcfgi notifications smtp_timeout_seconds 30)

    command -v curl &>/dev/null || return 1

    local env_from; env_from=$(_smtp_envelope_addr "$from")
    local msg_file; msg_file=$(mktemp)
    local curl_cfg_file; curl_cfg_file=$(mktemp)
    trap 'rm -f "$msg_file" "$curl_cfg_file"' RETURN

    _smtp_build_message "$from" "$to_csv" "$subject" "$body" > "$msg_file"

    local url ssl_flag=()
    if [[ "$use_ssl" == "true" || "$port" == "465" ]]; then
        url="smtps://${host}:${port}"
    else
        url="smtp://${host}:${port}"
        [[ "$use_tls" == "true" ]] && ssl_flag=(--ssl-reqd)
    fi

    local -a curl_args=(
        --silent --show-error
        --max-time "$timeout"
        --url "$url"
        "${ssl_flag[@]}"
        --mail-from "$env_from"
        --upload-file "$msg_file"
    )

    if [[ -n "$user" ]]; then
        # Write credentials to a temp config file so they never appear in the process arg list
        chmod 600 "$curl_cfg_file" 2>/dev/null || true
        printf 'user = "%s:%s"\n' "$user" "$pass" > "$curl_cfg_file"
        curl_args+=(--config "$curl_cfg_file")
    fi

    local part rcpt
    IFS=',' read -ra _rcpts <<< "$to_csv"
    for part in "${_rcpts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ -z "$part" ]] && continue
        rcpt=$(_smtp_envelope_addr "$part")
        curl_args+=(--mail-rcpt "$rcpt")
    done

    local err
    if err=$(curl "${curl_args[@]}" 2>&1); then
        log_info "notify: email delivered via curl SMTP (${host}:${port})"
        return 0
    fi

    log_warn "notify: curl SMTP failed (${err:-curl error})"
    return 1
}

# ---------- openssl / bash SMTP ----------

_smtp_b64() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

_smtp_read_response() {
    local line cont
    SMTP_LAST_CODE=""
    SMTP_LAST_LINE=""
    while IFS= read -r -t "$SMTP_TIMEOUT" -u "$SMTP_OUT" line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[0-9]{3} ]] || continue
        SMTP_LAST_CODE="${line:0:3}"
        SMTP_LAST_LINE="$line"
        cont="${line:3:1}"
        [[ "$cont" != "-" ]] && return 0
    done
    return 1
}

_smtp_expect() {
    local want="$1"
    shift
    local code
    for code in "$want" "$@"; do
        [[ "$SMTP_LAST_CODE" == "$code" ]] && return 0
    done
    return 1
}

_smtp_cmd() {
    local cmd="$1"; shift
    local expect=("$@")
    printf '%s\r\n' "$cmd" >&"$SMTP_IN" || return 1
    _smtp_read_response || return 1
    local code
    for code in "${expect[@]}"; do
        [[ "$SMTP_LAST_CODE" == "$code" ]] && return 0
    done
    return 1
}

_smtp_open_openssl() {
    local host="$1" port="$2" use_tls="$3" use_ssl="$4"
    local mode="plain"
    SMTP_TIMEOUT=$(mcfgi notifications smtp_timeout_seconds 30)

    if [[ "$use_ssl" == "true" || "$port" == "465" ]]; then
        mode="ssl"
        coproc SMTP_PROC {
            openssl s_client -quiet -connect "${host}:${port}" -crlf -servername "$host" 2>/dev/null
        }
        SMTP_OUT=${SMTP_PROC[0]}
        SMTP_IN=${SMTP_PROC[1]}
    elif [[ "$use_tls" == "true" ]]; then
        mode="starttls"
        coproc SMTP_PROC {
            openssl s_client -quiet -starttls smtp -connect "${host}:${port}" -crlf -servername "$host" 2>/dev/null
        }
        SMTP_OUT=${SMTP_PROC[0]}
        SMTP_IN=${SMTP_PROC[1]}
    else
        if ! exec {SMTP_FD}<>"/dev/tcp/${host}/${port}" 2>/dev/null; then
            log_warn "notify: SMTP connect failed (${host}:${port})"
            return 1
        fi
        SMTP_OUT=$SMTP_FD
        SMTP_IN=$SMTP_FD
    fi

    if [[ "$mode" == "starttls" ]]; then
        return 0
    fi

    _smtp_read_response || {
        log_warn "notify: SMTP no greeting from ${host}:${port} (${SMTP_LAST_LINE:-timeout})"
        _smtp_close_openssl
        return 1
    }
    _smtp_expect 220 || {
        log_warn "notify: SMTP bad greeting (${SMTP_LAST_LINE})"
        _smtp_close_openssl
        return 1
    }
    return 0
}

_smtp_close_openssl() {
    if [[ -n "$SMTP_IN" && -n "$SMTP_OUT" ]]; then
        _smtp_cmd "QUIT" 221 2>/dev/null || true
        exec {SMTP_IN}>&- 2>/dev/null || true
        [[ "$SMTP_IN" != "$SMTP_OUT" ]] && exec {SMTP_OUT}>&- 2>/dev/null || true
    fi
    SMTP_IN=""
    SMTP_OUT=""
    kill "${SMTP_PROC_PID:-}" 2>/dev/null || true
}

_smtp_auth_openssl() {
    local user="$1" pass="$2"
    [[ -z "$user" || -z "$pass" ]] && return 0
    _smtp_cmd "AUTH LOGIN" 334 || return 1
    _smtp_cmd "$(_smtp_b64 "$user")" 334 || return 1
    _smtp_cmd "$(_smtp_b64 "$pass")" 235 || {
        log_warn "notify: SMTP authentication failed (${SMTP_LAST_LINE})"
        return 1
    }
    return 0
}

_smtp_send_data_openssl() {
    local from="$1" to_csv="$2" message="$3"
    local env_from; env_from=$(_smtp_envelope_addr "$from")
    local rcpt part

    _smtp_cmd "EHLO dbmonitor.local" 250 || return 1
    _smtp_cmd "MAIL FROM:<${env_from}>" 250 || return 1

    IFS=',' read -ra _rcpts <<< "$to_csv"
    for part in "${_rcpts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ -z "$part" ]] && continue
        rcpt=$(_smtp_envelope_addr "$part")
        _smtp_cmd "RCPT TO:<${rcpt}>" 250 251 || return 1
    done

    _smtp_cmd "DATA" 354 || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == .* ]] && line=".$line"
        printf '%s\r\n' "$line" >&"$SMTP_IN" || return 1
    done <<< "$message"
    printf '\r\n.\r\n' >&"$SMTP_IN" || return 1

    _smtp_read_response || return 1
    _smtp_expect 250 || {
        log_warn "notify: SMTP DATA rejected (${SMTP_LAST_LINE})"
        return 1
    }
    return 0
}

_smtp_send_openssl() {
    local from="$1" to_csv="$2" subject="$3" body="$4"
    local host port use_tls use_ssl user pass
    host=$(mcfg notifications smtp_host)
    port=$(mcfgi notifications smtp_port 587)
    use_tls=$(mcfgb notifications smtp_use_tls true)
    use_ssl=$(mcfgb notifications smtp_use_ssl false)
    user=$(mcfg notifications smtp_username)
    pass=$(get_cred smtp_password)

    if ! command -v openssl &>/dev/null; then
        return 1
    fi

    local message
    message=$(_smtp_build_message "$from" "$to_csv" "$subject" "$body")

    _smtp_open_openssl "$host" "$port" "$use_tls" "$use_ssl" || return 1

    if [[ -n "$user" ]]; then
        _smtp_auth_openssl "$user" "$pass" || { _smtp_close_openssl; return 1; }
    fi

    if _smtp_send_data_openssl "$from" "$to_csv" "$message"; then
        log_info "notify: email delivered via openssl SMTP (${host}:${port})"
        _smtp_close_openssl
        return 0
    fi

    log_warn "notify: openssl SMTP failed (${SMTP_LAST_LINE:-no response})"
    _smtp_close_openssl
    return 1
}

# smtp_send_message FROM TO_CSV SUBJECT BODY — curl, then openssl/bash
smtp_send_message() {
    local from="$1" to_csv="$2" subject="$3" body="$4"

    [[ -z "$(mcfg notifications smtp_host)" ]] && return 1

    if _smtp_send_curl "$from" "$to_csv" "$subject" "$body"; then
        return 0
    fi

    if _smtp_send_openssl "$from" "$to_csv" "$subject" "$body"; then
        return 0
    fi

    return 1
}

# send_email_via_mailer FROM TO_CSV SUBJECT BODY — sendmail/msmtp pipe
send_email_via_mailer() {
    local from="$1" to_csv="$2" subject="$3" body="$4"
    local mailer
    if   command -v sendmail &>/dev/null; then mailer="sendmail"
    elif command -v msmtp    &>/dev/null; then mailer="msmtp"
    else
        return 1
    fi

    _smtp_build_message "$from" "$to_csv" "$subject" "$body" | "$mailer" -t 2>/dev/null
}

# email_mailer_available → 0 when sendmail or msmtp is installed
email_mailer_available() {
    command -v sendmail &>/dev/null || command -v msmtp &>/dev/null
}
