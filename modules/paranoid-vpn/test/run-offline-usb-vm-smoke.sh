#!/usr/bin/env bash
###############################################################################
# Offline USB VM smoke test for paranoid-vpn.
#
# This test creates a USB-style FAT disk image containing the offline bundle,
# boots a disposable Fedora Cloud VM, attaches the image to the VM, mounts it,
# runs the offline preflight, and starts the hardening entrypoint. It only proves
# that hardening starts from the USB path; it does not validate final lockdown.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
REPO_DIR="$(cd -- "$MODULE_DIR/../.." && pwd -P)"

# shellcheck source=modules/paranoid-vpn/test/lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
STARTED_AT="$(date -Is)"

DEFAULT_FEDORA_RELEASE="43"
if command -v rpm >/dev/null 2>&1; then
    DETECTED_FEDORA_RELEASE="$(rpm -E %fedora 2>/dev/null || true)"
    if [[ "$DETECTED_FEDORA_RELEASE" =~ ^[0-9]+$ ]]; then
        DEFAULT_FEDORA_RELEASE="$DETECTED_FEDORA_RELEASE"
    fi
fi
FEDORA_RELEASE="${FEDORA_RELEASE:-$DEFAULT_FEDORA_RELEASE}"
FEDORA_ARCH="${FEDORA_ARCH:-x86_64}"
FEDORA_IMAGE_INDEX_URL="${FEDORA_IMAGE_INDEX_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Cloud/${FEDORA_ARCH}/images/}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
VM_MEMORY_MB="${VM_MEMORY_MB:-2048}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_BOOT_ATTEMPTS="${VM_BOOT_ATTEMPTS:-60}"
VM_BOOT_DELAY="${VM_BOOT_DELAY:-5}"
VM_USER="${VM_USER:-fedora}"
VM_PORT="${VM_PORT:-22}"
VM_NAME="${VM_NAME:-paranoid-vpn-offline-usb-${TIMESTAMP}-$$}"

ARTIFACT_DIR="${TEST_ARTIFACT_DIR:-$SCRIPT_DIR/artifacts/offline-usb-$TIMESTAMP}"
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
    WORK_DIR="/var/tmp/paranoid-vpn-offline-usb-${TIMESTAMP}-$$"
else
    WORK_DIR="$ARTIFACT_DIR/vm-work"
fi

REPORT_PATH="${VM_INTEGRATION_REPORT:-$ARTIFACT_DIR/offline-usb-smoke-report-$TIMESTAMP.md}"
RUNNER_LOG="$ARTIFACT_DIR/offline-usb-runner.log"
HOST_TOOLS_FILE="$ARTIFACT_DIR/host-tools.txt"
PREFLIGHT_ERRORS_FILE="$ARTIFACT_DIR/preflight-errors.txt"
KNOWN_HOSTS_FILE="$WORK_DIR/known_hosts"
USB_BUNDLE_DIR="$ARTIFACT_DIR/usb-bundle/paranoid-vpn"
if [ -n "${USB_IMAGE_PATH:-}" ]; then
    USB_IMAGE_PATH="$USB_IMAGE_PATH"
