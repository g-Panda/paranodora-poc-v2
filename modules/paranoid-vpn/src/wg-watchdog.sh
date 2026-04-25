#!/bin/bash
###############################################################################
# WG-WATCHDOG: WireGuard kill switch
# Runs in a loop and checks the tunnel state every 5 seconds.
###############################################################################

set -euo pipefail

ZONE_NAME="${PARANOID_VPN_ZONE_NAME:-wireguard-only}"
LOG_FILE="${PARANOID_VPN_LOG_FILE:-/var/log/paranoid-vpn.log}"
WATCHDOG_INTERVAL_SECONDS="${PARANOID_VPN_WATCHDOG_INTERVAL_SECONDS:-5}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $1" >> "$LOG_FILE"
}

check_tunnel() {
    # WireGuard interfaces commonly report state UNKNOWN, so existence plus a
    # recent handshake is a better health signal than link state text.
    if ! ip link show wg0 >/dev/null 2>&1; then
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

    # Remove all IPv4 default routes so nothing can leave.
    while ip -4 route show default | grep -q .; do
        ip -4 route del default 2>/dev/null || break
    done

    # Send a notification (optional).
    # notify-send "Paranoid VPN" "Tunnel dropped! No internet access."
}

enforce_tunnel_route() {
    local default_routes

    default_routes="$(ip -4 route show default || true)"
    if [ -z "$default_routes" ]; then
        log "Tunnel active. Restoring wg0 default route."
        ip -4 route add default dev wg0 2>/dev/null || true
        return
    fi

    if printf '%s\n' "$default_routes" | grep -Evq '(^|[[:space:]])dev[[:space:]]+wg0($|[[:space:]])'; then
        log "Tunnel active. Removing non-wg0 default routes."
        while ip -4 route show default | grep -q .; do
            ip -4 route del default 2>/dev/null || break
        done
        ip -4 route add default dev wg0 2>/dev/null || true
    fi
}

run_once() {
    if check_tunnel; then
        enforce_tunnel_route
    else
        # The tunnel is down.
        trigger_killswitch
    fi
}

main() {
    while true; do
        run_once
        sleep "$WATCHDOG_INTERVAL_SECONDS"
    done
}

if [ "${PARANOID_VPN_WATCHDOG_SOURCE_ONLY:-0}" != "1" ]; then
    main
fi
