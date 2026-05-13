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

## Recommended Test Path

If a bare-metal run fails with `wg` missing, stop there and test in a disposable
VM first. `wg` is provided by `wireguard-tools`.

### Manual ISO lab: exact distro/flavor testing

Use this when you want to test against a real installer ISO for any Linux
distribution, version, branch, or flavor instead of the automated Fedora Cloud
lab:

```bash
VM_ISO=/isos/Fedora-Workstation-Live-x86_64-44.iso TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-manual-iso-vm.sh
```

`VM_ISO` can be a local ISO path or an `https://` URL. The runner creates a
blank VM disk, boots the installer ISO, attaches a second CD labeled
`PVPNPAYLOAD`, and leaves the VM running for manual install and testing. The CD
contains the same `paranoid-vpn/` directory that
`tools/prepare-offline-usb.sh` writes to a real second pendrive, including
`offline-preflight.sh`, `install-offline-deps.sh`, `run-hardening.sh`, optional
`wg0.conf`, and `rpms/` when RPM download is enabled.

After installing the OS in the VM, mount the payload CD, copy the `paranoid-vpn`
directory to a writable location in the guest, and use it exactly like the
offline USB bundle:

```bash
cd /path/to/copied/paranoid-vpn
sudo bash ./install-offline-deps.sh
bash ./offline-preflight.sh
sudo bash ./run-hardening.sh
```

To build the CD for a specific Fedora offline target release:

```bash
TARGET_FEDORA_RELEASE=44 VM_ISO=/isos/Fedora-Workstation-Live-x86_64-44.iso TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-manual-iso-vm.sh
```

If you already have a prepared RPM cache, use it instead of downloading during
payload creation:

```bash
PAYLOAD_RPM_DIR=/path/to/rpms VM_ISO=/isos/Fedora-Workstation-Live-x86_64-44.iso TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-manual-iso-vm.sh
```

To create the CD without RPMs, set `DOWNLOAD_RPMS=0`:

```bash
DOWNLOAD_RPMS=0 VM_ISO=/isos/Fedora-Workstation-Live-x86_64-44.iso TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-manual-iso-vm.sh
```

Open the VM with:

```bash
virt-manager --connect qemu:///system
```

Useful manual-lab settings:

```bash
export VM_DISK_SIZE=80G
export VM_MEMORY_MB=8192
export VM_CPUS=4
export VM_NAME=paranoid-vpn-fedora-workstation-44
export ISO_COPY=1
```

This path is intentionally manual. It is the right choice when the automated lab
passes but the real installer or distribution flavor behaves differently.

### Automated Fedora labs

There are two dependency paths:

- The desktop and independent VM runners are online test labs. They install
  module runtime dependencies by running `tools/install-deps.sh` inside the VM.
- The offline USB flow copies that same installer as `install-offline-deps.sh`,
  which installs the bundled RPM cache from `rpms/`. That cache includes
  `wireguard-tools` and is validated to provide both `wg` and `wg-quick`.

For a Fedora desktop lab like the existing Fedora Workstation flow, run:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-desktop-vm-instrumented.sh
```

The desktop and independent VM labs default to Fedora 43. To run another Fedora
Cloud release, set `FEDORA_RELEASE`:

```bash
FEDORA_RELEASE=44 TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-desktop-vm-instrumented.sh
```

The desktop lab defaults to a smaller GNOME lab profile. To install the Fedora
Workstation desktop environment inside the VM, set `FEDORA_DESKTOP_PROFILE`:

```bash
FEDORA_DESKTOP_PROFILE=workstation FEDORA_RELEASE=44 TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-desktop-vm-instrumented.sh
```

`FEDORA_DESKTOP_PROFILE=workstation` still boots from Fedora Cloud qcow2 so the
runner can use cloud-init and SSH automation, then installs Fedora's Workstation
environment group in the guest.

If you need a specific image instead of the release-index auto-discovery, set
`FEDORA_CLOUD_IMAGE_URL` to the exact `.qcow2` URL.

To check host virtualization prerequisites without creating the VM:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-desktop-vm-instrumented.sh --preflight-only
```