elif [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
    USB_IMAGE_PATH="$WORK_DIR/paranoid-vpn-offline-usb.img"
else
    USB_IMAGE_PATH="$ARTIFACT_DIR/paranoid-vpn-offline-usb.img"
fi
USB_IMAGE_SIZE_MB="${USB_IMAGE_SIZE_MB:-2048}"
USB_DOWNLOAD_RPMS="${USB_DOWNLOAD_RPMS:-1}"
HARDENING_START_TIMEOUT="${HARDENING_START_TIMEOUT:-90}"
PRESERVE_USB_IMAGE="${PRESERVE_USB_IMAGE:-1}"
PREFLIGHT_ONLY=0
USB_ARTIFACT_IMAGE="$ARTIFACT_DIR/paranoid-vpn-offline-usb.img"

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
CLEANUP_STATUS="not-started"
SEED_TOOL=""
USB_TARGET_DEV="sdb"
USB_LABEL="${USB_LABEL:-PVPNUSB}"
USB_ATTACHED=0

declare -a PREFLIGHT_ERRORS=()

usage() {
    cat <<EOF
Usage:
  TEST_WG_CONF=/path/to/wg0.conf $0
  $0 --preflight-only

Required environment:
  TEST_WG_CONF              Local WireGuard config copied into the USB image.

Optional environment:
  USB_DOWNLOAD_RPMS         Download RPMs into the USB bundle. Default: 1
  USB_IMAGE_SIZE_MB         FAT USB image size. Default: 2048
  USB_IMAGE_PATH            Override generated disk-image path.
  USB_LABEL                 FAT filesystem label. Default: PVPNUSB
  PRESERVE_USB_IMAGE        Copy the generated image into artifacts. Default: 1
  HARDENING_START_TIMEOUT   Seconds to let run-hardening start. Default: 90
  FEDORA_RELEASE            Fedora Cloud release. Default: host Fedora release, fallback 43
  LIBVIRT_URI               Libvirt connection URI. Default: qemu:///system
  LIBVIRT_NETWORK           Libvirt NAT/private network. Default: default
  VM_MEMORY_MB              VM memory. Default: 2048
  VM_CPUS                   VM vCPU count. Default: 2
  VM_DISK_SIZE              Throwaway overlay disk size. Default: 20G
EOF
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
        ssh|scp|ssh-keygen)
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

copy_vm_log() {
    local remote_name="$1"
    local local_name="$2"

    scp \
        -i "$SSH_KEY_PATH" \
        -P "$VM_PORT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
        "${VM_USER}@${VM_IP}:/home/${VM_USER}/${remote_name}" \
        "$ARTIFACT_DIR/$local_name" >/dev/null 2>&1 || true
}

copy_usb_smoke_logs() {
    remote_run "
set +e
sudo -n cp /tmp/install-offline-deps.log /tmp/offline-preflight.log /tmp/run-hardening-start.log /home/$VM_USER/ 2>/dev/null || true
sudo -n chown $VM_USER:$VM_USER /home/$VM_USER/install-offline-deps.log /home/$VM_USER/offline-preflight.log /home/$VM_USER/run-hardening-start.log 2>/dev/null || true
" >/dev/null 2>&1 || true

    copy_vm_log "install-offline-deps.log" "install-offline-deps-vm.log"
    copy_vm_log "offline-preflight.log" "offline-preflight-vm.log"
    copy_vm_log "run-hardening-start.log" "run-hardening-start-vm.log"
}

capture_tool_versions() {
    {
        printf 'started_at: %s\n' "$STARTED_AT"
        printf 'libvirt_uri: %s\n' "$LIBVIRT_URI"
        printf 'libvirt_network: %s\n' "$LIBVIRT_NETWORK"
        printf 'fedora_release: %s\n' "$FEDORA_RELEASE"
        printf 'usb_image_size_mb: %s\n' "$USB_IMAGE_SIZE_MB"
        printf 'usb_download_rpms: %s\n' "$USB_DOWNLOAD_RPMS"

        local tool
        for tool in bash curl ssh ssh-keygen virsh virt-install qemu-img mkfs.vfat mcopy timeout awk sed grep; do
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
    local finished_at report_status report_tmp

    finished_at="$(date -Is)"
    report_tmp="${REPORT_PATH}.tmp"

    if (( status == 0 )); then
        report_status="PASS"
    else
        report_status="FAIL"
    fi

    {
        printf '# Offline USB VM Smoke Report\n\n'
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
        printf '\n'

        printf '## USB\n\n'
        printf -- '- Image: %s\n' "$USB_IMAGE_PATH"
        if [ "$PRESERVE_USB_IMAGE" = "1" ]; then
            printf -- '- Preserved image: %s\n' "$USB_ARTIFACT_IMAGE"
        fi
        printf -- '- Bundle: %s\n' "$USB_BUNDLE_DIR"
        printf -- '- Label: %s\n' "$USB_LABEL"
        printf -- '- Requested target: /dev/%s\n' "$USB_TARGET_DEV"
        printf -- '- Download RPMs: %s\n' "$USB_DOWNLOAD_RPMS"
        printf '\n'

        printf '## Artifacts\n\n'
        printf -- '- Directory: %s\n' "$ARTIFACT_DIR"
        printf -- '- Runner log: %s\n' "$RUNNER_LOG"
        printf -- '- Host tools: %s\n' "$HOST_TOOLS_FILE"
        printf -- '- Cleanup: %s\n' "$CLEANUP_STATUS"
        printf '\n'

        if [ -s "$PREFLIGHT_ERRORS_FILE" ]; then
            printf '## Preflight Errors\n\n'
            sed 's/^/- /' "$PREFLIGHT_ERRORS_FILE"
            printf '\n'
        fi
    } > "$report_tmp" && mv "$report_tmp" "$REPORT_PATH"
}

cleanup_vm() {
    CLEANUP_STATUS="running"

    if [ "$USB_ATTACHED" = "1" ] && command -v virsh >/dev/null 2>&1; then
        virsh --connect "$LIBVIRT_URI" detach-disk "$VM_NAME" "$USB_TARGET_DEV" --persistent >/dev/null 2>&1 || true
    fi

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
            "$ARTIFACT_DIR"/vm-work|/tmp/paranoid-vpn-offline-usb-*|/var/tmp/paranoid-vpn-offline-usb-*)
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

    local required_commands=(bash curl ssh ssh-keygen virsh virt-install qemu-img mkfs.vfat mcopy timeout awk sed grep)
    local command_name
    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done

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
        if ! timeout 10 virsh --connect "$LIBVIRT_URI" list --all >/dev/null 2>&1; then
            add_preflight_error "cannot access libvirt URI: $LIBVIRT_URI"
        elif ! timeout 10 virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1; then
            add_preflight_error "libvirt network does not exist: $LIBVIRT_NETWORK"
        fi
    fi

    capture_tool_versions

    if ((${#PREFLIGHT_ERRORS[@]} > 0)); then
        printf '%s\n' "${PREFLIGHT_ERRORS[@]}" > "$PREFLIGHT_ERRORS_FILE"
        die "host preflight failed; see $PREFLIGHT_ERRORS_FILE"
    fi

    log_pass "host tools and test inputs are ready"
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

    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$SEED_ISO_PATH"
    fi

    log_pass "cloud-init seed created"
}

create_vm_disk() {
    set_phase "Create VM disk"

    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$VM_DISK_PATH" "$VM_DISK_SIZE" >/dev/null
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$VM_DISK_PATH"
    fi
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

prepare_usb_bundle() {
    set_phase "Prepare offline bundle"

    DOWNLOAD_RPMS="$USB_DOWNLOAD_RPMS" \
        WG_CONF="$TEST_WG_CONF" \
        "$MODULE_DIR/tools/prepare-offline-usb.sh" "$USB_BUNDLE_DIR" > "$ARTIFACT_DIR/prepare-offline-usb.log" 2>&1

    log_pass "offline bundle directory prepared"
}

create_usb_image() {
    set_phase "Create USB image"

    rm -f "$USB_IMAGE_PATH"
    truncate -s "${USB_IMAGE_SIZE_MB}M" "$USB_IMAGE_PATH"
    mkfs.vfat -n "$USB_LABEL" "$USB_IMAGE_PATH" >/dev/null
    mcopy -s -i "$USB_IMAGE_PATH" "$USB_BUNDLE_DIR" ::/
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$USB_IMAGE_PATH"
    fi

    if [ "$PRESERVE_USB_IMAGE" = "1" ] && [ "$USB_IMAGE_PATH" != "$USB_ARTIFACT_IMAGE" ]; then
        cp --sparse=always "$USB_IMAGE_PATH" "$USB_ARTIFACT_IMAGE"
        chmod 600 "$USB_ARTIFACT_IMAGE"
    elif [ "$PRESERVE_USB_IMAGE" = "1" ] && [ "$USB_IMAGE_PATH" = "$USB_ARTIFACT_IMAGE" ]; then
        chmod 600 "$USB_ARTIFACT_IMAGE"
    fi

    log_pass "USB image created at $USB_IMAGE_PATH"
}

attach_usb_image() {
    set_phase "Attach USB image"

    virsh --connect "$LIBVIRT_URI" attach-disk "$VM_NAME" "$USB_IMAGE_PATH" "$USB_TARGET_DEV" \
        --targetbus usb --driver qemu --subdriver raw --live >/dev/null
    USB_ATTACHED=1

    log_pass "USB image attached; guest device will be discovered by label $USB_LABEL"
}

mount_usb_in_vm() {
    set_phase "Mount USB in VM"

    local remote_script
    remote_script="$(cat <<EOF
set -Eeuo pipefail
USB_LABEL=$(shell_quote "$USB_LABEL")
MOUNT_DIR=/mnt/paranoid-vpn-usb
DEBUG_LOG=/tmp/usb-mount-debug.log
USB_DEVICE=/tmp/paranoid-vpn-usb-device

write_debug() {
    {
        printf 'USB mount debug at %s\n' "\$(date -Is)"
        printf '\n## lsblk\n'
        lsblk -fp || true
        printf '\n## blkid\n'
        sudo -n blkid || true
        printf '\n## /dev/disk/by-label\n'
        ls -la /dev/disk/by-label 2>/dev/null || true
        printf '\n## dmesg tail\n'
        sudo -n dmesg | tail -120 || true
    } > "\$DEBUG_LOG" 2>&1
}
trap 'write_debug' ERR

sudo -n modprobe usb-storage 2>/dev/null || true
sudo -n modprobe uas 2>/dev/null || true

dev=''
for attempt in {1..30}; do
    sudo -n udevadm settle --timeout=3 >/dev/null 2>&1 || true

    dev="\$(blkid -L "\$USB_LABEL" 2>/dev/null || true)"
    if [ -n "\$dev" ] && [ -b "\$dev" ]; then
        break
    fi

    if [ -b "/dev/disk/by-label/\$USB_LABEL" ]; then
        dev="/dev/disk/by-label/\$USB_LABEL"
        break
    fi

    dev="\$(lsblk -rpno NAME,LABEL,FSTYPE 2>/dev/null | awk -v label="\$USB_LABEL" '\$2 == label && \$3 ~ /^(vfat|fat|msdos)$/ {print \$1; exit}')"
    if [ -n "\$dev" ] && [ -b "\$dev" ]; then
        break
    fi

    sleep 1
done

if [ -z "\$dev" ] || [ ! -b "\$dev" ]; then
    write_debug
    printf 'Could not find attached USB image with label %s\n' "\$USB_LABEL" >&2
    exit 1
fi

sudo -n mkdir -p /mnt/paranoid-vpn-usb
sudo -n mount -t vfat -o ro "\$dev" "\$MOUNT_DIR"
test -x /mnt/paranoid-vpn-usb/paranoid-vpn/offline-preflight.sh
printf '%s\n' "\$dev" > "\$USB_DEVICE"
write_debug
EOF
)"

    if ! remote_run "$remote_script"; then
        remote_run "sudo -n cp /tmp/usb-mount-debug.log /home/$VM_USER/ 2>/dev/null || true" >/dev/null 2>&1 || true
        scp \
            -i "$SSH_KEY_PATH" \
            -P "$VM_PORT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
            "${VM_USER}@${VM_IP}:/home/${VM_USER}/usb-mount-debug.log" \
            "$ARTIFACT_DIR/usb-mount-debug.log" >/dev/null 2>&1 || true
        die "USB image attached but guest could not mount it; see $ARTIFACT_DIR/usb-mount-debug.log"
    fi

    remote_run "sudo -n cp /tmp/usb-mount-debug.log /home/$VM_USER/ 2>/dev/null || true" >/dev/null 2>&1 || true
    scp \
        -i "$SSH_KEY_PATH" \
        -P "$VM_PORT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
        "${VM_USER}@${VM_IP}:/home/${VM_USER}/usb-mount-debug.log" \
        "$ARTIFACT_DIR/usb-mount-debug.log" >/dev/null 2>&1 || true

    log_pass "USB image mounted in VM"
}

run_usb_smoke() {
    set_phase "Run offline USB smoke"

    local remote_script
    remote_script="
set -Eeuo pipefail
cd /mnt/paranoid-vpn-usb/paranoid-vpn
if find rpms -type f -name '*.rpm' -print -quit 2>/dev/null | grep -q .; then
    sudo -n ./install-offline-deps.sh > /tmp/install-offline-deps.log 2>&1
else
    printf 'No RPM cache found on USB image; skipping offline package install.\n' > /tmp/install-offline-deps.log
fi
./offline-preflight.sh > /tmp/offline-preflight.log 2>&1
set +e
ALLOW_SSH=1 timeout $HARDENING_START_TIMEOUT sudo -E ./run-hardening.sh > /tmp/run-hardening-start.log 2>&1
status=\$?
set -e
if grep -Eq 'Running paranoid-vpn hardening|Phase 1: WireGuard configuration|Starting wg0 tunnel' /tmp/run-hardening-start.log; then
    exit 0
fi
printf 'run-hardening did not reach expected start marker; exit=%s\n' \"\$status\" >&2
tail -120 /tmp/run-hardening-start.log >&2 || true
exit 1
"

    if ! remote_run "$remote_script"; then
        copy_usb_smoke_logs
        die "offline USB smoke failed; see $ARTIFACT_DIR/install-offline-deps-vm.log, offline-preflight-vm.log, and run-hardening-start-vm.log"
    fi

    copy_usb_smoke_logs

    log_pass "offline USB preflight passed and hardening started"
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

    prepare_usb_bundle
    create_usb_image
    ensure_libvirt_network
    discover_fedora_image_url
    ensure_base_image
    create_cloud_init_seed
    create_vm_disk
    boot_vm
    wait_for_vm_ip
    wait_for_ssh
    attach_usb_image
    mount_usb_in_vm
    run_usb_smoke

    RESULT="passed"
    log_section "Offline USB smoke complete"
    log_pass "offline USB VM smoke passed"
}

main "$@"
