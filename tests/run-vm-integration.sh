#!/usr/bin/env bash
###############################################################################
# VM integration suite for paranoid-vpn.
#
# This suite intentionally drives a real disposable VM. The final test brings
# wg0 down and expects the watchdog kill switch to block outbound traffic.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=tests/lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=tests/lib/retry.sh
source "$SCRIPT_DIR/lib/retry.sh"
# shellcheck source=tests/lib/cleanup.sh
source "$SCRIPT_DIR/lib/cleanup.sh"
# shellcheck source=tests/lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"

VM_PORT="${VM_PORT:-22}"
VM_WG_CONF="${VM_WG_CONF:-/etc/wireguard/wg0.conf}"
PUBLIC_IP_URL="${PUBLIC_IP_URL:-https://ifconfig.me}"
NMAP_PORTS="${NMAP_PORTS:-1-1024,51820,22,53}"
NMAP_TIMEOUT="${NMAP_TIMEOUT:-120}"
SKIP_NMAP="${SKIP_NMAP:-0}"
TEST_ALLOW_SSH="${TEST_ALLOW_SSH:-0}"
RESTORE_AFTER_TEST="${RESTORE_AFTER_TEST:-0}"
WATCHDOG_ATTEMPTS="${WATCHDOG_ATTEMPTS:-12}"
WATCHDOG_DELAY="${WATCHDOG_DELAY:-5}"

LOCAL_TMP=""
REMOTE_WORKDIR=""
ARTIFACT_DIR="${TEST_ARTIFACT_DIR:-$SCRIPT_DIR/artifacts/$(date +%Y%m%d_%H%M%S)}"

usage() {
    cat <<EOF
Usage:
  VM_HOST=<ip> VM_USER=<user> $0

Required environment:
  VM_HOST                 Private VM address reachable from this runner.
  VM_USER                 SSH user with passwordless sudo.

Optional environment:
  VPN_EXPECTED_EXIT_IP    Exact public IPv4 expected through VPN, or auto. Default: auto
  VM_PORT                 SSH port. Default: 22
  SSH_KEY                 SSH private key path.
  VM_WG_CONF              Existing WireGuard config on the VM. Default: /etc/wireguard/wg0.conf
  PUBLIC_IP_URL           Public IP endpoint. Default: https://ifconfig.me
  NMAP_PORTS              Host-side TCP ports to scan. Default: 1-1024,51820,22,53
  SKIP_NMAP               Set to 1 to skip host-side nmap scans. Default: 0
  TEST_ALLOW_SSH          Set to 1 to run setup with --allow-ssh. Default: 0
  RESTORE_AFTER_TEST       Set to 1 to restore the VM after final test. Default: 0
  TEST_ARTIFACT_DIR       Local output directory. Default: tests/artifacts/<timestamp>

The final test is destructive: it runs 'sudo wg-quick down wg0' on the VM.
EOF
}

on_exit() {
    local status=$?

    if (( status != 0 )); then
        log_warn "suite failed; collecting VM artifacts best-effort"
        collect_remote_artifacts "failure" || true
        if [ "${RESTORE_AFTER_TEST:-0}" = "1" ]; then
            log_warn "RESTORE_AFTER_TEST=1; restoring VM after failure best-effort"
            remote_run "sudo -n /opt/paranoid-vpn/paranoid-vpn.sh --restore" >/dev/null 2>&1 || true
        fi
    fi

    cleanup_run

    if [ -d "$ARTIFACT_DIR" ]; then
        if (( status == 0 )); then
            log_info "Artifacts saved to $ARTIFACT_DIR"
        else
            log_warn "Artifacts saved to $ARTIFACT_DIR"
        fi
    fi

    exit "$status"
}

require_env() {
    local name="$1"

    if [ -z "${!name:-}" ]; then
        fail "missing required environment variable: $name"
    fi
}

require_local_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "missing local command: $command_name"
    fi
}

normalize_one_line() {
    sed 's/[[:space:]]//g'
}

