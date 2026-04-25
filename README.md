🛡️ Paranoid VPN for Fedora Silverblue

Automatyczna, "paranoiczna" konfiguracja sieciowa dla Fedory Silverblue.
Cel: Pełna izolacja sieciowa przez tunel WireGuard (Proton VPN) z automatycznym Kill-Switchem. Żaden bit nie opuści Twojego komputera poza szyfrowanym tunelem.

    ⚠️ OSTRZEŻENIE: Ten skrypt blokuje cały ruch sieciowy, jeśli tunel WireGuard nie jest aktywny. Może to spowodować utratę dostępu do internetu i zdalnego (SSH), jeśli nie zostanie skonfigurowany odpowiednio. Używaj z rozwagą.

📋 Cechy

    Pełna izolacja: Blokada wszystkich portów poza tunelem WireGuard.
    Kill-Switch: Automatyczne odcięcie internetu, jeśli tunel spadnie.
    DNS Leak Protection: Wymuszenie użycia DNS tylko przez tunel.
    IPv6 Disabled: Całkowite wyłączenie IPv6 (eliminacja wycieków).
    Automatyczny Backup: Przed każdą zmianą tworzy kopię zapasową konfiguracji.
    Silverblue Ready: Dostosowany do systemu niezmodyfikowalnego (immutable).
    Watchdog: Proces systemd monitorujący stan tunelu 24/7.

🏗️ Wymagania

    System: Fedora Silverblue (lub podobny immutable system z rpm-ostree).
    Uprawnienia: Root (sudo).
    Zależności:
        wireguard-tools
        firewalld
        NetworkManager
        jq (opcjonalnie, do parsowania)
    Konfiguracja Proton VPN: Plik konfiguracyjny .conf dla WireGuard.

📥 Instalacja
1. Przygotowanie katalogu

sudo mkdir -p /opt/paranoid-vpn
cd /opt/paranoid-vpn

2. Pobranie plików

Skopiuj poniższe pliki do katalogu (lub pobierz z repozytorium, jeśli takie istnieje):

    paranoid-vpn.sh
    wg-watchdog.sh
    wg-startup.service
    README.md

3. Nadanie uprawnień

sudo chmod +x paranoid-vpn.sh wg-watchdog.sh

4. Konfiguracja WireGuard

Umieść swój plik konfiguracji Proton VPN w /etc/wireguard/wg0.conf.

sudo nano /etc/wireguard/wg0.conf
# Wklej zawartość swojego pliku .conf
sudo chmod 600 /etc/wireguard/wg0.conf

    Ważne: Upewnij się, że w sekcji [Peer] masz ustawione AllowedIPs = 0.0.0.0/0, ::/0.

5. Rejestracja serwisu autostartu

sudo nano /etc/systemd/system/wg-startup.service
# Wklej zawartość pliku wg-startup.service
sudo systemctl daemon-reload
sudo systemctl enable wg-startup.service

🚀 Uruchomienie
Tryb domyślny (Pełna blokada SSH)

sudo ./paranoid-vpn.sh

Po uruchomieniu:

    Tunel WireGuard zostanie uruchomiony.
    Wszystkie porty zostaną zablokowane (poza UDP 51820).
    Jeśli tunel spadnie, internet zostanie odcięty.
    Nie będziesz mógł połączyć się przez SSH (chyba że użyjesz flagi --allow-ssh).

Tryb z dostępem SSH (Zalecane dla serwerów)

sudo ./paranoid-vpn.sh --allow-ssh

Otwiera port 22 tylko dla ruchu wychodzącego/przychodzącego przez tunel lub lokalnie (zależnie od konfiguracji).
Sprawdzenie statusu

sudo ./paranoid-vpn.sh --status

Przywracanie konfiguracji (Awaria)

Jeśli stracisz dostęp do systemu lub chcesz cofnąć zmiany:

sudo ./paranoid-vpn.sh --restore
sudo reboot

Ta komenda przywraca backup firewalla i routingu z ostatniego punktu kontrolnego.
🔧 Diagnostyka
Logi

Główne logi znajdują się w:

    /var/log/paranoid-vpn.log
    journalctl -u wg-watchdog.service -f (monitorowanie watchdog)
    journalctl -u wg-quick@wg0.service -f (stan tunelu)

Test wycieku IP

curl ifconfig.me
# Powinno zwrócić IP serwera Proton, a nie Twoje lokalne.

Test wycieku DNS

dig example.com
# Sprawdź, czy odpowiedź przyszła z DNS serwera Proton.

Sprawdzenie routingu

ip route show
# Domyślna trasa (default) musi wskazywać na dev wg0.

Sprawdzenie firewalla

firewall-cmd --list-all --zone=wireguard-only

🛑 Rozwiązywanie problemów
Problem: "Nie mam internetu po uruchomieniu skryptu"

Przyczyna: Tunel WireGuard nie połączył się. Rozwiązanie:

    Sprawdź logi: journalctl -u wg-quick@wg0 -f.
    Sprawdź, czy plik konfiguracyjny jest poprawny.
    Uruchom sudo ./paranoid-vpn.sh --restore i spróbuj ponownie.

Problem: "Utraciłem dostęp SSH"

Przyczyna: Port 22 został zablokowany. Rozwiązanie:

    Zaloguj się fizycznie do maszyny.
    Uruchom: sudo ./paranoid-vpn.sh --allow-ssh.
    Lub przywróć konfigurację: sudo ./paranoid-vpn.sh --restore.

Problem: "Skrypt nie działa po aktualizacji systemu"

Przyczyna: Aktualizacja rpm-ostree mogła nadpisać warstwę systemową. Rozwiązanie:

    Upewnij się, że pliki w /opt/paranoid-vpn/ i /etc/wireguard/ są w warstwie użytkownika (powinny być).
    Uruchom ponownie skrypt: sudo ./paranoid-vpn.sh.
    Jeśli to nie pomoże, zrestartuj system.

Problem: "IPv6 nie działa"

Przyczyna: Skrypt domyślnie blokuje IPv6. Rozwiązanie: Edytuj paranoid-vpn.sh i usuń linie:

sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

Nie zalecane dla trybu "paranoicznego".
📝 Architektura

    Phase 0: Backup konfiguracji.
    Phase 1: Uruchomienie tunelu WireGuard.
    Phase 2: Zmiana routingu (default przez wg0).
    Phase 3: Konfiguracja Firewalld (strefa wireguard-only z targetem DROP).
    Phase 4: Uruchomienie Watchdog (Kill-Switch).
    Phase 5: Walidacja i testy.

⚖️ Licencja i Odpowiedzialność

Ten skrypt jest udostępniany w stanie "jak jest" (AS IS). Autor nie ponosi odpowiedzialności za utratę danych, przerwy w dostępie do internetu lub inne szkody wynikające z jego użycia. Używaj na własną odpowiedzialność.
🤝 Wkład

Jeśli znajdziesz błąd lub chcesz dodać nową funkcję, zgłoś issue lub pull request.
