#!/bin/bash
###############################################################################
# WG-WATCHDOG: WireGuard kill switch
# Runs in a loop and checks the tunnel state every 5 seconds.
###############################################################################

set -euo pipefail

ZONE_NAME="wireguard-only"
LOG_FILE="/var/log/paranoid-vpn.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $1" >> "$LOG_FILE"
}

check_tunnel() {
    # Check whether the interface exists and is up.
    if ! ip link show wg0 | grep -q "state UP"; then
        return 1
    fi

    # Check whether any handshakes are active.
    if ! wg show wg0 latest-handshakes | awk '{if ($2 > 0) found=1} END{exit(found?0:1)}'; then
        # Simplification: if latest-handshakes is empty or 0, there is no connection.
        return 1
    fi

    return 0
}

trigger_killswitch() {
    log "KILL SWITCH ACTIVATED! Tunnel inactive. Blocking network."

    # Block everything. DROP should already be the default, but make sure.
    firewall-cmd --zone="$ZONE_NAME" --set-target=DROP --permanent
    firewall-cmd --reload

    # Remove the default route so nothing can leave.
    ip route del default 2>/dev/null || true

    # Send a notification (optional).
    # notify-send "Paranoid VPN" "Tunnel dropped! No internet access."
}

restore_network() {
    log "Tunnel restored. Restoring network."

    # Restore the default route.
    ip route add default dev wg0 2>/dev/null || true

    # The firewall target is DROP with explicit exceptions in this setup.
    # Nothing needs to change there; just make sure the route is present.
}

# Main loop.
while true; do
    if check_tunnel; then
        # The tunnel is running. Check whether the default route still exists.
        if ! ip route | grep -q "default.*wg0"; then
            restore_network
        fi
    else
        # The tunnel is down.
        trigger_killswitch
    fi

    sleep 5
done
