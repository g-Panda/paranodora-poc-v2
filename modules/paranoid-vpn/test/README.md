# VPN Tests

## CI Unit Suite

The fast CI suite validates the `paranoid-vpn` setup, restore, watchdog, and
status behavior with mocked system commands. It does not require root,
WireGuard, Firewalld, NetworkManager, libvirt, or a real VPN config.

From the repository root:

```bash
modules/paranoid-vpn/test/run-unit.sh
```

GitHub Actions runs this suite in `.github/workflows/vpn-tests.yml` on pushes,
pull requests, and manual dispatches. The workflow also runs Bash syntax checks
and ShellCheck on the CI-safe VPN scripts.

## VM Integration Tests

This directory contains the integration suite for the `paranoid-vpn` module. The
self-provisioning runner creates a disposable Fedora Cloud VM with libvirt,
copies in a local WireGuard config, runs the existing SSH-driven suite, saves a
module artifact report, and destroys the VM afterward. The lower-level runner can
still be used directly against an already-running disposable VM.

## Run: Manual ISO VM Lab

Use this runner when you want the VM to boot from the exact Linux installer ISO
you care about: any distribution, version, branch, or flavor. It does not assume
Fedora, cloud-init, SSH, or a package manager.

```bash
VM_ISO=/isos/Fedora-Workstation-Live-x86_64-44.iso TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-manual-iso-vm.sh
```

`VM_ISO` can be a local path or an `https://` URL. The runner creates a blank VM
disk, attaches the installer ISO, attaches a second payload ISO labeled
`PVPNPAYLOAD`, and leaves the VM running for manual installation and testing.
The payload ISO contains the same `paranoid-vpn/` directory that
`tools/prepare-offline-usb.sh` writes to a real second pendrive:

- `offline-preflight.sh`
- `install-offline-deps.sh`
- `run-hardening.sh`
- `paranoid-vpn.sh`
- `wg-watchdog.sh`
- `README-OFFLINE.md`
- `module-README.md`
- `rpms/` when RPM download is enabled or `PAYLOAD_RPM_DIR` is set
- optional `wg0.conf` when `TEST_WG_CONF` is set

Open the VM:

```bash
virt-manager --connect qemu:///system
```

After installing the OS, mount `PVPNPAYLOAD`, copy the `paranoid-vpn` directory
to a writable location, and use the same commands as the real offline USB flow:

```bash
cd /path/to/copied/paranoid-vpn
sudo bash ./install-offline-deps.sh
bash ./offline-preflight.sh
sudo bash ./run-hardening.sh
```

Useful settings:

```bash
export VM_DISK_SIZE=80G
export VM_MEMORY_MB=8192
export VM_CPUS=4
export VM_NAME=paranoid-vpn-my-distro
export ISO_COPY=1
export TARGET_FEDORA_RELEASE=44
export PAYLOAD_RPM_DIR=/path/to/rpms
```

## Safety model

Use a disposable VM. The final test runs:

```bash
sudo wg-quick down wg0
```

The expected result is that `wg-watchdog.service` activates the kill switch and
blocks outbound traffic. Depending on the VM networking path, this can also make
the VM unreachable until you restore, reboot, or recreate it.

The suite opens an SSH ControlMaster connection before lockdown so later remote
commands can reuse an established control channel. The intended setup is a
private or host-only VM network that survives default-route changes.

## Runner requirements

Install these tools on the machine running the tests:

- `bash`
- `curl`
- `ssh`
- `scp`
- `ssh-keygen`
- `virsh`
- `virt-install`
- `qemu-img`
- `cloud-localds` or `genisoimage` or `mkisofs`
- `nmap`
- `timeout`
- `awk`
- `sed`
- `grep`

For the independent runner, libvirt/VMM must already be installed and usable by
the current user. The runner checks this and reports missing host setup, but it
does not install host virtualization packages.

## VM requirements

The VM must already be running and reachable over SSH. It must have:

- passwordless `sudo` for `VM_USER`
- `firewalld`
- `wireguard-tools`
- `NetworkManager`
- `curl`
- `dig` or `resolvectl`
- a valid WireGuard config already present on the VM

The WireGuard config must include a full-tunnel IPv4 route, for example:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

## Environment

Required:

```bash
export VM_HOST=192.168.56.10
export VM_USER=fedora
```

Optional:

```bash
export VPN_EXPECTED_EXIT_IP=203.0.113.10
export VM_PORT=22
export SSH_KEY="$HOME/.ssh/id_ed25519"
export VM_WG_CONF=/etc/wireguard/wg0.conf
export PUBLIC_IP_URL=https://ifconfig.me
export NMAP_PORTS=1-1024,51820,22,53
export SKIP_NMAP=1
export TEST_ALLOW_SSH=1
export RESTORE_AFTER_TEST=1
export TEST_ARTIFACT_DIR=modules/paranoid-vpn/test/artifacts/manual-run
```

