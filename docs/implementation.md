# Hermes Sandbox — Implementation

## File map

```
sandbox/
├── README.md                      # User-facing: what, why, quickstart
├── docs/
│   ├── design.md                  # This document's sibling — architecture & threat model
│   └── implementation.md          # This file
│
├── justfile                       # Task runner (just run, just run-repo, just test, …)
│
├── run.sh                         # ██████████████████████████████████████
├── slot-run.sh                    # ███  LAUNCHER (policy engine)    ███
├── analysis.sh                    # ██████████████████████████████████████
├── get-repo.sh                    # Import workflow (disposable → primary)
├── local-models.sh                # Lifecycle manager for llama.cpp backends
│
├── gateway/
│   └── openrouter.conf.template   # nginx config for analysis-mode LLM proxy
│
├── profiles/
│   ├── default.conf               # Delegation profile: 3 agents × 50 iterations
│   └── flat.conf                  # Delegation profile: 5 agents × 30 iterations
│
├── local-models/
│   ├── README.md                  # Contribution guide for model profiles
│   ├── profile.schema.json        # JSON Schema for model profiles
│   └── profiles/
│       ├── gemma-4-e4b.json       # Example profile: Gemma 4 E4B Q4_0
│       └── qwen-3-6-35b.json      # Example profile: Qwen3.6 35B-A3B Q4_K_M
│
├── workspace/
│   └── AGENTS.md                  # Injected into multi-repo sessions
│
├── tests/
│   └── local-models.sh            # Profile validation and override tests
│
├── data/                          # Runtime state (gitignored)
│   ├── .env                       # API keys (0600, never committed)
│   ├── config.yaml                # Hermes config (shared across slots)
│   ├── slots/                     # Slot reservations and state
│   └── …
│
└── repos/                         # Disposable clones (gitignored)
    ├── project-a/                 # cloned from ~/projects/project-a
    └── …
```

## Component breakdown

### 1. Launcher (`run.sh`, `slot-run.sh`, `analysis.sh`)

These three files form the policy engine. They translate user intent into
Podman invocations with specific security properties.

**`run.sh`** — Low-level launcher. Takes environment variables as its API:

| Variable | Purpose |
|---|---|
| `HERMES_REPOS` | Space-separated repo names to mount as disposable clones |
| `HERMES_DATA_MANIFEST` | Path to a file listing host paths to mount read-only |
| `HERMES_ANALYSIS` | If `1`, join the `hermes-analysis` internal network (no internet) |
| `HERMES_LOCAL_LLM` | If `1`, drop `--no-map-gw` so the container can reach a host inference server |
| `HERMES_LOCAL_PROFILE` | Catalog model ID that drives the container/network/secret setup |
| `HERMES_CONTAINER_NAME` | Override the default container name (used by slot system) |

Security invariants it enforces:

- Repository names are validated against `[A-Za-z0-9._-]` (no path traversal)
- Data manifest paths are resolved with `realpath -e` and validated for existence
- Repository and data mounts are mutually exclusive (prevents accidental cross-contamination)
- Only the explicitly selected repos/data paths are mounted — never a parent directory
- The host home directory, `/etc`, `/proc`, `/sys`, `/dev` are never mounted

**`slot-run.sh`** — Session manager. Adds:

- Slot reservation via flock on `data/slots/.lock`
- Model picker menu (cloud presets + discovered local profiles)
- Lifecycle: claims slot → picks model → launches → releases slot on exit
- Max 16 slots, configurable via `just slots N`

**`analysis.sh`** — Restricted analysis mode. Orchestrates:

1. Creates `hermes-analysis` internal Podman network (once, reused)
2. Starts the nginx LLM gateway container (pinned image, read-only rootfs)
3. Waits for gateway health check
4. Runs `run.sh` with `HERMES_ANALYSIS=1`
5. On exit, stops and removes the gateway container

### 2. Gateway (`gateway/openrouter.conf.template`)

An nginx config that acts as an LLM API proxy with endpoint allowlisting.
Rendered by the nginx image's `envsubst` at container start.

Security properties:

