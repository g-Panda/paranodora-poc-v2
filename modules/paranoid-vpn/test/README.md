# VM Integration Tests

This directory contains the integration suite for the `paranoid-vpn` module. The
self-provisioning runner creates a disposable Fedora Cloud VM with libvirt,
copies in a local WireGuard config, runs the existing SSH-driven suite, saves a
module artifact report, and destroys the VM afterward. The lower-level runner can
still be used directly against an already-running disposable VM.

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