`VPN_EXPECTED_EXIT_IP` is the public IPv4 address the VM should expose after the
tunnel is active. If it is unset or set to `auto`, the suite records the observed
post-setup public IP instead of failing on a mismatch. Use an exact value for a
real leak assertion once the expected VPN exit is known.

Set `SKIP_NMAP=1` when `nmap` is not installed or when you only want tunnel,
routing, DNS, and kill-switch checks.

Set `TEST_ALLOW_SSH=1` while iterating on the suite itself. It passes
`--allow-ssh` to `paranoid-vpn.sh`, so SSH stays open even if a later assertion
fails. Leave it unset for a full paranoid-mode lockdown run.

Set `RESTORE_AFTER_TEST=1` to restore the VM after the final tunnel-down checks
while the suite still has its established SSH control connection.

## Run: Independent Disposable VM

From the repository root:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-independent-vm-integration.sh
```

`TEST_WG_CONF` must point to a real, untracked WireGuard config with a full
tunnel route such as `AllowedIPs = 0.0.0.0/0, ::/0`. The config is copied into
the VM as `/etc/wireguard/wg0.conf`; its contents and path are not written to
the generated report.

Optional independent-runner settings:

```bash
export FEDORA_RELEASE=43
export FEDORA_CLOUD_IMAGE_URL=https://example.invalid/Fedora-Cloud-Base.qcow2
export LIBVIRT_URI=qemu:///system
export LIBVIRT_NETWORK=default
export VM_MEMORY_MB=2048
export VM_CPUS=2
export VM_DISK_SIZE=20G
```

The runner caches the Fedora base image under
`modules/paranoid-vpn/test/vm-cache/`, writes detailed artifacts under
`modules/paranoid-vpn/test/artifacts/independent-<timestamp>/`, and writes the
timestamped `vm-integration-report-<timestamp>.md` there by default. It always
destroys and undefines the disposable VM and removes generated disks, seed ISOs,
and SSH keys after collecting artifacts.

To validate only host prerequisites and report generation:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-independent-vm-integration.sh --preflight-only
```

## Run: Persistent Desktop VM Lab

Use the desktop runner when you want automated network validation first, then a
running graphical VM for manual follow-up testing:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-desktop-vm-instrumented.sh
```

The runner provisions a Fedora libvirt VM, runs the module dependency installer,
installs GNOME/GDM and SPICE guest tools, enables GDM autologin for the test
user, copies in the local WireGuard config as `/etc/wireguard/wg0.conf`, runs
the paranoid-vpn setup, performs VM-side tunnel/firewall/DNS checks, and runs a
host-side full `nmap` audit. It then prints the VM name, IP address, SSH
command, artifact directory, report path, and a `virt-manager` command.

Long guest provisioning commands are split into named timed steps. Full guest
package and service output is written to `guest-step-*.log` files under the run
artifact directory, while the terminal shows concise section status and the log
path to inspect if a step fails or times out.

Each major runner phase prints a simple text progress bar. Long remote steps,
including guest provisioning and paranoid-vpn setup inside the VM, show a live
pulse bar with elapsed time while full output is captured to a step log. Retry
loops, such as waiting for a DHCP lease or SSH, print smaller attempt bars so
long waits are visible. Set `PROGRESS_WIDTH` to adjust the bar width.

Open the desktop with:

```bash
virt-manager --connect qemu:///system
```

Then select the printed VM name. The VM remains running until the script prompt
receives Enter, `yes`, or `destroy`; at that point the runner destroys and
undefines the VM and removes generated disks, seed files, and SSH keys.

Useful desktop-lab settings:

```bash
export KEEP_VM_ON_EXIT=1
export RUN_DESTRUCTIVE_ON_CLEANUP=1
export FEDORA_RELEASE=44
export FEDORA_DESKTOP_PROFILE=workstation
export AUTO_INSTALL_HOST_DEPS=1
export HOST_SETUP_ASSUME_YES=1
export PROGRESS_WIDTH=24
export NMAP_FULL_AUDIT=1
export NMAP_TIMEOUT=300
export NMAP_PORTS=1-1024,51820,22,53
export NMAP_UDP_PORTS=53,123,51820
export NMAP_ALLOWED_OPEN_TCP=22
```

`KEEP_VM_ON_EXIT=1` leaves the VM and generated work files in place on normal
exit or Ctrl-C. This also leaves the generated SSH private key under the
artifact work directory, so treat that directory as sensitive.

`FEDORA_DESKTOP_PROFILE=lab` is the default and installs a smaller GNOME lab
desktop. `FEDORA_DESKTOP_PROFILE=workstation` installs Fedora's Workstation
environment group inside the VM. Both profiles boot from a Fedora Cloud qcow2 so
cloud-init and SSH automation remain available.

The desktop runner automatically checks host prerequisites before touching
libvirt. By default, `AUTO_INSTALL_HOST_DEPS=1` prints a compact host setup
plan, asks for terminal `sudo` once, installs missing Fedora/Debian packages,
starts libvirt services when needed, and adds the current user to the `libvirt`
group when using `qemu:///system`. It uses `sudo -n` after the initial terminal
authentication, so host setup fails clearly instead of producing repeated
graphical PolicyKit password dialogs.