preflight_local() {
    log_section "Local preflight"

    require_env VM_HOST
    require_env VM_USER

    VPN_EXPECTED_EXIT_IP="${VPN_EXPECTED_EXIT_IP:-auto}"

    if [ "$VPN_EXPECTED_EXIT_IP" != "auto" ] && ! [[ "$VPN_EXPECTED_EXIT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        fail "VPN_EXPECTED_EXIT_IP must be an exact IPv4 address or 'auto'"
    fi

    local required_commands=(ssh scp timeout awk sed grep)
    local command_name
    for command_name in "${required_commands[@]}"; do
        require_local_command "$command_name"
    done
    if [ "$SKIP_NMAP" != "1" ]; then
        require_local_command nmap
    else
        log_warn "SKIP_NMAP=1; host-side port scans will be skipped"
    fi
    if [ "$TEST_ALLOW_SSH" = "1" ]; then
        log_warn "TEST_ALLOW_SSH=1; setup will keep SSH open during this run"
    fi
    if [ "$RESTORE_AFTER_TEST" = "1" ]; then
        log_warn "RESTORE_AFTER_TEST=1; suite will restore VM after destructive checks"
    fi

    mkdir -p "$ARTIFACT_DIR"
    LOCAL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/paranoid-vpn-itest.XXXXXX")"

    cleanup_add 'rm -rf "$LOCAL_TMP"'

    log_pass "required local environment and tools are present"
    log_info "Artifacts directory: $ARTIFACT_DIR"
}

remote_check() {
    local description="$1"
    local command="$2"

    if remote_run "$command"; then
        log_pass "$description"
    else
        fail "$description"
    fi
}

preflight_vm() {
    log_section "VM preflight"

    local required_tool_check
    required_tool_check='
missing=()
for tool in sudo firewall-cmd wg-quick wg ip systemctl sysctl awk grep install curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done
if ! command -v dig >/dev/null 2>&1 && ! command -v resolvectl >/dev/null 2>&1; then
    missing+=("dig-or-resolvectl")
fi
if (( ${#missing[@]} > 0 )); then
    printf "missing VM tools: %s\n" "${missing[*]}" >&2
    exit 1
fi
'

    remote_check "passwordless sudo works" "sudo -n true"
    remote_check "required VM tools are present" "$required_tool_check"
    remote_check "firewalld is active" "systemctl is-active --quiet firewalld.service"
    remote_check "NetworkManager is active" "systemctl is-active --quiet NetworkManager.service"
    remote_check "WireGuard config exists at $VM_WG_CONF" "sudo -n test -f $(shell_quote "$VM_WG_CONF")"
    remote_check "WireGuard config contains full-tunnel AllowedIPs" "sudo -n grep -Eiq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0[.]0[.]0[.]0/0' $(shell_quote "$VM_WG_CONF")"
}

capture_pre_setup_public_ip() {
    log_section "Pre-setup diagnostics"

    local ip_output
    ip_output="$(remote_capture "timeout 20 curl -4fsS $(shell_quote "$PUBLIC_IP_URL") || true" | normalize_one_line)"

    printf '%s\n' "${ip_output:-unavailable}" > "$ARTIFACT_DIR/pre-setup-public-ip.txt"
    log_info "VM public IP before setup: ${ip_output:-unavailable}"
}

create_remote_workdir() {
    REMOTE_WORKDIR="$(remote_capture 'mktemp -d /tmp/paranoid-vpn-itest.XXXXXX')"
    cleanup_add 'cleanup_remote_workdir'
    log_info "Remote workdir: $REMOTE_WORKDIR"
}

cleanup_remote_workdir() {
    if [ -n "${REMOTE_WORKDIR:-}" ]; then
        remote_run "rm -rf $(shell_quote "$REMOTE_WORKDIR")" >/dev/null 2>&1 || true
    fi
}

copy_project_to_vm() {
    log_section "Copy project files"

    local file
    for file in paranoid-vpn.sh wg-watchdog.sh README.md; do
        remote_scp_to "$REPO_ROOT/$file" "$REMOTE_WORKDIR"
    done

    remote_check "remote scripts are executable" "chmod 755 $(shell_quote "$REMOTE_WORKDIR")/paranoid-vpn.sh $(shell_quote "$REMOTE_WORKDIR")/wg-watchdog.sh"
}

run_setup() {
    log_section "Run paranoid VPN setup"

    local allow_ssh_arg=""
    if [ "$TEST_ALLOW_SSH" = "1" ]; then
        allow_ssh_arg=" --allow-ssh"
    fi

    remote_check "setup completed on VM" "cd $(shell_quote "$REMOTE_WORKDIR") && sudo -n ./paranoid-vpn.sh --wg-conf $(shell_quote "$VM_WG_CONF")$allow_ssh_arg"
}

verify_observability() {
    log_section "Observability checks"

    remote_check "wg0 is visible to WireGuard" "sudo -n wg show wg0 >/dev/null"
    remote_check "default route points to wg0" "ip route show default | grep -Eq '(^|[[:space:]])dev[[:space:]]+wg0($|[[:space:]])'"
    remote_check "no physical IPv4 default route remains" "ip -4 route show default | awk 'BEGIN { ok=1 } !/(^|[[:space:]])dev[[:space:]]+wg0($|[[:space:]])/ { ok=0 } END { exit(ok ? 0 : 1) }'"
    remote_check "WireGuard latest handshake is non-zero" "sudo -n wg show wg0 latest-handshakes | awk '{ if (\$2 > 0) found=1 } END { exit(found ? 0 : 1) }'"
    remote_check "IPv6 is disabled globally" 'test "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = "1"'
    remote_check "IPv6 is disabled by default" 'test "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" = "1"'
    remote_check "IPv6 is disabled on loopback" 'test "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" = "1"'

    local post_ip
    if ! post_ip="$(remote_capture "timeout 30 curl -4fsS $(shell_quote "$PUBLIC_IP_URL")" | normalize_one_line)"; then
        fail "public IP lookup failed after setup"
    fi
    printf '%s\n' "$post_ip" > "$ARTIFACT_DIR/post-setup-public-ip.txt"
    if [ "$VPN_EXPECTED_EXIT_IP" = "auto" ]; then
        log_warn "VPN_EXPECTED_EXIT_IP=auto; learned VPN exit IP is $post_ip"
        log_pass "public IP lookup through VPN returned $post_ip"
    else
        assert_eq "public IP matches expected VPN exit" "$VPN_EXPECTED_EXIT_IP" "$post_ip"
    fi

    local dns_output
    local dns_command
    dns_command='
if command -v dig >/dev/null 2>&1; then
    timeout 20 dig +time=5 +tries=1 +short example.com
else
    timeout 20 resolvectl query example.com
fi
'
    if ! dns_output="$(remote_capture "$dns_command")"; then
        fail "DNS lookup failed after setup"
    fi
    printf '%s\n' "$dns_output" > "$ARTIFACT_DIR/post-setup-dns.txt"
    if [ -z "$(printf '%s\n' "$dns_output" | sed '/^[[:space:]]*$/d')" ]; then
        fail "DNS lookup after setup returned no records"
    fi
    log_pass "DNS lookup works after setup"

    verify_firewall
}

verify_firewall() {
    log_section "Firewall checks"

    remote_check "wireguard-only zone exists" '
for zone in $(sudo -n firewall-cmd --get-zones); do
    if [ "$zone" = "wireguard-only" ]; then
        exit 0
    fi
done
exit 1
'

    local target
    target="$(remote_capture "sudo -n firewall-cmd --permanent --zone=wireguard-only --get-target" | normalize_one_line)"
    assert_eq "wireguard-only target is DROP" "DROP" "$target"

    remote_check "wireguard-only zone includes wg0" "sudo -n firewall-cmd --zone=wireguard-only --list-interfaces | grep -Eq '(^|[[:space:]])wg0($|[[:space:]])'"

    local ports
    ports="$(remote_capture "sudo -n firewall-cmd --zone=wireguard-only --list-ports")"
    printf '%s\n' "$ports" > "$ARTIFACT_DIR/firewall-ports.txt"
    assert_contains "firewall has WireGuard UDP port entry" "$ports" "51820/udp"
    assert_not_contains "firewall does not expose DNS over UDP" "$ports" "53/udp"
    assert_not_contains "firewall does not expose DNS over TCP" "$ports" "53/tcp"

    local services
    services="$(remote_capture "sudo -n firewall-cmd --zone=wireguard-only --list-services")"
    printf '%s\n' "$services" > "$ARTIFACT_DIR/firewall-services.txt"
    assert_not_contains "firewall does not expose DNS service" "$services" "dns"
    if [ "$TEST_ALLOW_SSH" = "1" ]; then
        assert_contains "firewall exposes SSH in debug mode" "$services" "ssh"
    else
        assert_not_contains "firewall does not expose SSH in paranoid mode" "$services" "ssh"
    fi
}

run_nmap_scan() {
    local label="$1"
    local output_file="$ARTIFACT_DIR/nmap-${label}.txt"

    if [ "$SKIP_NMAP" = "1" ]; then
        log_section "Host-side nmap scan: $label"
        log_warn "SKIP_NMAP=1; skipping host-side nmap scan for $label"
        printf 'skipped: SKIP_NMAP=1\n' > "$output_file"
        return 0
    fi

    log_section "Host-side nmap scan: $label"

    if ! timeout "$NMAP_TIMEOUT" nmap -Pn -p "$NMAP_PORTS" "$VM_HOST" | tee "$output_file"; then
        fail "nmap scan failed for $label"
    fi

    assert_nmap_no_open_tcp "$label" "$output_file"
}

assert_nmap_no_open_tcp() {
    local label="$1"
    local output_file="$2"
    local open_lines

    open_lines="$(awk '$1 ~ /^[0-9]+\/tcp$/ && $2 == "open" { print }' "$output_file")"
    if [ -n "$open_lines" ]; then
        printf '%s\n' "$open_lines" >&2
        fail "nmap found open TCP ports during $label"
    fi

    log_pass "nmap found no open TCP ports during $label"
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

verify_outbound_blocked_after_down() {
    local output
    local status

    set +e
    output="$(remote_capture "timeout 15 curl -4fsS $(shell_quote "$PUBLIC_IP_URL")" 2>&1)"
    status=$?
    set -e

    printf '%s\n' "$output" > "$ARTIFACT_DIR/post-down-curl.txt"

    if (( status == 0 )); then
        fail "outbound curl unexpectedly succeeded after tunnel down"
    fi

    if (( status == 255 )); then
        fail "SSH control channel was lost while checking outbound block"
    fi

    log_pass "outbound curl fails after tunnel down"
}

run_tunnel_down_final_test() {
    log_section "Final destructive tunnel-down test"
    log_warn "bringing wg0 down on the disposable VM; this may cut network access"

    remote_check "wg-quick down wg0 completed" "sudo -n wg-quick down wg0"
    retry_until "watchdog removed any physical default route" "$WATCHDOG_ATTEMPTS" "$WATCHDOG_DELAY" default_route_has_no_physical_escape
    verify_outbound_blocked_after_down
    collect_remote_artifacts "post-down" || true
    run_nmap_scan "post-down"
}

restore_vm_after_test() {
    log_section "Restore VM after destructive test"

    remote_check "VM restore completed" "sudo -n /opt/paranoid-vpn/paranoid-vpn.sh --restore"
}

collect_remote_artifacts() {
    local label="$1"

    if [ -z "${ARTIFACT_DIR:-}" ] || [ -z "${REMOTE_TARGET:-}" ]; then
        return 0
    fi

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
    collect_remote_artifact "$output_dir/wg-quick-journal.txt" "sudo -n journalctl -u wg-quick@wg0.service -n 300 --no-pager || true"
}

collect_remote_artifact() {
    local output_file="$1"
    local command="$2"

    if ! remote_capture "$command" > "$output_file" 2>&1; then
        log_warn "could not collect $(basename "$output_file")"
    fi
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    trap on_exit EXIT

    preflight_local
    remote_init "$LOCAL_TMP"
    cleanup_add 'remote_stop_master'

    log_section "Open SSH control channel"
    remote_start_master
    log_pass "SSH ControlMaster is established"

    preflight_vm
    capture_pre_setup_public_ip
    create_remote_workdir
    copy_project_to_vm
    run_setup
    verify_observability
    collect_remote_artifacts "post-setup"
    run_nmap_scan "post-setup"
    run_tunnel_down_final_test
    if [ "$RESTORE_AFTER_TEST" = "1" ]; then
        restore_vm_after_test
    fi

    log_section "Suite complete"
    log_pass "VM integration suite passed"
}

main "$@"
