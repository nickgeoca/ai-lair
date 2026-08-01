# AI Lair

An isolated workspace for AI agent harnesses. Bring in only the repositories or
data an agent needs, then review what comes back.

AI Lair currently supports **Hermes Agent only**. The CLI is intentionally
harness-neutral so additional adapters can be added later without changing the
repository and data boundary:

```text
lair add ...   host -> lair
lair get ...   lair -> host
```

Under the hood, the current adapter is a rootless Podman wrapper for running
Hermes without exposing the host home directory, host credentials, Podman
socket, or unrelated project checkouts. AI Lair is an independent project and
is not affiliated with or endorsed by Nous Research.

This is an experimental Linux preview for technical users. The supported path
requires Bash 4+, Git, `just`, `jq`, OpenSSL, rootless Podman, and `pasta`.
Local-model and restricted-analysis GPU features additionally require NVIDIA
CDI support.

## Clean-clone quickstart

Clone the repository, then build the exact Hermes Agent revision selected by
the sandbox:

```bash
git clone <public-repository-url> ai-lair
cd ai-lair
just bootstrap
./lair doctor
```

`bootstrap` creates the ignored runtime directories and builds
`hermes-agent:v2026.7.1` from the full upstream commit recorded in
`images/hermes/metadata.conf`. It applies the small tracked Podman compatibility
patch before building. The upstream checkout is temporary and is removed when
the build finishes. Use `just bootstrap --rebuild` to replace an existing
image.

Configure OpenRouter inside the persistent lair home, then launch the first
session with no project or data access:

```bash
./lair setup
./lair
```

`lair doctor` is read-only. It reports missing host commands, an unusable or
non-rootless Podman service, a missing or mismatched Hermes image, and missing
runtime directories. Image construction downloads upstream source, base
images, operating-system packages, and application dependencies.

The examples use `./lair` so they work directly from a clone. Add the checkout
to `PATH` or symlink this file into a directory already on `PATH` to invoke it
as simply `lair`.

Once `lair` is on `PATH`, inspect the complete command surface and enable
optional shell completions:

```bash
lair --help
eval "$(lair completions bash)"       # current Bash session
eval "$(lair completions zsh)"        # current Zsh session
lair completions fish > ~/.config/fish/completions/lair.fish
```

## Everyday commands

```bash
./lair slots 4                         # allow four parallel sessions
./lair status                          # show running and available slots
./lair                                 # no project or data access
./lair add repo example-api            # one disposable project clone
./lair add repo example-api example-web
./lair add data ~/Downloads/paper.pdf  # ephemeral, read-only access
./lair get                             # list tracked work and outbox items
./lair get repo example-api            # review and import commits
```

Each launch claims the lowest available slot, opens the model/provider menu,
and starts the TUI. Containers disappear on exit. Every slot mounts the same
persistent default Hermes home, so sessions, memories, identity, skills, logs,
credentials, and configuration are shared. Pressing Enter at the model menu
selects DeepSeek V4 Flash through OpenRouter's Novita FP8 route.

The Tencent Hy3 preset is pinned to OpenRouter's DeepInfra FP8 route. Its
provider pricing is $0.14 per million input tokens, $0.58 per million output
tokens, and $0.035 per million cache-read tokens.

## Optional local models

The model menu keeps the cloud presets first and appends the declarative local
profiles from `local-models/profiles/`. Cloning this repository does not pull a
llama.cpp image or download model weights. Uninstalled local models are labeled
in the menu and require an explicit confirmation before setup downloads only
the selected model; there is deliberately no bulk-install command.

```bash
just local-models
just local-setup gemma-4-e4b
just local-setup qwen-3-6-35b
```

Local setup requires `jq`, `openssl`, rootless Podman, and NVIDIA CDI support.
It creates or validates an internal `hermes-llm` network, a Podman secret, one
model volume, and a stopped hardened llama.cpp backend. Model weights remain in
Podman volumes and are never stored in this Git repository. Cached weights are
verified and reused. Outdated Hermes-managed backend containers are disposable
and refreshed automatically; setup stops only when the expected container name
belongs to something Hermes does not manage.

Each tracked JSON profile contains only model metadata and inference arguments;
it cannot add host mounts, publish ports, or change the fixed container security
policy. Add or remove one JSON file to contribute a public model. Put private
profiles in the ignored `local-models.local/` directory; a matching local ID
overrides its tracked profile.

