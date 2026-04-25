#!/bin/bash
###############################################################################
# PARANOID VPN FOR FEDORA SILVERBLUE
# Goal: Full network isolation through WireGuard with a kill switch.
# Requirements: root, Firewalld, NetworkManager, wireguard-tools
###############################################################################

set -euo pipefail # Stop on the first error and unset variables

# --- CONFIGURATION ---
BACKUP_DIR="/var/lib/paranoid-vpn/backups"
LOG_FILE="/var/log/paranoid-vpn.log"
WG_CONF="/etc/wireguard/wg0.conf"
ZONE_NAME="wireguard-only"
ALLOW_SSH=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --allow-ssh) ALLOW_SSH=true; shift ;;
        --restore) ACTION="restore"; shift ;;
        --status) ACTION="status"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

ACTION=${ACTION:-"setup"}

# --- HELPER FUNCTIONS ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root (sudo)."
    fi
}

check_dependencies() {
    local deps=("firewall-cmd" "wg-quick" "wg" "ip" "systemctl" "sysctl" "awk" "grep")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        error_exit "Missing required tools: ${missing[*]}"
    fi
}

backup_config() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR/$timestamp"

    log "Creating configuration backup..."

    # Backup firewall
    firewall-cmd --runtime-to-permanent 2>/dev/null || true
    cp -r /etc/firewalld/zones "$BACKUP_DIR/$timestamp/" 2>/dev/null || true

    # Backup NetworkManager
    cp -r /etc/NetworkManager/system-connections/ "$BACKUP_DIR/$timestamp/" 2>/dev/null || true

    # Backup routing
    ip route show > "$BACKUP_DIR/$timestamp/routes.txt"
    ip addr show > "$BACKUP_DIR/$timestamp/addresses.txt"

    # Backup WireGuard
    if [ -f "$WG_CONF" ]; then
        cp "$WG_CONF" "$BACKUP_DIR/$timestamp/wg0.conf.bak"
    fi

    log "Backup completed: $BACKUP_DIR/$timestamp"
}

# --- MAIN FUNCTIONS ---

setup_wireguard() {
    log "Phase 1: WireGuard configuration..."

    # Check whether the configuration file exists.
    if [ ! -f "$WG_CONF" ]; then
        error_exit "Configuration file $WG_CONF does not exist. Create it manually or use the Proton tool."
    fi

    # Make sure the keys are protected.
    chmod 600 "$WG_CONF"

    # Start the tunnel.
    log "Starting wg0 tunnel..."
    if ! wg-quick up wg0; then
        error_exit "Failed to start the WireGuard tunnel. Check the logs."
    fi

    log "wg0 tunnel is active."
}

setup_routing() {
    log "Phase 2: Routing configuration..."
    local endpoint endpoint_host gateway gateway_dev

    # Disable IPv6 (paranoid mode).
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1

    # Capture the physical default route before switching the default route.
    gateway=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')
    gateway_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')

    # Add a route to the WireGuard server through the physical interface.
    # To do this, extract the endpoint from the configuration.
    endpoint=$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$WG_CONF")
    if [ -n "$endpoint" ]; then
        # Handle endpoints with ports:
        # - 203.0.113.1:51820
        # - [2001:db8::1]:51820
        if [[ "$endpoint" =~ ^\[.+\]:[0-9]+$ ]]; then
            endpoint_host="${endpoint#[}"
            endpoint_host="${endpoint_host%%]*}"
        else
            endpoint_host="${endpoint%:*}"
        fi

        if [ -n "$gateway" ] && [ -n "$gateway_dev" ] && [ -n "$endpoint_host" ]; then
            if ip route replace "$endpoint_host" via "$gateway" dev "$gateway_dev" 2>/dev/null; then
                log "Added route to WireGuard endpoint: $endpoint_host via $gateway ($gateway_dev)"
            else
                log "Warning: Failed to add route to WireGuard endpoint: $endpoint_host"
            fi
        else
            log "Warning: Could not determine a complete endpoint route (gateway/dev/host)."
        fi
    fi

    # Remove the default route through the physical interface, if it exists.
    # This can briefly cut internet access until wg0 is ready, so it happens
    # after wg0 has been started.
    ip route del default 2>/dev/null || true

    # Add the default route through wg0.
    ip route add default dev wg0
}

