# Initial source-publication audit

Date: 2026-08-01

This record covers the initial experimental source preview of AI Lair. It does
not certify the project as a production security boundary or complete the live
runtime gates required for a versioned v0.5 release.

## Repository and history

- Reviewed the tracked-path inventory and complete 40-commit object inventory.
  The largest historical blobs are small source and documentation files.
- Ran Gitleaks 8.30.1 against all refs and the complete Git history with
  redacted output. It reported no leaks.
- Manually searched the complete history for credential patterns, private-key
  headers, personal home paths, repository URLs, and host-specific material.
  Only intended public upstream/model URLs and placeholder API-key examples
  were found.
- Confirmed that `data/`, `repos/`, `outbox/`, `datasets/`,
  `local-models.local/`, and `src/` have never been tracked.
- Confirmed that the historical Nick Geoca public author identity and older
  synthetic `Hermes Sandbox <sandbox@hermes.local>` author identity are
  intentional publication metadata.

## Licensing and provenance

- AI Lair is published under the MIT License, copyright 2026 Nick Geoca.
- The Podman compatibility patch targets the exact Nous Research Hermes Agent
  commit in `images/hermes/metadata.conf`. The pinned upstream source is MIT
  licensed, copyright 2025 Nous Research.
- No oh-my-pi source or binaries are included. It is named only as a possible
  future harness adapter.

## Validation

- `just test`
- `shellcheck -x ./*.sh ./lair ./tests/*.sh` with ShellCheck 0.11.0
- `git diff --check`
- Actionlint 1.7.12 against `.github/workflows/test.yml`
- Bash syntax validation of generated Bash completions

Zsh and Fish were not installed for live completion-parser validation. Their
generated completion text is covered by the CLI regression test.

## Outstanding live gates

The publication environment did not have OpenSSL, `pasta`, an available
rootless Podman user service, or the pinned Hermes image. Consequently, the
clean-clone bootstrap, first launch, live mount/network isolation, local-model,
and GPU paths remain unverified. The README and roadmap identify AI Lair as an
experimental preview and keep these items open before a versioned v0.5 release.
