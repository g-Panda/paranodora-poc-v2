# Paranodora POC

Paranodora is organized as independent security modules. Each module owns its
own `src/` and `test/` directories so new work can grow without adding root
level source or test trees.

## Modules

- [paranoid-vpn](modules/paranoid-vpn/README.md): WireGuard full-tunnel setup
  with a kill switch for Fedora Silverblue-style systems.
- [secure-boot](modules/secure-boot/README.md): scaffold for managing custom
  Secure Boot platform keys.
- [fido-luks](modules/fido-luks/README.md): scaffold for adding FIDO2-backed
  LUKS unlock beside an existing password.

## Module Commands

The VPN setup entrypoint lives inside the module:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh [options]
```

For setup, pass a WireGuard config explicitly:

```bash
sudo modules/paranoid-vpn/src/paranoid-vpn.sh --wg-conf /path/to/proton.conf
```

No Secure Boot or FIDO/LUKS mutation commands exist yet.
