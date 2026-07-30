# Roadmap

Hermes sandbox is approaching a v0.5 public preview. The policy engine and
non-integration test suite are in place; the remaining work is primarily
release engineering, portability, and end-to-end verification.

## v0.5 publication

- Make the `hermes-agent:v2026.7.1` image reproducible from a clean clone.
  Commit a build script and the Podman-compatible upstream Dockerfile patch,
  pinned to an exact Hermes Agent release or commit. Alternatively, use a
  published image pinned by digest.
- Add a clean-clone quickstart covering prerequisites, image preparation,
  OpenRouter setup, the first launch, and a smoke test.
- Add a `just doctor` or `just bootstrap` command that checks required tools,
  rootless Podman, `pasta`, the Hermes image, and required runtime directories.
- Add continuous integration that runs `just test`; add ShellCheck once its
  findings have been reviewed.
- Run a final full-history secret and private-data scan immediately before
  attaching the public remote. Confirm that the author identity and email in
  existing commits are intended to be public.
- Decide how local-model launches fit the capability-policy model. They
  currently bypass capability profiles for compatibility. Either add a
  `local-dual` profile selected by `slot-run.sh`, or document the narrower
  policy guarantee prominently.

## Portability and hardening

- Make the primary checkout root configurable instead of assuming
  `~/projects`.
- Make default cloud models and provider routes configurable.
- Make GPU access optional for restricted analysis mode and improve behavior
  on systems without NVIDIA CDI.
- Add Podman integration tests for mount visibility, host-service isolation,
  analysis-mode egress restrictions, gateway cleanup, and first-run behavior.
- Test and document supported Linux distributions and Podman versions.
- Improve diagnostics for missing images, unsupported networking, and
  unavailable GPU devices.

## Later packaging

- Consider an optional Nix flake or NixOS module for dependency installation
  and reproducible image builds. The shell-and-Podman implementation should
  remain usable without Nix.
- Consider publishing a prebuilt Hermes Agent image after defining the image
  update and supply-chain policy.
