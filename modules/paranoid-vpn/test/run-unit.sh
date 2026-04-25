#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="$(cd -- "$MODULE_DIR/../.." && pwd -P)"
VPN_SCRIPT="$MODULE_DIR/src/paranoid-vpn.sh"
WATCHDOG_SCRIPT="$MODULE_DIR/src/wg-watchdog.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/paranoid-vpn-unit.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    local path="$1"
    [ -f "$path" ] || die "expected file to exist: $path"
}

assert_executable() {
    local path="$1"
    [ -x "$path" ] || die "expected file to be executable: $path"
}

assert_contains() {
    local path="$1"
    local needle="$2"

    grep -Fq -- "$needle" "$path" || die "expected $path to contain: $needle"
}

assert_not_contains() {
    local path="$1"
    local needle="$2"

    if grep -Fq -- "$needle" "$path"; then
        die "expected $path not to contain: $needle"
    fi
}

assert_mode() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(stat -c '%a' "$path")"
    [ "$actual" = "$expected" ] || die "expected $path mode $expected, got $actual"
}

run_test() {
    local name="$1"
    local output

    printf 'test: %s ... ' "$name"
    if output="$("$name" 2>&1)"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'ok\n'
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAILED\n'
        printf '%s\n' "$output"
    fi
}

make_case_dir() {
    local name="$1"
    local case_dir="$TEST_ROOT/$name"

    mkdir -p "$case_dir"
    printf '%s\n' "$case_dir"
}

write_fixture_wg_conf() {
    local path="$1"

    cat > "$path" <<'EOF'
[Interface]
PrivateKey = test-private-key
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = test-public-key
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF
}

write_fake_command_bin() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/fake-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="$(basename "$0")"
state_dir="${FAKE_STATE_DIR:?FAKE_STATE_DIR is required}"
log_file="${FAKE_CMD_LOG:?FAKE_CMD_LOG is required}"

mkdir -p "$state_dir"
{
    printf '%s' "$cmd"
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
} >> "$log_file"

show_default_route() {
    if [ -f "$state_dir/wg_default" ]; then
        printf 'default dev wg0 scope link\n'
    elif [ ! -f "$state_dir/no_default" ]; then
        printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'
    fi
}

case "$cmd" in
    firewall-cmd)
        case " $* " in
            *" --get-zones "*) printf 'public trusted\n' ;;
            *" --get-services "*) printf 'ssh dhcp-client\n' ;;
            *" --get-active-zones "*) printf 'wireguard-only\n  interfaces: wg0\n' ;;
        esac
        ;;
    ip)
        if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "show" ] && [ "${4:-}" = "default" ]; then
            show_default_route
            exit 0
        fi

        if [ "${1:-}" = "route" ] && [ "${2:-}" = "show" ] && [ "${3:-}" = "default" ]; then
            show_default_route
            exit 0
        fi

        if [ "${1:-}" = "route" ] && [ "${2:-}" = "show" ]; then
            show_default_route
            printf '203.0.113.7 via 192.0.2.1 dev eth0\n'
            exit 0
        fi

        if [ "${1:-}" = "addr" ] && [ "${2:-}" = "show" ]; then
            printf '2: eth0    inet 192.0.2.20/24\n'
            printf '3: wg0     inet 10.2.0.2/32\n'
            exit 0
        fi

        if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "del" ] && [ "${4:-}" = "default" ]; then
            rm -f "$state_dir/wg_default"
            touch "$state_dir/no_default"
            exit 0
        fi

        if [ "${1:-}" = "-4" ] && [ "${2:-}" = "route" ] && [ "${3:-}" = "add" ] && [ "${4:-}" = "default" ] && [ "${5:-}" = "dev" ] && [ "${6:-}" = "wg0" ]; then
            rm -f "$state_dir/no_default"
            touch "$state_dir/wg_default"
            exit 0
        fi

        if [ "${1:-}" = "route" ] && [ "${2:-}" = "replace" ]; then
            exit 0
        fi

        if [ "${1:-}" = "-o" ] && [ "${2:-}" = "link" ] && [ "${3:-}" = "show" ]; then
            printf '1: lo: <LOOPBACK,UP> mtu 65536 state UNKNOWN mode DEFAULT group default qlen 1000\n'
            printf '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500 state UP mode DEFAULT group default qlen 1000\n'
            printf '3: wg0: <POINTOPOINT,NOARP,UP> mtu 1420 state UNKNOWN mode DEFAULT group default qlen 1000\n'
            exit 0
        fi

        if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ] && [ "${3:-}" = "wg0" ]; then
            [ "${FAKE_WG_LINK_UP:-1}" = "1" ] || exit 1
            printf '3: wg0: <POINTOPOINT,NOARP,UP> mtu 1420 state UNKNOWN mode DEFAULT group default qlen 1000\n'
            exit 0
        fi
        ;;
    nmcli)
        if [ "${1:-}" = "-t" ] && [ "${2:-}" = "-f" ] && [ "${3:-}" = "DEVICE,TYPE" ] && [ "${4:-}" = "device" ] && [ "${5:-}" = "status" ]; then
            printf 'eth0:ethernet\nwg0:wireguard\n'
        fi
        ;;
    wg)
        if [ "${1:-}" = "show" ] && [ "${2:-}" = "wg0" ] && [ "${3:-}" = "latest-handshakes" ]; then
            case "${FAKE_WG_HANDSHAKE:-up}" in
                up) printf 'peer 123456\n' ;;
                stale) printf 'peer 0\n' ;;
                empty) ;;
            esac
            exit 0
        fi

        if [ "${1:-}" = "show" ] && [ "${2:-}" = "wg0" ]; then
            [ -f "$state_dir/wg_up" ] || [ "${FAKE_WG_SHOW_UP:-0}" = "1" ] || exit 1
            printf 'interface: wg0\n'
            exit 0
        fi
        ;;
    wg-quick)
        if [ "${1:-}" = "up" ] && [ "${2:-}" = "wg0" ]; then
            touch "$state_dir/wg_up"
        elif [ "${1:-}" = "down" ] && [ "${2:-}" = "wg0" ]; then
            rm -f "$state_dir/wg_up"
        fi
        ;;
    systemctl|sysctl)
        ;;
    *)
        printf 'unexpected fake command: %s\n' "$cmd" >&2
        exit 127
        ;;
