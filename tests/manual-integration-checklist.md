# Manual macOS/UTM integration checklist

Run these checks only on a disposable or recoverable test network. Replace angle-bracket placeholders locally and do not paste real MAC addresses, private addresses, hostnames, tokens, or full home-directory paths into issues.

## 1. Preflight

- [ ] Confirm the Mac and UTM versions and record only non-sensitive version numbers.
- [ ] Confirm at least one running UTM VM uses bridged networking.
- [ ] Confirm the intended uplink and bridge using `ifconfig -l` and `ifconfig <bridge>`.
- [ ] Confirm the candidate bridge has exactly one intended physical uplink and one or more `vmenetN` members.
- [ ] Confirm the installed config is owned by `root:wheel` and is not writable by group or others.
- [ ] Confirm the package directories, config, binary, LaunchDaemon plist, and `run.lock` have no extended ACL (`ls -lde` shows no `+`).
- [ ] Confirm no second copy of the LaunchDaemon is loaded.

## 2. Read-only discovery

```sh
sudo /Library/Application\ Support/UTMBridgeFDBGuard/bin/utm-bridge-fdb-guard \
  scan --config /Library/Application\ Support/UTMBridgeFDBGuard/config.plist
```

- [ ] Verify every rejected bridge includes a useful fail-closed reason.
- [ ] Verify the selected uplink MAC is derived from the live interface, not copied from config.
- [ ] Verify detected guest evidence belongs to an actual current `vmenetN` member.
- [ ] Verify `scan` does not change `ifconfig <bridge> addr` output.

## 3. Dry run

```sh
sudo /Library/Application\ Support/UTMBridgeFDBGuard/bin/utm-bridge-fdb-guard \
  run --config /Library/Application\ Support/UTMBridgeFDBGuard/config.plist \
  --dry-run
```

- [ ] With no offending entry, verify the command reports no action.
- [ ] With one unique dynamic offending entry, verify it reports only `deladdr <current-uplink-mac>`.
- [ ] Verify it never proposes a guest MAC, bridge MAC, route, address, DNS, PF, or VM change.

## 4. One-shot repair

- [ ] Save a redacted copy of the candidate bridge FDB before testing.
- [ ] Run one non-dry `run` invocation.
- [ ] Verify exactly one dynamic host-MAC entry disappeared.
- [ ] Verify all guest FDB entries remain.
- [ ] Verify host-to-guest connectivity recovers.
- [ ] Verify another LAN device can still reach the guest.
- [ ] Verify routes, interface addresses, DNS, PF, and UTM settings are unchanged.

## 5. VM MAC change

- [ ] Stop the disposable VM cleanly.
- [ ] Change or regenerate only its bridged adapter MAC, using a locally administered test value such as `02:00:00:00:20:99`.
- [ ] Start the VM and wait for a new MAC to be learned on its `vmenetN` member.
- [ ] In `learned-any` mode, verify `scan` still accepts the guest evidence without reinstallation.
- [ ] In guest allowlist mode, verify the new unlisted MAC causes a fail-closed no-op.

## 6. Host MAC and interface change

Do not spoof or change a production uplink MAC merely for this test. Use a lab interface or switch between disposable uplinks.

- [ ] Verify `scan` reports the current live uplink MAC after the interface changes.
- [ ] Verify a stale value is not retained in config or state.
- [ ] If explicit uplink mode is enabled, verify an unconfigured uplink causes a no-op until deliberately reconfigured.

## 7. Multiple VMs and ambiguous bridges

- [ ] Start two bridged VMs attached to the same uplink and same vmnet bridge.
- [ ] Verify both `vmenetN` members are accepted and only one host-MAC deletion is attempted for that bridge.
- [ ] Create two independently qualifying bridge candidates in a lab setup.
- [ ] Verify automatic bridge selection fails closed without deleting from either bridge.
- [ ] Add one exact bridge to `AllowedBridges`, then verify only that bridge can be repaired.
- [ ] Add an unexpected second non-vmenet member to a candidate and verify it is rejected.

## 8. Lifecycle

- [ ] Start UTM after login and verify the next LaunchDaemon interval discovers the new bridge.
- [ ] Restart the VM and verify bridge/vmenet renumbering does not require reinstallation.
- [ ] Sleep and wake the Mac, then repeat `scan` before allowing mutation.
- [ ] Stop all bridged VMs and verify periodic runs are silent no-ops.
- [ ] Verify unified logs contain an entry only when a deletion or actionable error occurs.
- [ ] Uninstall and verify only the documented package files and LaunchDaemon label are removed.

## 9. Evidence hygiene

- [ ] Replace all MAC examples with `02:00:00:00:xx:xx` documentation values.
- [ ] Replace any test IP with an RFC documentation address before sharing.
- [ ] Remove usernames and absolute home-directory paths.
- [ ] Do not attach raw packet captures, UTM configuration bundles, cookies, secrets, or subscription URLs.
- [ ] Run `zsh tests/privacy-scan.zsh` before publishing diagnostic material.
