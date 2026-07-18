# UTM Bridge FDB Guard

[简体中文](README.zh-CN.md) · [Technical background](docs/technical-background.md) · [Security policy](SECURITY.md)

`utm-bridge-fdb-guard` is a narrowly scoped, fail-closed macOS LaunchDaemon workaround for a stale bridge forwarding-database (FDB) entry that can disrupt connectivity between a Mac host and a bridged UTM guest.

The guard discovers the live bridge topology on every run. It does **not** pin a virtual machine MAC address, bridge number, `vmenet` number, or host MAC address. When—and only when—all safety checks agree, it removes one exact, dynamic FDB entry for the physical uplink's own MAC address. Ambiguous or unfamiliar state is left untouched.

This project is an independent workaround for observed Apple `vmnet`/macOS bridge behavior. It is not an upstream fix from Apple or UTM.

## Why this exists

In the affected state, the Mac's physical-uplink MAC address appears as a dynamically learned entry on that same uplink inside a UTM-created bridge. Host-to-guest traffic may then time out even though the guest and other LAN devices continue to communicate.

Deleting that one stale entry restores connectivity in observed cases:

```sh
/sbin/ifconfig <bridge> deladdr <uplink-mac>
```

Running that command without strong validation would be unsafe. This project automates it only after validating the bridge, uplink, active `vmenet` evidence, target uniqueness, entry type, and a second fresh snapshot immediately before the change.

## Safety model

The default policy is deliberately conservative:

1. Discover active macOS bridges that contain a `vmenet*` member, apply any bridge allowlist, and require exactly one globally eligible bridge.
2. Require the bridge's only non-`vmenet` member to be in the configured uplink allowlist. During installation or reconfiguration, the installer derives that allowlist from the current default-route interface unless an interface is explicitly supplied.
3. Read and normalize the uplink's current MAC address at runtime.
4. Require learned guest evidence on an actual `vmenet*` member. The guest MAC may change without reinstalling the guard.
5. Require exactly one matching dynamic FDB entry: the uplink's own MAC learned on that same uplink.
6. Re-read the topology and FDB and require an identical decision before deleting the exact entry.
7. Do nothing on ambiguity, malformed output, missing evidence, multiple uplinks, static entries, or command failure.

The guard never flushes a bridge table. It does not modify IP addresses, routes, DNS, packet-filter rules, UTM configuration, or guest configuration, and it does not restart a VM.

## Requirements and scope

- macOS with `/sbin/ifconfig`, `launchd`, and a UTM bridged network backed by Apple virtualization networking.
- Administrator access for installation and for the FDB change.
- A topology matching the validated safety model above.

The parser is intentionally coupled to known macOS `ifconfig` bridge output. Unknown output is treated as a reason to stop, not to guess. Use `scan` before installation and after macOS or UTM upgrades.

This workaround addresses one specific FDB failure mode. Similar symptoms can also be caused by guest firewall rules, service failures, IP conflicts, routing, or proxy configuration.

## Quick start