Set `AUTO_INSTALL_HOST_DEPS=0` to disable automatic host changes. The runner
will print the exact commands to run and stop.

For `qemu:///system`, generated VM disks and seed ISOs are placed under
`/var/tmp/paranoid-vpn-desktop-*`, and the Fedora base image cache is placed
under `/var/tmp/paranoid-vpn-vm-cache`, so the system `qemu` user can read both
the overlay and its backing file. Reports and logs still stay under the module
artifact directory. Override with `VM_WORK_DIR=/some/libvirt-readable/path` or
`VM_CACHE_DIR=/some/libvirt-readable/cache` if needed.

If host setup adds your user to `libvirt`, refresh your shell session before
rerunning:

```bash
newgrp libvirt
virsh --connect qemu:///system list --all
```

`RUN_DESTRUCTIVE_ON_CLEANUP=1` runs the tunnel-down kill-switch check after
manual testing and before VM destruction. It is disabled by default so the
desktop stays usable during the manual phase.

`NMAP_FULL_AUDIT=1` is the default for this runner. When the host process runs
as root, or has passwordless `sudo`, it uses SYN scanning, OS detection, and UDP
scanning; otherwise it falls back to a TCP connect scan and skips UDP while still
running service/version and default/safe NSE checks. The audit is reconnaissance
only; it does not run exploit scripts. Raw `nmap` output is saved under
`modules/paranoid-vpn/test/artifacts/desktop-<timestamp>/`.

## Run: Offline USB VM Smoke

Use this runner to test the second-pendrive workflow before touching a real
cut-off machine. It creates the offline USB bundle on the host, writes it into a
FAT disk image, boots a disposable Fedora Cloud VM, attaches the image as a USB
disk, mounts it inside the VM, runs the offline preflight, and starts the
hardening launcher.

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-offline-usb-vm-smoke.sh
```

This is a smoke test only: it checks that hardening started from the mounted USB
image, but it does not assert that the final network lockdown worked. The VM is
destroyed after the test.

Useful settings:

```bash
export USB_DOWNLOAD_RPMS=1
export USB_IMAGE_SIZE_MB=2048
export PRESERVE_USB_IMAGE=1
export HARDENING_START_TIMEOUT=90
```

For `qemu:///system`, the generated USB disk image is placed under
`/var/tmp/paranoid-vpn-offline-usb-*` so the system `qemu` user can read it.
By default, a copy of that image is preserved in the artifact directory for
later manual attachment. Reports, bundle contents, and copied VM logs are saved under
`modules/paranoid-vpn/test/artifacts/offline-usb-<timestamp>/`.

To validate only host prerequisites:

```bash
TEST_WG_CONF=/secure/wg0.conf modules/paranoid-vpn/test/run-offline-usb-vm-smoke.sh --preflight-only
```

## Run: Existing VM

From the repository root:

```bash
modules/paranoid-vpn/test/run-vm-integration.sh
```

The suite writes logs and command output under
`modules/paranoid-vpn/test/artifacts/<timestamp>/` by default. Artifacts include
pre/post public IP checks, DNS output, Firewalld state, WireGuard status,
journal excerpts, and `nmap` results.

## What It Checks

- local and VM preflight requirements fail fast
- SSH connectivity and passwordless sudo work
- the VM WireGuard config exists and is full tunnel
- setup copies and runs the project scripts on the VM
- `wg0` exists and has a non-zero handshake
- the default route points to `wg0`
- IPv6 is disabled
- the VM public IP matches `VPN_EXPECTED_EXIT_IP`
- DNS lookup works after setup
- Firewalld zone `wireguard-only` exists, targets `DROP`, includes `wg0`, and
  does not expose DNS ports
- host-side TCP `nmap` finds no open ports in `NMAP_PORTS`
- after `wg-quick down wg0`, outbound curl fails and no physical default route
  remains

UDP `51820` is recorded but not treated as an inbound-open requirement. The
default `nmap` invocation is a TCP scan.