esac
EOF
    chmod 755 "$bin_dir/fake-command"

    for command_name in firewall-cmd ip nmcli wg wg-quick systemctl sysctl; do
        ln -s fake-command "$bin_dir/$command_name"
    done
}

prepare_fake_runtime() {
    local case_dir="$1"
    local fake_bin="$case_dir/bin"
    local fake_root="$case_dir/root"

    mkdir -p \
        "$fake_root/etc/firewalld/zones" \
        "$fake_root/etc/NetworkManager/system-connections" \
        "$fake_root/var/log"
    write_fake_command_bin "$fake_bin"
}

run_vpn_setup() {
    local case_dir="$1"
    shift

    PATH="$case_dir/bin:$PATH" \
        FAKE_STATE_DIR="$case_dir/state" \
        FAKE_CMD_LOG="$case_dir/commands.log" \
        PARANOID_VPN_TEST_ROOT="$case_dir/root" \
        PARANOID_VPN_ALLOW_NON_ROOT_FOR_TESTS=1 \
        bash "$VPN_SCRIPT" "$@"
}

test_help_does_not_need_root_or_dependencies() {
    local case_dir
    local output_file

    case_dir="$(make_case_dir help)"
    output_file="$case_dir/help.txt"

    env -i PATH="/usr/bin:/bin" bash "$VPN_SCRIPT" --help > "$output_file"

    assert_contains "$output_file" "Usage: sudo ./paranoid-vpn.sh [options]"
    assert_contains "$output_file" "--wg-conf PATH"
}

test_setup_installs_files_and_locks_down_firewall() {
    local case_dir
    local wg_conf
    local root
    local log

    case_dir="$(make_case_dir setup)"
    prepare_fake_runtime "$case_dir"
    wg_conf="$case_dir/wg0.conf"
    root="$case_dir/root"
    log="$case_dir/commands.log"
    write_fixture_wg_conf "$wg_conf"

    run_vpn_setup "$case_dir" --wg-conf "$wg_conf" > "$case_dir/output.txt"

    assert_file "$root/etc/wireguard/wg0.conf"
    assert_mode "$root/etc/wireguard/wg0.conf" "600"
    assert_executable "$root/opt/paranoid-vpn/paranoid-vpn.sh"
    assert_executable "$root/opt/paranoid-vpn/wg-watchdog.sh"
    assert_file "$root/etc/systemd/system/wg-startup.service"
    assert_file "$root/etc/systemd/system/wg-watchdog.service"

    assert_contains "$root/etc/systemd/system/wg-startup.service" "ExecStart=$root/opt/paranoid-vpn/paranoid-vpn.sh --wg-conf $root/etc/wireguard/wg0.conf"
    assert_not_contains "$root/etc/systemd/system/wg-startup.service" "--allow-ssh"

    assert_contains "$log" "wg-quick up wg0"
    assert_contains "$log" "ip route replace 203.0.113.7 via 192.0.2.1 dev eth0"
    assert_contains "$log" "ip -4 route add default dev wg0"
    assert_contains "$log" "firewall-cmd --zone=wireguard-only --set-target=DROP --permanent"
    assert_contains "$log" "firewall-cmd --zone=wireguard-only --change-interface=eth0 --permanent"
    assert_contains "$log" "firewall-cmd --zone=wireguard-only --change-interface=wg0 --permanent"
    assert_not_contains "$log" "firewall-cmd --zone=wireguard-only --add-service=ssh --permanent"
}

