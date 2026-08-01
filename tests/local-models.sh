#!/usr/bin/env bash
set -euo pipefail

HERE="$(dirname "$(dirname "$(readlink -f "$0")")")"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/catalog" "$TMP/local"

cp "$HERE/local-models/profiles/gemma-4-e4b.json" "$TMP/catalog/"
HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" validate >/dev/null

jq '.id = "wrong-id"' "$TMP/catalog/gemma-4-e4b.json" > "$TMP/catalog/bad-id.json"
if HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" validate >/dev/null 2>&1; then
  echo "expected mismatched profile ID validation to fail" >&2
  exit 1
fi
rm "$TMP/catalog/bad-id.json"

jq '.llama_args += ["--host"]' "$TMP/catalog/gemma-4-e4b.json" \
  > "$TMP/local/gemma-4-e4b.json"
if HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" validate >/dev/null 2>&1; then
  echo "expected reserved argument validation to fail" >&2
  exit 1
fi
rm "$TMP/local/gemma-4-e4b.json"

jq '.llama_args += ["-c", "65536"]' "$TMP/catalog/gemma-4-e4b.json" \
  > "$TMP/local/gemma-4-e4b.json"
if HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" validate >/dev/null 2>&1; then
  echo "expected reserved context argument validation to fail" >&2
  exit 1
fi
rm "$TMP/local/gemma-4-e4b.json"

jq '.context.target_free_mib = 512.5' "$TMP/catalog/gemma-4-e4b.json" \
  > "$TMP/local/gemma-4-e4b.json"
if HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" validate >/dev/null 2>&1; then
  echo "expected fractional fit target validation to fail" >&2
  exit 1
fi
rm "$TMP/local/gemma-4-e4b.json"

jq '.context = {"mode":"fixed","tokens":8192}' \
  "$TMP/catalog/gemma-4-e4b.json" > "$TMP/local/gemma-4-e4b.json"
HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" validate >/dev/null
rm "$TMP/local/gemma-4-e4b.json"

jq '.label = "Private override"' "$TMP/catalog/gemma-4-e4b.json" \
  > "$TMP/local/gemma-4-e4b.json"
actual="$(HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" field gemma-4-e4b label)"
[ "$actual" = "Private override" ] || {
  echo "local profile did not override tracked profile" >&2
  exit 1
}

if HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" field gemma-4-e4b 'label | error("injected")' \
  >/dev/null 2>&1; then
  echo "expected unknown profile field to fail" >&2
  exit 1
fi

if HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" release gemma-4-e4b ../../outside \
  >/dev/null 2>&1; then
  echo "expected unsafe reservation name to fail" >&2
  exit 1
fi

# A newly created Podman CDI container records the requested logical device in
# CreateCommand before its first start. Resolved /dev/nvidia devices are empty
# until Podman starts it, so compatibility must accept the logical request.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "secret inspect") exit 0 ;;
  "inspect llama-gemma4") cat "$FAKE_PODMAN_INSPECT" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/podman"

profile="$TMP/local/gemma-4-e4b.json"
expected_args="$(jq -c '["-hf", .model_source, "--offline"] + .llama_args +
  ["--fit", "on",
   "--fit-target", (.context.target_free_mib | tostring),
   "--fit-ctx", (.context.minimum_tokens | tostring)] +
  ["--no-webui", "--no-agent", "--host", "0.0.0.0", "--port", "8080",
   "--api-key-file", "/run/secrets/llama-api-key",
   "--sleep-idle-seconds", "60"]' "$profile")"
jq -n --arg image "$(jq -r .image "$profile")" \
  --arg volume "$(jq -r .volume "$profile")" \
  --arg secret "$(jq -r .secret "$profile")" \
  --argjson args "$expected_args" '[{
    ImageName: $image,
    Args: $args,
    HostConfig: {
      ReadonlyRootfs: true,
      PidsLimit: 512,
      SecurityOpt: ["no-new-privileges"],
      PortBindings: {},
      Devices: []
    },
    Mounts: [{
      Type: "volume", Name: $volume, Destination: "/root/.cache", RW: false
    }],
    Config: {
      Secrets: [{Name: $secret}],
      CreateCommand: ["podman", "create", "--device", "nvidia.com/gpu=all"]
    },
    NetworkSettings: {Networks: {"hermes-llm": {}}}
  }]' > "$TMP/inspect.json"

FAKE_PODMAN_INSPECT="$TMP/inspect.json" \
PATH="$TMP/bin:$PATH" \
HERMES_MODEL_CATALOG="$TMP/catalog" HERMES_LOCAL_MODEL_DIR="$TMP/local" \
  "$HERE/local-models.sh" compatible gemma-4-e4b || {
    echo "expected an unstarted NVIDIA CDI backend to be compatible" >&2
  exit 1
}

echo "local-model profile tests passed"
