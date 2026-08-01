# Local model profiles

Each JSON file beneath `profiles/` is a non-executable recipe for one tested
llama.cpp backend. Adding or removing a model is a one-file change suitable for
review in a pull request. Profiles select model and inference parameters only;
the launcher owns Podman networks, mounts, devices, ports, and hardening.

The included profiles were tested on an NVIDIA RTX 5070 Laptop GPU with 8 GiB
VRAM. They are examples, not universal defaults. Cloning this repository never
downloads their images or weights.

The `context` object makes allocation policy explicit. Fit mode starts at the
model's native maximum and lets llama.cpp reduce it until it fits available
device memory:

```json
"context": {
  "mode": "fit",
  "target_free_mib": 512,
  "minimum_tokens": 32768
}
```

Fixed mode is available for testing or hardware-specific overrides:

```json
"context": { "mode": "fixed", "tokens": 65536 }
```

In fit mode, `target_free_mib` is the free-memory margin requested per GPU and
`minimum_tokens` is the lowest useful context llama.cpp may select. Hermes
prints the selected per-slot context when the backend starts.

For private changes, create `local-models.local/<id>.json` using the same schema.
A local file with the same ID replaces the tracked profile and is ignored by
Git. Validate all effective profiles with:

```bash
./local-models.sh validate
```

Reserved llama.cpp arguments include model download, networking, API-key,
offline, sleep, Web UI, agent-tool, and context-policy flags. Those boundaries
are fixed by the trusted launcher and cannot be changed through `llama_args`.
