# Hermes sandbox

Rootless Podman wrapper for running Hermes without exposing the host home
directory, credentials, Podman socket, or unrelated project checkouts.

Run commands from this directory:

```bash
cd ~/sandboxes/hermes
just --list
```

## Everyday commands

```bash
just slots 4                          # allow up to four parallel Hermes sessions
just status                           # show running and available slots
just run                              # no project or data access
just run-repo sdk-rec                 # one disposable project clone
just run-repo sdk-rec habbit-track    # multiple disposable project clones
just run-data ~/Downloads/paper.pdf   # selected data, read-only, normal Internet
```

Each launch claims the lowest available slot, opens the model/provider menu,
and starts the TUI. Containers disappear on exit. Every slot mounts the same
persistent default Hermes home, so sessions, memories, identity, skills, logs,
credentials, and configuration are shared. Pressing Enter at the model menu
selects DeepSeek V4 Flash through OpenRouter's Novita FP8 route.

## Parallel-session safety

This sandbox uses one persistent Hermes home shared by multiple disposable
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

`run-repo` creates a disposable clone from
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
/workspace/repos/sdk-rec
/workspace/repos/habbit-track
```

Hermes starts in `/workspace/repos`, so both selected repositories are visible
to workspace-scoped tools. A read-only `AGENTS.md` at that container-only
workspace root tells Hermes to enumerate the selected child repositories before
claiming that one is missing.

The `repos/` parent directory itself is never mounted.

`run-data` accepts files or directories, including paths with spaces. Only the
selected paths are mounted, read-only, beneath `/workspace/data`. Hermes retains
normal Internet access in this mode, so selected content may be sent to remote
services. Generated files belong in `/workspace/outbox`, which maps to the
host's `outbox/` directory. Repository and data mounts are intentionally not
combined.

## Review and bring work back

```bash
just get-repo sdk-rec
just get-repo sdk-rec habbit-track
```

`get-repo` preflights every named repository before changing anything. It:

- requires both disposable and primary checkouts to be clean;
- requires each primary checkout to be on a branch, not detached HEAD;
- shows the new commits and changed-file summary;
- asks for an explicit `IMPORT` confirmation;
- cherry-picks new disposable commits onto each primary's current branch;
- records an incremental marker so later imports include only newer commits.

Hermes must commit useful work inside each disposable clone before import.
Disposable clones are retained after import.

## Interface and maintenance

Common configuration is available from:

```bash
just options
```

Slot launches always use the modern TUI. Sandbox configuration is versioned in
this repository. Runtime state, secrets, datasets, outputs, disposable clones,
slot reservations, and the separate upstream `src/` checkout are ignored.
