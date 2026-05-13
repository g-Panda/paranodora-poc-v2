#!/usr/bin/env bash
###############################################################################
# Persistent desktop VM instrumented network test for paranoid-vpn.
#
# This runner provisions a Fedora libvirt VM, installs a graphical desktop,
# applies paranoid-vpn, runs VM-side network checks plus host-side nmap audit,
# then leaves the VM running for manual testing until the user confirms cleanup.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MODULE_SRC_DIR="$MODULE_DIR/src"
MODULE_TOOLS_DIR="$MODULE_DIR/tools"

# shellcheck source=modules/paranoid-vpn/test/lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
STARTED_AT="$(date -Is)"

FEDORA_RELEASE="${FEDORA_RELEASE:-43}"
FEDORA_ARCH="${FEDORA_ARCH:-x86_64}"
FEDORA_IMAGE_INDEX_URL="${FEDORA_IMAGE_INDEX_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Cloud/${FEDORA_ARCH}/images/}"
FEDORA_DESKTOP_PROFILE="${FEDORA_DESKTOP_PROFILE:-lab}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_BOOT_ATTEMPTS="${VM_BOOT_ATTEMPTS:-90}"
VM_BOOT_DELAY="${VM_BOOT_DELAY:-5}"
VM_USER="${VM_USER:-fedora}"
VM_PORT="${VM_PORT:-22}"
VM_NAME="${VM_NAME:-paranoid-vpn-desktop-${TIMESTAMP}-$$}"
VM_GRAPHICS="${VM_GRAPHICS:-spice,listen=127.0.0.1}"

PUBLIC_IP_URL="${PUBLIC_IP_URL:-https://ifconfig.me}"
VPN_EXPECTED_EXIT_IP="${VPN_EXPECTED_EXIT_IP:-auto}"
TEST_ALLOW_SSH="${TEST_ALLOW_SSH:-0}"
KEEP_VM_ON_EXIT="${KEEP_VM_ON_EXIT:-0}"
RUN_DESTRUCTIVE_ON_CLEANUP="${RUN_DESTRUCTIVE_ON_CLEANUP:-0}"
AUTO_INSTALL_HOST_DEPS="${AUTO_INSTALL_HOST_DEPS:-1}"
HOST_SETUP_ASSUME_YES="${HOST_SETUP_ASSUME_YES:-1}"
NMAP_FULL_AUDIT="${NMAP_FULL_AUDIT:-1}"
NMAP_PORTS="${NMAP_PORTS:-1-1024,51820,22,53}"
NMAP_UDP_PORTS="${NMAP_UDP_PORTS:-53,123,51820}"
NMAP_TIMEOUT="${NMAP_TIMEOUT:-300}"
NMAP_UDP_TIMEOUT="${NMAP_UDP_TIMEOUT:-300}"
NMAP_ALLOWED_OPEN_TCP="${NMAP_ALLOWED_OPEN_TCP:-}"
WATCHDOG_ATTEMPTS="${WATCHDOG_ATTEMPTS:-12}"
WATCHDOG_DELAY="${WATCHDOG_DELAY:-5}"

ARTIFACT_DIR="${TEST_ARTIFACT_DIR:-$SCRIPT_DIR/artifacts/desktop-$TIMESTAMP}"
if [ -n "${VM_CACHE_DIR:-}" ]; then
    CACHE_DIR="$VM_CACHE_DIR"
