#!/usr/bin/env bash
# lib/secrets_crypto.sh — AES-256-CBC secret encryption via openssl (no Python).
# Blob format: DBMON1:<base64(iv+ciphertext)>  (compatible with legacy secrets_crypto.py)

_SECRETS_MAGIC="DBMON1:"
_SECRETS_SALT_HEX="64626d6f6e69746f722d736563726574732d76312d37633465396132623166306438653661336335663165396237643261346338"
_SECRETS_PBKDF2_ITERS=210000

_secrets_machine_id() {
    local path v
    for path in /etc/machine-id /var/lib/dbus/machine-id; do
        if [[ -f "$path" ]]; then
            v=$(tr -d '[:space:]' < "$path")
            [[ -n "$v" ]] && { echo "$v"; return 0; }
        fi
    done
    hostname
}

# _secrets_pbkdf2_sha256_hex PASS SALT_HEX ITERATIONS → 64-char hex key
# Matches Python hashlib.pbkdf2_hmac (RFC 2898). OpenSSL 1.1.x `enc -pbkdf2 -P`
# derives key+IV together and does not match; use perl Digest::SHA when available.
_secrets_pbkdf2_sha256_hex() {
    local pass="$1" salt_hex="$2" iter="$3"
    local key
    if command -v perl >/dev/null 2>&1; then
        key=$(SECRETS_PBKDF2_PASS="$pass" SECRETS_PBKDF2_SALT="$salt_hex" SECRETS_PBKDF2_ITER="$iter" \
            perl -MDigest::SHA=hmac_sha256 -e '
use strict; use warnings;
my $pass = $ENV{SECRETS_PBKDF2_PASS} // "";
my $salt_hex = $ENV{SECRETS_PBKDF2_SALT} // "";
my $iter = 0 + ($ENV{SECRETS_PBKDF2_ITER} // 0);
die unless $pass ne "" && $salt_hex =~ /^[0-9a-fA-F]+$/ && $iter > 0;
my $salt = pack("H*", $salt_hex);
my $dklen = 32;
my $block = 1;
my $dk = "";
while (length($dk) < $dklen) {
    my $u = hmac_sha256($salt . pack("N", $block), $pass);
    my $t = $u;
    for (my $i = 2; $i <= $iter; $i++) {
        $u = hmac_sha256($u, $pass);
        $t ^= $u;
    }
    $dk .= $t;
    $block++;
}
my $out = substr($dk, 0, $dklen);
print unpack("H*", $out);
' 2>/dev/null | tr -d '\n')
        [[ ${#key} -eq 64 ]] && { printf '%s' "$key"; return 0; }
    fi
    local helper
    helper="$(dirname "${BASH_SOURCE[0]}")/secrets_pbkdf2"
    if [[ -x "$helper" ]]; then
        key=$(SECRETS_PBKDF2_PASS="$pass" "$helper" "$salt_hex" "$iter" 2>/dev/null | tr -d '\n')
        [[ ${#key} -eq 64 ]] && { printf '%s' "$key"; return 0; }
    fi
    log_warn "secrets: PBKDF2 unavailable (need perl or compiled lib/secrets_pbkdf2)"
    return 1
}

# _secrets_derive_key_hex → 64-char hex key for openssl -K
_secrets_derive_key_hex() {
    local home="${DBMONITOR_HOME:-}"
    local material="${home}:$(_secrets_machine_id)"
    _secrets_pbkdf2_sha256_hex "$material" "$_SECRETS_SALT_HEX" "$_SECRETS_PBKDF2_ITERS"
}

# _secrets_b64_encode FILE → stdout base64 (no newlines)
_secrets_b64_encode() {
    local f="$1"
    if openssl base64 -A -in "$f" 2>/dev/null; then
        return 0
    fi
    base64 -w 0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
}

# _secrets_b64_decode B64_STRING → binary stdout
_secrets_b64_decode() {
    local b64="$1"
    if printf '%s' "$b64" | openssl base64 -d -A 2>/dev/null; then
        return 0
    fi
    printf '%s' "$b64" | base64 -d 2>/dev/null
}

# secrets_encrypt PLAINTEXT → prints DBMON1:... blob
secrets_encrypt() {
    local plaintext="${1:-}"
    local key iv tmp_in tmp_out combined
    key=$(_secrets_derive_key_hex)
    [[ ${#key} -eq 64 ]] || { log_warn "secrets: key derivation failed — cannot encrypt"; return 1; }

    iv=$(openssl rand -hex 16)
    tmp_in=$(mktemp); tmp_out=$(mktemp)
    local tmp_key; tmp_key=$(mktemp); chmod 0600 "$tmp_key"; printf '%s' "$key" > "$tmp_key"; key=""
    printf '%s' "$plaintext" > "$tmp_in"
    if ! openssl enc -aes-256-cbc -nosalt -K "$(<"$tmp_key")" -iv "$iv" -in "$tmp_in" -out "$tmp_out" 2>/dev/null; then
        rm -f "$tmp_in" "$tmp_out" "$tmp_key"
        return 1
    fi
    rm -f "$tmp_key"
    combined=$(mktemp)
    echo "$iv" | xxd -r -p > "$combined"
    cat "$tmp_out" >> "$combined"
    printf '%s' "${_SECRETS_MAGIC}$(_secrets_b64_encode "$combined")"
    rm -f "$tmp_in" "$tmp_out" "$combined"
}

# secrets_decrypt BLOB → plaintext (legacy plaintext passthrough)
secrets_decrypt() {
    local blob="${1:-}"
    blob="${blob//$'\n'/}"
    blob="${blob//$'\r'/}"

    if [[ "$blob" != "${_SECRETS_MAGIC}"* ]]; then
        printf '%s' "$blob"
        return 0
    fi

    local b64="${blob#${_SECRETS_MAGIC}}"
    local key raw iv ct tmp_iv tmp_ct tmp_out
    key=$(_secrets_derive_key_hex)
    [[ ${#key} -eq 64 ]] || return 1

    raw=$(mktemp)
    if ! _secrets_b64_decode "$b64" > "$raw"; then
        rm -f "$raw"
        return 1
    fi

    iv=$(head -c 16 "$raw" | xxd -p -c 32 | tr -d '\n')
    ct=$(mktemp)
    tail -c +17 "$raw" > "$ct"
    rm -f "$raw"

    tmp_out=$(mktemp)
    local tmp_key; tmp_key=$(mktemp); chmod 0600 "$tmp_key"; printf '%s' "$key" > "$tmp_key"; key=""
    if ! openssl enc -d -aes-256-cbc -nosalt -K "$(<"$tmp_key")" -iv "$iv" -in "$ct" -out "$tmp_out" 2>/dev/null; then
        rm -f "$ct" "$tmp_out" "$tmp_key"
        return 1
    fi
    rm -f "$tmp_key"
    cat "$tmp_out"
    rm -f "$ct" "$tmp_out"
}
