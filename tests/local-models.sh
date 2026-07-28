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

echo "local-model profile tests passed"
