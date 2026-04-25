#!/usr/bin/env bash
###############################################################################
# Independent VM integration runner for paranoid-vpn.
#
# This wrapper provisions a disposable Fedora Cloud VM with libvirt, injects a
# local WireGuard config, runs the existing VM integration suite, writes a
# module artifact report, and then destroys the VM.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=modules/paranoid-vpn/test/lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
STARTED_AT="$(date -Is)"

FEDORA_RELEASE="${FEDORA_RELEASE:-43}"
FEDORA_ARCH="${FEDORA_ARCH:-x86_64}"
FEDORA_IMAGE_INDEX_URL="${FEDORA_IMAGE_INDEX_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Cloud/${FEDORA_ARCH}/images/}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
VM_MEMORY_MB="${VM_MEMORY_MB:-2048}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_BOOT_ATTEMPTS="${VM_BOOT_ATTEMPTS:-60}"
VM_BOOT_DELAY="${VM_BOOT_DELAY:-5}"
VM_USER="fedora"
VM_PORT="22"
VM_NAME="${VM_NAME:-paranoid-vpn-itest-${TIMESTAMP}-$$}"

ARTIFACT_DIR="${TEST_ARTIFACT_DIR:-$SCRIPT_DIR/artifacts/independent-$TIMESTAMP}"
CACHE_DIR="${VM_CACHE_DIR:-$SCRIPT_DIR/vm-cache}"
WORK_DIR="${VM_WORK_DIR:-$ARTIFACT_DIR/vm-work}"
REPORT_PATH="${VM_INTEGRATION_REPORT:-$ARTIFACT_DIR/vm-integration-report-$TIMESTAMP.md}"
RUNNER_LOG="$ARTIFACT_DIR/independent-runner.log"
SUITE_LOG="$ARTIFACT_DIR/vm-integration-suite.log"
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
VM_IP=""
PHASE="initialization"
RESULT="failed"
FAILURE_MESSAGE=""
SUITE_EXIT="not-run"
CLEANUP_STATUS="not-started"
SEED_TOOL=""
PREFLIGHT_ONLY=0

declare -a PREFLIGHT_ERRORS=()

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
  FEDORA_IMAGE_INDEX_URL    Fedora image index URL used for discovery.
  LIBVIRT_URI               Libvirt connection URI. Default: qemu:///system
  LIBVIRT_NETWORK           Libvirt NAT/private network. Default: default
  VM_MEMORY_MB              VM memory. Default: 2048
  VM_CPUS                   VM vCPU count. Default: 2
  VM_DISK_SIZE              Throwaway overlay disk size. Default: 20G
  VM_CACHE_DIR              Fedora image cache. Default: module test vm-cache
  TEST_ARTIFACT_DIR         Artifact directory. Default: module test artifacts/independent-<timestamp>
  VM_INTEGRATION_REPORT     Report path. Default: vm-integration-report-<timestamp>.md

Existing suite environment such as VPN_EXPECTED_EXIT_IP, PUBLIC_IP_URL,
NMAP_PORTS, SKIP_NMAP, WATCHDOG_ATTEMPTS, and WATCHDOG_DELAY is passed through.
EOF
}

on_exit() {
    local status=$?

    set +e
    if (( status == 0 )) && [ "$RESULT" != "passed" ]; then
        RESULT="passed"
    fi

    cleanup_vm
    write_report "$status"

    if [ -f "$REPORT_PATH" ]; then
        if (( status == 0 )); then
            log_info "Report saved to $REPORT_PATH"
        else
            log_warn "Report saved to $REPORT_PATH"
        fi
    fi

    exit "$status"
}

set_phase() {
    PHASE="$1"
    log_section "$PHASE"
}

die() {
    FAILURE_MESSAGE="$1"
    log_error "$FAILURE_MESSAGE"
    exit 1
}

add_preflight_error() {
    PREFLIGHT_ERRORS+=("$1")
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        add_preflight_error "missing host command: $command_name"
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

shell_quote() {
    printf '%q' "$1"
}

tool_version() {
    local tool="$1"

    case "$tool" in
        ssh)
            ssh -V 2>&1 | sed -n '1p'
            ;;
        scp|ssh-keygen)
            ssh -V 2>&1 | sed -n '1p'
            ;;
        *)
            "$tool" --version 2>&1 | sed -n '1p'
            ;;
    esac
}

remote_run() {
    local command="$1"

    ssh \
        -i "$SSH_KEY_PATH" \
        -p "$VM_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
        "${VM_USER}@${VM_IP}" \
        "bash -s --" <<< "$command"
}

remote_scp_to() {
    local source_path="$1"
    local target_path="$2"

    scp \
        -i "$SSH_KEY_PATH" \
        -P "$VM_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
        "$source_path" \
        "${VM_USER}@${VM_IP}:$target_path"
}

