# Security notes

This is a small personal project maintained on a best-effort basis. There is no supported-version schedule, guaranteed response time, security-update commitment, or promise that a reported problem will be fixed. If you need audited software with dependable support and patch timelines, this project is not intended to provide that.

If you find something security-sensitive and would rather not post it publicly, GitHub's **Report a vulnerability** feature is enabled in the repository Security tab. A useful report may include the affected version and macOS version, what the tool did, a minimal sanitized reproduction, and whether an unintended FDB change occurred. I will look when time permits, but a prompt response should not be assumed.

## Sensitive diagnostic data

Before attaching logs or command output, remove information that is not required to reproduce the issue, including:

- interface MAC addresses that you consider sensitive;
- usernames and filesystem locations;
- LAN addresses and device names;
- DNS names, tokens, credentials, and cookies.

Use locally administered example MAC addresses such as `02:00:00:00:00:01` when a real address is unnecessary. Never send secrets in a GitHub issue.

## What the tool is meant to change

This package installs a root-owned LaunchDaemon because deleting a bridge FDB entry requires elevated privileges. Its binary, configuration, containing directories, LaunchDaemon plist, and advisory-lock file must not have extended ACLs granting unprivileged access. Its intended mutation is limited to one exact command after all validation succeeds:

```sh
/sbin/ifconfig <validated-bridge> deladdr <validated-current-uplink-mac>
```

The checks are intended to make uncertain or unfamiliar states a no-op. That is an implementation goal, not a warranty or a substitute for reviewing the scripts before running them as root.
