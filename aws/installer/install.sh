#!/usr/bin/env bash
# install.sh — Monitoring daemon installer (pure bash, no Python/pip)
#
# Installs OS packages (when a package manager is available), AWS CLI v2,
# optional secrets PBKDF2 helper, runtime directories, and default configs.
#
# Usage:
#   bash installer/install.sh
#   INSTALL_PACKAGES=0 bash installer/install.sh    # skip apt/yum/dnf (check only)
#   INSTALL_DB_CLIENTS=1 bash installer/install.sh  # also install mysql/psql clients
#
# Environment:
#   INSTALL_PACKAGES=1|0   Install missing packages via apt/yum/dnf (default: 1)
#   INSTALL_DB_CLIENTS=1|0 Install mysql + postgresql clients (default: 0)
#   SUDO=command           Override sudo (default: sudo when not root)

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd -P)"

INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
INSTALL_DB_CLIENTS="${INSTALL_DB_CLIENTS:-0}"
SUDO="${SUDO:-sudo}"

# ---------- helpers ----------

info()  { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
fail()  { echo "[FAIL]  $*" >&2; exit 1; }

_run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v "$SUDO" &>/dev/null; then
        "$SUDO" "$@"
    else
        return 1
    fi
}

_pkg_mgr() {
    if command -v apt-get &>/dev/null; then
        echo apt
    elif command -v dnf &>/dev/null; then
        echo dnf
    elif command -v yum &>/dev/null; then
        echo yum
    else
        echo none
    fi
}

_have_tool() {
    command -v "$1" &>/dev/null
}

_have_perl_digest_sha() {
    perl -MDigest::SHA=hmac_sha256 -e '1' 2>/dev/null
}

# ---------- OS packages ----------

_apt_install() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -gt 0 ]] || return 0
    info "Installing packages (apt): ${pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive _run_as_root apt-get update -qq || warn "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive _run_as_root apt-get install -y -qq "${pkgs[@]}" \
        || warn "Some apt packages could not be installed: ${pkgs[*]}"
}

_yum_install() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -gt 0 ]] || return 0
    info "Installing packages (yum): ${pkgs[*]}"
    _run_as_root yum install -y "${pkgs[@]}" \
        || warn "Some yum packages could not be installed: ${pkgs[*]}"
}

_dnf_install() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -gt 0 ]] || return 0
    info "Installing packages (dnf): ${pkgs[*]}"
    _run_as_root dnf install -y "${pkgs[@]}" \
        || warn "Some dnf packages could not be installed: ${pkgs[*]}"
}

_install_packages() {
    local mgr; mgr=$(_pkg_mgr)
    if [[ "$INSTALL_PACKAGES" != "1" ]]; then
        info "INSTALL_PACKAGES=0 — skipping OS package installation"
        return 0
    fi
    if [[ "$mgr" == none ]]; then
        warn "No supported package manager (apt/yum/dnf). Install dependencies manually."
        return 0
    fi
    if ! _run_as_root true 2>/dev/null; then
        warn "Not root and sudo unavailable — cannot install OS packages automatically."
        warn "Re-run as root or install packages manually (see docs/README_INSTALL.md)."
        return 0
    fi

    local -a required recommended optional_db compile_deps
    case "$mgr" in
        apt)
            required=(curl wget openssh-client openssl unzip util-linux perl libdigest-sha-perl)
            # xxd: standalone on newer Ubuntu; vim-common on older Debian/Ubuntu
            _have_tool xxd || required+=(xxd vim-common)
            # column: bsdmainutils (Debian/Ubuntu; util-linux on RHEL)
            _have_tool column || required+=(bsdmainutils)
            recommended=(sshpass msmtp)
            optional_db=(default-mysql-client postgresql-client)
            compile_deps=(gcc libssl-dev)
            _apt_install "${required[@]}"
            _apt_install "${recommended[@]}"
            [[ "$INSTALL_DB_CLIENTS" == "1" ]] && _apt_install "${optional_db[@]}"
            ;;
        yum|dnf)
            required=(curl wget openssh-clients openssl unzip util-linux perl perl-Digest-SHA)
            _have_tool xxd || required+=(vim-common)
            recommended=(sshpass)
            optional_db=(mariadb postgresql)
            compile_deps=(gcc openssl-devel)
            if [[ "$mgr" == dnf ]]; then
                _dnf_install "${required[@]}"
                _dnf_install "${recommended[@]}"
                [[ "$INSTALL_DB_CLIENTS" == "1" ]] && _dnf_install "${optional_db[@]}"
            else
                _yum_install "${required[@]}"
                _yum_install "${recommended[@]}"
                [[ "$INSTALL_DB_CLIENTS" == "1" ]] && _yum_install "${optional_db[@]}"
            fi
            ;;
    esac

    # PBKDF2 fallback compile deps (only if perl Digest::SHA still missing)
    if ! _have_perl_digest_sha && ! [[ -x "${BUNDLE_DIR}/lib/secrets_pbkdf2" ]]; then
        case "$mgr" in
            apt) _apt_install "${compile_deps[@]}" ;;
            yum) _yum_install "${compile_deps[@]}" ;;
            dnf) _dnf_install "${compile_deps[@]}" ;;
        esac
    fi
}

