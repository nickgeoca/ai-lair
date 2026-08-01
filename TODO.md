# Roadmap

Hermes sandbox is approaching a v0.5 public preview. The policy engine and
non-integration test suite are in place; the remaining work is primarily
release engineering, portability, and end-to-end verification.

## v0.5 publication

- Verify the source-pinned `hermes-agent:v2026.7.1` build from a genuinely
  clean clone on the supported host. Record the build result and exact host
  versions; decide whether binary-reproducible builds or a published image
  pinned by digest are required after the preview.
- Verify the documented clean-clone quickstart, OpenRouter setup, first launch,
  and smoke test without relying on existing Podman or runtime state.
- Expand `just doctor` diagnostics as clean-host testing reveals additional
  implicit dependencies or unsupported configurations.
- Add continuous integration that runs `just test` and ShellCheck.
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
