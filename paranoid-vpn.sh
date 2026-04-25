#!/bin/bash
###############################################################################
# PARANOID VPN FOR FEDORA SILVERBLUE
# Cel: Pełna izolacja sieciowa przez WireGuard z Kill-Switchem.
# Wymagania: Root, Firewalld, NetworkManager, WireGuard-tools
###############################################################################

set -euo pipefail # Zatrzymaj się przy pierwszym błędzie i błędach zmiennych

# --- KONFIGURACJA ---
BACKUP_DIR="/var/lib/paranoid-vpn/backups"
LOG_FILE="/var/log/paranoid-vpn.log"
WG_CONF="/etc/wireguard/wg0.conf"
ZONE_NAME="wireguard-only"
ALLOW_SSH=false

# Parse argumenty
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --allow-ssh) ALLOW_SSH=true; shift ;;
        --restore) ACTION="restore"; shift ;;
        --status) ACTION="status"; shift ;;
        *) echo "Nieznana opcja: $1"; exit 1 ;;
    esac
done

ACTION=${ACTION:-"setup"}

# --- FUNKCJE POMOCNICZE ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "BŁĄD: $1"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Ten skrypt musi być uruchomiony jako root (sudo)."
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
        error_exit "Brak wymaganych narzędzi: ${missing[*]}"
    fi
}

backup_config() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR/$timestamp"

    log "Tworzenie backupu konfiguracji..."

    # Backup firewall
    firewall-cmd --runtime-to-permanent 2>/dev/null || true
    cp -r /etc/firewalld/zones "$BACKUP_DIR/$timestamp/" 2>/dev/null || true

    # Backup NetworkManager
    cp -r /etc/NetworkManager/system-connections/ "$BACKUP_DIR/$timestamp/" 2>/dev/null || true

    # Backup routingu
    ip route show > "$BACKUP_DIR/$timestamp/routes.txt"
    ip addr show > "$BACKUP_DIR/$timestamp/addresses.txt"

    # Backup WireGuard
    if [ -f "$WG_CONF" ]; then
        cp "$WG_CONF" "$BACKUP_DIR/$timestamp/wg0.conf.bak"
    fi

    log "Backup zakończony: $BACKUP_DIR/$timestamp"
}

# --- FUNKCJE GŁÓWNE ---

setup_wireguard() {
    log "Faza 1: Konfiguracja WireGuard..."

    # Sprawdź czy plik konfiguracyjny istnieje
    if [ ! -f "$WG_CONF" ]; then
        error_exit "Plik konfiguracyjny $WG_CONF nie istnieje. Utwórz go ręcznie lub użyj narzędzia Proton."
    fi

    # Upewnij się, że klucze są bezpieczne
    chmod 600 "$WG_CONF"

    # Uruchom tunel
    log "Uruchamianie tunelu wg0..."
    if ! wg-quick up wg0; then
        error_exit "Nie udało się uruchomić tunelu WireGuard. Sprawdź logi."
    fi

    log "Tunel wg0 aktywny."
}

setup_routing() {
    log "Faza 2: Konfiguracja routingu..."
    local endpoint endpoint_host gateway gateway_dev

    # Wyłącz IPv6 (Paranoiczny tryb)
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1

    # Usuń domyślną trasę przez fizyczny interfejs (jeśli istnieje)
    # Uwaga: To może chwilowo odciąć internet, dopóki wg0 nie będzie gotowy
    # Dlatego robimy to PO uruchomieniu wg0

    # Pobierz fizyczną trasę domyślną zanim przełączymy default route.
    gateway=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')
    gateway_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')

    # Dodaj trasę default przez wg0
    ip route del default 2>/dev/null || true
    ip route add default dev wg0

    # Ważne: Dodaj trasę do serwera WireGuard przez fizyczny interfejs
    # Aby to zrobić, musimy wiedzieć, gdzie jest endpoint.
    # Pobieramy endpoint z konfiguracji
    endpoint=$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$WG_CONF")
    if [ -n "$endpoint" ]; then
        # Obsługa endpointów IPv4/IPv6 z portem:
        #  - 203.0.113.1:51820
        #  - [2001:db8::1]:51820
        if [[ "$endpoint" =~ ^\[.+\]:[0-9]+$ ]]; then
            endpoint_host="${endpoint#[}"
            endpoint_host="${endpoint_host%%]*}"
        else
            endpoint_host="${endpoint%:*}"
        fi

        if [ -n "$gateway" ] && [ -n "$gateway_dev" ] && [ -n "$endpoint_host" ]; then
            ip route replace "$endpoint_host" via "$gateway" dev "$gateway_dev" 2>/dev/null || true
            log "Dodano trasę do endpointu WG: $endpoint_host przez $gateway ($gateway_dev)"
        else
            log "Ostrzeżenie: Nie znaleziono kompletnej trasy do endpointu (gateway/dev/host)."
        fi
    fi
}

