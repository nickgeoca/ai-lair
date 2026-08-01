# Security policy

## Project status

AI Lair is experimental software. It is not a formally audited security
boundary and does not claim production readiness. Security properties are
limited to the behavior documented in `docs/design.md` and covered by the
available tests.

The project currently supports the latest commit on `main`. Reports against an
older revision are welcome when the issue still reproduces on `main`.

## Reporting a vulnerability

Please use the repository's private **Report a vulnerability** link under the
Security tab. The repository owner must enable private vulnerability reporting
before making the project public.

Do not include exploit details, credentials, private repository content, host
information, or other sensitive material in a public issue. If private
reporting is unavailable, open a minimal issue stating only that the private
reporting channel is unavailable and ask the maintainer to provide a private
contact route.

A useful report includes:

- the affected commit and host configuration;
- the boundary or capability profile being tested;
- the expected and observed behavior;
- minimal reproduction steps that do not contain secrets or private data;
- the practical impact and any known prerequisites;
- whether the issue is already public or being actively exploited.

Reports are handled on a best-effort basis. The maintainer will acknowledge the
report, attempt to reproduce it, and coordinate disclosure and remediation when
the report is confirmed. No response-time or remediation-time guarantee is
currently offered.

## Issues treated as security-sensitive

Examples include:

- access to host files outside explicitly selected mounts;
- writes to a primary checkout without the reviewed import workflow;
- exposure of provider keys, Podman secrets, or persistent conversation data;
- access to host services despite a boundary that claims to block them;
- bypass of restricted-analysis network policy;
- command or argument injection through repository names, paths, manifests, or
  declarative profiles;
- an import/export operation affecting a repository or artifact that the user
  did not select;
- unsafe ownership, permission, or symlink handling at a host/container
  boundary.

Documented limitations are not automatically vulnerabilities. Normal mode
permits Internet access, local-model mode has a weaker host-network boundary,
containers share the host kernel, and selected files may be disclosed to the
configured model provider. A security report is still appropriate when the
implementation behaves less restrictively than its documented boundary.

## Safe testing

Test only systems, accounts, repositories, and data you are authorized to use.
Avoid destructive actions, persistence outside the test environment, privacy
violations, service disruption, and unnecessary access to real secrets. Stop
once you have enough evidence for a minimal report.
