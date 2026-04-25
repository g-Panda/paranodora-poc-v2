# Paranoid VPN Module

Automatic, paranoid network configuration for Fedora Silverblue.

Goal: full network isolation through a WireGuard tunnel (Proton VPN) with an automatic kill switch. No traffic should leave your computer outside the encrypted tunnel.

> WARNING: This script blocks all network traffic when the WireGuard tunnel is not active. You can lose internet access and remote SSH access if it is not configured correctly. Use it with care.

## Features

- Full isolation: blocks all ports outside the WireGuard tunnel.
- Kill switch: automatically cuts off internet access if the tunnel drops.
- DNS leak protection: forces DNS to go through the tunnel only.
- IPv6 disabled: fully disables IPv6 to eliminate leaks.
- Automatic backup: creates a configuration backup before every change.
- Silverblue ready: designed for an immutable system.
- Watchdog: a systemd process monitors the tunnel state 24/7.

## Requirements

- System: Fedora Silverblue, or a similar immutable system using rpm-ostree.
- Privileges: root access through `sudo`.
- Dependencies:
  - `wireguard-tools`
  - `firewalld`
  - `NetworkManager`
- Proton VPN configuration: a WireGuard `.conf` file.

## Installation

### One-command setup

Clone or unpack the repository anywhere. The compatibility wrapper can still be
used from the repository root. Put your Proton VPN WireGuard config beside the
wrapper as `wg0.conf`, then run:

```bash
sudo ./paranoid-vpn.sh
```

The canonical module entrypoint also works directly:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --wg-conf /path/to/proton.conf
```

The script handles the preparation work:

- Copies `paranoid-vpn.sh` and `wg-watchdog.sh` into `/opt/paranoid-vpn`.
- Installs `wg0.conf` into `/etc/wireguard/wg0.conf` with mode `600`.
- Writes and enables the `wg-startup.service` boot service.
- Writes, enables, and starts the `wg-watchdog.service` kill switch.
- Creates a backup before making network changes.

Important: in the `[Peer]` section, make sure `AllowedIPs = 0.0.0.0/0, ::/0` is set.

If your WireGuard config is somewhere else, pass it explicitly from either
entrypoint:

```bash
sudo ./paranoid-vpn.sh --wg-conf /path/to/proton.conf
```

## Usage

### Default mode: full SSH lockdown

```bash
sudo ./paranoid-vpn.sh
```

After startup:

- The WireGuard tunnel is started.
- All ports are blocked except UDP 51820.
- If the tunnel drops, internet access is cut off.
- SSH access is blocked unless you use `--allow-ssh`.

### SSH access mode: recommended for servers

```bash
sudo ./paranoid-vpn.sh --allow-ssh
```

This opens port 22 for SSH traffic according to the firewall configuration.
The boot service will keep this setting when it is installed by that run.

### Check status

```bash
sudo ./paranoid-vpn.sh --status
```

### Restore configuration after a failure

If you lose system access or want to roll back the changes:

```bash
sudo ./paranoid-vpn.sh --restore
sudo reboot
```

This command restores the firewall and routing backup from the latest checkpoint
and removes the installed systemd services.

## Diagnostics

### Logs

Main logs are available at:

- `/var/log/paranoid-vpn.log`
- `journalctl -u wg-watchdog.service -f` for watchdog monitoring
- `journalctl -u wg-quick@wg0.service -f` for tunnel status

### IP leak test

```bash
curl ifconfig.me
# Should return the Proton server IP, not your local/public ISP IP.
```

### DNS leak test

```bash
dig example.com
# Check whether the answer came from the Proton DNS server.
```

### Routing check

```bash
ip route show
# The default route must point to dev wg0.
```

### Firewall check

```bash
firewall-cmd --list-all --zone=wireguard-only
```

## Troubleshooting

### Problem: "I have no internet after running the script"

Cause: the WireGuard tunnel did not connect.

Fix:

- Check logs with `journalctl -u wg-quick@wg0 -f`.
- Check whether the configuration file is valid.
- Run `sudo ./paranoid-vpn.sh --restore` and try again.

### Problem: "I lost SSH access"

Cause: port 22 was blocked.

Fix:

- Log in to the machine locally.
- Run `sudo ./paranoid-vpn.sh --allow-ssh`.
- Or restore the configuration with `sudo ./paranoid-vpn.sh --restore`.

### Problem: "The script does not work after a system update"

Cause: an rpm-ostree update may have overwritten the system layer.

Fix:

- Make sure files in `/opt/paranoid-vpn/` and `/etc/wireguard/` are in the user-managed layer.
- Run the script again with `sudo ./paranoid-vpn.sh`.
- If that does not help, restart the system.

### Problem: "IPv6 does not work"

Cause: the script blocks IPv6 by default.

Fix: edit `modules/paranoid-vpn/src/paranoid-vpn.sh` and remove these lines:

```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

This is not recommended for paranoid mode.

## Architecture

- Phase 0: configuration backup.
- Phase 1: start the WireGuard tunnel.
- Phase 2: change routing so the default route goes through `wg0`.
- Phase 3: configure Firewalld with the `wireguard-only` zone and DROP target.
- Phase 4: start the watchdog kill switch.
- Phase 5: validate and test.

## Module Layout

- `src/`: setup script, watchdog script, and systemd unit template.
- `test/`: VM integration runners, shared test helpers, ignored artifacts, and
  VM image cache.

## License and Liability

This script is provided "as is". The author is not responsible for data loss, internet outages, or any other damage caused by its use. Use it at your own risk.

## Contributing

If you find a bug or want to add a feature, open an issue or pull request.
