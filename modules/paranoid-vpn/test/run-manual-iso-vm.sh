#!/usr/bin/env bash
###############################################################################
# Manual ISO VM lab for paranoid-vpn.
#
# This runner does not assume Fedora, cloud-init, SSH, or package names. It
# creates a blank VM disk, attaches any user-supplied installer ISO, attaches a
# second payload ISO containing the same paranoid-vpn bundle produced by
# tools/prepare-offline-usb.sh, and leaves the VM running for manual testing.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MODULE_TOOLS_DIR="$MODULE_DIR/tools"

# shellcheck source=modules/paranoid-vpn/test/lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

VM_ISO="${VM_ISO:-}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
VM_NAME="${VM_NAME:-paranoid-vpn-manual-${TIMESTAMP}-$$}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_GRAPHICS="${VM_GRAPHICS:-spice,listen=127.0.0.1}"
VM_OSINFO="${VM_OSINFO:-detect=on,require=off}"
ISO_COPY="${ISO_COPY:-1}"
TEST_WG_CONF="${TEST_WG_CONF:-}"
PAYLOAD_RPM_DIR="${PAYLOAD_RPM_DIR:-}"

ARTIFACT_DIR="${TEST_ARTIFACT_DIR:-$SCRIPT_DIR/artifacts/manual-iso-$TIMESTAMP}"
if [ -n "${VM_WORK_DIR:-}" ]; then
    WORK_DIR="$VM_WORK_DIR"