Download both the `v1.0.0` archive and `SHA256SUMS` from the [Releases page](https://github.com/HosamaJJF/utm-bridge-fdb-guard/releases), verify before extracting, and inspect the scripts before using `sudo`:

```sh
shasum -a 256 -c SHA256SUMS
tar -xzf utm-bridge-fdb-guard-1.0.0.tar.gz
cd utm-bridge-fdb-guard-1.0.0
```

Alternatively, clone the exact release tag for inspection or development:

```sh
git clone --branch v1.0.0 --depth 1 https://github.com/HosamaJJF/utm-bridge-fdb-guard.git
cd utm-bridge-fdb-guard
```

Install with automatic bridge discovery. The installer records the current default-route interface as the allowed physical uplink:

```sh
sudo ./scripts/install.zsh
```

The installer shows its detected configuration and performs a read-only preflight before installing. For unattended use, add `--yes` only after reviewing the same command interactively.

The system installation consists of:

- `/Library/Application Support/UTMBridgeFDBGuard/bin/utm-bridge-fdb-guard`
- `/Library/Application Support/UTMBridgeFDBGuard/config.plist`
- `/Library/Application Support/UTMBridgeFDBGuard/run.lock` (a persistent root-owned file used only for a kernel advisory lock)
- package version and manifest files in the same application-support directory
- `/Library/LaunchDaemons/io.github.hosamajjf.utm-bridge-fdb-guard.plist`

All installed files are root-owned. The LaunchDaemon label is `io.github.hosamajjf.utm-bridge-fdb-guard`.

### Explicit configuration

Pin the eligible uplink or bridge when automatic selection would be ambiguous:

```sh
sudo ./scripts/install.zsh --uplink en0 --bridge auto
sudo ./scripts/install.zsh --uplink en0 --bridge bridge100
```

Optionally require one or more known guest MAC addresses as stricter evidence:

```sh
sudo ./scripts/install.zsh \
  --guest-mac 02:00:00:00:00:01 \
  --guest-mac 02:00:00:00:00:02
```

Guest MAC allowlisting is optional. The default `learned-any` policy accepts a valid learned unicast guest MAC on an actual `vmenet*` member, so rebuilding a VM normally does not require reconfiguration.

## Commands

The installed LaunchDaemon invokes one short-lived check at each interval; it is not a continuously running process.

```sh
# Explain candidates and rejection reasons; does not modify the FDB
sudo ./bin/utm-bridge-fdb-guard scan --config /path/to/config.plist

# Exercise the complete decision path without deleting anything
sudo ./bin/utm-bridge-fdb-guard run --config /path/to/config.plist --dry-run

# Run one guarded check
sudo ./bin/utm-bridge-fdb-guard run --config /path/to/config.plist

# Validate configuration, permissions, parsing, and launchd state
sudo ./bin/utm-bridge-fdb-guard doctor --config /path/to/config.plist

./bin/utm-bridge-fdb-guard version
```

For an installed copy, use the root-owned binary and configuration directly:

```sh
sudo "/Library/Application Support/UTMBridgeFDBGuard/bin/utm-bridge-fdb-guard" \
  scan --config "/Library/Application Support/UTMBridgeFDBGuard/config.plist"
```

### Reconfigure or upgrade

```sh
sudo ./scripts/install.zsh --upgrade --reconfigure --uplink en0 --bridge auto
sudo ./scripts/install.zsh --upgrade
```

The installer stages and validates an immutable root-owned copy of the release inputs before prompting, strips inherited ACLs from installed paths, and refuses unsafe overwrites. Once a configuration exists, options such as `--uplink`, `--bridge`, `--guest-mac`, and `--dry-run` are rejected unless `--upgrade --reconfigure` is also present, so they can never be silently ignored. If the Mac changes to another physical uplink interface, reconfigure the allowlist explicitly with `--upgrade --reconfigure --uplink <interface>`.

### Check the LaunchDaemon

```sh
sudo launchctl print system/io.github.hosamajjf.utm-bridge-fdb-guard
```

Because each check exits promptly, `state = not running` between intervals is normal. Review the last exit status and system log for errors.

### Uninstall

```sh
sudo ./scripts/uninstall.zsh
```

Preserve the root-owned configuration for a later reinstall:

```sh
sudo ./scripts/uninstall.zsh --keep-config
```

A later normal install reuses that preserved configuration after validating that it is the only file left in the package directory and remains owned by `root:wheel`. Use `--upgrade --reconfigure` if you want to replace it instead.

## Operational guidance

- Run `scan` and `run --dry-run` before enabling the workaround on an unfamiliar Mac.
- Re-run `doctor` after macOS, UTM, network-adapter, or topology changes.
- Never replace the targeted command with a full FDB flush.
- If the guard reports ambiguity, correct the configuration or investigate the topology; even an explicit allowlist never permits multiple simultaneous eligible bridges.
- Diagnostic output can contain interface MAC addresses. Redact them before posting publicly if they are sensitive in your environment.

For the underlying decision model and limitations, see [docs/technical-background.md](docs/technical-background.md). A related UTM discussion is [UTM issue #7121](https://github.com/utmapp/UTM/issues/7121).

## Contributing

Bug reports with sanitized `scan` output and macOS/UTM versions are welcome. Parser changes should include fixtures for both the accepted form and nearby forms that must fail closed. CI must never perform a real `ifconfig ... deladdr` operation.

Please report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

MIT © 2026 [HosamaJJF](https://github.com/HosamaJJF). See [LICENSE](LICENSE).
