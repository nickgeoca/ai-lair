# Open-source release plan

This document is the working plan for publishing AI Lair as an
experimental public project without making completion of every planned feature
a prerequisite. It complements `TODO.md`, which remains the product roadmap.

## Objective

Publish a useful, honest v0.5 public preview that:

- has one documented and tested happy path;
- protects credentials, conversations, private repositories, and host data;
- makes the security model and its limitations understandable;
- gives prospective contributors bounded work they can pick up;
- treats durable local-model conversation caching as an integration track, not
  as a release blocker;
- does not imply production readiness or a support commitment.

The release should help people use and improve the existing sandbox. It should
not turn the project into a new general-purpose inference framework.

## Release posture

Use these expectations consistently in the README, release notes, and project
description:

- Status: experimental public preview.
- Target audience: technical Linux users comfortable with rootless Podman.
- Supported path: the exact distribution, Podman, GPU, and networking
  combination verified before release.
- Compatibility elsewhere: welcome, but not yet guaranteed.
- Security claim: isolation properties are limited to those documented and
  tested. Defense-in-depth measures are not described as hard boundaries.
- Support: best effort; issues and contributions are welcome.

## Publication and release gates

The source may be published as an explicitly experimental preview after the
history, licensing, documentation, and project-hygiene checks are complete and
any missing live verification is disclosed. Do not tag a versioned v0.5
release or describe the runtime path as supported until every blocking item
below is complete.

The audit performed before the initial source preview is recorded in
`docs/publication-audit.md`.

### 1. Repository and history safety audit

- [x] Confirm `git status --short` contains only intentional changes.
- [x] Review every tracked path with `git ls-files`.
- [x] Scan the complete Git history, all refs, and large objects for:
  - API keys, tokens, passwords, and private endpoints;
  - `.env` contents and Podman secrets;
  - Hermes conversations, memories, logs, and pasted material;
  - private repository names, remotes, source code, and issue content;
  - personal filesystem paths, hostnames, usernames, email addresses, and IPs;
  - documents or datasets that cannot be redistributed.
- [x] Use a maintained secret scanner against the full history. Record the
  scanner and version used in the release notes or audit log.
- [x] Manually inspect suspicious findings; do not rely only on automated
  scanning.
- [x] Confirm the Git author name and email in every published commit are
  intended to be public.
- [x] Confirm ignored runtime locations have never been tracked, especially
  `data/`, `repos/`, `outbox/`, `local-models.local/`, model files, cache
  volumes, generated manifests, and backup configuration files.
- [ ] If any credential ever entered history, rotate it first. Removing the
  current file is not sufficient.
- [ ] If private material entered history, rewrite the affected history before
  publication and repeat the complete audit afterward.

Suggested read-only inventory commands:

```bash
git status --short
git ls-files
git log --all --format='%h %an <%ae> %ad %s' --date=short
git rev-list --objects --all
git remote -v
```

Do not paste raw secret-scanner findings into public issues or logs.

### 2. Licensing and provenance

- [ ] Confirm the existing MIT license is the intended project license.
- [ ] Identify copied, adapted, vendored, or generated material and record its
  provenance.
- [ ] Confirm third-party notices and licenses are compatible with publication.
- [ ] Confirm container images, image patches, model profiles, examples, and
  documentation can be redistributed in their proposed form.
- [ ] Add attribution or notices where required.

### 3. Reproducible happy path

- [ ] Start from a clean clone on a supported machine.
- [ ] Follow only the public documentation.
- [ ] Prepare or obtain the pinned Hermes Agent image reproducibly.
- [ ] Run the dependency/host preflight.
- [ ] Configure OpenRouter without exposing the key.
- [ ] Launch one ordinary session successfully.
- [ ] Launch one disposable-repository session successfully.
- [ ] Run the complete non-integration test suite.
- [ ] Install and run one local llama.cpp profile, if local inference is
  included in the v0.5 supported path.
- [ ] Record exact supported versions: OS, kernel, Podman, NVIDIA driver/CDI,
  `pasta`, `jq`, and other required host tools.

### 4. Documentation check

- [ ] README explains the problem, intended user, prerequisites, installation,
  first launch, cleanup, and known limitations.
- [ ] The quickstart works from a clean clone without undocumented local state.
- [ ] `docs/design.md` accurately describes trust boundaries and network paths.
- [ ] `docs/implementation.md` matches the current scripts and container
  arguments.
- [ ] `TODO.md` clearly separates release blockers from later work.
- [ ] Troubleshooting covers missing images, rootless Podman, `pasta`, NVIDIA
  CDI, unavailable GPU devices, and local-model setup failures.
- [ ] Commands identify whether they create, stop, remove, or retain resources.

### 5. Project hygiene

- [x] Add a concise `CONTRIBUTING.md`.
- [x] Add a security reporting policy appropriate for an experimental project.
- [x] Add issue templates for bugs, portability reports, and feature proposals.
- [x] Add a pull-request template with testing and security-impact fields.
- [x] Configure CI to run `just test`.
- [x] Review ShellCheck findings before making ShellCheck a required check.
- [ ] Decide whether to enable GitHub Discussions.
- [ ] Create labels: `good first issue`, `help wanted`, `security`,
  `portability`, `local-model`, `caching`, and `documentation`.

## Release sequence

### Phase A: Freeze the public surface

1. Choose the v0.5 supported host configuration.
2. Decide whether local inference is supported or explicitly experimental.
3. Complete the reproducible Hermes image path.
4. Complete `just doctor` or `just bootstrap`.
5. Avoid unrelated feature work until the clean-clone path passes.

### Phase B: Audit