capture_tool_versions() {
    {
        printf 'started_at: %s\n' "$STARTED_AT"
        printf 'libvirt_uri: %s\n' "$LIBVIRT_URI"
        printf 'libvirt_network: %s\n' "$LIBVIRT_NETWORK"

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

write_report() {
    local status="$1"
    local finished_at
    local report_status
    local report_tmp

    finished_at="$(date -Is)"
    report_tmp="${REPORT_PATH}.tmp"

    if (( status == 0 )); then
        report_status="PASS"
    else
        report_status="FAIL"
    fi

    {
        printf '# VM Integration Report\n\n'
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
        printf -- '- Memory MB: %s\n' "$VM_MEMORY_MB"
        printf -- '- CPUs: %s\n' "$VM_CPUS"
        printf -- '- Disk size: %s\n' "$VM_DISK_SIZE"
        printf '\n'

        printf '## Fedora Image\n\n'
        printf -- '- Release: %s\n' "$FEDORA_RELEASE"
        printf -- '- Architecture: %s\n' "$FEDORA_ARCH"
        printf -- '- Source: %s\n' "${FEDORA_IMAGE_SOURCE:-not-selected}"
        printf -- '- Cached image: %s\n' "${BASE_IMAGE_PATH:-not-created}"
        printf '\n'

        printf '## Results\n\n'
        printf -- '- Existing suite exit: %s\n' "$SUITE_EXIT"
        printf -- '- Artifact directory: %s\n' "$ARTIFACT_DIR"
        printf -- '- Runner log: %s\n' "$RUNNER_LOG"
        printf -- '- Suite log: %s\n' "$SUITE_LOG"
        printf -- '- Host tools: %s\n' "$HOST_TOOLS_FILE"
        printf -- '- Cleanup: %s\n' "$CLEANUP_STATUS"
        printf '\n'

        if [ -s "$PREFLIGHT_ERRORS_FILE" ]; then
            printf '## Preflight Errors\n\n'
            sed 's/^/- /' "$PREFLIGHT_ERRORS_FILE"
            printf '\n'
        fi

        printf '## Notes\n\n'
        printf -- '- The WireGuard config path and contents are intentionally omitted.\n'
        printf -- '- The generated SSH private key is intentionally omitted and removed during cleanup.\n'
        printf -- '- The Fedora base image cache is preserved; generated VM disks and seed files are removed.\n'
    } > "$report_tmp" && mv "$report_tmp" "$REPORT_PATH"
}

cleanup_vm() {
    CLEANUP_STATUS="running"

    if command -v virsh >/dev/null 2>&1; then
        if virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
            local state
            state="$(virsh --connect "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null || true)"
            if [ "$state" = "running" ] || [ "$state" = "paused" ]; then
                log_warn "Destroying disposable VM $VM_NAME"
                virsh --connect "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null 2>&1 || true
            fi

            log_warn "Undefining disposable VM $VM_NAME"
            virsh --connect "$LIBVIRT_URI" undefine "$VM_NAME" --nvram >/dev/null 2>&1 \
                || virsh --connect "$LIBVIRT_URI" undefine "$VM_NAME" >/dev/null 2>&1 \
                || true
        fi
    fi

    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        case "$WORK_DIR" in
            "$ARTIFACT_DIR"/vm-work|/tmp/paranoid-vpn-vm-*)
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

    local required_commands=(bash curl ssh scp ssh-keygen virsh virt-install qemu-img timeout awk sed grep)
    local command_name
    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done

    if [ "${SKIP_NMAP:-0}" != "1" ]; then
        require_command nmap
    fi

    if SEED_TOOL="$(first_command cloud-localds genisoimage mkisofs)"; then
        log_info "Cloud-init seed tool: $SEED_TOOL"
    else
        add_preflight_error "missing host command: cloud-localds, genisoimage, or mkisofs"
    fi

    if [ -z "${TEST_WG_CONF:-}" ]; then
        add_preflight_error "missing required environment variable: TEST_WG_CONF"
    elif [ ! -r "$TEST_WG_CONF" ]; then
        add_preflight_error "TEST_WG_CONF is not readable"
    elif ! grep -Eiq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0[.]0[.]0[.]0/0' "$TEST_WG_CONF"; then
        add_preflight_error "TEST_WG_CONF does not contain full-tunnel IPv4 AllowedIPs"
    fi

    if command -v virsh >/dev/null 2>&1; then
        if ! virsh --connect "$LIBVIRT_URI" list --all >/dev/null 2>&1; then
            add_preflight_error "cannot access libvirt URI: $LIBVIRT_URI"
        elif ! virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1; then
            add_preflight_error "libvirt network does not exist: $LIBVIRT_NETWORK"
        fi
    fi

    capture_tool_versions

    if ((${#PREFLIGHT_ERRORS[@]} > 0)); then
        printf '%s\n' "${PREFLIGHT_ERRORS[@]}" > "$PREFLIGHT_ERRORS_FILE"
        die "host preflight failed; see $PREFLIGHT_ERRORS_FILE"
    fi

    log_pass "host tools, libvirt access, and WireGuard config are ready"
}

ensure_libvirt_network() {
    set_phase "Libvirt network"

    local active
    active="$(virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" | awk '/^Active:/ {print $2}')"
    if [ "$active" != "yes" ]; then
        log_warn "Starting inactive libvirt network $LIBVIRT_NETWORK"
        virsh --connect "$LIBVIRT_URI" net-start "$LIBVIRT_NETWORK" >/dev/null
    fi

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

    if [ -z "$FEDORA_IMAGE_NAME" ]; then
        FEDORA_IMAGE_NAME="${FEDORA_IMAGE_SOURCE%%\?*}"
        FEDORA_IMAGE_NAME="${FEDORA_IMAGE_NAME##*/}"
    fi
    if [ -z "$FEDORA_IMAGE_NAME" ]; then
        FEDORA_IMAGE_NAME="fedora-cloud-${FEDORA_RELEASE}-${FEDORA_ARCH}.qcow2"
    fi

    BASE_IMAGE_PATH="$CACHE_DIR/$FEDORA_IMAGE_NAME"

    if [ -f "$BASE_IMAGE_PATH" ] && qemu-img info "$BASE_IMAGE_PATH" >/dev/null 2>&1; then
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

    log_pass "Fedora image cached"
}

create_cloud_init_seed() {
    set_phase "Create cloud-init seed"

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

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
    log_pass "throwaway VM disk created"
}

boot_vm() {
    set_phase "Boot VM"

    local os_args=()
    if virt-install --help 2>&1 | grep -q -- '--osinfo'; then
        os_args=(--osinfo "${VM_OSINFO:-detect=on,require=off}")
    else
        os_args=(--os-variant "${VM_OS_VARIANT:-fedora-unknown}")
    fi

    virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY_MB" \
        --vcpus "$VM_CPUS" \
        --import \
        --disk "path=$VM_DISK_PATH,format=qcow2,bus=virtio" \
        --disk "path=$SEED_ISO_PATH,device=cdrom" \
        --network "network=$LIBVIRT_NETWORK,model=virtio" \
        --graphics none \
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

        log_info "VM IP not ready yet (${attempt}/${VM_BOOT_ATTEMPTS}); retrying in ${VM_BOOT_DELAY}s"
        sleep "$VM_BOOT_DELAY"
    done

    die "timed out waiting for VM DHCP lease"
}

wait_for_ssh() {
    set_phase "Wait for SSH"

    local attempt
    for ((attempt = 1; attempt <= VM_BOOT_ATTEMPTS; attempt++)); do
        if remote_run "true" >/dev/null 2>&1; then
            log_pass "SSH is ready"
            return
        fi

        log_info "SSH not ready yet (${attempt}/${VM_BOOT_ATTEMPTS}); retrying in ${VM_BOOT_DELAY}s"
        sleep "$VM_BOOT_DELAY"
    done

    die "timed out waiting for SSH on $VM_IP"
}

provision_guest() {
    set_phase "Provision guest"

    remote_run '
set -Eeuo pipefail
if command -v cloud-init >/dev/null 2>&1; then
    sudo -n cloud-init status --wait >/dev/null || true
fi
sudo -n dnf -y install firewalld wireguard-tools NetworkManager curl bind-utils iproute iputils procps-ng sudo
sudo -n systemctl enable --now NetworkManager.service
sudo -n systemctl enable --now firewalld.service
sudo -n install -d -m 700 /etc/wireguard
'

    remote_scp_to "$TEST_WG_CONF" "/tmp/paranoid-vpn-wg0.conf"
    remote_run '
set -Eeuo pipefail
sudo -n install -m 600 -o root -g root /tmp/paranoid-vpn-wg0.conf /etc/wireguard/wg0.conf
rm -f /tmp/paranoid-vpn-wg0.conf
sudo -n test -f /etc/wireguard/wg0.conf
'

    log_pass "guest dependencies and WireGuard config are installed"
}

run_existing_suite() {
    set_phase "Run VM integration suite"

    set +e
    VM_HOST="$VM_IP" \
        VM_USER="$VM_USER" \
        VM_PORT="$VM_PORT" \
        SSH_KEY="$SSH_KEY_PATH" \
        VM_WG_CONF="/etc/wireguard/wg0.conf" \
        TEST_ARTIFACT_DIR="$ARTIFACT_DIR" \
        "$SCRIPT_DIR/run-vm-integration.sh" > "$SUITE_LOG" 2>&1
    SUITE_EXIT=$?
    set -e

    if [ "$SUITE_EXIT" -ne 0 ]; then
        die "existing VM integration suite failed with exit code $SUITE_EXIT"
    fi

    log_pass "existing VM integration suite passed"
}

main() {
    parse_args "$@"

    mkdir -p "$ARTIFACT_DIR" "$WORK_DIR"
    exec > >(tee -a "$RUNNER_LOG") 2>&1
    trap on_exit EXIT

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
    provision_guest
    run_existing_suite

    RESULT="passed"
    log_section "Independent suite complete"
    log_pass "independent VM integration run passed"
}

main "$@"
