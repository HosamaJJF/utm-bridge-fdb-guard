# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Simplified the repository documentation and clarified that ongoing maintenance should not be expected.

## [1.0.0] - 2026-07-18

### Added

- Fail-closed discovery of eligible macOS bridges, physical uplinks, and `vmenet*` guest evidence.
- Runtime host MAC discovery, avoiding machine-specific configuration.
- Default `learned-any` guest policy, so a rebuilt VM or changed virtual NIC MAC does not require reinstalling.
- Optional explicit bridge, uplink, and guest MAC restrictions.
- Unique dynamic FDB target validation and a second pre-mutation snapshot.
- Full global bridge re-enumeration immediately before mutation and a one-candidate rule for every bridge policy.
- Strict rejection of truncated FDB rows and duplicate flag fields.
- `scan`, `run`, `run --dry-run`, `doctor`, and `version` commands.
- Root-owned LaunchDaemon installer with staged release inputs, ACL hardening, signal-safe rollback, reconfiguration, and upgrade modes.
- Validated uninstaller with an option to preserve configuration.
- Kernel advisory locking without stale lock directories or writable `/var/run` markers.
- Fixture, race, logger, ACL, and root install-lifecycle tests on macOS CI.
- Tag-driven reproducible release packaging with normalized metadata and SHA-256 checksums.

[Unreleased]: https://github.com/HosamaJJF/utm-bridge-fdb-guard/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/HosamaJJF/utm-bridge-fdb-guard/releases/tag/v1.0.0
