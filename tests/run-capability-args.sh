#!/usr/bin/env bash
# Arg-vector capture tests using a fake podman executable.
# Does NOT require a running Podman or container images.
# Validates that capability profiles produce the correct mount and network flags.
set -euo pipefail

HERE="$(dirname "$(dirname "$(readlink -f "$0")")")"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*" >&2; FAIL=$((FAIL + 1)); }

# ── Fake podman ─────────────────────────────────────────────────────────────

FAKE_PODMAN="$TMP/podman"
ARGS_FILE="$TMP/podman-args"

cat > "$FAKE_PODMAN" <<'FAKE'
#!/usr/bin/env bash
# Record the final argument vector and exit 0 for "run".
# For other subcommands, behave minimally.
case "${1:-}" in
  run) printf '%s\n' "$@" > "${ARGS_FILE:?}" ;;
  exec) exit 0 ;;
  inspect) echo "true" ;;  # pretend container is running for _sandbox
  *)
    # Pass through anything else quietly.
    ;;
esac
exit 0
FAKE
chmod +x "$FAKE_PODMAN"

# ── Arg capture helper ──────────────────────────────────────────────────────

capture_args() {
  local desc="$1" profile="$2"
  shift 2
  local extra_env=("$@")
  rm -f "$ARGS_FILE"
  env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
    "${extra_env[@]}" \
    bash "$HERE/run.sh" --capability-profile "$profile" true 2>/dev/null || true
  if [ -f "$ARGS_FILE" ]; then
    cat "$ARGS_FILE"
  else
    echo "NO_ARGS"
  fi
}

# ── Helper: check flags in captured args ────────────────────────────────────

assert_flag() {
  local desc="$1" args="$2" flag="$3"
  if echo "$args" | grep -qF "$flag"; then
    pass "$desc"
  else
    fail "$desc (missing '$flag' in: $args)"
  fi
}

assert_no_flag() {
  local desc="$1" args="$2" flag="$3"
  if echo "$args" | grep -qF "$flag"; then
    fail "$desc (unexpected '$flag' in: $args)"
  else
    pass "$desc"
  fi
}

# ── Skip if jq is not available ─────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required for capability profile arg-vector tests"
  exit 0
fi

# ── Create minimal directories that run.sh expects ──────────────────────────

mkdir -p "$HERE/repos/test-repo"
if [ ! -d "$HERE/repos/test-repo/.git" ]; then
  git -C "$HERE/repos/test-repo" init -q
fi
mkdir -p "$HERE/data"
mkdir -p "$HERE/datasets"
mkdir -p "$HERE/outbox"
if [ ! -f "$HERE/workspace/AGENTS.md" ]; then
  mkdir -p "$HERE/workspace"
  echo "# Test workspace" > "$HERE/workspace/AGENTS.md"
fi

# ── Test: dev profile with repos ────────────────────────────────────────────

echo "=== dev profile ==="
args="$(capture_args "dev with repos" dev HERMES_REPOS=test-repo)"

assert_flag "dev: pasta --no-map-gw" "$args" "no-map-gw"
assert_flag "dev: repos mounted" "$args" "/workspace/repo"
assert_flag "dev: outbox mounted" "$args" "/workspace/outbox:rw"
assert_no_flag "dev: no datasets mount" "$args" "/workspace/data:ro"
assert_no_flag "dev: no analysis network" "$args" "hermes-analysis"
assert_no_flag "dev: no GPU device" "$args" "nvidia.com/gpu"

# ── Test: data-science profile ─────────────────────────────────────────────

echo
echo "=== data-science profile ==="
DATA_MANIFEST="$TMP/data-manifest"
echo "$HERE/data" > "$DATA_MANIFEST"
args="$(capture_args "data-science with data" data-science \
  HERMES_DATA_MANIFEST="$DATA_MANIFEST")"

assert_flag "data-science: pasta --no-map-gw" "$args" "no-map-gw"
assert_flag "data-science: outbox mounted" "$args" "/workspace/outbox:rw"
assert_no_flag "data-science: no repo mounts" "$args" "repos/"
assert_no_flag "data-science: no analysis network" "$args" "hermes-analysis"

# ── Test: dev profile rejects data manifest ─────────────────────────────────

echo
echo "=== profile mount enforcement ==="
output="$(env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
  HERMES_DATA_MANIFEST="$DATA_MANIFEST" HERMES_REPOS=test-repo \
  bash "$HERE/run.sh" --capability-profile dev true 2>&1 || true)"
if echo "$output" | grep -qi "does not allow data\|cannot be combined"; then
  pass "dev rejects data manifest"
else
  fail "dev should reject data manifest: $output"
fi

# ── Test: data-science profile rejects repos ────────────────────────────────

output="$(env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
  HERMES_REPOS=test-repo \
  bash "$HERE/run.sh" --capability-profile data-science true 2>&1 || true)"
if echo "$output" | grep -qi "does not allow repository"; then
  pass "data-science rejects repos"
else
  fail "data-science should reject repos: $output"
fi

# ── Test: analysis profile redirects to analysis.sh ─────────────────────────

echo
echo "=== llm-gateway ==="
# Direct call without HERMES_ANALYSIS should instruct to use analysis.sh.
output="$(env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
  bash "$HERE/run.sh" --capability-profile analysis true 2>&1 || true)"
if echo "$output" | grep -qi "analysis.sh"; then
  pass "analysis profile (direct) redirects to analysis.sh"
else
  fail "analysis profile should redirect: $output"
fi
# With HERMES_ANALYSIS=1, the analysis profile should proceed.
rm -f "$ARGS_FILE"
env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
  HERMES_ANALYSIS=1 \
  bash "$HERE/run.sh" --capability-profile analysis true 2>/dev/null || true
if [ -f "$ARGS_FILE" ] && grep -qF "hermes-analysis" "$ARGS_FILE"; then
  pass "analysis profile + HERMES_ANALYSIS=1 uses analysis network"
elif [ -f "$ARGS_FILE" ]; then
  fail "analysis profile + HERMES_ANALYSIS=1 wrong network: $(tr '\n' ' ' < "$ARGS_FILE")"
else
  fail "analysis profile + HERMES_ANALYSIS=1 did not reach podman"
fi

# ── Test: HERMES_ANALYSIS with dev profile rejected ─────────────────────────

echo
echo "=== env var contradiction ==="
output="$(env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
  HERMES_ANALYSIS=1 \
  bash "$HERE/run.sh" --capability-profile dev true 2>&1 || true)"
if echo "$output" | grep -qi "contradicts"; then
  pass "HERMES_ANALYSIS rejected with dev profile"
else
  fail "HERMES_ANALYSIS should be rejected: $output"
fi

# ── Test: --capability-profile does not consume Hermes --profile ─────────────

echo
echo "=== option collision ==="
rm -f "$ARGS_FILE"
env PATH="$TMP:$PATH" ARGS_FILE="$ARGS_FILE" \
  HERMES_REPOS=test-repo \
  bash "$HERE/run.sh" --capability-profile dev --profile my-hermes-profile true 2>/dev/null || true
if [ -f "$ARGS_FILE" ] && grep -qF -- '--profile' "$ARGS_FILE"; then
  pass "--capability-profile does not consume Hermes --profile"
elif [ -f "$ARGS_FILE" ]; then
  fail "--capability-profile consumed --profile (args: $(tr '\n' ' ' < "$ARGS_FILE"))"
else
  fail "--capability-profile did not reach podman"
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────

rm -rf "$HERE/repos/test-repo/.git" 2>/dev/null || true

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1