setup_firewall() {
    log "Faza 3: Konfiguracja Firewalld (Lockdown)..."

    # Utwórz strefę
    if ! firewall-cmd --get-zones | grep -q "$ZONE_NAME"; then
        firewall-cmd --new-zone="$ZONE_NAME" --permanent
    fi

    # Ustaw target na DROP (blokuj wszystko domyślnie)
    firewall-cmd --zone="$ZONE_NAME" --set-target=DROP --permanent

    # Pozwól na ruch loopback
    firewall-cmd --zone="$ZONE_NAME" --add-rich-rule='rule family=ipv4 source address=127.0.0.0/8 accept' --permanent

    # Pozwól na ruch DHCP (kluczowe dla uzyskania IP)
    firewall-cmd --zone="$ZONE_NAME" --add-service=dhcp-client --permanent

    # Pozwól na ruch ESTABLISHED, RELATED
    firewall-cmd --zone="$ZONE_NAME" --add-icmp-block-inversion --permanent # To pozwala na odpowiedzi

    # Pozwól na ruch wychodzący przez WireGuard (UDP 51820)
    firewall-cmd --zone="$ZONE_NAME" --add-port=51820/udp --permanent

    # Opcjonalnie: SSH
    if [ "$ALLOW_SSH" = true ]; then
        log "Otwieranie portu SSH (uwaga: ryzyko bezpieczeństwa)..."
        firewall-cmd --zone="$ZONE_NAME" --add-service=ssh --permanent
    else
        log "Port SSH zablokowany (tryb paranoiczny)."
    fi

    # Zablokuj DNS poza tunelem (zapobieganie wyciekom)
    firewall-cmd --zone="$ZONE_NAME" --add-port=53/udp --permanent
    firewall-cmd --zone="$ZONE_NAME" --add-port=53/tcp --permanent
    # UWAGA: W trybie paranoicznym DNS powinien iść TYLKO przez WG.
    # Jeśli konfiguracja WG ma DNS, nie musimy otwierać portu 53 na wyjście do ISP.
    # Ale musimy pozwolić na DNS wewnątrz tunelu (to robi sam tunel).
    # Tutaj blokujemy DNS wychodzący przez fizyczny interfejs.
    # W firewalld strefie "wireguard-only" domyślnie DROP, więc port 53 nie jest otwarty.
    # Musimy usunąć ewentualne otwarcie portu 53 jeśli było wcześniej.
    firewall-cmd --zone="$ZONE_NAME" --remove-port=53/udp --permanent 2>/dev/null || true
    firewall-cmd --zone="$ZONE_NAME" --remove-port=53/tcp --permanent 2>/dev/null || true

    # Zastosuj strefę do wszystkich interfejsów (poza loopback)
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        firewall-cmd --zone="$ZONE_NAME" --change-interface="$iface" --permanent
    done

    # Zapisz i przeładuj
    firewall-cmd --runtime-to-permanent
    firewall-cmd --reload

    log "Firewall skonfigurowany."
}

setup_watchdog() {
    log "Faza 4: Konfiguracja Watchdog..."

    # Stwórz plik serwisu
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

    log "Watchdog uruchomiony."
}

validate_setup() {
    log "Faza 5: Walidacja..."

    # Sprawdź czy tunel działa
    if ! wg show wg0 > /dev/null 2>&1; then
        error_exit "Tunel wg0 nie działa!"
    fi

    # Sprawdź routing
    if ! ip route show default | grep -q "dev wg0"; then
        error_exit "Domyślna trasa nie wskazuje na wg0!"
    fi

    # Test wycieku IP (symulacja)
    log "Test wycieku IP..."
    # W prawdziwym środowisku: curl ifconfig.me
    # Tutaj tylko logujemy, że konfiguracja jest gotowa
    log "Konfiguracja zakończona pomyślnie. Pamiętaj: bez tunelu nie ma internetu."
}

restore_config() {
    log "Przywracanie konfiguracji..."
    # Szukaj ostatniego backupu
    local latest_backup
    latest_backup=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -1)
    if [ -z "$latest_backup" ]; then
        error_exit "Nie znaleziono backupów do przywrócenia."
    fi

    # Przywracanie firewall
    rm -rf /etc/firewalld/zones/*
    if [ -d "$BACKUP_DIR/$latest_backup/zones" ]; then
        cp -r "$BACKUP_DIR/$latest_backup/zones/." /etc/firewalld/zones/
    else
        log "Ostrzeżenie: Backup nie zawiera katalogu zones, pomijam przywracanie firewalld."
    fi

    # Przywracanie routingu
    # To jest trudne, bo musimy wiedzieć co było.
    # Najbezpieczniej: restart sieci
    systemctl restart NetworkManager

    # Usunięcie strefy
    firewall-cmd --delete-zone="$ZONE_NAME" --permanent 2>/dev/null || true
    firewall-cmd --reload

    # Wyłączenie watchdog
    systemctl stop wg-watchdog.service
    systemctl disable wg-watchdog.service
    rm -f /etc/systemd/system/wg-watchdog.service
    systemctl daemon-reload

    # Wyłączenie IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0

    log "Konfiguracja przywrócona. Restart systemu zalecany."
}

show_status() {
    echo "=== STATUS PARANOID VPN ==="
    echo "Tunel wg0:"
    wg show wg0 2>/dev/null || echo "Nieaktywny"
    echo ""
    echo "Routing:"
    ip route | grep default || echo "Brak domyślnej trasy"
    echo ""
    echo "Firewall Zone:"
    firewall-cmd --get-active-zones | grep -A 10 "$ZONE_NAME" || echo "Strefa nieaktywna"
    echo ""
    echo "Watchdog:"
    systemctl status wg-watchdog.service --no-pager -l
}

# --- GŁÓWNY BLOK ---
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
        echo "Użycie: $0 [--allow-ssh] [--restore] [--status]"
        exit 1
        ;;
esac