1. Back up the private working repository.
2. Complete the history safety and licensing audits.
3. Rotate or remove anything questionable.
4. Repeat the audit after any history rewrite.
5. Have another person review the publication candidate if possible.

### Phase C: Contributor preparation

1. Add the contribution and security documents.
2. File the initial bounded issues listed below.
3. Mark dependencies and acceptance criteria on each issue.
4. Confirm a new contributor can run tests without private infrastructure.

### Phase D: Publish

1. Create the public repository without pushing automatically from an
   unaudited checkout.
2. Verify the exact destination and visibility.
3. Attach the public remote only after the audit gate passes.
4. Push the audited branch and tags.
5. Verify the public file list and rendered README while logged out.
6. Create a v0.5 preview release with supported versions and known limitations.

### Phase E: Announce and observe

1. Share a short demonstration and the concrete problem it solves.
2. Post where relevant users already gather: Hermes Agent, llama.cpp, and
   local-inference communities.
3. Link directly to bounded `help wanted` issues.
4. Triage early installation reports into documentation, portability, or bugs.
5. Do not promise every requested platform or feature.

## Initial contributor issues

Each issue should include motivation, non-goals, affected files, security
constraints, acceptance criteria, and a test plan.

### Release engineering

1. **Reproducible Hermes Agent image**
   - Produce the pinned image from a clean clone or consume an upstream image by
     digest.
   - Document provenance and update policy.

2. **Add `just doctor`**
   - Check required commands, rootless Podman, networking, images, runtime
     directories, and optional NVIDIA CDI.
   - Make checks read-only and provide actionable remediation.

3. **Continuous integration**
   - Run `just test` on pull requests.
   - Keep host-specific Podman/GPU integration tests separate initially.

4. **Clean-clone quickstart verification**
   - Test the README on a supported host and report every implicit dependency.

### Portability and security

5. **Configurable primary-checkout root**
   - Remove the assumption that primary projects live beneath `~/projects`.

6. **Local-model capability profile**
   - Replace the current capability-policy bypass with an explicit local-model
     policy and tests.

7. **Optional GPU behavior**
   - Improve diagnostics and supported behavior when NVIDIA CDI is absent.

8. **Podman isolation integration tests**
   - Test mounts, host-service isolation, analysis egress restrictions, and
     cleanup against real containers.

### Local conversation caching

9. **Benchmark current llama.cpp prompt-cache behavior**
   - Measure cold and warm time-to-first-token across turns, separate
     conversations, idle sleep, container stop, and model switching.
   - Record cache-hit evidence from server logs or metrics.

10. **Evaluate CachyLLama on NVIDIA/CUDA**
    - Treat [CachyLLama](https://github.com/fewtarius/CachyLlama) as an
      integration candidate rather than reimplementing its SSD cache.
    - Test the exact Gemma 4 and Qwen3.6 profiles used by this project.
    - Verify OpenAI-compatible chat and tool calling, cache correctness,
      restart restoration, disk growth, and failure behavior.
    - Do not replace the default backend until the fork, build provenance, and
      update strategy have been reviewed.

11. **Package an experimental cached backend**
    - If the evaluation succeeds, build a pinned CUDA container.
    - Add a dedicated persistent, writable cache volume without weakening the
      read-only model or root filesystem policy.
    - Keep the official upstream llama.cpp backend available as the stable
      option.

12. **Bound persistent cache storage**
    - Define maximum conversations and maximum bytes.
    - Prefer oldest-conversation eviction.
    - Determine whether exact time-based conversation expiry is available or
      requires a small external cleanup policy.

13. **Cache observability**
    - Surface cold, RAM-hit, and disk-hit behavior without logging prompt
      content.
    - Report cache size and eviction counts.

## Caching decision record

The current position is:

- Do not build a new general-purpose KV-cache orchestration framework.
- Use upstream llama.cpp RAM prompt caching for the default implementation.
- Consider a longer but bounded idle window only after measuring its resource
  effect.
- Evaluate existing SSD-backed implementations before writing disk-cache code.
- CachyLLama is the closest known implementation, but it is new and primarily
  developed around AMD APU hardware; NVIDIA/CUDA behavior must be verified.
- LMCache is more mature but targets vLLM and SGLang rather than llama.cpp, so
  adopting it would change the inference stack substantially.
- Persistent KV state is an acceleration layer. Hermes conversation transcripts
  remain the source of truth and must work correctly after a cache miss.
- Cache contents may encode private prompts and tool output. Persistent cache
  storage must receive the same privacy treatment as conversation data.

### Success criteria for a cached backend

- A conversation resumed after a backend restart produces a verified cache hit.
- Two or more conversations can alternate without corrupting one another.
- A cache miss falls back safely to normal prompt processing.
- Changing the model, model digest, chat template, or incompatible inference
  configuration cannot restore stale state.
- Cache storage is private to the host user and is never mounted into Hermes
  session containers.
- Disk use is bounded and observable.
- Eviction never deletes the authoritative Hermes transcript.
- The feature can be disabled without changing ordinary local inference.

## Suggested v0.5 release notes

The release notes should state:

- this is an experimental public preview;
- the exact supported host configuration;
- which paths have been tested from a clean clone;
- known security and portability limitations;
- that local model weights persist but inference caches are currently
  best-effort and non-authoritative;
- that persistent conversation acceleration is a contributor integration
  track, not a completed guarantee;
- where to report security concerns and ordinary bugs.

## Definition of done

The project is ready for public preview when:

- all publication gates are complete;
- a clean-clone happy path succeeds;
- tests pass in the documented environment;
- the full-history audit is complete and recorded privately;
- initial contributor issues are public and bounded;
- the README makes experimental status and limitations unmistakable;
- publishing does not depend on completing persistent conversation caching.
