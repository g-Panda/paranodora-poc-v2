# FIDO LUKS Module

Scaffold for future FIDO2-backed LUKS unlock support.

## Intended Scope

- Add a FIDO2 unlock method for encrypted disks.
- Keep the existing password unlock path intact.
- Include recovery checks before enrollment so the machine is not locked out.
- Document supported distributions and systemd-cryptenroll expectations before
  adding executable logic.

## Current State

This module is documentation-only. It does not enroll FIDO devices, change LUKS
slots, or modify initramfs configuration.

Implementation notes live in [src/README.md](src/README.md). Test guidance lives
in [test/README.md](test/README.md).
