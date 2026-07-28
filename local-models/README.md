# Local model profiles

Each JSON file beneath `profiles/` is a non-executable recipe for one tested
llama.cpp backend. Adding or removing a model is a one-file change suitable for
review in a pull request. Profiles select model and inference parameters only;
the launcher owns Podman networks, mounts, devices, ports, and hardening.

The included profiles were tested on an NVIDIA RTX 5070 Laptop GPU with 8 GiB
VRAM. They are examples, not universal defaults. Cloning this repository never
downloads their images or weights.

For private changes, create `local-models.local/<id>.json` using the same schema.
A local file with the same ID replaces the tracked profile and is ignored by
Git. Validate all effective profiles with:

```bash
./local-models.sh validate
```

Reserved llama.cpp arguments include model download, networking, API-key,
offline, sleep, Web UI, and agent-tool flags. Those boundaries are fixed by the
trusted launcher and cannot be changed by a profile.
