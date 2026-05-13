#!/usr/bin/env bash
###############################################################################
# Prepare an offline USB bundle for paranoid-vpn metal installs.
#
# The bundle contains:
# - paranoid-vpn scripts
# - optional WireGuard config
# - Fedora RPM dependency cache when dnf download is available
# - offline preflight, dependency install, and hardening helper scripts
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MODULE_SRC_DIR="$MODULE_DIR/src"
MODULE_TOOLS_DIR="$MODULE_DIR/tools"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-$MODULE_DIR/offline-bundles/paranoid-vpn-offline-$TIMESTAMP}"
WG_CONF="${WG_CONF:-}"
DOWNLOAD_RPMS="${DOWNLOAD_RPMS:-1}"
ASSUME_YES="${ASSUME_YES:-1}"
TARGET_FEDORA_RELEASE="${TARGET_FEDORA_RELEASE:-}"
DOWNLOAD_REPOS="${DOWNLOAD_REPOS:-fedora}"
DOWNLOAD_ALL_DEPS="${DOWNLOAD_ALL_DEPS:-1}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"

if [ -z "$TARGET_FEDORA_RELEASE" ] && command -v rpm >/dev/null 2>&1; then
    TARGET_FEDORA_RELEASE="$(rpm -E %fedora 2>/dev/null || true)"
fi
if ! [[ "$TARGET_FEDORA_RELEASE" =~ ^[0-9]+$ ]]; then
    TARGET_FEDORA_RELEASE=""
fi

RPM_PACKAGES=(
    firewalld
    wireguard-tools
    NetworkManager
    curl
    bind-utils
    iproute
    iputils
    procps-ng
    sudo
)

usage() {
    cat <<EOF
Usage:
  $0 [OUTPUT_DIR]

Optional environment:
  OUTPUT_DIR       Bundle directory. Default: module offline-bundles/<timestamp>
  WG_CONF          Optional WireGuard config copied into the bundle.
  DOWNLOAD_RPMS    Download Fedora RPM dependencies into bundle/rpms. Default: 1
  DOWNLOAD_REPOS   Comma-separated Fedora repos used for RPM download.
                   Default: fedora
  DOWNLOAD_ALL_DEPS
                   Use dnf download --alldeps when available. Default: 1
  TARGET_ARCH      Target RPM architecture. Default: current machine arch
  TARGET_FEDORA_RELEASE
                   Fedora release of the offline target, such as 43 or 44.
                   Default: online host release when detectable.
  ASSUME_YES       Use -y for package download/install helpers. Default: 1

Example:
  TARGET_FEDORA_RELEASE=44 WG_CONF=/secure/wg0.conf $0 /run/media/\$USER/OFFLINE_USB/paranoid-vpn
EOF
}

log_section() {
    printf '\n==> %s\n' "$1"
}

log_info() {
    printf '    %s\n' "$1"
}

log_pass() {
    printf ' ok %s\n' "$1"
}

log_warn() {
    printf 'WARN %s\n' "$1" >&2
}

die() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "missing required host command: $command_name"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

