# Code review: capability profiles

Status: **changes requested**

Reviewed range: `hermes-base..177a9c4`

The direction is good: a small declarative capability vocabulary can make
sandbox policy easier to audit, test, and extend. The current implementation
is not ready to import because the profiles describe stronger guarantees than
the launcher enforces, and the branch does not pass its own basic checks.

## Blocking findings

### 1. The `justfile` does not parse

`justfile:30` contains an indented command without a recipe:

```text
./profile-read.sh validate || true
```

As a result, both `just --list` and `just test` fail before running anything.
Profile validation must be part of the `test` recipe and must not be suppressed
with `|| true`.

### 2. Every bundled capability profile fails validation

The `jq` expression in `profile-read.sh:55-59` changes context while checking
`.model`, then looks for `.model.type` beneath that changed context. Running:

```bash
./profile-read.sh validate
```

currently fails on the tracked profiles.

### 3. The schema is documentation, not enforcement

`validate_one` checks only a subset of `schema.json`. It does not enforce the
closed object shape, mount values, compute keys and types, label/description
types, or all model constraints. A profile with an extra top-level key,
`"repos": "ro"`, or `"gpu": "yes"` can pass once the model-expression bug is
fixed.

Use one canonical validation implementation and add negative tests proving
that every rejected shape in the schema is also rejected at runtime.

### 4. `--profile` collides with Hermes's existing CLI

`run.sh` consumes every `--profile` argument as a capability profile, but the
existing private `parallel-pick` recipe forwards `--profile` to Hermes to select
a Hermes home/profile. This change breaks that workflow.

Use an unambiguous wrapper option such as `--capability-profile`, or keep
capability selection entirely in an environment variable owned by the wrapper.

### 5. Profiles do not determine or constrain the resulting sandbox

Most declared fields are ignored:

- `mounts.repos`, `mounts.data`, and `mounts.outbox` do not generate or require
  mounts;
- `network: internet` does not reject conflicting analysis/local environment
  state;
- `network: llm-gateway` sets a flag but does not start the required gateway;
- `model.type: cloud` does not prevent `slot-run.sh` from supplying a local
  model through `HERMES_LOCAL_PROFILE`;
- `local-dual` has no independent enforcement;
- existing environment variables can still select capabilities that contradict
  the chosen profile.

Profiles are therefore labels over the existing mode branches, not an
enforcement boundary. The launcher must fail closed when requested inputs,
model selection, network mode, and the selected profile disagree.

### 6. The branch predates the file-tool safe-root fix

Primary `main` contains:

```text
6c35be8 fix: allow Hermes file tools in writable mounts
```

That commit dynamically sets `HERMES_WRITE_SAFE_ROOT` to `/opt/data`, only the
selected writable repository mounts, and `/workspace/outbox` when enabled.
Rebase or rebuild this work on top of that commit and preserve its regression
tests. Do not broaden the safe root to `/workspace`.

### 7. Security documentation overclaims current isolation

Revise these claims before publication:

- Slot reservations prevent container-name collisions, but sessions share
  `/opt/data`; they can interfere through configuration, credentials, memory,
  history, and other mutable Hermes state.
- Analysis mode says the agent never sees the injected API key, but
  `analysis.sh` reads `data/.env` while `run.sh` mounts all of `data/` at
  `/opt/data`. Hermes's file-tool denylist is defense in depth, not a security
  boundary, because the terminal can read mounted files.
- “Capability profiles as data (implemented)” is followed by text describing a
  planned evolution, and its examples do not match the tracked schema.

Either change the implementation so these claims become true or document the
actual boundary precisely.

## Required behavior

A capability profile should be an authorization policy, while command inputs
identify the concrete resources the user selected:

1. Parse and fully validate one profile before creating containers or changing
   runtime state.
2. Resolve explicit repository/data inputs using the existing path checks.
3. Reject inputs not authorized by the profile.
4. Derive mounts, network attachments, devices, model routing, secrets, and
   `HERMES_WRITE_SAFE_ROOT` deterministically from the validated combination.
5. Reject contradictory legacy environment variables when a capability profile
   is active.
6. Start and clean up required auxiliary services, or reject profiles that the
   selected entry point cannot orchestrate.
7. Preserve the legacy no-profile interface until it is deliberately removed.

## Minimum regression coverage

Add tests that run without downloading images or model weights:

- `just --list` and `just test` parse and succeed;
- all tracked profiles validate;
- unknown keys, wrong types, invalid mount modes, and invalid model/network
  combinations fail;
- the wrapper's capability option does not consume Hermes's `--profile`;
- `dev` produces only selected repository mounts, normal Internet networking,
  and matching safe-write roots;
- `data-science` produces read-only selected data, writable outbox, normal
  Internet networking, and no repository mounts;
- `analysis` cannot launch without its internal network and gateway lifecycle;
- local-model selection cannot contradict a cloud-only profile;
- unrelated repositories, host paths, the Podman socket, and read-only data
  never enter the writable allowlist.

Use a fake `podman` executable to capture and assert the final argument vector,
following `tests/run-safe-roots.sh`.

## Suggested repair sequence

1. Rebase the work onto current primary `main`, resolving conflicts in
   `run.sh`, `slot-run.sh`, `.gitignore`, `justfile`, and tests.
2. Restore a green baseline before adding behavior.
3. Rename the wrapper option and implement complete profile validation.
4. Make profiles authoritative and fail closed on contradictions.
5. Add argument-vector and negative validation tests.
6. Correct the design and implementation documents to match tested behavior.
7. Run `just test`, inspect the full diff, and only then import.

The profile JSON and documentation structure are useful starting points; the
policy translation should be rebuilt around explicit invariants rather than
patched onto the existing environment-variable branches.
