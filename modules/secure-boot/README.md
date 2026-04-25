# Secure Boot Module

Scaffold for future custom Secure Boot ownership.

## Intended Scope

- Prepare and document custom PK, KEK, and db key ownership.
- Support explicit backup and recovery steps before enrollment.
- Add preflight checks for firmware state, current Secure Boot status, and key
  material location.
- Keep dangerous operations gated behind clear, reviewed implementation.

## Current State

This module is documentation-only. It does not enroll keys, change firmware
state, or write Secure Boot variables.

Implementation notes live in [src/README.md](src/README.md). Test guidance lives
in [test/README.md](test/README.md).
