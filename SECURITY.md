# Security policy

## Supported versions

Security fixes are provided for the latest released minor version.

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| Earlier or unreleased builds | No |

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's **Report a vulnerability** feature in the repository Security tab to submit a private security advisory. Include:

- the affected version and macOS version;
- the command and configuration mode involved;
- the expected and observed behavior;
- a minimal, sanitized reproduction;
- whether an unintended FDB mutation occurred.

You should receive an acknowledgement within seven days. Assessment and remediation timing depends on severity and reproducibility. Coordinated disclosure is appreciated.

## Sensitive diagnostic data

Before attaching logs or command output, remove information that is not required to reproduce the issue, including:

- interface MAC addresses that you consider sensitive;
- usernames and filesystem locations;
- LAN addresses and device names;
- DNS names, tokens, credentials, and cookies.

Use locally administered example MAC addresses such as `02:00:00:00:00:01` when a real address is unnecessary. Never send secrets in a GitHub issue.

## Security boundary

This package installs a root-owned LaunchDaemon because deleting a bridge FDB entry requires elevated privileges. Its binary, configuration, containing directories, LaunchDaemon plist, and advisory-lock file must not have extended ACLs granting unprivileged access. Its intended mutation is limited to one exact command after all validation succeeds:

```sh
/sbin/ifconfig <validated-bridge> deladdr <validated-current-uplink-mac>
```

The program is designed to fail closed. A report is security-relevant if, for example, unprivileged input can alter its configuration, validation can be bypassed, arguments can be injected, a static or unrelated FDB entry can be removed, or installation/uninstallation can overwrite or delete files outside the package's fixed paths.

General connectivity problems, unsupported topologies that correctly produce a no-op, and requests to weaken the validation model are normally handled as regular issues.
