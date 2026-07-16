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
just run                              # Hermes without project or dataset access
just repo-run sdk-rec                 # one project, normal Internet access
just repo-run sdk-rec habbit-track    # selected projects, normal Internet access
just analysis sdk-rec                 # project + datasets + outbox + GPU
just analysis sdk-rec habbit-track    # selected projects in restricted analysis
just analysis                         # restricted analysis without a project
just analysis-check                   # verify the restricted network and gateway
```

`repo-run` and `analysis` create a disposable clone from
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

## Review and bring work back

```bash
just repo-check                         # summarize every disposable clone
just repo-check sdk-rec                 # summarize one clone
just repo-check sdk-rec habbit-track    # summarize selected clones
```

For each clone, `repo-check` shows:

- uncommitted and untracked files;
- files changed since the clone's `hermes-base` commit;
- commits Hermes created;
- how many commits the primary and disposable checkouts have made since their
  shared base.

Commit useful work inside the disposable clone, then import one commit at a
time into the clean primary checkout:

```bash
just repo-import sdk-rec                # import disposable HEAD
just repo-import sdk-rec abc1234        # import a specific commit
```

When finished:

```bash
just repo-remove sdk-rec
```

Removal displays clone-only work and requires typing `REMOVE`. Check or import
anything valuable first.

## Interface and maintenance

Make the modern TUI the persistent default:

```bash
just _sandbox "hermes config set display.interface tui"
```

Use `--cli` directly for a one-off classic session. Sandbox configuration is
versioned in this repository. Runtime state, secrets, datasets, outputs,
disposable clones, and the separate upstream `src/` checkout are ignored.