The desktop runner provisions a Fedora VM, runs the module dependency installer,
installs GNOME/GDM and SPICE guest tools for the lab UI, copies the WireGuard
config to `/etc/wireguard/wg0.conf`, runs the module, performs tunnel and
firewall checks, runs a host-side `nmap` audit, and then leaves the VM open for
manual testing through `virt-manager`.

Use the offline USB smoke runner before trying the second-pendrive workflow on a
real cut-off machine:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-offline-usb-vm-smoke.sh
```

## Installation

### Offline second-pendrive bundle

For a cut-off metal install, prepare a second pendrive on an online Fedora
machine before hardening the target:

```bash
TARGET_FEDORA_RELEASE=44 WG_CONF=/secure/wg0.conf modules/paranoid-vpn/tools/prepare-offline-usb.sh /run/media/$USER/OFFLINE_USB/paranoid-vpn
```

The bundle contains the VPN scripts, optional `wg0.conf`, an RPM dependency
cache, and helper scripts:

- `offline-preflight.sh`: checks tools, services, and WireGuard config before
  hardening.
- `install-offline-deps.sh`: installs bundled RPMs from `rpms/`.
- `run-hardening.sh`: runs preflight and then applies paranoid-vpn.

Set `TARGET_FEDORA_RELEASE` to the Fedora release installed on the offline
machine. If the online host is Fedora 44 but the offline machine is Fedora 43,
use `TARGET_FEDORA_RELEASE=43`. The bundle preparation fails if the RPM cache
does not contain the package providing both `wg` and `wg-quick`.

If you do not want to copy the WireGuard config into the USB bundle, omit
`WG_CONF` and pass it later on the target:

```bash
WG_CONF=/path/on/target/wg0.conf bash ./offline-preflight.sh
WG_CONF=/path/on/target/wg0.conf sudo bash ./run-hardening.sh
```

The USB is sensitive if it contains `wg0.conf`.

On the offline target, install and verify before hardening:

```bash
cd /run/media/$USER/OFFLINE_USB/paranoid-vpn
sudo bash ./install-offline-deps.sh
bash ./offline-preflight.sh
```

### One-command setup

Clone or unpack the repository anywhere. Run the module entrypoint directly and
pass your Proton VPN WireGuard config:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --wg-conf /path/to/proton.conf
```

If you want the default no-flag command, put your untracked WireGuard config
beside the module script as `modules/paranoid-vpn/src/wg0.conf`, then run:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh
```

The script handles the preparation work:

- Copies `paranoid-vpn.sh` and `wg-watchdog.sh` into `/opt/paranoid-vpn`.
- Installs `wg0.conf` into `/etc/wireguard/wg0.conf` with mode `600`.
- Writes and enables the `wg-startup.service` boot service.
- Writes, enables, and starts the `wg-watchdog.service` kill switch.
- Creates a backup before making network changes.

Important: in the `[Peer]` section, make sure `AllowedIPs = 0.0.0.0/0, ::/0` is set.

If your WireGuard config is somewhere else, pass it explicitly:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --wg-conf /path/to/proton.conf
```

## Usage

### Default mode: full SSH lockdown

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh
```

After startup:

- The WireGuard tunnel is started.
- All ports are blocked except UDP 51820.
- If the tunnel drops, internet access is cut off.
- SSH access is blocked unless you use `--allow-ssh`.

### SSH access mode: recommended for servers

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --allow-ssh
```

This opens port 22 for SSH traffic according to the firewall configuration.
The boot service will keep this setting when it is installed by that run.

### Check status

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --status
```

### Restore configuration after a failure

If you lose system access or want to roll back the changes:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --restore
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
- Run `sudo modules/paranoid-vpn/src/paranoid-vpn.sh --restore` and try again.

### Problem: "I lost SSH access"

Cause: port 22 was blocked.

Fix:

- Log in to the machine locally.
- Run `sudo modules/paranoid-vpn/src/paranoid-vpn.sh --allow-ssh`.
- Or restore the configuration with `sudo modules/paranoid-vpn/src/paranoid-vpn.sh --restore`.

### Problem: "The script does not work after a system update"

Cause: an rpm-ostree update may have overwritten the system layer.

Fix:

- Make sure files in `/opt/paranoid-vpn/` and `/etc/wireguard/` are in the user-managed layer.
- Run the script again with `sudo modules/paranoid-vpn/src/paranoid-vpn.sh`.
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