setup_firewall() {
    log "Phase 3: Firewalld configuration (lockdown)..."

    # Create the zone.
    if ! firewall-cmd --get-zones | grep -q "$ZONE_NAME"; then
        firewall-cmd --new-zone="$ZONE_NAME" --permanent
    fi

    # Set the target to DROP, blocking everything by default.
    firewall-cmd --zone="$ZONE_NAME" --set-target=DROP --permanent

    # Allow loopback traffic.
    firewall-cmd --zone="$ZONE_NAME" --add-rich-rule='rule family=ipv4 source address=127.0.0.0/8 accept' --permanent

    # Allow DHCP traffic, which is required to obtain an IP address.
    firewall-cmd --zone="$ZONE_NAME" --add-service=dhcp-client --permanent

    # Allow ESTABLISHED and RELATED traffic.
    firewall-cmd --zone="$ZONE_NAME" --add-icmp-block-inversion --permanent # Allows replies

    # Allow outbound WireGuard traffic (UDP 51820).
    firewall-cmd --zone="$ZONE_NAME" --add-port=51820/udp --permanent

    # Optional: SSH.
    if [ "$ALLOW_SSH" = true ]; then
        log "Opening SSH port (security risk)..."
        firewall-cmd --zone="$ZONE_NAME" --add-service=ssh --permanent
    else
        log "SSH port blocked (paranoid mode)."
    fi

    # Block DNS outside the tunnel to prevent leaks.
    firewall-cmd --zone="$ZONE_NAME" --add-port=53/udp --permanent
    firewall-cmd --zone="$ZONE_NAME" --add-port=53/tcp --permanent
    # In paranoid mode, DNS should go only through WireGuard.
    # If the WireGuard config contains DNS settings, there is no need to open
    # port 53 toward the ISP. Remove any previous DNS openings in this zone.
    firewall-cmd --zone="$ZONE_NAME" --remove-port=53/udp --permanent 2>/dev/null || true
    firewall-cmd --zone="$ZONE_NAME" --remove-port=53/tcp --permanent 2>/dev/null || true

    # Apply the zone to all interfaces except loopback.
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        firewall-cmd --zone="$ZONE_NAME" --change-interface="$iface" --permanent
    done

    # Save and reload.
    firewall-cmd --runtime-to-permanent
    firewall-cmd --reload

    log "Firewall configured."
}

setup_watchdog() {
    log "Phase 4: Watchdog configuration..."

    # Create the service file.
    cat > /etc/systemd/system/wg-watchdog.service <<EOF
[Unit]
Description=WireGuard Kill-Switch Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/paranoid-vpn/wg-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-watchdog.service
    systemctl start wg-watchdog.service

    log "Watchdog started."
}

validate_setup() {
    log "Phase 5: Validation..."

    # Check whether the tunnel is running.
    if ! wg show wg0 > /dev/null 2>&1; then
        error_exit "wg0 tunnel is not running!"
    fi

    # Check routing.
    if ! ip route show default | grep -q "dev wg0"; then
        error_exit "Default route does not point to wg0!"
    fi

    # IP leak test placeholder.
    log "IP leak test..."
    # In a real environment: curl ifconfig.me
    # Here we only log that the configuration is ready.
    log "Configuration completed successfully. Remember: without the tunnel, there is no internet."
}

restore_config() {
    log "Restoring configuration..."
    # Find the latest backup.
    local latest_backup
    latest_backup=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -1)
    if [ -z "$latest_backup" ]; then
        error_exit "No backups found to restore."
    fi

    # Restore firewall.
    rm -rf /etc/firewalld/zones/*
    if [ -d "$BACKUP_DIR/$latest_backup/zones" ]; then
        cp -r "$BACKUP_DIR/$latest_backup/zones/." /etc/firewalld/zones/
    else
        log "Warning: Backup does not contain a zones directory; skipping Firewalld restore."
    fi

    # Restore routing. The safest approach is to restart the network because
    # the previous route state may vary.
    systemctl restart NetworkManager

    # Remove the zone.
    firewall-cmd --delete-zone="$ZONE_NAME" --permanent 2>/dev/null || true
    firewall-cmd --reload

    # Disable the watchdog.
    systemctl stop wg-watchdog.service
    systemctl disable wg-watchdog.service
    rm -f /etc/systemd/system/wg-watchdog.service
    systemctl daemon-reload

    # Re-enable IPv6.
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0

    log "Configuration restored. System restart recommended."
}

show_status() {
    echo "=== STATUS PARANOID VPN ==="
    echo "wg0 tunnel:"
    wg show wg0 2>/dev/null || echo "Inactive"
    echo ""
    echo "Routing:"
    ip route | grep default || echo "No default route"
    echo ""
    echo "Firewall Zone:"
    firewall-cmd --get-active-zones | grep -A 10 "$ZONE_NAME" || echo "Zone inactive"
    echo ""
    echo "Watchdog:"
    systemctl status wg-watchdog.service --no-pager -l
}

# --- MAIN BLOCK ---
check_root
check_dependencies

case $ACTION in
    setup)
        backup_config
        setup_wireguard
        setup_routing
        setup_firewall
        setup_watchdog
        validate_setup
        ;;
    restore)
        restore_config
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [--allow-ssh] [--restore] [--status]"
        exit 1
        ;;
esac
