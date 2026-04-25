#!/bin/bash
###############################################################################
# WG-WATCHDOG: Kill-Switch dla WireGuard
# Działa w pętli, sprawdzając stan tunelu co 5 sekund.
###############################################################################

set -euo pipefail

ZONE_NAME="wireguard-only"
LOG_FILE="/var/log/paranoid-vpn.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $1" >> "$LOG_FILE"
}

check_tunnel() {
    # Sprawdź czy interfejs istnieje i jest UP
    if ! ip link show wg0 | grep -q "state UP"; then
        return 1
    fi

    # Sprawdź czy są aktywne ręce (handshakes)
    if ! wg show wg0 latest-handshakes | awk '{if ($2 > 0) found=1} END{exit(found?0:1)}'; then
        # Sprawdź czy jest jakieś połączenie w ciągu ostatnich 30 sekund
        # (uproszczenie: jeśli handshakes jest 0, to nie ma połączenia)
        return 1
    fi

    return 0
}

trigger_killswitch() {
    log "KILL-SWITCH AKTYWOWANY! Tunel nieaktywny. Blokada sieci."

    # Zablokuj wszystko (target DROP jest już domyślny, ale upewnijmy się)
    firewall-cmd --zone="$ZONE_NAME" --set-target=DROP --permanent
    firewall-cmd --reload

    # Usuń domyślną trasę, aby nic nie wyszło
    ip route del default 2>/dev/null || true

    # Wyślij powiadomienie (opcjonalnie)
    # notify-send "Paranoid VPN" "Tunel spadł! Brak dostępu do internetu."
}

restore_network() {
    log "Tunel przywrócony. Przywracanie sieci."

    # Przywróć domyślną trasę
    ip route add default dev wg0 2>/dev/null || true

    # Upewnij się, że firewall pozwala na ruch (target DROP z wyjątkami)
    # W naszej konfiguracji target to DROP, ale mamy wyjątki w strefie.
    # Nie musimy nic zmieniać w firewallu, tylko upewnić się, że trasa jest OK.
}

# Główna pętla
while true; do
    if check_tunnel; then
        # Tunel działa
        # Sprawdzamy czy nie jesteśmy w trybie kill-switch (np. czy trasa default istnieje)
        if ! ip route | grep -q "default.*wg0"; then
            restore_network
        fi
    else
        # Tunel nie działa
        trigger_killswitch
    fi

    sleep 5
done