elif [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
    CACHE_DIR="/var/tmp/paranoid-vpn-vm-cache"
else
    CACHE_DIR="$SCRIPT_DIR/vm-cache"
fi
if [ -n "${VM_WORK_DIR:-}" ]; then
    WORK_DIR="$VM_WORK_DIR"
elif [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
    WORK_DIR="/var/tmp/paranoid-vpn-desktop-${TIMESTAMP}-$$"
else
    WORK_DIR="$ARTIFACT_DIR/vm-work"
fi
REPORT_PATH="${VM_INTEGRATION_REPORT:-$ARTIFACT_DIR/desktop-vm-report-$TIMESTAMP.md}"
RUNNER_LOG="$ARTIFACT_DIR/desktop-runner.log"
HOST_TOOLS_FILE="$ARTIFACT_DIR/host-tools.txt"
PREFLIGHT_ERRORS_FILE="$ARTIFACT_DIR/preflight-errors.txt"
KNOWN_HOSTS_FILE="$WORK_DIR/known_hosts"

BASE_IMAGE_PATH=""
FEDORA_IMAGE_NAME=""
FEDORA_IMAGE_SOURCE="${FEDORA_CLOUD_IMAGE_URL:-}"
VM_DISK_PATH="$WORK_DIR/${VM_NAME}.qcow2"
SEED_ISO_PATH="$WORK_DIR/${VM_NAME}-seed.iso"
USER_DATA_PATH="$WORK_DIR/user-data"
META_DATA_PATH="$WORK_DIR/meta-data"
SSH_KEY_PATH="$WORK_DIR/id_ed25519"
SSH_CONTROL_PATH="$WORK_DIR/ssh-control-%h-%p-%r"
VM_IP=""
PHASE="initialization"
RESULT="failed"
FAILURE_MESSAGE=""
CLEANUP_STATUS="not-started"
SEED_TOOL=""
PREFLIGHT_ONLY=0
MANUAL_PAUSE_REACHED=0
VM_CLEANUP_REQUIRED=0
HOST_SETUP_RERUN_REQUIRED=0
SUDO_KEEPALIVE_PID=""
PROGRESS_CURRENT=0
PROGRESS_TOTAL="${PROGRESS_TOTAL:-24}"
PROGRESS_WIDTH="${PROGRESS_WIDTH:-24}"

declare -a PREFLIGHT_ERRORS=()
declare -a HOST_SETUP_PACKAGES=()
declare -a HOST_SETUP_ACTIONS=()
declare -a SSH_BASE_OPTS=()
declare -a SSH_CONTROL_OPTS=()
declare -a SCP_CONTROL_OPTS=()

usage() {
    cat <<EOF
Usage:
  TEST_WG_CONF=/path/to/wg0.conf $0
  $0 --preflight-only

Required environment:
  TEST_WG_CONF              Local WireGuard config copied into the VM.

Optional environment:
  FEDORA_RELEASE            Fedora Cloud release. Default: 43
  FEDORA_CLOUD_IMAGE_URL    Exact Fedora Cloud qcow2 URL. Default: discovered
                            from the Fedora release image index.
  FEDORA_DESKTOP_PROFILE    Guest desktop package profile: lab or workstation.
                            Default: lab
  LIBVIRT_URI               Libvirt connection URI. Default: qemu:///system
  LIBVIRT_NETWORK           Libvirt NAT/private network. Default: default
  VM_MEMORY_MB              VM memory. Default: 4096
  VM_CPUS                   VM vCPU count. Default: 2
  VM_DISK_SIZE              Persistent lab overlay disk size. Default: 40G
  VM_GRAPHICS               virt-install graphics string. Default: spice,listen=127.0.0.1
  TEST_ALLOW_SSH            Keep SSH open in paranoid firewall. Default: 0
  KEEP_VM_ON_EXIT           Leave VM and generated files on exit/Ctrl-C. Default: 0
  RUN_DESTRUCTIVE_ON_CLEANUP Run tunnel-down kill-switch test before cleanup. Default: 0
  AUTO_INSTALL_HOST_DEPS    Install missing host packages and libvirt setup. Default: 1
  HOST_SETUP_ASSUME_YES     Pass -y to supported package managers. Default: 1
  NMAP_FULL_AUDIT           Use service/version/default/safe nmap checks. Default: 1
  NMAP_PORTS                TCP ports scanned from host. Default: 1-1024,51820,22,53
  NMAP_UDP_PORTS            UDP ports scanned from host. Default: 53,123,51820
  NMAP_ALLOWED_OPEN_TCP     Comma-separated TCP ports allowed to be open.
  TEST_ARTIFACT_DIR         Artifact directory. Default: module test artifacts/desktop-<timestamp>
EOF
}

set_phase() {
    PHASE="$1"
    PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
    print_progress "$PHASE" "$PROGRESS_CURRENT" "$PROGRESS_TOTAL"
}

progress_bar() {
    local current="$1"
    local total="$2"
    local width="$3"
    local filled empty percent

    if (( total <= 0 )); then
        total=1
    fi
    if (( current > total )); then
        current="$total"
    fi

    filled=$((current * width / total))
    empty=$((width - filled))
    percent=$((current * 100 / total))

    printf '['
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf '] %3d%%' "$percent"
}

print_progress() {
    local label="$1"
    local current="$2"
    local total="$3"

    printf '\n==> %s/%s ' "$current" "$total"
    progress_bar "$current" "$total" "$PROGRESS_WIDTH"
    printf ' %s\n' "$label"
}

print_attempt_progress() {
    local label="$1"
    local current="$2"
    local total="$3"

    printf '    %s ' "$label"
    progress_bar "$current" "$total" 18
    printf ' (%s/%s)\n' "$current" "$total"
}

pulse_bar() {
    local tick="$1"
    local width="$2"
    local pos bar index

    pos=$((tick % width))
    bar=""
    for ((index = 0; index < width; index++)); do
        if (( index == pos )); then
            bar="${bar}#"
        else
            bar="${bar}-"
        fi
    done

    printf '[%s]' "$bar"
}

animate_activity() {
    local label="$1"
    local pid="$2"
    local timeout_seconds="$3"
    local started elapsed tick spinner spinner_char

    started="$(date +%s)"
    tick=0
    spinner='-\|/'

    while kill -0 "$pid" >/dev/null 2>&1; do
        elapsed=$(($(date +%s) - started))
        spinner_char="${spinner:tick % 4:1}"
        printf '\r    %s ' "$label"
        pulse_bar "$tick" 18
        printf ' %s elapsed %ss/%ss' "$spinner_char" "$elapsed" "$timeout_seconds"
        tick=$((tick + 1))
        sleep 1
    done

    printf '\r    %s ' "$label"
    progress_bar 1 1 18
    printf ' done%*s\n' 24 ''
}

die() {
    FAILURE_MESSAGE="$1"
    log_error "$FAILURE_MESSAGE"
    exit 1
}

add_preflight_error() {
    PREFLIGHT_ERRORS+=("$1")
}

print_preflight_errors() {
    local error_line
    local missing_commands=()

    if ((${#PREFLIGHT_ERRORS[@]} == 0)) && [ -s "$PREFLIGHT_ERRORS_FILE" ]; then
        mapfile -t PREFLIGHT_ERRORS < "$PREFLIGHT_ERRORS_FILE"
    fi

    log_error "Host preflight found ${#PREFLIGHT_ERRORS[@]} problem(s):"
    for error_line in "${PREFLIGHT_ERRORS[@]}"; do
        printf '  - %s\n' "$error_line" >&2
        if [[ "$error_line" == missing\ host\ command:* ]]; then
            missing_commands+=("${error_line#missing host command: }")
        fi
    done

    if ((${#missing_commands[@]} > 0)); then
        printf '\nMissing command install hints:\n' >&2
        printf '  Fedora/RHEL: sudo dnf install -y virt-install nmap cloud-utils genisoimage\n' >&2
        printf '  Debian/Ubuntu: sudo apt-get install -y virtinst nmap cloud-image-utils genisoimage\n' >&2
    fi

    if printf '%s\n' "${PREFLIGHT_ERRORS[@]}" | grep -Eq 'cannot access libvirt URI|timed out checking libvirt URI|current user is not in the libvirt group'; then
        printf '\nLibvirt access hint:\n' >&2
        printf '  Try: sudo usermod -aG libvirt "$USER" && newgrp libvirt\n' >&2
        printf '  Or run with sudo if your local policy allows it.\n' >&2
        printf '  Quick check: timeout 10 virsh --connect %s list --all\n' "$LIBVIRT_URI" >&2
    fi

    printf '\nPreflight artifact files:\n' >&2
    printf '  Errors: %s\n' "$PREFLIGHT_ERRORS_FILE" >&2
    printf '  Host tools: %s\n' "$HOST_TOOLS_FILE" >&2
}

user_in_group() {
    local group_name="$1"

    id -nG 2>/dev/null | tr ' ' '\n' | grep -Fxq "$group_name"
}

array_contains() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

host_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf 'dnf\n'
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt-get\n'
        return 0
    fi

    return 1
}

package_for_command() {
    local command_name="$1"
    local package_manager="$2"

    case "$package_manager:$command_name" in
        dnf:virt-install) printf 'virt-install\n' ;;
        dnf:nmap) printf 'nmap\n' ;;
        dnf:cloud-localds) printf 'cloud-utils\n' ;;
        dnf:genisoimage|dnf:mkisofs) printf 'genisoimage\n' ;;
        dnf:virsh) printf 'libvirt-client\n' ;;
        dnf:qemu-img) printf 'qemu-img\n' ;;
        dnf:curl) printf 'curl\n' ;;
        dnf:ssh|dnf:scp|dnf:ssh-keygen) printf 'openssh-clients\n' ;;
        dnf:timeout) printf 'coreutils\n' ;;
        dnf:awk) printf 'gawk\n' ;;
        dnf:sed) printf 'sed\n' ;;
        dnf:grep) printf 'grep\n' ;;
        apt-get:virt-install) printf 'virtinst\n' ;;
        apt-get:nmap) printf 'nmap\n' ;;
        apt-get:cloud-localds) printf 'cloud-image-utils\n' ;;
        apt-get:genisoimage|apt-get:mkisofs) printf 'genisoimage\n' ;;
        apt-get:virsh) printf 'libvirt-clients\n' ;;
        apt-get:qemu-img) printf 'qemu-utils\n' ;;
        apt-get:curl) printf 'curl\n' ;;
        apt-get:ssh|apt-get:scp|apt-get:ssh-keygen) printf 'openssh-client\n' ;;
        apt-get:timeout) printf 'coreutils\n' ;;
        apt-get:awk) printf 'gawk\n' ;;
        apt-get:sed) printf 'sed\n' ;;
        apt-get:grep) printf 'grep\n' ;;
        *) return 1 ;;
    esac
}

add_host_setup_package() {
    local package_name="$1"

    if [ -n "$package_name" ] && ! array_contains "$package_name" "${HOST_SETUP_PACKAGES[@]}"; then
        HOST_SETUP_PACKAGES+=("$package_name")
    fi
}

add_host_setup_action() {
    local action="$1"

    if ! array_contains "$action" "${HOST_SETUP_ACTIONS[@]}"; then
        HOST_SETUP_ACTIONS+=("$action")
    fi
}

start_sudo_keepalive() {
    while true; do
        sudo -n true >/dev/null 2>&1 || exit 0
        sleep 45
    done &
    SUDO_KEEPALIVE_PID="$!"
}

stop_sudo_keepalive() {
    if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
        kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

require_terminal_sudo() {
    log_info "Requesting sudo once in the terminal for host setup"
    if ! sudo -v; then
        die "sudo authentication failed; cannot perform automatic host setup"
    fi
    start_sudo_keepalive
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        add_preflight_error "missing host command: $command_name"
    fi
}

required_host_commands() {
    printf '%s\n' bash curl ssh scp ssh-keygen virsh virt-install qemu-img timeout awk sed grep nmap
}

validate_wireguard_input() {
    if [ -z "${TEST_WG_CONF:-}" ]; then
        add_preflight_error "missing required environment variable: TEST_WG_CONF"
    elif [ ! -r "$TEST_WG_CONF" ]; then
        add_preflight_error "TEST_WG_CONF is not readable"
    elif ! grep -Eiq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0[.]0[.]0[.]0/0' "$TEST_WG_CONF"; then
        add_preflight_error "TEST_WG_CONF does not contain full-tunnel IPv4 AllowedIPs"
    fi
}

validate_desktop_profile() {
    case "$FEDORA_DESKTOP_PROFILE" in
        lab|workstation) ;;
        *) add_preflight_error "FEDORA_DESKTOP_PROFILE must be 'lab' or 'workstation'" ;;
    esac
}

