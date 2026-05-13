#!/usr/bin/env bash
###############################################################################
# Install paranoid-vpn runtime dependencies.
#
# Online Fedora guests use dnf repositories. Offline bundles place RPMs in
# ./rpms next to this script, and this installer uses those RPMs first.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RPM_DIR="${RPM_DIR:-$SCRIPT_DIR/rpms}"
ASSUME_YES="${ASSUME_YES:-1}"
ENABLE_SERVICES="${ENABLE_SERVICES:-1}"
INSTALL_DEPS_MODE="${INSTALL_DEPS_MODE:-auto}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"

PACKAGES=(
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

REQUIRED_TOOLS=(
    wg
    wg-quick
    firewall-cmd
    nmcli
    ip
    curl
)

if ((EUID == 0)); then
    SUDO=()
else
    SUDO=(sudo)
fi

usage() {
    cat <<EOF
Usage:
  $0

Optional environment:
  RPM_DIR          Directory containing offline RPMs. Default: ./rpms
  INSTALL_DEPS_MODE
                   Dependency source: auto, offline, or online. Default: auto
  TARGET_ARCH      Preferred RPM architecture. Default: current machine arch
  ASSUME_YES       Pass -y to dnf installs. Default: 1
  ENABLE_SERVICES  Enable/start NetworkManager and firewalld. Default: 1
EOF
}

log_section() {
    printf '\n==> %s\n' "$1"
}

log_pass() {
    printf ' ok %s\n' "$1"
}

die() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

rpm_cache_has_packages() {
    [ -d "$RPM_DIR" ] && find "$RPM_DIR" -name '*.rpm' -type f -print -quit | grep -q .
}

rpm_cache_has_repo_metadata() {
    [ -f "$RPM_DIR/repodata/repomd.xml" ]
}

rpm_package_name() {
    rpm -qp --queryformat '%{NAME}\n' "$1" 2>/dev/null || true
}

rpm_package_arch() {
    rpm -qp --queryformat '%{ARCH}\n' "$1" 2>/dev/null || true
}

find_cached_rpm_for_package() {
    local package_name="$1"
    local rpm_file
    local rpm_arch
    local rpm_name
    local fallback_file=""

    while IFS= read -r rpm_file; do
        rpm_name="$(rpm_package_name "$rpm_file")"
        if [ "$rpm_name" = "$package_name" ]; then
            rpm_arch="$(rpm_package_arch "$rpm_file")"
            if [ "$rpm_arch" = "$TARGET_ARCH" ]; then
                printf '%s\n' "$rpm_file"
                return 0
            fi
            if [ "$rpm_arch" = "noarch" ] && [ -z "$fallback_file" ]; then
                fallback_file="$rpm_file"
            fi
        fi
    done < <(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' -type f | sort -V)

    if [ -n "$fallback_file" ]; then
        printf '%s\n' "$fallback_file"
        return 0
    fi

    return 1
}

install_from_rpms() {
    if command -v dnf >/dev/null 2>&1; then
        if rpm_cache_has_repo_metadata; then
            "${SUDO[@]}" dnf install -y \
                --disablerepo='*' \
                --repofrompath paranoid-vpn-offline,"file://$RPM_DIR" \
                --repo paranoid-vpn-offline \
                --setopt=paranoid-vpn-offline.gpgcheck=0 \
                "${PACKAGES[@]}"
        else
            local rpm_files=()
            local package_name
            local rpm_file

            for package_name in "${PACKAGES[@]}"; do
                if rpm_file="$(find_cached_rpm_for_package "$package_name")"; then
                    rpm_files+=("$rpm_file")
                fi
            done

            if ((${#rpm_files[@]} == 0)); then
                die "RPM cache exists in $RPM_DIR, but none of the required top-level packages were found"
            fi

            "${SUDO[@]}" dnf install -y --disablerepo='*' "${rpm_files[@]}"
        fi
    elif command -v rpm-ostree >/dev/null 2>&1; then
        local rpm_files=()
        local package_name
        local rpm_file

        for package_name in "${PACKAGES[@]}"; do
            if rpm_file="$(find_cached_rpm_for_package "$package_name")"; then
                rpm_files+=("$rpm_file")
            fi
        done

        if ((${#rpm_files[@]} == 0)); then
            die "RPM cache exists in $RPM_DIR, but none of the required top-level packages were found"
        fi

        "${SUDO[@]}" rpm-ostree install "${rpm_files[@]}"
        printf '\nReboot required before newly layered tools are available:\n'
        printf '  sudo reboot\n'
    else
        die "Neither dnf nor rpm-ostree is available on this system."
    fi
}

install_from_repos() {
    local assume_yes=()

    if ! command -v dnf >/dev/null 2>&1; then
        die "No offline RPM cache found in $RPM_DIR and dnf is not available."
    fi

    if [ "$ASSUME_YES" = "1" ]; then
        assume_yes=(-y)
    fi

    "${SUDO[@]}" dnf install "${assume_yes[@]}" "${PACKAGES[@]}"
}

enable_runtime_services() {
    if [ "$ENABLE_SERVICES" != "1" ]; then
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        "${SUDO[@]}" systemctl enable --now NetworkManager.service
        "${SUDO[@]}" systemctl enable --now firewalld.service
    fi
}

verify_tools() {
    local missing=()
    local tool

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if ! command -v dig >/dev/null 2>&1 && ! command -v resolvectl >/dev/null 2>&1; then
        missing+=("dig-or-resolvectl")
    fi

    if ((${#missing[@]} > 0)); then
        printf '\nInstall command finished, but required tools are still missing:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        if command -v rpm-ostree >/dev/null 2>&1; then
            printf '\nIf this is Silverblue/Kinoite/CoreOS, reboot and run preflight again:\n' >&2
            printf '  sudo reboot\n' >&2
        fi
        exit 1
    fi
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    case "$INSTALL_DEPS_MODE" in
        auto|offline|online) ;;
        *) die "INSTALL_DEPS_MODE must be auto, offline, or online" ;;
    esac

    log_section "Installing paranoid-vpn dependencies"

    case "$INSTALL_DEPS_MODE" in
        offline)
            if ! rpm_cache_has_packages; then
                die "Offline dependency mode requested, but no RPM cache exists in $RPM_DIR"
            fi
            install_from_rpms
            ;;
        online)
            install_from_repos
            ;;
        auto)
            if rpm_cache_has_packages; then
                install_from_rpms
            else
                install_from_repos
            fi
            ;;
    esac

    enable_runtime_services
    verify_tools

    log_pass "paranoid-vpn dependencies installed"
}

main "$@"
