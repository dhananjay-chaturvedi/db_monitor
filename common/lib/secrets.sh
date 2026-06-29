#!/usr/bin/env bash
# lib/secrets.sh — encrypted credential storage under .dbmonitor/secrets/
# On EC2, IAM roles or Systems Manager Parameter Store are preferred.
# This module handles local credential storage for on-prem / hybrid setups.

# shellcheck source=lib/util.sh
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"

# shellcheck source=lib/secrets_crypto.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets_crypto.sh"

# save_cred NAME VALUE
# Write encrypted VALUE to .dbmonitor/secrets/NAME with mode 0600.
save_cred() {
    local name="$1" value="$2"
    ensure_dirs
    local path="${DBMONITOR_SECRETS}/${name}"
    local enc
    enc=$(secrets_encrypt "$value")
    install -m 0600 /dev/null "$path"
    printf '%s' "$enc" > "$path"
}

# get_cred NAME → prints the credential or empty string
get_cred() {
    local path="${DBMONITOR_SECRETS}/$1"
    [[ -f "$path" ]] || { echo ""; return 0; }
    local blob
    blob=$(cat "$path")
    secrets_decrypt "$blob"
}

# delete_cred NAME
delete_cred() {
    rm -f "${DBMONITOR_SECRETS}/$1"
}

# cred_exists NAME → returns 0 if exists, 1 if not
cred_exists() {
    [[ -f "${DBMONITOR_SECRETS}/$1" ]]
}
