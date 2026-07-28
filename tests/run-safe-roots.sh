#!/usr/bin/env bash
set -euo pipefail

HERE="$(dirname "$(dirname "$(readlink -f "$0")")")"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/sandbox/data" "$TMP/sandbox/outbox" \
  "$TMP/sandbox/repos/example" "$TMP/sandbox/repos/second" \
  "$TMP/sandbox/workspace"
cp "$HERE/run.sh" "$TMP/sandbox/run.sh"
cp "$HERE/workspace/AGENTS.md" "$TMP/sandbox/workspace/AGENTS.md"
git -C "$TMP/sandbox/repos/example" init -q
git -C "$TMP/sandbox/repos/second" init -q

cat > "$TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HERMES_TEST_CAPTURE"
EOF
chmod +x "$TMP/bin/podman"

PATH="$TMP/bin:$PATH" \
HERMES_TEST_CAPTURE="$TMP/repo.args" \
HERMES_REPOS=example \
  "$TMP/sandbox/run.sh" --version

grep -Fx 'HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace/repo' "$TMP/repo.args" \
  >/dev/null

PATH="$TMP/bin:$PATH" \
HERMES_TEST_CAPTURE="$TMP/multi-repo.args" \
HERMES_REPOS='example second' \
  "$TMP/sandbox/run.sh" --version

grep -Fx \
  'HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace/repos/example:/workspace/repos/second' \
  "$TMP/multi-repo.args" >/dev/null

printf '%s\n' "$TMP/input.txt" > "$TMP/manifest"
touch "$TMP/input.txt"
PATH="$TMP/bin:$PATH" \
HERMES_TEST_CAPTURE="$TMP/data.args" \
HERMES_DATA_MANIFEST="$TMP/manifest" \
  "$TMP/sandbox/run.sh" --version

grep -Fx 'HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace/outbox' "$TMP/data.args" \
  >/dev/null

echo "run.sh safe-write-root tests passed"