test_setup_can_keep_ssh_open_when_requested() {
    local case_dir
    local wg_conf
    local root
    local log

    case_dir="$(make_case_dir allow-ssh)"
    prepare_fake_runtime "$case_dir"
    wg_conf="$case_dir/wg0.conf"
    root="$case_dir/root"
    log="$case_dir/commands.log"
    write_fixture_wg_conf "$wg_conf"

    run_vpn_setup "$case_dir" --allow-ssh --wg-conf "$wg_conf" > "$case_dir/output.txt"

    assert_contains "$root/etc/systemd/system/wg-startup.service" "ExecStart=$root/opt/paranoid-vpn/paranoid-vpn.sh --wg-conf $root/etc/wireguard/wg0.conf --allow-ssh"
    assert_contains "$log" "firewall-cmd --zone=wireguard-only --add-service=ssh --permanent"
}

test_restore_uses_test_root_paths() {
    local case_dir
    local root

    case_dir="$(make_case_dir restore)"
    prepare_fake_runtime "$case_dir"
    root="$case_dir/root"

    mkdir -p "$root/var/lib/paranoid-vpn/backups/20250101_000000/zones"
    printf '<zone target="DROP"/>\n' > "$root/var/lib/paranoid-vpn/backups/20250101_000000/zones/wireguard-only.xml"
    mkdir -p "$root/etc/systemd/system" "$root/etc/firewalld/zones"
    printf 'stale\n' > "$root/etc/firewalld/zones/stale.xml"
    printf 'service\n' > "$root/etc/systemd/system/wg-watchdog.service"
    printf 'service\n' > "$root/etc/systemd/system/wg-startup.service"

    run_vpn_setup "$case_dir" --restore > "$case_dir/output.txt"

    assert_file "$root/etc/firewalld/zones/wireguard-only.xml"
    [ ! -f "$root/etc/firewalld/zones/stale.xml" ] || die "stale firewall zone was not removed"
    [ ! -f "$root/etc/systemd/system/wg-watchdog.service" ] || die "watchdog service was not removed"
    [ ! -f "$root/etc/systemd/system/wg-startup.service" ] || die "startup service was not removed"
    assert_contains "$case_dir/commands.log" "wg-quick down wg0"
    assert_contains "$case_dir/commands.log" "systemctl restart NetworkManager"
}

test_watchdog_accepts_active_handshake() {
    local case_dir

    case_dir="$(make_case_dir watchdog-up)"
    prepare_fake_runtime "$case_dir"

    PATH="$case_dir/bin:$PATH" \
        FAKE_STATE_DIR="$case_dir/state" \
        FAKE_CMD_LOG="$case_dir/commands.log" \
        PARANOID_VPN_LOG_FILE="$case_dir/watchdog.log" \
        PARANOID_VPN_WATCHDOG_SOURCE_ONLY=1 \
        bash -c 'source "$1"; check_tunnel; run_once' bash "$WATCHDOG_SCRIPT"

    assert_not_contains "$case_dir/commands.log" "firewall-cmd --zone=wireguard-only --set-target=DROP --permanent"
}

test_watchdog_triggers_killswitch_without_handshake() {
    local case_dir

    case_dir="$(make_case_dir watchdog-down)"
    prepare_fake_runtime "$case_dir"

    PATH="$case_dir/bin:$PATH" \
        FAKE_STATE_DIR="$case_dir/state" \
        FAKE_CMD_LOG="$case_dir/commands.log" \
        FAKE_WG_HANDSHAKE=stale \
        PARANOID_VPN_LOG_FILE="$case_dir/watchdog.log" \
        PARANOID_VPN_WATCHDOG_SOURCE_ONLY=1 \
        bash -c 'source "$1"; ! check_tunnel; run_once' bash "$WATCHDOG_SCRIPT"

    assert_contains "$case_dir/commands.log" "firewall-cmd --zone=wireguard-only --set-target=DROP --permanent"
    assert_contains "$case_dir/commands.log" "ip -4 route del default"
    assert_contains "$case_dir/watchdog.log" "KILL SWITCH ACTIVATED"
}

test_root_wrapper_prefers_root_level_wg_conf() {
    local case_dir
    local fake_module
    local output_file

    case_dir="$(make_case_dir wrapper)"
    fake_module="$case_dir/repo/modules/paranoid-vpn/src/paranoid-vpn.sh"
    output_file="$case_dir/output.txt"

    mkdir -p "$(dirname "$fake_module")"
    cp "$REPO_ROOT/paranoid-vpn.sh" "$case_dir/repo/paranoid-vpn.sh"
    printf 'fixture\n' > "$case_dir/repo/wg0.conf"
    cat > "$fake_module" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
    chmod 755 "$case_dir/repo/paranoid-vpn.sh" "$fake_module"

    (cd "$case_dir/repo" && bash ./paranoid-vpn.sh --status) > "$output_file"

    assert_contains "$output_file" "--wg-conf"
    assert_contains "$output_file" "$case_dir/repo/wg0.conf"
    assert_contains "$output_file" "--status"
}

run_test test_help_does_not_need_root_or_dependencies
run_test test_setup_installs_files_and_locks_down_firewall
run_test test_setup_can_keep_ssh_open_when_requested
run_test test_restore_uses_test_root_paths
run_test test_watchdog_accepts_active_handshake
run_test test_watchdog_triggers_killswitch_without_handshake
run_test test_root_wrapper_prefers_root_level_wg_conf

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