validate_expected_exit_ip() {
    if [ "$VPN_EXPECTED_EXIT_IP" != "auto" ] && ! [[ "$VPN_EXPECTED_EXIT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        add_preflight_error "VPN_EXPECTED_EXIT_IP must be an exact IPv4 address or 'auto'"
    fi
}

first_command() {
    local command_name

    for command_name in "$@"; do
        if command -v "$command_name" >/dev/null 2>&1; then
            printf '%s\n' "$command_name"
            return 0
        fi
    done

    return 1
}

detect_missing_host_packages() {
    local package_manager="$1"
    local command_name package_name

    while IFS= read -r command_name; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            if package_name="$(package_for_command "$command_name" "$package_manager")"; then
                add_host_setup_package "$package_name"
            else
                add_preflight_error "missing host command without package mapping: $command_name"
            fi
        fi
    done < <(required_host_commands)

    if ! first_command cloud-localds genisoimage mkisofs >/dev/null; then
        if package_name="$(package_for_command cloud-localds "$package_manager")"; then
            add_host_setup_package "$package_name"
        fi
        if package_name="$(package_for_command genisoimage "$package_manager")"; then
            add_host_setup_package "$package_name"
        fi
    fi
}

plan_host_setup() {
    local package_manager

    HOST_SETUP_PACKAGES=()
    HOST_SETUP_ACTIONS=()

    if ! package_manager="$(host_package_manager)"; then
        add_preflight_error "could not find supported package manager: dnf or apt-get"
        return
    fi

    detect_missing_host_packages "$package_manager"

    if [[ "$LIBVIRT_URI" = qemu:///system* ]] && [ "$(id -u)" != "0" ] && ! user_in_group libvirt; then
        add_host_setup_action "add current user to libvirt group"
    fi
}

print_host_setup_plan() {
    local package_manager="$1"
    local package_name action

    print_progress "Host setup plan" "$PROGRESS_CURRENT" "$PROGRESS_TOTAL"
    log_info "Package manager: $package_manager"

    if ((${#HOST_SETUP_PACKAGES[@]} > 0)); then
        printf 'Packages to install:\n'
        for package_name in "${HOST_SETUP_PACKAGES[@]}"; do
            printf '  - %s\n' "$package_name"
        done
    else
        printf 'Packages to install: none\n'
    fi

    if ((${#HOST_SETUP_ACTIONS[@]} > 0)); then
        printf 'Libvirt/user actions:\n'
        for action in "${HOST_SETUP_ACTIONS[@]}"; do
            printf '  - %s\n' "$action"
        done
    else
        printf 'Libvirt/user actions: none\n'
    fi
}

print_manual_host_setup() {
    local package_manager="$1"

    printf '\nAutomatic host setup is disabled. Run these commands, then rerun the script:\n' >&2

    if ((${#HOST_SETUP_PACKAGES[@]} > 0)); then
        case "$package_manager" in
            dnf)
                printf '  sudo dnf install -y %s\n' "${HOST_SETUP_PACKAGES[*]}" >&2
                ;;
            apt-get)
                printf '  sudo apt-get update\n' >&2
                printf '  sudo apt-get install -y %s\n' "${HOST_SETUP_PACKAGES[*]}" >&2
                ;;
        esac
    fi

    if array_contains "add current user to libvirt group" "${HOST_SETUP_ACTIONS[@]}"; then
        printf '  sudo usermod -aG libvirt "$USER"\n' >&2
        printf '  newgrp libvirt\n' >&2
    fi
}

install_host_packages() {
    local package_manager="$1"
    local assume_yes=()

    if ((${#HOST_SETUP_PACKAGES[@]} == 0)); then
        return 0
    fi

    if [ "$HOST_SETUP_ASSUME_YES" = "1" ]; then
        assume_yes=(-y)
    fi

    case "$package_manager" in
        dnf)
            sudo -n dnf install "${assume_yes[@]}" "${HOST_SETUP_PACKAGES[@]}"
            ;;
        apt-get)
            sudo -n apt-get update
            sudo -n apt-get install "${assume_yes[@]}" "${HOST_SETUP_PACKAGES[@]}"
            ;;
        *)
            die "unsupported package manager for host setup: $package_manager"
            ;;
    esac
}

apply_libvirt_host_setup() {
    if array_contains "add current user to libvirt group" "${HOST_SETUP_ACTIONS[@]}"; then
        if ! getent group libvirt >/dev/null 2>&1; then
            die "libvirt group does not exist after package setup"
        fi

        sudo -n usermod -aG libvirt "$USER"
        HOST_SETUP_RERUN_REQUIRED=1
        log_warn "Added $USER to libvirt group; refresh your shell session before rerunning"
    fi
}

maybe_enable_libvirt_service() {
    if [[ "$LIBVIRT_URI" != qemu:///system* ]] || ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if systemctl list-unit-files libvirtd.service >/dev/null 2>&1; then
        if ! systemctl is-active --quiet libvirtd.service; then
            log_info "Starting libvirtd.service"
            sudo -n systemctl enable --now libvirtd.service
        fi
    elif systemctl list-unit-files virtqemud.service >/dev/null 2>&1; then
        if ! systemctl is-active --quiet virtqemud.service; then
            log_info "Starting virtqemud.service"
            sudo -n systemctl enable --now virtqemud.service
        fi
    fi
}

run_host_setup() {
    local package_manager

    set_phase "Host setup"

    PREFLIGHT_ERRORS=()
    validate_wireguard_input
    validate_desktop_profile
    validate_expected_exit_ip
    if ((${#PREFLIGHT_ERRORS[@]} > 0)); then
        printf '%s\n' "${PREFLIGHT_ERRORS[@]}" > "$PREFLIGHT_ERRORS_FILE"
        print_preflight_errors
        die "host setup blocked by invalid test input"
    fi

    if ! package_manager="$(host_package_manager)"; then
        add_preflight_error "could not find supported package manager: dnf or apt-get"
        printf '%s\n' "${PREFLIGHT_ERRORS[@]}" > "$PREFLIGHT_ERRORS_FILE"
        print_preflight_errors
        die "host setup failed before preflight"
    fi

    plan_host_setup

    if ((${#PREFLIGHT_ERRORS[@]} > 0)); then
        printf '%s\n' "${PREFLIGHT_ERRORS[@]}" > "$PREFLIGHT_ERRORS_FILE"
        print_preflight_errors
        die "host setup cannot continue"
    fi

    if ((${#HOST_SETUP_PACKAGES[@]} == 0)) && ((${#HOST_SETUP_ACTIONS[@]} == 0)); then
        log_pass "host setup is already satisfied"
        return 0
    fi

    print_host_setup_plan "$package_manager"

    if [ "$AUTO_INSTALL_HOST_DEPS" != "1" ]; then
        print_manual_host_setup "$package_manager"
        die "host setup is required and AUTO_INSTALL_HOST_DEPS=0"
    fi

    require_terminal_sudo
    install_host_packages "$package_manager"
    maybe_enable_libvirt_service
    apply_libvirt_host_setup

    if [ "$HOST_SETUP_RERUN_REQUIRED" = "1" ]; then
        cat >&2 <<EOF

Host setup changed your group membership.

Run one of these, then rerun this script:
  newgrp libvirt
  # or log out and log back in

Quick check:
  virsh --connect $LIBVIRT_URI list --all

EOF
        die "host setup completed; rerun after refreshing libvirt group membership"
    fi

    log_pass "host setup completed"
}

run_with_timeout() {
    local seconds="$1"
    shift

    timeout "$seconds" "$@"
}

shell_quote() {
    printf '%q' "$1"
}

normalize_one_line() {
    sed 's/[[:space:]]//g'
}

tool_version() {
    local tool="$1"

    case "$tool" in
        ssh|scp|ssh-keygen)
            ssh -V 2>&1 | sed -n '1p'
            ;;
        *)
            "$tool" --version 2>&1 | sed -n '1p'
            ;;
    esac
}

capture_tool_versions() {
    {
        printf 'started_at: %s\n' "$STARTED_AT"
        printf 'libvirt_uri: %s\n' "$LIBVIRT_URI"
        printf 'libvirt_network: %s\n' "$LIBVIRT_NETWORK"
        printf 'fedora_release: %s\n' "$FEDORA_RELEASE"
        printf 'fedora_desktop_profile: %s\n' "$FEDORA_DESKTOP_PROFILE"
        printf 'vm_graphics: %s\n' "$VM_GRAPHICS"

        local tool
        for tool in bash curl ssh scp ssh-keygen virsh virt-install qemu-img nmap cloud-localds genisoimage mkisofs; do
            if command -v "$tool" >/dev/null 2>&1; then
                printf '%s: %s | %s\n' "$tool" "$(command -v "$tool")" "$(tool_version "$tool")"
            else
                printf '%s: missing\n' "$tool"
            fi
        done
    } > "$HOST_TOOLS_FILE"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --preflight-only)
                PREFLIGHT_ONLY=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown option: $1"
                ;;
        esac
    done
}

preflight_host() {
    set_phase "Host preflight"

    local command_name
    PREFLIGHT_ERRORS=()
    while IFS= read -r command_name; do
        require_command "$command_name"
    done < <(required_host_commands)

    if SEED_TOOL="$(first_command cloud-localds genisoimage mkisofs)"; then
        log_info "Cloud-init seed tool: $SEED_TOOL"
    else
        add_preflight_error "missing host command: cloud-localds, genisoimage, or mkisofs"
    fi

    validate_wireguard_input
    validate_desktop_profile
    validate_expected_exit_ip

    if ((${#PREFLIGHT_ERRORS[@]} > 0)); then
        log_warn "Skipping libvirt access probe until missing host prerequisites are fixed"
    elif [[ "$LIBVIRT_URI" = qemu:///system* ]] && [ "$(id -u)" != "0" ] && ! user_in_group libvirt; then
        add_preflight_error "current user is not in the libvirt group for $LIBVIRT_URI"
    elif command -v virsh >/dev/null 2>&1; then
        local virsh_status
        set +e
        run_with_timeout 10 virsh --connect "$LIBVIRT_URI" list --all >/dev/null 2>&1
        virsh_status=$?
        set -e

        if [ "$virsh_status" -eq 124 ]; then
            add_preflight_error "timed out checking libvirt URI: $LIBVIRT_URI (likely waiting for graphical authentication)"
        elif [ "$virsh_status" -ne 0 ]; then
            add_preflight_error "cannot access libvirt URI: $LIBVIRT_URI"
        else
            set +e
            run_with_timeout 10 virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1
            virsh_status=$?
            set -e

            if [ "$virsh_status" -eq 124 ]; then
                add_preflight_error "timed out checking libvirt network: $LIBVIRT_NETWORK"
            elif [ "$virsh_status" -ne 0 ]; then
                add_preflight_error "libvirt network does not exist: $LIBVIRT_NETWORK"
            fi
        fi
    fi

    capture_tool_versions

    if ((${#PREFLIGHT_ERRORS[@]} > 0)); then
        printf '%s\n' "${PREFLIGHT_ERRORS[@]}" > "$PREFLIGHT_ERRORS_FILE"
        print_preflight_errors
        die "host preflight failed; see $PREFLIGHT_ERRORS_FILE"
    fi

    log_pass "host tools, libvirt access, and WireGuard config are ready"
}

remote_init() {
    SSH_BASE_OPTS=(
        -i "$SSH_KEY_PATH"
        -p "$VM_PORT"
        -o BatchMode=yes
        -o ConnectTimeout=15
        -o ServerAliveInterval=10
        -o ServerAliveCountMax=3
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
    )

    SSH_CONTROL_OPTS=(
        "${SSH_BASE_OPTS[@]}"
        -o ControlMaster=no
        -o ControlPath="$SSH_CONTROL_PATH"
    )

    SCP_CONTROL_OPTS=(
        -i "$SSH_KEY_PATH"
        -P "$VM_PORT"
        -o BatchMode=yes
        -o ConnectTimeout=15
        -o ControlMaster=no
        -o ControlPath="$SSH_CONTROL_PATH"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
    )
}

remote_target() {
    printf '%s@%s\n' "$VM_USER" "$VM_IP"
}

remote_start_master() {
    ssh "${SSH_BASE_OPTS[@]}" \
        -o ControlMaster=yes \
        -o ControlPath="$SSH_CONTROL_PATH" \
        -o ControlPersist=yes \
        -N -f "$(remote_target)"
}

remote_stop_master() {
    if [ -n "${VM_IP:-}" ] && [ -n "${SSH_CONTROL_PATH:-}" ]; then
        ssh "${SSH_BASE_OPTS[@]}" -o ControlPath="$SSH_CONTROL_PATH" -O exit "$(remote_target)" >/dev/null 2>&1 || true
    fi
}

remote_run_plain() {
    local command="$1"

    ssh "${SSH_BASE_OPTS[@]}" "$(remote_target)" "bash -s --" <<< "$command"
}

remote_run() {
    local command="$1"

    ssh "${SSH_CONTROL_OPTS[@]}" "$(remote_target)" "bash -s --" <<< "$command"
}

remote_capture() {
    local command="$1"

    remote_run "$command"
}

remote_scp_to() {
    local source_path="$1"
    local target_path="$2"

    scp "${SCP_CONTROL_OPTS[@]}" "$source_path" "$(remote_target):$target_path"
}

remote_check() {
    local description="$1"
    local command="$2"

    if remote_run "$command"; then
        log_pass "$description"
    else
        die "$description"
    fi
}

remote_step() {
    local description="$1"
    local timeout_seconds="$2"
    local artifact_name="$3"
    local command="$4"
    local output_file="$ARTIFACT_DIR/guest-step-${artifact_name}.log"
    local status command_pid

    print_progress "$description" "$PROGRESS_CURRENT" "$PROGRESS_TOTAL"
    log_info "Full output: $output_file"

    set +e
    remote_capture "timeout $(shell_quote "$timeout_seconds") bash -c $(shell_quote "$command")" > "$output_file" 2>&1 &
    command_pid="$!"
    animate_activity "$description" "$command_pid" "$timeout_seconds"
    wait "$command_pid"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        log_pass "$description"
        return 0
    fi

    if [ "$status" -eq 124 ]; then
        log_error "$description timed out after ${timeout_seconds}s"
    else
        log_error "$description failed with exit code $status"
    fi

    if [ -s "$output_file" ]; then
        printf '\nLast output from %s:\n' "$description" >&2
        tail -80 "$output_file" >&2 || true
    fi

    die "$description failed; see $output_file"
}

ensure_libvirt_network() {
    set_phase "Libvirt network"

    local active
    active="$(run_with_timeout 10 virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" | awk '/^Active:/ {print $2}')"
    if [ "$active" != "yes" ]; then
        log_warn "Starting inactive libvirt network $LIBVIRT_NETWORK"
        run_with_timeout 30 virsh --connect "$LIBVIRT_URI" net-start "$LIBVIRT_NETWORK" >/dev/null
    fi

    run_with_timeout 10 virsh --connect "$LIBVIRT_URI" net-autostart "$LIBVIRT_NETWORK" >/dev/null 2>&1 || true

    log_pass "libvirt network is active"
}

discover_fedora_image_url() {
    if [ -n "${FEDORA_CLOUD_IMAGE_URL:-}" ]; then
        FEDORA_IMAGE_SOURCE="$FEDORA_CLOUD_IMAGE_URL"
        FEDORA_IMAGE_NAME="${FEDORA_IMAGE_SOURCE%%\?*}"
        FEDORA_IMAGE_NAME="${FEDORA_IMAGE_NAME##*/}"
        return
    fi

    set_phase "Discover Fedora image"

    local index_file image_name
    index_file="$ARTIFACT_DIR/fedora-image-index.html"

    curl -fsSL "$FEDORA_IMAGE_INDEX_URL" -o "$index_file"
    image_name="$(
        grep -Eo "Fedora-Cloud-Base(-Generic)?-${FEDORA_RELEASE}-[^\"'<>[:space:]]*${FEDORA_ARCH}[.]qcow2" "$index_file" \
            | sort -V \
            | tail -1 \
            || true
    )"

    if [ -z "$image_name" ]; then
        die "could not discover Fedora Cloud qcow2 from $FEDORA_IMAGE_INDEX_URL; set FEDORA_CLOUD_IMAGE_URL"
    fi

    FEDORA_IMAGE_NAME="$image_name"
    FEDORA_IMAGE_SOURCE="${FEDORA_IMAGE_INDEX_URL%/}/$FEDORA_IMAGE_NAME"
    log_info "Selected Fedora image: $FEDORA_IMAGE_NAME"
}

ensure_base_image() {
    set_phase "Prepare Fedora image"

    mkdir -p "$CACHE_DIR"
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 755 "$CACHE_DIR"
    fi

    if [ -z "$FEDORA_IMAGE_NAME" ]; then
        FEDORA_IMAGE_NAME="${FEDORA_IMAGE_SOURCE%%\?*}"
        FEDORA_IMAGE_NAME="${FEDORA_IMAGE_NAME##*/}"
    fi
    if [ -z "$FEDORA_IMAGE_NAME" ]; then
        FEDORA_IMAGE_NAME="fedora-cloud-${FEDORA_RELEASE}-${FEDORA_ARCH}.qcow2"
    fi

    BASE_IMAGE_PATH="$CACHE_DIR/$FEDORA_IMAGE_NAME"

    if [ -f "$BASE_IMAGE_PATH" ] && qemu-img info "$BASE_IMAGE_PATH" >/dev/null 2>&1; then
        if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
            chmod 644 "$BASE_IMAGE_PATH"
        fi
        log_pass "cached Fedora image is usable"
        return
    fi

    local tmp_image
    tmp_image="${BASE_IMAGE_PATH}.download"
    rm -f "$tmp_image"

    log_info "Downloading Fedora image to cache"
    curl -fL --retry 3 --retry-delay 5 "$FEDORA_IMAGE_SOURCE" -o "$tmp_image"
    qemu-img info "$tmp_image" >/dev/null
    mv "$tmp_image" "$BASE_IMAGE_PATH"
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$BASE_IMAGE_PATH"
    fi

    log_pass "Fedora image cached"
}

create_cloud_init_seed() {
    set_phase "Create cloud-init seed"

    mkdir -p "$WORK_DIR"
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 755 "$WORK_DIR"
    else
        chmod 700 "$WORK_DIR"
    fi

    ssh-keygen -q -t ed25519 -N "" -C "$VM_NAME" -f "$SSH_KEY_PATH"

    local public_key
    public_key="$(cat "$SSH_KEY_PATH.pub")"

    cat > "$USER_DATA_PATH" <<EOF
#cloud-config
users:
  - default
  - name: $VM_USER
    groups: [wheel]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $public_key
disable_root: true
ssh_pwauth: false
EOF

    cat > "$META_DATA_PATH" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

    case "$SEED_TOOL" in
        cloud-localds)
            cloud-localds "$SEED_ISO_PATH" "$USER_DATA_PATH" "$META_DATA_PATH"
            ;;
        genisoimage|mkisofs)
            "$SEED_TOOL" -quiet -output "$SEED_ISO_PATH" -volid cidata -joliet -rock \
                -graft-points "user-data=$USER_DATA_PATH" "meta-data=$META_DATA_PATH"
            ;;
        *)
            die "unsupported cloud-init seed tool: $SEED_TOOL"
            ;;
    esac

    log_pass "cloud-init seed created"
}

create_vm_disk() {
    set_phase "Create VM disk"

    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$VM_DISK_PATH" "$VM_DISK_SIZE" >/dev/null
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$VM_DISK_PATH" "$SEED_ISO_PATH"
    fi
    log_pass "desktop VM disk created"
}

check_hypervisor_storage_access() {
    if [[ "$LIBVIRT_URI" != qemu:///system* ]]; then
        return 0
    fi

    local missing=()

    if [ ! -x "$WORK_DIR" ]; then
        missing+=("$WORK_DIR is not searchable")
    fi
    if [ ! -r "$VM_DISK_PATH" ]; then
        missing+=("$VM_DISK_PATH is not readable")
    fi
    if [ ! -r "$SEED_ISO_PATH" ]; then
        missing+=("$SEED_ISO_PATH is not readable")
    fi

    if ((${#missing[@]} > 0)); then
        printf '%s\n' "${missing[@]}" >&2
        die "VM storage is not readable/searchable before boot"
    fi
}

boot_vm() {
    set_phase "Boot VM"

    local os_args=()
    if virt-install --help 2>&1 | grep -q -- '--osinfo'; then
        os_args=(--osinfo "${VM_OSINFO:-detect=on,require=off}")
    else
        os_args=(--os-variant "${VM_OS_VARIANT:-fedora-unknown}")
    fi

    VM_CLEANUP_REQUIRED=1
    check_hypervisor_storage_access

    virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY_MB" \
        --vcpus "$VM_CPUS" \
        --import \
        --disk "path=$VM_DISK_PATH,format=qcow2,bus=virtio" \
        --disk "path=$SEED_ISO_PATH,device=cdrom" \
        --network "network=$LIBVIRT_NETWORK,model=virtio" \
        --graphics "$VM_GRAPHICS" \
        --video virtio \
        --channel spicevmc \
        --noautoconsole \
        "${os_args[@]}"

    log_pass "VM boot requested"
}

discover_vm_ip() {
    local ip mac

    ip="$(
        virsh --connect "$LIBVIRT_URI" domifaddr "$VM_NAME" --source lease 2>/dev/null \
            | awk '$0 ~ /ipv4/ { split($4, parts, "/"); print parts[1]; exit }' \
            || true
    )"
    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
        return 0
    fi

    mac="$(
        virsh --connect "$LIBVIRT_URI" domiflist "$VM_NAME" 2>/dev/null \
            | awk -v network="$LIBVIRT_NETWORK" '$2 == "network" && $3 == network { print $5; exit }' \
            || true
    )"
    if [ -n "$mac" ]; then
        virsh --connect "$LIBVIRT_URI" net-dhcp-leases "$LIBVIRT_NETWORK" 2>/dev/null \
            | awk -v mac="$mac" '$0 ~ mac && $0 ~ /ipv4/ { split($5, parts, "/"); print parts[1]; exit }' \
            || true
    fi
}

wait_for_vm_ip() {
    set_phase "Discover VM IP"

    local attempt ip
    for ((attempt = 1; attempt <= VM_BOOT_ATTEMPTS; attempt++)); do
        ip="$(discover_vm_ip || true)"
        if [ -n "$ip" ]; then
            VM_IP="$ip"
            log_pass "VM IP discovered: $VM_IP"
            return
        fi

        print_attempt_progress "Waiting for VM IP" "$attempt" "$VM_BOOT_ATTEMPTS"
        sleep "$VM_BOOT_DELAY"
    done

    die "timed out waiting for VM DHCP lease"
}

wait_for_ssh() {
    set_phase "Wait for SSH"

    local attempt
    remote_init

    for ((attempt = 1; attempt <= VM_BOOT_ATTEMPTS; attempt++)); do
        if remote_run_plain "true" >/dev/null 2>&1; then
            log_pass "SSH is ready"
            return
        fi

        print_attempt_progress "Waiting for SSH" "$attempt" "$VM_BOOT_ATTEMPTS"
        sleep "$VM_BOOT_DELAY"
    done

    die "timed out waiting for SSH on $VM_IP"
}

start_control_master() {
    set_phase "Open SSH control channel"

    remote_start_master
    log_pass "SSH ControlMaster is established"
}

provision_guest() {
    set_phase "Provision desktop guest"

    remote_step "Guest cloud-init wait" 300 "cloud-init" '
set -Eeuo pipefail
if command -v cloud-init >/dev/null 2>&1; then
    sudo -n cloud-init status --wait >/dev/null || true
fi
'

    remote_scp_to "$MODULE_TOOLS_DIR/install-deps.sh" "/tmp/paranoid-vpn-install-deps.sh"
    remote_step "Guest module dependency install" 1800 "module-deps" '
set -Eeuo pipefail
sudo -n bash /tmp/paranoid-vpn-install-deps.sh
rm -f /tmp/paranoid-vpn-install-deps.sh
'

    case "$FEDORA_DESKTOP_PROFILE" in
        workstation)
            remote_step "Guest Fedora Workstation install" 2400 "workstation-package-install" '
set -Eeuo pipefail
sudo -n dnf -y install @workstation-product-environment spice-vdagent qemu-guest-agent
'
            ;;
        lab)
            remote_step "Guest desktop package install" 1800 "desktop-package-install" '
set -Eeuo pipefail
sudo -n dnf -y install gdm gnome-shell gnome-terminal nautilus control-center spice-vdagent qemu-guest-agent
'
            ;;
    esac

    remote_step "Guest desktop and service setup" 300 "desktop-services" '
set -Eeuo pipefail
sudo -n systemctl set-default graphical.target
sudo -n systemctl enable gdm.service
sudo -n systemctl start gdm.service || sudo -n systemctl status gdm.service --no-pager
sudo -n systemctl enable --now spice-vdagentd.service 2>/dev/null || true
sudo -n systemctl enable --now qemu-guest-agent.service 2>/dev/null || true
sudo -n install -d -m 700 /etc/wireguard
'

    remote_step "Guest GDM autologin setup" 120 "gdm-autologin" "sudo -n install -d -m 755 /etc/gdm && printf '%s\n' '[daemon]' 'AutomaticLoginEnable=True' 'AutomaticLogin=$(shell_quote "$VM_USER")' | sudo -n tee /etc/gdm/custom.conf >/dev/null && sudo -n systemctl restart gdm.service || true"

    remote_scp_to "$TEST_WG_CONF" "/tmp/paranoid-vpn-wg0.conf"
    remote_step "Guest WireGuard config install" 120 "wireguard-config" '
set -Eeuo pipefail
sudo -n install -m 600 -o root -g root /tmp/paranoid-vpn-wg0.conf /etc/wireguard/wg0.conf
rm -f /tmp/paranoid-vpn-wg0.conf
sudo -n test -f /etc/wireguard/wg0.conf
'

    log_pass "desktop profile, guest tools, and WireGuard config are installed"
}

copy_project_to_vm() {
    set_phase "Copy project files"

    remote_run "mkdir -p /tmp/paranoid-vpn-desktop-test"
    remote_scp_to "$MODULE_SRC_DIR/paranoid-vpn.sh" "/tmp/paranoid-vpn-desktop-test/"
    remote_scp_to "$MODULE_SRC_DIR/wg-watchdog.sh" "/tmp/paranoid-vpn-desktop-test/"
    remote_scp_to "$MODULE_DIR/README.md" "/tmp/paranoid-vpn-desktop-test/"
    remote_check "remote scripts are executable" "chmod 755 /tmp/paranoid-vpn-desktop-test/paranoid-vpn.sh /tmp/paranoid-vpn-desktop-test/wg-watchdog.sh"
}

run_setup() {
    set_phase "Run paranoid VPN setup"

    local allow_ssh_arg=""
    local setup_command
    if [ "$TEST_ALLOW_SSH" = "1" ]; then
        allow_ssh_arg=" --allow-ssh"
        log_warn "TEST_ALLOW_SSH=1; SSH will remain open in the lockdown firewall"
    fi

    setup_command="sudo -n /tmp/paranoid-vpn-desktop-test/paranoid-vpn.sh --wg-conf /etc/wireguard/wg0.conf$allow_ssh_arg"
    remote_step "Paranoid VPN setup inside VM" 600 "paranoid-vpn-setup" "$setup_command"
    log_pass "setup completed on VM"
}

capture_pre_setup_public_ip() {
    set_phase "Pre-setup diagnostics"

    local ip_output
    ip_output="$(remote_capture "timeout 20 curl -4fsS $(shell_quote "$PUBLIC_IP_URL") || true" | normalize_one_line)"

    printf '%s\n' "${ip_output:-unavailable}" > "$ARTIFACT_DIR/pre-setup-public-ip.txt"
    log_info "VM public IP before setup: ${ip_output:-unavailable}"
}

verify_vm_state() {
    set_phase "VM network checks"

    remote_check "passwordless sudo works" "sudo -n true"
    remote_check "WireGuard config exists" "sudo -n test -f /etc/wireguard/wg0.conf"
    remote_check "WireGuard config contains full-tunnel AllowedIPs" "sudo -n grep -Eiq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0[.]0[.]0[.]0/0' /etc/wireguard/wg0.conf"
    remote_check "wg0 is visible to WireGuard" "sudo -n wg show wg0 >/dev/null"
    remote_check "default route points to wg0" "ip route show default | grep -Eq '(^|[[:space:]])dev[[:space:]]+wg0($|[[:space:]])'"
    remote_check "no physical IPv4 default route remains" "ip -4 route show default | awk 'BEGIN { ok=1 } !/(^|[[:space:]])dev[[:space:]]+wg0($|[[:space:]])/ { ok=0 } END { exit(ok ? 0 : 1) }'"
    remote_check "WireGuard latest handshake is non-zero" "sudo -n wg show wg0 latest-handshakes | awk '{ if (\$2 > 0) found=1 } END { exit(found ? 0 : 1) }'"
    remote_check "IPv6 is disabled globally" 'test "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = "1"'
    remote_check "IPv6 is disabled by default" 'test "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" = "1"'
    remote_check "IPv6 is disabled on loopback" 'test "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" = "1"'
    remote_check "GDM is active for desktop access" "systemctl is-active --quiet gdm.service"

    local post_ip
    if ! post_ip="$(remote_capture "timeout 30 curl -4fsS $(shell_quote "$PUBLIC_IP_URL")" | normalize_one_line)"; then
        die "public IP lookup failed after setup"
    fi
    printf '%s\n' "$post_ip" > "$ARTIFACT_DIR/post-setup-public-ip.txt"
    if [ "$VPN_EXPECTED_EXIT_IP" = "auto" ]; then
        log_warn "VPN_EXPECTED_EXIT_IP=auto; learned VPN exit IP is $post_ip"
        log_pass "public IP lookup through VPN returned $post_ip"
    elif [ "$VPN_EXPECTED_EXIT_IP" = "$post_ip" ]; then
        log_pass "public IP matches expected VPN exit"
    else
        die "public IP mismatch: expected $VPN_EXPECTED_EXIT_IP, got $post_ip"
    fi

    local dns_output
    dns_output="$(
        remote_capture '
if command -v dig >/dev/null 2>&1; then
    timeout 20 dig +time=5 +tries=1 +short example.com
else
    timeout 20 resolvectl query example.com
fi
'
    )"
    printf '%s\n' "$dns_output" > "$ARTIFACT_DIR/post-setup-dns.txt"
    if [ -z "$(printf '%s\n' "$dns_output" | sed '/^[[:space:]]*$/d')" ]; then
        die "DNS lookup after setup returned no records"
    fi
    log_pass "DNS lookup works after setup"
}

verify_firewall() {
    set_phase "Firewall checks"

    remote_check "wireguard-only zone exists" '
for zone in $(sudo -n firewall-cmd --get-zones); do
    if [ "$zone" = "wireguard-only" ]; then
        exit 0
    fi
done
exit 1
'

    local target ports services
    target="$(remote_capture "sudo -n firewall-cmd --permanent --zone=wireguard-only --get-target" | normalize_one_line)"
    if [ "$target" != "DROP" ]; then
        die "wireguard-only target is $target, expected DROP"
    fi
    log_pass "wireguard-only target is DROP"

    remote_check "wireguard-only zone includes wg0" "sudo -n firewall-cmd --zone=wireguard-only --list-interfaces | grep -Eq '(^|[[:space:]])wg0($|[[:space:]])'"
    remote_check "all non-loopback interfaces are in wireguard-only zone" '
for iface in $(ip -o link show | awk -F": " "{split(\$2, parts, /[:@]/); if (parts[1] != \"lo\") print parts[1]}"); do
    zone="$(sudo -n firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || true)"
    if [ "$zone" != "wireguard-only" ]; then
        printf "%s is in zone %s\n" "$iface" "${zone:-unassigned}" >&2
        exit 1
    fi
done
'

    ports="$(remote_capture "sudo -n firewall-cmd --zone=wireguard-only --list-ports")"
    printf '%s\n' "$ports" > "$ARTIFACT_DIR/firewall-ports.txt"
    if [[ "$ports" != *"51820/udp"* ]]; then
        die "firewall does not include WireGuard UDP port entry"
    fi
    if [[ "$ports" == *"53/udp"* ]] || [[ "$ports" == *"53/tcp"* ]]; then
        die "firewall unexpectedly exposes DNS ports"
    fi
    log_pass "firewall ports match lockdown expectations"

    services="$(remote_capture "sudo -n firewall-cmd --zone=wireguard-only --list-services")"
    printf '%s\n' "$services" > "$ARTIFACT_DIR/firewall-services.txt"
    if [[ "$services" == *"dns"* ]]; then
        die "firewall unexpectedly exposes DNS service"
    fi
    if [ "$TEST_ALLOW_SSH" = "1" ]; then
        if [[ "$services" != *"ssh"* ]]; then
            die "firewall does not expose SSH while TEST_ALLOW_SSH=1"
        fi
        log_pass "firewall exposes SSH in debug mode"
    elif [[ "$services" == *"ssh"* ]]; then
        die "firewall unexpectedly exposes SSH in paranoid mode"
    else
        log_pass "firewall does not expose SSH in paranoid mode"
    fi
}

tcp_port_allowed() {
    local port="$1"
    local item
    local -a allowed_ports=()

    IFS=',' read -r -a allowed_ports <<< "$NMAP_ALLOWED_OPEN_TCP"
    for item in "${allowed_ports[@]}"; do
        if [ "$item" = "$port" ]; then
            return 0
        fi
    done

    return 1
}

assert_no_unexpected_open_tcp() {
    local label="$1"
    local output_file="$2"
    local unexpected_file="$ARTIFACT_DIR/nmap-${label}-unexpected-open-tcp.txt"
    local port

    : > "$unexpected_file"
    while read -r port _rest; do
        port="${port%/tcp}"
        if ! tcp_port_allowed "$port"; then
            printf '%s\n' "$port" >> "$unexpected_file"
        fi
    done < <(awk '$1 ~ /^[0-9]+\/tcp$/ && $2 == "open" { print }' "$output_file")

    if [ -s "$unexpected_file" ]; then
        die "nmap found unexpected open TCP ports during $label; see $unexpected_file"
    fi

    log_pass "nmap found no unexpected open TCP ports during $label"
}

run_nmap_audit() {
    set_phase "Host-side nmap audit"

    local tcp_output udp_output
    local -a nmap_privileged=()
    local -a tcp_args=()
    tcp_output="$ARTIFACT_DIR/nmap-full-tcp.txt"
    udp_output="$ARTIFACT_DIR/nmap-full-udp.txt"

    if [ "$(id -u)" = "0" ]; then
        nmap_privileged=(nmap)
    elif sudo -n true >/dev/null 2>&1; then
        nmap_privileged=(sudo -n nmap)
    fi

    if [ "$NMAP_FULL_AUDIT" = "1" ]; then
        if ((${#nmap_privileged[@]} > 0)); then
            tcp_args=(-Pn -sS -sV -O --version-light --script "default,safe" -p "$NMAP_PORTS")
        else
            log_warn "no non-interactive root available; using TCP connect scan and skipping OS detection"
            tcp_args=(-Pn -sT -sV --version-light --script "default,safe" -p "$NMAP_PORTS")
        fi
        log_info "Running TCP service/version/default/safe audit against $VM_IP"
        if ((${#nmap_privileged[@]} > 0)); then
            if ! timeout "$NMAP_TIMEOUT" "${nmap_privileged[@]}" "${tcp_args[@]}" "$VM_IP" | tee "$tcp_output"; then
                die "TCP nmap audit failed"
            fi
        elif ! timeout "$NMAP_TIMEOUT" nmap "${tcp_args[@]}" "$VM_IP" | tee "$tcp_output"; then
            die "TCP nmap audit failed"
        fi
    else
        log_info "Running TCP port audit against $VM_IP"
        if ! timeout "$NMAP_TIMEOUT" nmap -Pn -p "$NMAP_PORTS" "$VM_IP" | tee "$tcp_output"; then
            die "TCP nmap audit failed"
        fi
    fi
    assert_no_unexpected_open_tcp "full-tcp" "$tcp_output"

    log_info "Running UDP audit against $VM_IP"
    if ((${#nmap_privileged[@]} == 0)); then
        log_warn "skipping UDP audit; UDP scans require root or passwordless sudo"
        printf 'skipped: UDP scan requires root or passwordless sudo\n' > "$udp_output"
        return 0
    fi
    if ! timeout "$NMAP_UDP_TIMEOUT" "${nmap_privileged[@]}" -Pn -sU --version-light -p "$NMAP_UDP_PORTS" "$VM_IP" | tee "$udp_output"; then
        die "UDP nmap audit failed"
    fi
    log_pass "UDP nmap audit completed"
}

collect_remote_artifacts() {
    local label="$1"
    local output_dir="$ARTIFACT_DIR/remote-${label}"

    mkdir -p "$output_dir"

    collect_remote_artifact "$output_dir/status.txt" "sudo -n /opt/paranoid-vpn/paranoid-vpn.sh --status || true"
    collect_remote_artifact "$output_dir/routes.txt" "ip route show || true"
    collect_remote_artifact "$output_dir/addresses.txt" "ip addr show || true"
    collect_remote_artifact "$output_dir/wg-show.txt" "sudo -n wg show wg0 || true"
    collect_remote_artifact "$output_dir/firewall-zone.txt" "sudo -n firewall-cmd --list-all --zone=wireguard-only || true"
    collect_remote_artifact "$output_dir/resolver.txt" "resolvectl status 2>/dev/null || cat /etc/resolv.conf || true"
    collect_remote_artifact "$output_dir/paranoid-vpn-log.txt" "sudo -n tail -n 300 /var/log/paranoid-vpn.log || true"
    collect_remote_artifact "$output_dir/watchdog-journal.txt" "sudo -n journalctl -u wg-watchdog.service -n 300 --no-pager || true"
    collect_remote_artifact "$output_dir/gdm-journal.txt" "sudo -n journalctl -u gdm.service -n 200 --no-pager || true"
}

collect_remote_artifact() {
    local output_file="$1"
    local command="$2"

    if ! remote_capture "$command" > "$output_file" 2>&1; then
        log_warn "could not collect $(basename "$output_file")"
    fi
}

default_route_has_no_physical_escape() {
    remote_run '
route="$(ip -4 route show default || true)"
if [ -z "$route" ]; then
    exit 0
fi
if printf "%s\n" "$route" | grep -Evq "(^|[[:space:]])dev[[:space:]]+wg0($|[[:space:]])"; then
    exit 1
fi
exit 0
'
}

run_destructive_cleanup_check() {
    set_phase "Optional destructive cleanup check"
    log_warn "RUN_DESTRUCTIVE_ON_CLEANUP=1; bringing wg0 down before VM destruction"

    remote_check "wg-quick down wg0 completed" "sudo -n wg-quick down wg0"

    local attempt
    for ((attempt = 1; attempt <= WATCHDOG_ATTEMPTS; attempt++)); do
        if default_route_has_no_physical_escape; then
            log_pass "watchdog removed any physical default route"
            break
        fi
        if (( attempt == WATCHDOG_ATTEMPTS )); then
            die "watchdog did not remove physical default route"
        fi
        print_attempt_progress "Waiting for watchdog route cleanup" "$attempt" "$WATCHDOG_ATTEMPTS"
        sleep "$WATCHDOG_DELAY"
    done

    collect_remote_artifacts "post-destructive-cleanup" || true
}

print_manual_access() {
    set_phase "Manual desktop testing"

    cat <<EOF

Desktop VM is ready and will keep running until you confirm cleanup.

VM name:        $VM_NAME
VM IP:          $VM_IP
SSH command:    ssh -i $(shell_quote "$SSH_KEY_PATH") -p $VM_PORT $VM_USER@$VM_IP
Open desktop:   virt-manager --connect $(shell_quote "$LIBVIRT_URI")
Artifacts:      $ARTIFACT_DIR
Report:         $REPORT_PATH

In virt-manager, open "$VM_NAME" to use the SPICE desktop console.
Press Enter, type yes, or type destroy here when you are done.
Set KEEP_VM_ON_EXIT=1 before running the script if you want Ctrl-C to leave it running.

EOF
}

wait_for_cleanup_confirmation() {
    local answer

    MANUAL_PAUSE_REACHED=1
    while true; do
        printf 'Cleanup VM now? [Enter/yes/destroy] '
        if ! IFS= read -r answer; then
            answer=""
        fi

        case "${answer,,}" in
            ""|y|yes|destroy|cleanup)
                return 0
                ;;
            keep)
                KEEP_VM_ON_EXIT=1
                log_warn "KEEP requested; VM and work files will be left in place"
                return 0
                ;;
            *)
                log_info "Type Enter/yes/destroy to cleanup, or keep to leave the VM running."
                ;;
        esac
    done
}

write_report() {
    local status="$1"
    local finished_at report_status report_tmp

    finished_at="$(date -Is)"
    report_tmp="${REPORT_PATH}.tmp"

    if (( status == 0 )); then
        report_status="PASS"
    else
        report_status="FAIL"
    fi

    {
        printf '# Desktop VM Instrumented Network Test Report\n\n'
        printf -- '- Status: %s\n' "$report_status"
        printf -- '- Exit code: %s\n' "$status"
        printf -- '- Started: %s\n' "$STARTED_AT"
        printf -- '- Finished: %s\n' "$finished_at"
        printf -- '- Last phase: %s\n' "$PHASE"
        if [ -n "$FAILURE_MESSAGE" ]; then
            printf -- '- Failure: %s\n' "$FAILURE_MESSAGE"
        fi
        printf '\n'

        printf '## VM\n\n'
        printf -- '- Name: %s\n' "$VM_NAME"
        printf -- '- IP: %s\n' "${VM_IP:-unavailable}"
        printf -- '- User: %s\n' "$VM_USER"
        printf -- '- Libvirt URI: %s\n' "$LIBVIRT_URI"
        printf -- '- Libvirt network: %s\n' "$LIBVIRT_NETWORK"
        printf -- '- Fedora release: %s\n' "$FEDORA_RELEASE"
        printf -- '- Desktop profile: %s\n' "$FEDORA_DESKTOP_PROFILE"
        printf -- '- Graphics: %s\n' "$VM_GRAPHICS"
        printf -- '- Memory MB: %s\n' "$VM_MEMORY_MB"
        printf -- '- CPUs: %s\n' "$VM_CPUS"
        printf -- '- Disk size: %s\n' "$VM_DISK_SIZE"
        printf '\n'

        printf '## Results\n\n'
        printf -- '- Artifact directory: %s\n' "$ARTIFACT_DIR"
        printf -- '- Fedora cache directory: %s\n' "$CACHE_DIR"
        printf -- '- Fedora cached image: %s\n' "${BASE_IMAGE_PATH:-not-created}"
        printf -- '- VM work directory: %s\n' "$WORK_DIR"
        printf -- '- Runner log: %s\n' "$RUNNER_LOG"
        printf -- '- Host tools: %s\n' "$HOST_TOOLS_FILE"
        printf -- '- Manual pause reached: %s\n' "$MANUAL_PAUSE_REACHED"
        printf -- '- Cleanup: %s\n' "$CLEANUP_STATUS"
        printf -- '- VM cleanup required: %s\n' "$VM_CLEANUP_REQUIRED"
        printf -- '- Auto install host deps: %s\n' "$AUTO_INSTALL_HOST_DEPS"
        printf -- '- Host setup rerun required: %s\n' "$HOST_SETUP_RERUN_REQUIRED"
        printf -- '- KEEP_VM_ON_EXIT: %s\n' "$KEEP_VM_ON_EXIT"
        printf -- '- RUN_DESTRUCTIVE_ON_CLEANUP: %s\n' "$RUN_DESTRUCTIVE_ON_CLEANUP"
        printf '\n'

        if [ -s "$PREFLIGHT_ERRORS_FILE" ]; then
            printf '## Preflight Errors\n\n'
            sed 's/^/- /' "$PREFLIGHT_ERRORS_FILE"
            printf '\n'
        fi

        printf '## Notes\n\n'
        printf -- '- The WireGuard config path and contents are intentionally omitted.\n'
        printf -- '- Full nmap output is stored as raw artifacts.\n'
        if [ "$KEEP_VM_ON_EXIT" = "1" ]; then
            printf -- '- The VM was intentionally left running; generated SSH keys remain in the work directory.\n'
        else
            printf -- '- Generated VM disks, seed files, and SSH keys are removed during cleanup.\n'
        fi
    } > "$report_tmp" && mv "$report_tmp" "$REPORT_PATH"
}

print_failure_summary() {
    local status="$1"

    if (( status == 0 )); then
        return 0
    fi

    print_progress "Failure summary" "$PROGRESS_CURRENT" "$PROGRESS_TOTAL"
    log_error "Exit code: $status"
    log_error "Last phase: $PHASE"
    if [ -n "$FAILURE_MESSAGE" ]; then
        log_error "$FAILURE_MESSAGE"
    fi

    if [ -s "$PREFLIGHT_ERRORS_FILE" ]; then
        printf '\nPreflight errors:\n' >&2
        sed 's/^/  - /' "$PREFLIGHT_ERRORS_FILE" >&2
    fi

    if [ -n "${VM_NAME:-}" ]; then
        printf '\nVM context:\n' >&2
        printf '  Name: %s\n' "$VM_NAME" >&2
        printf '  IP: %s\n' "${VM_IP:-unavailable}" >&2
        printf '  Libvirt URI: %s\n' "$LIBVIRT_URI" >&2
    fi

    printf '\nArtifacts:\n' >&2
    printf '  Directory: %s\n' "$ARTIFACT_DIR" >&2
    printf '  Fedora cache: %s\n' "$CACHE_DIR" >&2
    printf '  VM work dir: %s\n' "$WORK_DIR" >&2
    printf '  Runner log: %s\n' "$RUNNER_LOG" >&2
    printf '  Report: %s\n' "$REPORT_PATH" >&2
}

cleanup_vm() {
    CLEANUP_STATUS="running"

    remote_stop_master

    if [ "$KEEP_VM_ON_EXIT" = "1" ]; then
        CLEANUP_STATUS="skipped-keep-vm"
        log_warn "KEEP_VM_ON_EXIT=1; leaving VM and generated files in place"
        return
    fi

    if [ "$VM_CLEANUP_REQUIRED" = "1" ] && command -v virsh >/dev/null 2>&1; then
        if virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
            local state
            state="$(virsh --connect "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null || true)"
            if [ "$state" = "running" ] || [ "$state" = "paused" ]; then
                log_warn "Destroying desktop lab VM $VM_NAME"
                virsh --connect "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null 2>&1 || true
            fi

            log_warn "Undefining desktop lab VM $VM_NAME"
            virsh --connect "$LIBVIRT_URI" undefine "$VM_NAME" --nvram >/dev/null 2>&1 \
                || virsh --connect "$LIBVIRT_URI" undefine "$VM_NAME" >/dev/null 2>&1 \
                || true
        fi
    fi

    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        case "$WORK_DIR" in
            "$ARTIFACT_DIR"/vm-work|/tmp/paranoid-vpn-vm-*|/var/tmp/paranoid-vpn-desktop-*)
                rm -rf "$WORK_DIR" || true
                ;;
            *)
                rm -f "$VM_DISK_PATH" "$SEED_ISO_PATH" "$USER_DATA_PATH" "$META_DATA_PATH" \
                    "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub" "$KNOWN_HOSTS_FILE" 2>/dev/null || true
                ;;
        esac
    fi

    CLEANUP_STATUS="complete"
}

on_exit() {
    local status=$?

    set +e
    stop_sudo_keepalive
    if (( status == 0 )) && [ "$RESULT" != "passed" ]; then
        RESULT="passed"
    fi

    if [ "$RUN_DESTRUCTIVE_ON_CLEANUP" = "1" ] && [ "$KEEP_VM_ON_EXIT" != "1" ] && [ -n "${VM_IP:-}" ]; then
        run_destructive_cleanup_check || true
    fi

    cleanup_vm
    write_report "$status"
    print_failure_summary "$status"

    if [ -f "$REPORT_PATH" ]; then
        if (( status == 0 )); then
            log_info "Report saved to $REPORT_PATH"
        else
            log_warn "Report saved to $REPORT_PATH"
        fi
    fi

    exit "$status"
}

main() {
    parse_args "$@"

    mkdir -p "$ARTIFACT_DIR" "$WORK_DIR"
    exec > >(tee -a "$RUNNER_LOG") 2>&1
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    run_host_setup
    preflight_host

    if [ "$PREFLIGHT_ONLY" = "1" ]; then
        RESULT="passed"
        log_pass "preflight-only run passed"
        return 0
    fi

    ensure_libvirt_network
    discover_fedora_image_url
    ensure_base_image
    create_cloud_init_seed
    create_vm_disk
    boot_vm
    wait_for_vm_ip
    wait_for_ssh
    start_control_master
    provision_guest
    capture_pre_setup_public_ip
    copy_project_to_vm
    run_setup
    verify_vm_state
    verify_firewall
    collect_remote_artifacts "post-setup"
    run_nmap_audit
    print_manual_access
    wait_for_cleanup_confirmation

    RESULT="passed"
    print_progress "Desktop lab complete" "$PROGRESS_TOTAL" "$PROGRESS_TOTAL"
    log_pass "desktop VM instrumented test passed"
}

main "$@"
