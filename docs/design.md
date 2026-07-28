# Hermes Sandbox — Design

## What this is

A **capability gate** for AI coding agents. The user declares what an agent
gets — which files, what network access, which compute — and the sandbox
enforces that boundary. Everything else is invisible.

The agent is Hermes. It has a shell, file tools, and internet access. The
sandbox defines the *contract* between the agent and the host.

## Threat model

### What we defend against

| Threat | Mechanism |
|---|---|
| Agent reads or mutates host files outside its workspace | Mount allowlist — only explicitly selected paths are visible |
| Agent reads host secrets (SSH keys, `.env`, browser data) | Host home directory is never mounted |
| Agent writes to primary project checkouts | Agent operates on disposable Git clones; work crosses the boundary only through human-reviewed import |
| Agent exfiltrates data to arbitrary internet hosts | Normal mode has internet by design (the agent needs it); analysis mode blocks all non-LLM traffic |
| Agent reaches host services (database, dev server, Podman socket) | `pasta:--no-map-gw` blocks loopback and gateway routes |
| Agent escalates privileges inside the container | `no-new-privileges` blocks setuid; `--cap-drop=ALL` on hardened containers |
| Container escape → host compromise | Rootless Podman with user namespace remapping (`uid=10000`); escape lands in unprivileged user namespace |
| Malicious prompt injection in the LLM gateway | nginx only proxies two whitelisted API paths; all others return 403 |
| One agent session interferes with another | Slot system with flock-based reservation; each session is an isolated container |

### What we do NOT defend against

- A compromised Hermes Agent image itself (supply chain)
- GPU side-channel attacks
- An agent exfiltrating data over the internet in normal mode (the agent *needs* internet to function; this is a policy choice, not a bug)
- A targeted container-escape exploit against the Linux kernel (use a VM if this is in your threat model)
- The user mounting sensitive paths that the agent shouldn't see (the allowlist is user-declared)

## Architecture

### Capability model

Every sandbox session is defined by a **capability profile** — a declarative
set of things the agent can access. Profiles are data, not code.

```
Capability Profile
├── files:      which host paths are mounted (allowlist) + read/write mode
├── network:    internet | llm-gateway-only | host-blocked
├── compute:    GPU (for local models) | CPU-only
└── identity:   which Hermes home to use (shared default, or named profile)
```

The launcher validates the profile, resolves any disposable clones, starts
auxiliary services (LLM gateway, local model backend), and translates the
profile into Podman runtime flags.

### Component diagram

```
┌─────────────────────────────────────────────────────────┐
│  Host                                                   │
│                                                         │
│  ┌───────────┐   ┌───────────┐   ┌───────────────┐     │
│  │ ~/projects │   │ ~/data    │   │ outbox/       │     │
│  │ (primary)  │   │ (datasets)│   │ (results)     │     │
│  └─────┬─────┘   └─────┬─────┘   └───────┬───────┘     │
│        │ clone (ro)     │ mount (ro)      │ mount (rw)  │
│        ▼                ▼                 ▼             │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Hermes Sandbox Container (rootless Podman)     │    │
│  │  uid=10000  no-new-privileges  pids-limit=2048 │    │
│  │                                                 │    │
│  │  /workspace/repo      (disposable clone, rw)    │    │
│  │  /workspace/data      (selected files, ro)      │    │
│  │  /workspace/outbox    (results, rw)             │    │
│  │  /opt/data            (Hermes home — persistent)│    │
│  │                                                 │    │
│  │  ┌────────────────┐                            │    │
│  │  │ Hermes Agent   │                            │    │
│  │  │ (shell, files, │                            │    │
│  │  │  web, tools)   │                            │    │
│  │  └───────┬────────┘                            │    │
│  └──────────┼─────────────────────────────────────┘    │
│             │ HTTP (OpenAI-compatible API)              │
│             ▼                                          │
│  ┌──────────────────────┐    ┌────────────────────┐    │
│  │ Local llama.cpp      │    │ OpenRouter (cloud) │    │
│  │ (GPU, internal net,  │    │ (internet, normal  │    │
│  │  offline, read-only) │    │  or gateway-proxied│    │
│  └──────────────────────┘    │  in analysis mode) │    │
│                              └────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

### Network isolation tiers

| Mode | Internet | Host services | LLM API | Use case |
|---|---|---|---|---|
| **Normal** | Yes | Blocked (`--no-map-gw`) | Yes | Everyday dev, data analysis |
| **Local LLM** | Yes (bridge) | Yes (needs llama.cpp on host) | Local only | Offline-capable inference |
| **Analysis** | No (`--internal` net) | No | Gateway only (nginx proxy) | Sensitive data, air-gapped reasoning |

The analysis mode gateway is an nginx container that:

- Accepts only `GET /api/v1/models` and `POST /api/v1/chat/completions`
- Returns 403 on all other paths
- Injects the API key server-side (the agent never sees it)
- Runs read-only, `--cap-drop=ALL`, memory-capped at 128 MB
- Pinned by SHA256 digest

### Disposable clone workflow

```
Primary checkout (~/projects/foo)
    │
    │ git clone --no-hardlinks (one-time, clean state required)
    ▼
Disposable clone (repos/foo)
    │
    │ Agent works here: edits, commits
    │ Agent cannot see ~/projects or any other clone
    │
    ▼
Human runs: just get-repo foo
    ├── Preflight: both checkouts clean? Primary on a branch?
    ├── Review: shows commits, changed files
    ├── Confirm: explicit "IMPORT" prompt
    └── Import: cherry-picks new commits onto primary
```

Work only crosses the boundary through an explicit, human-reviewed step.

## Why Podman and not a VM

| | Rootless Podman | KVM VM | Firecracker |
|---|---|---|---|
| Isolation | Namespaces (shared kernel) | Hardware boundary | Hardware boundary |
| GPU sharing | CDI — trivial | Consumer cards: none or PCIe passthrough (all-or-nothing) | No GPU support |
| Startup | < 1s | 5–30s | ~125ms |
| File sharing | Bind mounts — instant | virtio-fs (good), 9p (slow) | virtio-fs |
| Attack surface | Linux kernel | Hypervisor + guest kernel | Firecracker (~50k loc) + guest kernel |
| Operational complexity | Low | Medium | High (build guest kernel, rootfs, orchestration) |

Podman is the right choice for the stated threat model. The agent is an
AI-assisted tool, not untrusted tenant code. Kernel escape CVEs exist but
are rare and targeted; the layered mitigations (rootless + user remap +
no-new-privileges + cap-drop) handle the realistic threats.

If your threat model includes a motivated attacker with a container escape
zero-day, run the sandbox inside a VM. The design intentionally keeps the
policy layer (capability profiles) separable from the runtime so this is
possible without architectural changes.

## Design principles

1. **Allowlist, not denylist.** The agent gets exactly what the profile declares.
   Everything else is invisible by default.

2. **Policy as data, not code.** Capability profiles are declarative.
   The launcher is a policy engine that translates profiles to runtime flags.

3. **Work crosses the boundary through human review.** The disposable clone
   workflow and `outbox/` directory are explicit one-way doors.

4. **Defense in depth.** No single isolation mechanism is trusted alone.
   Network isolation + mount isolation + user namespace remapping +
   capability dropping + disposable clones.

5. **Secure by default, opt-in to less security.** Normal mode blocks host
   services. Local LLM mode requires an explicit opt-in that weakens
   host isolation. Analysis mode is even tighter than default.

6. **The LLM is not the threat.** The inference backend runs read-only,
   offline, with no tools. The agent is the threat. Contain the agent.