Tracked models let llama.cpp fit the largest native context that preserves a
512 MiB device-memory margin, using one inference slot with a 32k minimum.
Gemma's and Qwen's model weights are Q4-quantized; their independently growing
KV caches use Q8_0. The selected context depends on free GPU memory at load time
and is printed when the backend starts.

Normal, repository, and data launches can use local profiles. Multiple Hermes
slots may share the same local backend, but a different local model is refused
while one is reserved. The backend stops after the last matching Hermes session
ends and also unloads idle weights after 60 seconds. Local sessions use the
ordinary rootless Podman bridge for tool egress in addition to the internal
inference network, so they do not have normal mode's stricter `pasta` gateway
isolation. They still receive no host home, Podman socket, or unrelated mounts.

## Parallel-session safety

AI Lair uses one persistent Hermes home shared by multiple disposable
container slots. Slots are runtime capacity only: sessions, memories, identity,
skills, provider settings, and conversation history all belong to the shared
Hermes home. Consequently, `/resume` and session search see the same global
conversation history from every slot.

**Never open or resume the same conversation in two terminals at the same
time.** Running different conversations concurrently is supported; concurrently
writing to one conversation can interleave state unpredictably. A session sees
a snapshot of Hermes memory when it starts, so memory changes made by another
session may require starting a new session or reloading before they appear.

Legacy `slot-*` profiles created by older versions of this wrapper are left
untouched beneath `data/profiles/`, but new launches no longer use them.

`lair add repo` creates a disposable clone from
`~/projects/<name>` when one is missing. The primary checkout must be clean so
uncommitted work is never silently omitted. Existing disposable clones are
reused; starting Hermes never deletes them.

With one selected repository, Hermes sees it at:

```text
/workspace/repo
```

Hermes starts in that directory, so file search and terminal tools immediately
operate on the selected repository.

With multiple selected repositories, Hermes sees only those repositories at:

```text
/workspace/repos/example-api
/workspace/repos/example-web
```

Hermes starts in `/workspace/repos`, so both selected repositories are visible
to workspace-scoped tools. A read-only `AGENTS.md` at that container-only
workspace root tells Hermes to enumerate the selected child repositories before
claiming that one is missing.

The `repos/` parent directory itself is never mounted.

`lair add data` accepts files or directories, including paths with spaces. Only
the selected paths are mounted, read-only, beneath `/workspace/data`. Hermes
retains normal Internet access in this mode, so selected content may be sent to
remote services. Generated files belong in `/workspace/outbox`, which maps to
the host's `outbox/` directory. Repository and data mounts are intentionally
not combined.

## Review and bring work back

```bash
./lair get
./lair get repo example-api
./lair get repo example-api example-web
```

`lair get repo` preflights every named repository before changing anything. It:

- requires both disposable and primary checkouts to be clean;
- requires each primary checkout to be on a branch, not detached HEAD;
- shows the new commits and changed-file summary;
- asks for an explicit `IMPORT` confirmation;
- cherry-picks new disposable commits onto each primary's current branch;
- records an incremental marker so later imports include only newer commits.

The harness must commit useful work inside each disposable clone before import.
Disposable clones are retained after import.

## Interface and maintenance

Common configuration is available from:

```bash
just options
```

Slot launches always use the modern TUI. AI Lair configuration is versioned in
this repository. Runtime state, secrets, datasets, outputs, disposable clones,
slot reservations, and the separate upstream `src/` checkout are ignored.

## Project status

AI Lair is preparing for a v0.5 public preview. The sandbox policy,
disposable-clone workflow, capability-profile validation, and non-integration
tests are implemented. The source-pinned image/bootstrap path and clean-clone
instructions are also implemented but still require verification on a clean
supported host. CI runs the non-integration suite and ShellCheck; broader
portability and live Podman integration coverage remain on the
[roadmap](TODO.md).

The current implementation targets Linux, Bash 4+, rootless Podman with
`pasta`, Git, `just`, `jq`, OpenSSL, primary repositories beneath `~/projects`,
and OpenRouter.
Restricted analysis mode and the bundled local-model profiles additionally
assume NVIDIA CDI support.

NixOS is not currently a runtime requirement: no tracked file refers to NixOS
or `/etc/nixos`. A Nix flake or NixOS module could later provide a convenient,
optional way to install the prerequisites, but it should remain separate from
the portable shell-and-Podman implementation.

## Contributing and security

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md) for the
project's checks and security-boundary expectations. Report vulnerabilities
through the private process in [SECURITY.md](SECURITY.md), not through a public
issue containing sensitive details.

## License

AI Lair is available under the [MIT License](LICENSE).