elif [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
    WORK_DIR="/var/tmp/paranoid-vpn-manual-iso-${TIMESTAMP}-$$"
else
    WORK_DIR="$ARTIFACT_DIR/vm-work"
fi
if [ -n "${VM_CACHE_DIR:-}" ]; then
    CACHE_DIR="$VM_CACHE_DIR"
elif [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
    CACHE_DIR="/var/tmp/paranoid-vpn-iso-cache"
else
    CACHE_DIR="$SCRIPT_DIR/vm-cache/manual-iso"
fi

RUNNER_LOG="$ARTIFACT_DIR/manual-iso-runner.log"
REPORT_PATH="${VM_MANUAL_ISO_REPORT:-$ARTIFACT_DIR/manual-iso-report-$TIMESTAMP.md}"
PAYLOAD_DIR="$WORK_DIR/payload"
VM_DISK_PATH="$WORK_DIR/${VM_NAME}.qcow2"
INSTALL_ISO_PATH=""
PAYLOAD_ISO_PATH="$WORK_DIR/${VM_NAME}-payload.iso"

usage() {
    cat <<EOF
Usage:
  VM_ISO=/path/to/linux.iso $0
  VM_ISO=https://example.invalid/linux.iso $0

Optional environment:
  TEST_WG_CONF       Optional WireGuard config copied into payload ISO.
  PAYLOAD_RPM_DIR    Optional RPM cache directory copied as paranoid-vpn/rpms.
  LIBVIRT_URI        Libvirt connection URI. Default: qemu:///system
  LIBVIRT_NETWORK    Libvirt network. Default: default
  VM_NAME            VM name. Default: paranoid-vpn-manual-<timestamp>
  VM_MEMORY_MB       VM memory. Default: 4096
  VM_CPUS            VM vCPU count. Default: 2
  VM_DISK_SIZE       Blank disk size. Default: 40G
  VM_GRAPHICS        virt-install graphics string. Default: spice,listen=127.0.0.1
  VM_OSINFO          virt-install osinfo value. Default: detect=on,require=off
  ISO_COPY           Copy local ISO into VM work/cache path. Default: 1
  DOWNLOAD_RPMS      Download RPMs through prepare-offline-usb.sh. Default: 1
  TARGET_FEDORA_RELEASE
                     Fedora release for the offline RPM cache.
  VM_WORK_DIR        Override generated disk/payload location.
  VM_CACHE_DIR       Override downloaded/copied ISO cache.
  TEST_ARTIFACT_DIR  Artifact directory. Default: module test artifacts/manual-iso-<timestamp>

The VM is intentionally left running. Open it with:
  virt-manager --connect \$LIBVIRT_URI
EOF
}

die() {
    log_error "$1"
    exit 1
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "missing host command: $command_name"
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

is_url() {
    [[ "$1" =~ ^https?:// ]]
}

safe_basename() {
    local value="$1"
    value="${value%%\?*}"
    value="${value##*/}"
    if [ -z "$value" ]; then
        value="installer.iso"
    fi
    printf '%s\n' "$value"
}

prepare_dirs() {
    mkdir -p "$ARTIFACT_DIR" "$WORK_DIR" "$CACHE_DIR"
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 755 "$WORK_DIR" "$CACHE_DIR"
    fi
}

resolve_iso() {
    log_section "Resolve installer ISO"

    local iso_name

    if [ -z "$VM_ISO" ]; then
        usage >&2
        die "missing required environment variable: VM_ISO"
    fi

    iso_name="$(safe_basename "$VM_ISO")"

    if is_url "$VM_ISO"; then
        INSTALL_ISO_PATH="$CACHE_DIR/$iso_name"
        if [ ! -f "$INSTALL_ISO_PATH" ]; then
            log_info "Downloading ISO to $INSTALL_ISO_PATH"
            curl -fL --retry 3 --retry-delay 5 "$VM_ISO" -o "${INSTALL_ISO_PATH}.download"
            mv "${INSTALL_ISO_PATH}.download" "$INSTALL_ISO_PATH"
        fi
    elif [ ! -f "$VM_ISO" ]; then
        die "VM_ISO does not exist: $VM_ISO"
    elif [ "$ISO_COPY" = "1" ]; then
        INSTALL_ISO_PATH="$CACHE_DIR/$iso_name"
        if [ "$VM_ISO" != "$INSTALL_ISO_PATH" ]; then
            log_info "Copying ISO to $INSTALL_ISO_PATH"
            cp -f "$VM_ISO" "$INSTALL_ISO_PATH"
        fi
    else
        INSTALL_ISO_PATH="$VM_ISO"
    fi

    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$INSTALL_ISO_PATH"
    fi

    log_pass "installer ISO ready: $INSTALL_ISO_PATH"
}

create_payload_iso() {
    log_section "Create payload ISO"

    local iso_tool
    local bundle_dir
    local prepare_env=()

    iso_tool="$(first_command genisoimage mkisofs)" || die "missing host command: genisoimage or mkisofs"
    bundle_dir="$PAYLOAD_DIR/paranoid-vpn"

    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$PAYLOAD_DIR"

    if [ -n "$TEST_WG_CONF" ]; then
        if [ ! -r "$TEST_WG_CONF" ]; then
            die "TEST_WG_CONF is not readable: $TEST_WG_CONF"
        fi
        prepare_env+=(WG_CONF="$TEST_WG_CONF")
    fi

    if [ -n "$PAYLOAD_RPM_DIR" ]; then
        if [ ! -d "$PAYLOAD_RPM_DIR" ]; then
            die "PAYLOAD_RPM_DIR is not a directory: $PAYLOAD_RPM_DIR"
        fi
        if ! find "$PAYLOAD_RPM_DIR" -name '*.rpm' -type f -print -quit | grep -q .; then
            die "PAYLOAD_RPM_DIR does not contain RPM files: $PAYLOAD_RPM_DIR"
        fi
        prepare_env+=(DOWNLOAD_RPMS=0)
    fi

    env "${prepare_env[@]}" "$MODULE_TOOLS_DIR/prepare-offline-usb.sh" "$bundle_dir"

    if [ -n "$PAYLOAD_RPM_DIR" ]; then
        mkdir -p "$bundle_dir/rpms"
        cp -f "$PAYLOAD_RPM_DIR"/*.rpm "$bundle_dir/rpms/"
        log_warn "Copied RPM cache into payload ISO; payload may be large"
    fi

    "$iso_tool" -quiet -output "$PAYLOAD_ISO_PATH" -volid PVPNPAYLOAD -joliet -rock "$PAYLOAD_DIR"

    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$PAYLOAD_ISO_PATH"
    fi

    log_pass "payload ISO ready: $PAYLOAD_ISO_PATH"
}

ensure_libvirt_network() {
    log_section "Libvirt network"

    local active
    active="$(virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" | awk '/^Active:/ {print $2}')"
    if [ "$active" != "yes" ]; then
        log_warn "Starting inactive libvirt network $LIBVIRT_NETWORK"
        virsh --connect "$LIBVIRT_URI" net-start "$LIBVIRT_NETWORK" >/dev/null
    fi
    virsh --connect "$LIBVIRT_URI" net-autostart "$LIBVIRT_NETWORK" >/dev/null 2>&1 || true

    log_pass "libvirt network is active"
}

create_vm_disk() {
    log_section "Create VM disk"

    qemu-img create -f qcow2 "$VM_DISK_PATH" "$VM_DISK_SIZE" >/dev/null
    if [[ "$LIBVIRT_URI" = qemu:///system* ]]; then
        chmod 644 "$VM_DISK_PATH"
    fi

    log_pass "blank VM disk ready: $VM_DISK_PATH"
}

boot_vm() {
    log_section "Boot manual VM"

    local os_args=()
    if virt-install --help 2>&1 | grep -q -- '--osinfo'; then
        os_args=(--osinfo "$VM_OSINFO")
    else
        os_args=(--os-variant "${VM_OS_VARIANT:-generic}")
    fi

    virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY_MB" \
        --vcpus "$VM_CPUS" \
        --disk "path=$VM_DISK_PATH,format=qcow2,bus=virtio" \
        --cdrom "$INSTALL_ISO_PATH" \
        --disk "path=$PAYLOAD_ISO_PATH,device=cdrom" \
        --network "network=$LIBVIRT_NETWORK,model=virtio" \
        --graphics "$VM_GRAPHICS" \
        --video virtio \
        --channel spicevmc \
        --noautoconsole \
        "${os_args[@]}"

    log_pass "VM boot requested"
}

write_report() {
    {
        printf '# Manual ISO VM Lab\n\n'
        printf -- '- VM name: %s\n' "$VM_NAME"
        printf -- '- Installer ISO: %s\n' "$INSTALL_ISO_PATH"
        printf -- '- Payload ISO: %s\n' "$PAYLOAD_ISO_PATH"
        printf -- '- VM disk: %s\n' "$VM_DISK_PATH"
        printf -- '- Libvirt URI: %s\n' "$LIBVIRT_URI"
        printf -- '- Libvirt network: %s\n' "$LIBVIRT_NETWORK"
        printf -- '- Graphics: %s\n' "$VM_GRAPHICS"
        printf -- '- Artifact directory: %s\n' "$ARTIFACT_DIR"
        printf '\n'
        printf 'Open with:\n\n'
        printf '```bash\n'
        printf 'virt-manager --connect %q\n' "$LIBVIRT_URI"
        printf '```\n\n'
        printf 'Cleanup when finished:\n\n'
        printf '```bash\n'
        printf 'virsh --connect %q destroy %q\n' "$LIBVIRT_URI" "$VM_NAME"
        printf 'virsh --connect %q undefine %q --remove-all-storage\n' "$LIBVIRT_URI" "$VM_NAME"
        printf 'rm -rf %q\n' "$WORK_DIR"
        printf '```\n'
    } > "$REPORT_PATH"
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    require_command curl
    require_command cp
    require_command install
    require_command qemu-img
    require_command virsh
    require_command virt-install

    prepare_dirs
    exec > >(tee -a "$RUNNER_LOG") 2>&1

    resolve_iso
    create_payload_iso
    ensure_libvirt_network
    create_vm_disk
    boot_vm
    write_report

    printf '\nManual ISO VM is running.\n'
    printf '  VM name: %s\n' "$VM_NAME"
    printf '  Open: virt-manager --connect %q\n' "$LIBVIRT_URI"
    printf '  Payload ISO label: PVPNPAYLOAD\n'
    printf '  Report: %s\n' "$REPORT_PATH"
}

main "$@"
