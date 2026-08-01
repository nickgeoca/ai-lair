# Contributing

AI Lair is an experimental, security-sensitive shell and Podman project. Hermes
Agent is the only supported harness in the current release.
Bug reports, portability findings, documentation improvements, tests, and
focused implementation changes are welcome.

## Before starting

Read `README.md`, `docs/design.md`, and the relevant portion of
`docs/implementation.md`. For planned work, check `TODO.md` and
`docs/open-source-release-plan.md` so a contribution does not accidentally
broaden the supported surface or weaken an intentional boundary.

For security vulnerabilities, follow `SECURITY.md` rather than opening a public
issue with sensitive details.

## Development checks

The non-integration suite does not download model weights or require a running
container:

```bash
just test
git diff --check
```

The tests require Bash 4+, Git, `just`, `jq`, and ordinary GNU/Linux command-line
utilities. Use `just doctor` to inspect the complete runtime prerequisites.

Changes that depend on Podman, `pasta`, NVIDIA CDI, a provider account, or a
local model should describe the exact environment used for live verification.
Never put credentials, conversations, private repository content, datasets, or
raw security-scanner output in a test fixture, commit, issue, or build log.

## Design constraints

Preserve these properties unless a proposal explicitly changes the documented
threat model:

- Host paths are allowlisted; a parent directory is not mounted for
  convenience.
- Primary checkouts are not writable from an agent session.
- Work enters disposable clones and returns through explicit reviewed import.
- Profiles are declarative data and cannot add arbitrary mounts, commands,
  ports, devices, secrets, or container options.
- Normal sessions block host services. Restricted analysis has no general
  Internet route. Any weaker mode must be explicit and documented.
- Runtime state and credentials remain outside the tracked tree.
- Agent-image, gateway-image, and local-model inputs remain pinned and their
  provenance remains reviewable.

Prefer extending an existing, tested path over introducing a new abstraction.
Broad multi-harness, execution-backend, MCP, or credential-broker work should
begin with a concrete use case and a design discussion.

## Making changes

- Use `set -euo pipefail` in executable Bash scripts unless a documented reason
  requires different error handling.
- Quote paths and preserve arguments as arrays; avoid `eval` and shell command
  construction from user-controlled strings.
- Resolve and validate host paths before constructing mount arguments.
- Keep security policy in trusted launcher code, not contributor-editable
  profile fields.
- Add negative tests for rejected input as well as positive tests for expected
  arguments and behavior.
- Keep commits small and explain the security effect of a change.

This repository uses an allowlist-style `.gitignore`. A new public file must be
explicitly unignored and reviewed before it can be committed. This is an
intentional publication safeguard, not a missing wildcard rule.

## Submitting a change

A contribution should state:

- the problem and intended behavior;
- relevant non-goals;
- security-boundary or compatibility effects;
- tests run, including any live Podman or GPU checks;
- documentation updated;
- any new downloads, images, dependencies, licenses, or provenance concerns.

By contributing, you agree that your contribution may be distributed under the
project's MIT license.