write_offline_preflight() {
    local path="$1"

    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WG_CONF="${WG_CONF:-$SCRIPT_DIR/wg0.conf}"

missing=()
for tool in sudo firewall-cmd wg wg-quick ip nmcli systemctl sysctl awk grep install; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if ! command -v dig >/dev/null 2>&1 && ! command -v resolvectl >/dev/null 2>&1; then
    missing+=("dig-or-resolvectl")
fi

printf '\n==> Offline paranoid-vpn preflight\n'

if ((${#missing[@]} > 0)); then
    printf 'Missing required tools:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf '\nTry first:\n  sudo %s/install-offline-deps.sh\n' "$SCRIPT_DIR" >&2
    exit 1
fi

if [ ! -r "$WG_CONF" ]; then
    printf 'WireGuard config is missing or unreadable: %s\n' "$WG_CONF" >&2
    exit 1
fi

if ! grep -Eiq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0[.]0[.]0[.]0/0' "$WG_CONF"; then
    printf 'WireGuard config does not contain full-tunnel IPv4 AllowedIPs.\n' >&2
    printf 'Expected something like: AllowedIPs = 0.0.0.0/0, ::/0\n' >&2
    exit 1
fi

if grep -Eiq '^[[:space:]]*Endpoint[[:space:]]*=.*[A-Za-z]' "$WG_CONF"; then
    printf 'WARN Endpoint appears to use a hostname. Offline first boot may not resolve it.\n' >&2
    printf '     Prefer an IP-address endpoint for cut-off setup.\n' >&2
fi

if ! systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
    printf 'WARN NetworkManager is not enabled.\n' >&2
fi

if ! systemctl is-enabled firewalld.service >/dev/null 2>&1; then
    printf 'WARN firewalld is not enabled. The hardening script will require it.\n' >&2
fi

printf ' ok required tools are present\n'
printf ' ok WireGuard config is readable and full-tunnel\n'
printf '\nNext dry status check:\n  sudo %s/paranoid-vpn.sh --status\n' "$SCRIPT_DIR"
printf '\nTo harden this machine:\n  sudo %s/run-hardening.sh\n' "$SCRIPT_DIR"
EOF
    chmod 755 "$path"
}

write_run_hardening() {
    local path="$1"

    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WG_CONF="${WG_CONF:-$SCRIPT_DIR/wg0.conf}"
ALLOW_SSH_ARG=""

if [ "${ALLOW_SSH:-0}" = "1" ]; then
    ALLOW_SSH_ARG="--allow-ssh"
fi

"$SCRIPT_DIR/offline-preflight.sh"

printf '\n==> Running paranoid-vpn hardening\n'
printf 'Config: %s\n' "$WG_CONF"
if [ -n "$ALLOW_SSH_ARG" ]; then
    printf 'Mode: SSH allowed\n'
else
    printf 'Mode: full SSH lockdown\n'
fi

sudo "$SCRIPT_DIR/paranoid-vpn.sh" --wg-conf "$WG_CONF" $ALLOW_SSH_ARG
EOF
    chmod 755 "$path"
}

write_bundle_readme() {
    local path="$1"

    cat > "$path" <<'EOF'
# Paranoid VPN Offline USB Bundle

Use this on the cut-off Fedora Workstation machine before running network
hardening.

## 1. Optional: install bundled RPMs

```bash
sudo bash ./install-offline-deps.sh
```

## 2. Run preflight

```bash
bash ./offline-preflight.sh
```

If your WireGuard config is not named `wg0.conf` in this directory:

```bash
WG_CONF=/path/to/config.conf bash ./offline-preflight.sh
```

## 3. Harden the machine

Full lockdown:

```bash
sudo bash ./run-hardening.sh
```

Temporary SSH-open test mode:

```bash
ALLOW_SSH=1 sudo bash ./run-hardening.sh
```

## Restore

```bash
sudo ./paranoid-vpn.sh --restore
sudo reboot
```

Keep local console access while testing. The hardening intentionally blocks
non-VPN network paths.
EOF
}

copy_module_files() {
    local bundle_dir="$1"

    install -m 755 "$MODULE_SRC_DIR/paranoid-vpn.sh" "$bundle_dir/paranoid-vpn.sh"
    install -m 755 "$MODULE_SRC_DIR/wg-watchdog.sh" "$bundle_dir/wg-watchdog.sh"
    install -m 755 "$MODULE_TOOLS_DIR/install-deps.sh" "$bundle_dir/install-offline-deps.sh"
    install -m 644 "$MODULE_DIR/README.md" "$bundle_dir/module-README.md"

    if [ -n "$WG_CONF" ]; then
        if [ ! -r "$WG_CONF" ]; then
            die "WG_CONF is not readable: $WG_CONF"
        fi
        install -m 600 "$WG_CONF" "$bundle_dir/wg0.conf"
        log_warn "Copied WireGuard config into bundle as wg0.conf; treat the USB as sensitive"
    fi
}

download_rpms() {
    local rpm_dir="$1"
    local assume_yes=()
    local repo_args=()
    local repo_name
    local repo_names=()

    if [ "$DOWNLOAD_RPMS" != "1" ]; then
        log_warn "DOWNLOAD_RPMS=0; skipping RPM download"
        return 0
    fi

    require_command dnf

    mkdir -p "$rpm_dir"
    if [ "$ASSUME_YES" = "1" ]; then
        assume_yes=(-y)
    fi

    local dnf_prefix=(dnf)
    if [ -n "$TARGET_FEDORA_RELEASE" ]; then
        dnf_prefix+=(--releasever="$TARGET_FEDORA_RELEASE")
        log_info "Target Fedora release: $TARGET_FEDORA_RELEASE"
    else
        log_warn "TARGET_FEDORA_RELEASE is unknown; downloading for the online host release"
    fi
    if [ -n "$DOWNLOAD_REPOS" ]; then
        repo_args+=(--disablerepo='*')
        IFS=',' read -r -a repo_names <<< "$DOWNLOAD_REPOS"
        for repo_name in "${repo_names[@]}"; do
            repo_name="${repo_name//[[:space:]]/}"
            if [ -n "$repo_name" ]; then
                repo_args+=(--enablerepo="$repo_name")
            fi
        done
        log_info "Download repos: $DOWNLOAD_REPOS"
    fi

    if dnf download --help >/dev/null 2>&1; then
        local download_args=(download --resolve --destdir "$rpm_dir" --arch="$TARGET_ARCH" --arch=noarch)
        if [ "$DOWNLOAD_ALL_DEPS" = "1" ] && dnf download --help 2>&1 | grep -q -- '--alldeps'; then
            download_args+=(--alldeps)
        fi
        "${dnf_prefix[@]}" "${repo_args[@]}" "${download_args[@]}" "${RPM_PACKAGES[@]}"
    else
        log_warn "'dnf download' is unavailable; trying install --downloadonly fallback"
        "${dnf_prefix[@]}" "${repo_args[@]}" install "${assume_yes[@]}" --downloadonly --downloaddir "$rpm_dir" "${RPM_PACKAGES[@]}"
    fi

    if ! find "$rpm_dir" -name '*.rpm' -type f | grep -q .; then
        die "RPM download did not produce any RPM files in $rpm_dir"
    fi
}

validate_rpm_cache() {
    local rpm_dir="$1"
    local wireguard_rpm=""

    if [ "$DOWNLOAD_RPMS" != "1" ]; then
        return 0
    fi

    require_command rpm

    while IFS= read -r rpm_file; do
        if rpm -qp --filesbypkg "$rpm_file" 2>/dev/null | grep -Eq '[[:space:]]/usr/bin/wg$'; then
            wireguard_rpm="$rpm_file"
            break
        fi
    done < <(find "$rpm_dir" -name '*.rpm' -type f | sort)

    if [ -z "$wireguard_rpm" ]; then
        die "RPM cache does not contain a package providing /usr/bin/wg"
    fi

    if ! rpm -qp --filesbypkg "$wireguard_rpm" 2>/dev/null | grep -Eq '[[:space:]]/usr/bin/wg-quick$'; then
        die "WireGuard RPM exists but does not provide /usr/bin/wg-quick: $wireguard_rpm"
    fi

    log_pass "RPM cache includes wg and wg-quick: $(basename "$wireguard_rpm")"
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    if [ "${1:-}" != "" ]; then
        OUTPUT_DIR="$1"
    fi

    require_command install
    require_command find
    require_command grep

    log_section "Prepare offline USB bundle"
    mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/rpms"

    copy_module_files "$OUTPUT_DIR"
    write_offline_preflight "$OUTPUT_DIR/offline-preflight.sh"
    write_run_hardening "$OUTPUT_DIR/run-hardening.sh"
    write_bundle_readme "$OUTPUT_DIR/README-OFFLINE.md"
    download_rpms "$OUTPUT_DIR/rpms"
    validate_rpm_cache "$OUTPUT_DIR/rpms"

    log_pass "offline bundle prepared"
    printf '\nBundle path:\n  %s\n' "$OUTPUT_DIR"
    printf '\nCopy this directory to the second pendrive. On the cut-off machine, run:\n'
    printf '  cd %s\n' "$(basename "$OUTPUT_DIR")"
    printf '  bash ./offline-preflight.sh\n'
}

main "$@"