# ---------- secrets PBKDF2 helper ----------

build_secrets_pbkdf2() {
    local helper="${BUNDLE_DIR}/lib/secrets_pbkdf2"
    local src="${BUNDLE_DIR}/lib/secrets_pbkdf2.c"

    if _have_perl_digest_sha; then
        ok "Secret encryption: perl Digest::SHA available"
        return 0
    fi
    if [[ -x "$helper" ]]; then
        ok "Secret encryption: ${helper} already built"
        return 0
    fi
    [[ -f "$src" ]] || { warn "Missing ${src}; secret encryption may fail"; return 0; }

    if ! command -v gcc &>/dev/null; then
        warn "perl Digest::SHA and gcc unavailable — encrypted secrets (Teams webhook, DB passwords) will not work"
        warn "Install libdigest-sha-perl (Debian) or perl-Digest-SHA (RHEL), or gcc + libssl-dev/openssl-devel"
        return 0
    fi

    info "Building lib/secrets_pbkdf2 (PBKDF2 fallback)..."
    if gcc -o "$helper" "$src" -lcrypto 2>/dev/null; then
        chmod +x "$helper"
        ok "Built ${helper}"
    else
        warn "Could not compile secrets_pbkdf2 — install perl-Digest-SHA or libssl development headers"
    fi
}

# ---------- check / install aws CLI v2 ----------

install_aws_cli() {
    if command -v aws &>/dev/null; then
        local ver; ver=$(aws --version 2>&1 | awk '{print $1}')
        ok "aws CLI already installed: $ver"
        return
    fi

    _have_tool unzip || fail "unzip is required to install AWS CLI v2 (install unzip first)"

    info "aws CLI not found — installing v2 (standalone binary, no Python required)"

    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64)         local url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        aarch64|arm64)  local url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
        *) fail "Unsupported architecture: $arch. Install aws CLI v2 manually." ;;
    esac

    local tmp_dir; tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    info "Downloading aws CLI v2 for $arch..."
    wget -q "$url" -O "${tmp_dir}/awscliv2.zip"
    unzip -q "${tmp_dir}/awscliv2.zip" -d "$tmp_dir"
    if [[ "$(id -u)" -eq 0 ]]; then
        "${tmp_dir}/aws/install" --update
    elif command -v "$SUDO" &>/dev/null; then
        "$SUDO" "${tmp_dir}/aws/install" --update
    else
        fail "Need root or sudo to install AWS CLI v2"
    fi
    ok "aws CLI v2 installed: $(aws --version 2>&1 | awk '{print $1}')"
}

# ---------- verify tools ----------