- Only `GET /api/v1/models` and `POST /api/v1/chat/completions` are proxied
- All other paths return 403
- `OPENROUTER_API_KEY` is injected via envsubst (read from `data/.env`; the agent's file tools have it on a denylist, but the terminal can read mounted files — this is defense in depth)
- `proxy_buffering off` for streaming responses
- `proxy_read_timeout 1800s` for long generations

Container hardening in `analysis.sh`:

```
--read-only                    # rootfs is immutable
--cap-drop=ALL --cap-add=CHOWN,SETGID,SETUID  # minimal caps for nginx user switch
--security-opt=no-new-privileges
--pids-limit=128
--memory=128m --cpus=1
--tmpfs /etc/nginx/conf.d:rw,noexec,nosuid,nodev,size=1m
--tmpfs /var/cache/nginx:rw,noexec,nosuid,nodev,size=16m
--tmpfs /var/run:rw,noexec,nosuid,nodev,size=1m
--tmpfs /tmp:rw,noexec,nosuid,nodev,size=1m
```

Verification: `analysis.sh --check` runs a Python script inside the Hermes
image on the analysis network that confirms:

- Gateway health endpoint returns 204
- Gateway proxies `/api/v1/models` (authenticated)
- Gateway returns 403 on `/forbidden`
- DNS resolution of external hosts fails
- TCP connections to external IPs fail

### 3. Disposable clone workflow (`get-repo.sh`)

The import pipeline that moves agent work from the sandbox back to the host.

```
get-repo.sh my-project
    │
    ├── Validate both disposable (repos/my-project) and primary (~/projects/my-project)
    │   are clean and on branches
    │
    ├── Show diffstat: git log --oneline hermes-base..HEAD
    │
    ├── Prompt "Type IMPORT to confirm"
    │
    ├── git fetch from disposable clone into primary
    ├── git cherry-pick FETCH_HEAD
    │
    └── Update hermes-base tag to mark imported commits
```

The `hermes-base` tag in the disposable clone tracks which commits have been
imported. Subsequent imports only show/import newer commits.

Clone creation (`justfile _repo-create`):
- Validates the primary checkout is clean (no uncommitted work silently omitted)
- `git clone --no-hardlinks` (no hardlink sharing — keeps clones truly separate)
- Removes origin remote from the clone (prevents accidental push)
- Tags HEAD as `hermes-base`

### 4. Local model manager (`local-models.sh`)

Lifecycle manager for declarative llama.cpp backends. Each model is defined
by a JSON profile that follows `profile.schema.json`.

**Profile validation** (`validate_profile`):
- All required fields present, no extras
- `id` matches filename, matches `[a-z0-9][a-z0-9-]{0,62}` pattern
- `image` is pinned by SHA256 digest
- `container`, `volume`, `secret` names match a safe pattern
- `llama_args` is an array of strings — no newlines, no tabs
- Reserved args (`--hf-repo`, `--host`, `--port`, `--api-key`, `--offline`, `--webui`, `--agent`) are rejected (the launcher owns these)

**Container compatibility check** (`container_compatible`):
- Validates an existing container against its profile using `podman inspect`
- Checks: image, args, read-only rootfs, pids limit, security opts, mount destinations, secret presence, network membership, port bindings (must be none), GPU device presence

**Backend lifecycle**:
```
acquire(profile, session, pid)
    ├── Flock reservation directory
    ├── Check: no other profile already reserved by a different session
    ├── Stop any stale backends for other profiles
    ├── Write reservation file
    ├── podman start (or reuse if already running)
    ├── Wait for /health (up to 900s)
    └── Unlock

release(profile, session)
    ├── Flock reservation directory
    ├── Remove reservation file
    ├── If no other sessions reserve this profile → podman stop
    └── Idle timeout: --sleep-idle-seconds 60 in llama.cpp args
```

**Setup** (`setup_profile`):
1. Validate profile
2. Ensure internal network (`hermes-llm`)
3. Ensure API key secret (`openssl rand -hex 32 | podman secret create`)
4. Pull llama.cpp image (pinned by SHA256)
5. Create model volume
6. Run download container (pasta-only network, downloads GGUF from HuggingFace)
7. Wait for `/health` (model loaded into VRAM, cache populated)
8. Stop download container
9. Create stopped backend container (read-only, offline, internal network, GPU)

**Profile override**: Profiles in `local-models.local/` override tracked
profiles with matching IDs. The `.gitignore` ignores `local-models.local/`.

### 5. Profiles (`profiles/`)

Currently delegation profiles only. Example:

```
# profiles/flat.conf
max_spawn_depth=1
max_concurrent_children=5
max_iterations=30
```

Applied via `just delegation flat` which reads the file and calls
`hermes config set delegation.<key> <value>` for each line.

### 6. Security properties of the Hermes container itself

Applied in `run.sh` for every session:

```
--userns=keep-id:uid=10000,gid=10000
    Agent runs as uid 10000 inside the container.
    On the host, this maps to the user's real uid (rootless).
    An escape lands in an unprivileged user namespace.

--security-opt=no-new-privileges
    setuid binaries cannot gain privileges.
    Even if the agent writes and executes a setuid binary, it won't work.

--pids-limit=2048
    Prevents fork bombs from exhausting host PID space.

--network=pasta:--no-map-gw   (normal mode)
    Own network namespace. Internet works. Host services unreachable.
    127.0.0.1 inside the container is the container's loopback, not the host's.

--network=podman --network=hermes-llm   (local model mode)
    Podman bridge for tool egress. Internal network for llama.cpp.
    Slightly weaker than normal mode — host services are reachable via bridge.

--network=hermes-analysis   (analysis mode)
    Internal-only network. Only the nginx gateway is reachable.
    No internet, no host services.
```

## State management

### What persists across sessions

Everything under `data/` — the shared Hermes home:

```
data/
├── .env                  # API keys (chmod 600)
├── config.yaml           # Hermes configuration
├── sessions.db           # Conversation history
├── memories.db           # Persistent memory
├── skills/               # Custom skills
├── logs/                 # Session logs
└── slots/                # Slot state (reservation files, config)
```

This directory is bind-mounted to `/opt/data` inside every container.
Multiple slots share this state — sessions, memories, and skills are global.

### What is ephemeral

- The container itself (`--rm` flag) — destroyed on exit
- The gateway container (`trap cleanup EXIT`)
- The cloned repos persist until explicitly deleted with `just repo-remove`

### What is gitignored

The `.gitignore` is an allowlist — everything is ignored by default (`/*`).
Only explicitly reviewed files are un-ignored. All runtime state (`data/`,
`repos/`, `outbox/`) is correctly excluded.

## Capability profiles as data (work in progress)

Capability profiles are declarative JSON files in `profiles/capabilities/`.
Currently `dev`, `data-science`, and `analysis` profiles are defined and
validated, and the launcher in `run.sh` enforces mounts, network, model, and
compute constraints when a profile is active via `--capability-profile`.
Full enforcement of all schema constraints is still being built out.

```json
{
  "id": "dev",
  "label": "Development — internet access",
  "description": "Work on code with full internet. Repos mounted read-write, results land in outbox/. Host services blocked.",
  "network": "internet",
  "mounts": {
    "repos": "rw",
    "outbox": "rw"
  },
  "model": {
    "type": "cloud"
  }
}
```

```json
{
  "id": "analysis",
  "label": "Restricted analysis — no internet",
  "description": "Work on sensitive data with NO internet access. Only the LLM API gateway is reachable. Datasets mounted read-only, results land in outbox/.",
  "network": "llm-gateway",
  "mounts": {
    "datasets": "ro",
    "outbox": "rw"
  },
  "compute": {
    "gpu": true
  },
  "model": {
    "type": "cloud"
  }
}
```

Profiles are validated by `profile-read.sh` against the constraints in
`profiles/capabilities/schema.json`. The launcher reads a profile, validates
it, and generates Podman flags deterministically. Profiles are data —
auditable, diffable, shareable. New modes are new profile files, not new
shell branches.

## Cross-cutting concerns

### Error handling

All shell scripts use `set -euo pipefail`. Failures are explicit — no silent
fallthrough. Validation happens early (profile parsing, repo name checks,
network existence, secret presence) before any containers are created.

### Testing

`just test` runs:
1. `bash -n` syntax checks on all `.sh` files
2. `profile-read.sh validate` — validates all capability profiles against the JSON schema
3. `tests/local-models.sh` — profile validation, override behavior, reserved argument rejection, safety checks
4. `local-models.sh validate` — validates all effective local-model profiles against their JSON schema

No integration tests yet (requires a running Podman environment).

### Portability assumptions

- Linux (kernel 5.x+)
- Bash 5.x
- Rootless Podman with `pasta` networking
- Git
- `just` command runner
- `jq` (for local model features)
- `openssl` (for local model secrets)
- OpenRouter (cloud LLM provider)
- NVIDIA GPU + CDI (for local models)
- Primary repositories under `~/projects/`

The README calls out that these need to be made configurable before
wider distribution.

### NixOS integration (planned)

A Nix flake would:

- Declare Podman, just, jq, openssl as build inputs
- Build the Hermes agent image as a Nix derivation (reproducible)
- Provide `nix run .#sandbox -- --profile dev --repo my-project`
- Optionally manage the Podman networks and systemd services for persistent components

The flake is packaging — it doesn't replace Podman as the isolation layer.
It makes the existing shell scripts reproducible and dependency-declared.
