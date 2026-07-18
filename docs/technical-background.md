# Technical background and safety invariants

## The observed failure mode

UTM bridged networking on macOS can involve a dynamically created `bridgeN`, one or more `vmenetN` interfaces, and a physical uplink such as an `enN` interface. The bridge forwarding database maps learned MAC addresses to bridge members.

In the failure mode this project targets, the physical uplink's own MAC address appears as a dynamic FDB entry learned on that same physical uplink. Host-to-guest connectivity can fail while other traffic paths remain functional. Removing the exact stale entry has restored host-to-guest communication in observed systems.

This is an empirical workaround, not a claim that every host-to-guest timeout has the same cause. See the related report in [UTM issue #7121](https://github.com/utmapp/UTM/issues/7121).

## Why a generic FDB cleanup is dangerous

An FDB contains legitimate forwarding state. Flushing it, deleting guest entries, or acting on a guessed interface can interrupt unrelated VMs and network traffic. Interface numbers also change across boots and VM rebuilds:

- `bridge100` may later be another `bridgeN`.
- `vmenet0` may later be another `vmenetN`.
- a guest virtual NIC may receive a new MAC.
- the host uplink or its current MAC may change.
- several UTM guests or bridges may exist simultaneously.

For those reasons, persisted VM MACs are not the default identity mechanism. The running topology is the source of truth.

## Discovery model

For each run, the guard obtains a fresh view of the system and evaluates candidate bridges independently.

### Bridge evidence

A candidate must be an active macOS bridge and must contain at least one actual `vmenet*` member. After an optional bridge allowlist narrows eligibility, exactly one global candidate must remain. An allowlist never authorizes simultaneous changes on several bridges and does not bypass any other check.

### Uplink evidence

During installation or reconfiguration, the installer derives the eligible physical uplink from the current default route unless the user supplies an explicit interface. It stores the resulting interface in a root-owned allowlist. On every guard run, the bridge's only non-`vmenet` member must be in that allowlist, must still be a current bridge member, and must expose a valid non-zero unicast MAC address. Moving to another physical uplink therefore requires an explicit reconfiguration.

The host MAC is read at runtime. It is not copied from the machine that built the package and is not assumed to remain constant.

### Guest evidence

The default `learned-any` policy requires at least one valid unicast MAC learned on a `vmenet*` member belonging to the candidate bridge. This proves that a guest-side forwarding path is active without coupling the installation to a particular VM MAC.

An optional guest MAC allowlist provides stricter evidence for environments that need it. If configured, changing the VM MAC requires updating that allowlist. The allowlist narrows candidates; it never relaxes the topology checks.

### Target evidence

The only eligible target is an FDB entry that satisfies all of these conditions:

- its normalized MAC equals the current physical uplink MAC;
- it is learned on that same uplink member;
- it is explicitly dynamic, not static or permanent;
- exactly one matching row exists;
- the surrounding bridge and guest evidence is unambiguous.

macOS may print a hexadecimal MAC component without a leading zero. The parser normalizes each component before comparison rather than relying on raw string equality.

## Time-of-check/time-of-use protection

Virtual network interfaces and bridges may be destroyed and recreated while a check is in progress. The guard therefore treats the initial result as a proposal, not authorization.

Immediately before deletion it re-enumerates every bridge and obtains a second full snapshot. The global candidate set, selected bridge membership, uplink, normalized uplink MAC, guest evidence, and unique target must still produce the same decision. Any difference causes a no-op.

The resulting mutation is limited to:

```sh
/sbin/ifconfig "$bridge" deladdr "$derived_uplink_mac"
```

Both arguments have already passed strict validation. After the command, the guard verifies that the exact target disappeared. It does not broaden the action if deletion fails.

## Fail-closed conditions

The following are examples of conditions that produce no FDB mutation:

- no eligible bridge or `vmenet*` member;
- several possible bridges where policy requires one;
- no eligible uplink or more than one possible physical uplink;
- uplink not active or not a current member;
- invalid, multicast, broadcast, or zero MAC data;
- no guest MAC learned on an actual `vmenet*` member;
- no target, more than one target, or a target on another member;
- a static or permanent target entry;
- unknown, truncated, or inconsistent command output;
- topology or FDB changes between the two snapshots;
- insecure, malformed, or unsupported configuration;
- inability to acquire the single-instance lock;
- failure of any required system command.

Normal “nothing to do” outcomes are expected and should not cause a retry storm.

## Privilege and configuration boundary

Deleting an FDB entry requires elevated privileges, so the scheduled check runs as a system LaunchDaemon. The installation and configuration are root-owned and must not be writable by unprivileged users. Configuration is parsed as data; it is never sourced as shell code.

The process uses fixed absolute paths for system utilities and ignores test-only tool overrides whenever it is privileged. It validates every interface name and MAC before use and serializes runs with a kernel advisory lock on a root-owned file, so a crash cannot leave a stale logical lock. The configuration file and its parent directory must be root-owned, not group/other writable, free of extended ACLs, and not symbolic links. `RunAtLoad` and a periodic interval schedule short-lived checks; `KeepAlive` is intentionally unnecessary.

The guard is not authorized to:

- flush an FDB;
- remove a guest MAC entry;
- alter IP addresses, DNS, routes, firewall rules, or DHCP;
- edit UTM bundles or VM settings;
- stop, start, or restart a VM;
- infer a destructive action from partial output.

## Diagnostics and privacy

`scan` explains candidates and rejection reasons without making changes. `run --dry-run` exercises the full decision path, including the final validation, but suppresses deletion. `doctor` checks configuration, permissions, parser prerequisites, and installed service state.

These outputs may include local interface names and MAC addresses. They should be reviewed and, where appropriate, redacted before sharing publicly. The project does not need LAN IP addresses, DNS names, proxy settings, or guest credentials to make its decision.

## Compatibility and testing expectations

The implementation targets known macOS `ifconfig` bridge and FDB output. Parser permissiveness is a safety risk: support for a new output form should be added with fixtures that prove both the intended acceptance and rejection of malformed or ambiguous neighbors.

Automated tests should use locally administered example MAC addresses. They must cover at least:

- changed bridge and `vmenet` numbers;
- changed guest and host MACs;
- missing guest evidence;
- target on the wrong member;
- duplicate and static target entries;
- multiple uplinks or bridges;
- shortened hexadecimal MAC components;
- command failure and truncated output;
- a bridge changing between snapshots;
- concurrent invocations.

CI must stub the mutation. A real `ifconfig ... deladdr` operation belongs only in an explicitly reviewed manual integration test on a disposable topology.