check_tools() {
    local missing=()
    local tool
    for tool in bash awk grep sed ssh wget openssl xxd perl flock column timeout unzip mktemp df install; do
        _have_tool "$tool" || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "Missing required tools: ${missing[*]}  Install via your package manager or re-run install.sh as root."
    fi
    ok "Core tools present"

    _have_tool sshpass \
        || warn "sshpass not installed — password SSH hosts require: sudo apt install sshpass  (or yum install sshpass)"
    _have_tool curl \
        || warn "curl not installed — Teams webhook delivery needs curl (wget fallback exists for some paths)"
    _have_tool sendmail || _have_tool msmtp \
        || warn "sendmail/msmtp not installed — local mailer unavailable (use smtp_host in config.ini for direct SMTP)"

    if [[ "$INSTALL_DB_CLIENTS" != "1" ]]; then
        local db_missing=()
        for tool in mysql psql; do
            _have_tool "$tool" || db_missing+=("$tool")
        done
        if [[ ${#db_missing[@]} -gt 0 ]]; then
            info "DB clients not installed (${db_missing[*]}). Re-run with INSTALL_DB_CLIENTS=1 or install clients for engines you use."
        fi
    fi
}

# ---------- set up runtime directory ----------

setup_dirs() {
    local home="${DBMONITOR_HOME:-${BUNDLE_DIR}/.dbmonitor}"
    local runtime="${home}/runtime"
    local secrets="${home}/secrets"
    mkdir -p "$runtime" "$secrets"
    chmod 700 "$secrets"
    ok "Data directory: $home"
}

# ---------- copy default configs if missing ----------

setup_configs() {
    # config.ini: provider-local .default first, then shared common/configs/
    local cfg_def="${BUNDLE_DIR}/configs/config.ini.default"
    [[ -f "$cfg_def" ]] || cfg_def="${BUNDLE_DIR}/../common/configs/config.ini.default"
    local cfg_dst="${BUNDLE_DIR}/configs/config.ini"
    if [[ ! -f "$cfg_dst" ]]; then
        [[ -f "$cfg_def" ]] || fail "config.ini.default not found"
        cp "$cfg_def" "$cfg_dst"
        info "Created config.ini from config.ini.default"
    fi

    # metrics_and_thresholds.ini: always provider-local (different catalog per provider)
    local thr_def="${BUNDLE_DIR}/configs/metrics_and_thresholds.ini.default"
    local thr_dst="${BUNDLE_DIR}/configs/metrics_and_thresholds.ini"
    if [[ ! -f "$thr_dst" ]]; then
        [[ -f "$thr_def" ]] || fail "metrics_and_thresholds.ini.default not found at $thr_def"
        cp "$thr_def" "$thr_dst"
        info "Created metrics_and_thresholds.ini from metrics_and_thresholds.ini.default"
    fi
    ok "Config files ready"

    # properties.ini: provider-local .default first, then shared common/configs/
    local props_def="${BUNDLE_DIR}/configs/properties.ini.default"
    [[ -f "$props_def" ]] || props_def="${BUNDLE_DIR}/../common/configs/properties.ini.default"
    local props_dst="${BUNDLE_DIR}/configs/properties.ini"
    if [[ ! -f "$props_dst" ]]; then
        [[ -f "$props_def" ]] || fail "properties.ini.default not found"
        cp "$props_def" "$props_dst"
        info "Created properties.ini from properties.ini.default"
    fi
    ok "Properties file ready"
}

# ---------- make scripts executable ----------

setup_permissions() {
    chmod +x "${BUNDLE_DIR}/monitor.sh" "${BUNDLE_DIR}/daemon.sh" \
        "${BUNDLE_DIR}/run_monitor.sh" "${BUNDLE_DIR}/stop_monitor.sh" \
        "${BUNDLE_DIR}/installer/"*.sh \
        "${BUNDLE_DIR}/lib/"*.sh "${BUNDLE_DIR}/setup/"*.sh 2>/dev/null || true
    ok "Scripts are executable"
}

# ---------- main ----------

echo ""
echo "====================================================="
echo "  Monitoring Daemon Installer"
echo "  Bundle: $BUNDLE_DIR"
echo "====================================================="
echo ""

_install_packages
check_tools
build_secrets_pbkdf2
install_aws_cli
setup_dirs
setup_configs
setup_permissions

echo ""
echo "====================================================="
ok "Installation complete."
echo ""
echo "  Configure monitoring (edit configs/config.ini):"
echo "    collect_os_metrics / collect_localhost_os / collect_ssh_hosts_os"
echo "    collect_cloud_metrics / collect_db_metrics"
echo ""
echo "  One-shot checks:"
echo "    bash ${BUNDLE_DIR}/monitor.sh os"
echo "    bash ${BUNDLE_DIR}/monitor.sh cloud --instance <RDS_INSTANCE_ID>"
echo "    bash ${BUNDLE_DIR}/monitor.sh monitor --source all --instance <RDS_INSTANCE_ID>"
echo ""
echo "  Start background daemon:"
echo "    bash ${BUNDLE_DIR}/monitor.sh daemon start"
echo ""
echo "  Notifications (Teams):"
echo "    bash ${BUNDLE_DIR}/monitor.sh notify config set --key teams_webhook_url --value <URL>"
echo ""
echo "  Uninstall (stop agents + remove .dbmonitor/):"
echo "    bash ${BUNDLE_DIR}/installer/uninstall.sh"
echo "    bash ${BUNDLE_DIR}/monitor.sh uninstall"
echo ""
echo "  Full documentation: ${BUNDLE_DIR}/docs/HOWTOUSE.txt"
echo "====================================================="
echo ""
