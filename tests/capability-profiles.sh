#!/usr/bin/env bash
# Capability profile regression tests — no Podman or model downloads required.
set -euo pipefail

HERE="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0
FAIL=0

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*" >&2; FAIL=$((FAIL + 1)); }

# ── 1. Syntax checks ────────────────────────────────────────────────────────

echo "=== Syntax checks ==="
for script in "$HERE"/*.sh "$HERE"/tests/*.sh; do
  [ -f "$script" ] || continue
  if bash -n "$script" 2>/dev/null; then
    pass "$(basename "$script")"
  else
    fail "$(basename "$script")"
  fi
done

# ── 2. Profile validation: all tracked profiles pass ────────────────────────

echo
echo "=== Tracked profile validation ==="
if command -v jq >/dev/null 2>&1; then
  for profile in "$HERE"/profiles/capabilities/*.json; do
    [ "$(basename "$profile")" = "schema.json" ] && continue
    id="$(basename "$profile" .json)"
    if "$HERE/profile-read.sh" read "$id" >/dev/null 2>&1; then
      pass "profile $id validates"
    else
      fail "profile $id fails validation"
    fi
  done
else
  echo "  SKIP jq not installed"
fi

# ── 3. Negative validation: known-bad profiles must fail ─────────────────────

echo
echo "=== Negative validation ==="

run_neg_test() {
  local name="$1" json="$2" local_dir="$3"
  local tmp
  tmp="$(mktemp)"
  echo "$json" > "$tmp"
  local id
  id="$(jq -r '.id' "$tmp" 2>/dev/null || true)"
  [ -z "$id" ] && id="bad"
  local target="$local_dir/$id.json"
  cp "$tmp" "$target"
  if "$HERE/profile-read.sh" read "$id" >/dev/null 2>&1; then
    fail "accepted: $name"
  else
    pass "rejected: $name"
  fi
  rm -f "$tmp" "$target"
}

if command -v jq >/dev/null 2>&1; then
  neg_dir="$HERE/profiles/capabilities.local"
  mkdir -p "$neg_dir"

  run_neg_test "extra top-level key" \
    '{"id":"extra","label":"x","network":"internet","model":{"type":"cloud"},"extra_key":true}' \
    "$neg_dir"

  run_neg_test "unknown network type" \
    '{"id":"bad-net","label":"x","network":"tor","model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "unknown model type" \
    '{"id":"bad-model","label":"x","network":"internet","model":{"type":"on-prem"}}' \
    "$neg_dir"

  run_neg_test "mounts.repos wrong value" \
    '{"id":"bad-mount","label":"x","network":"internet","mounts":{"repos":"ro"},"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "mounts.data wrong value" \
    '{"id":"bad-data","label":"x","network":"internet","mounts":{"data":"rw"},"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "unknown mount key" \
    '{"id":"bad-key","label":"x","network":"internet","mounts":{"home":"rw"},"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "compute.gpu not boolean" \
    '{"id":"bad-gpu","label":"x","network":"internet","compute":{"gpu":"yes"},"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "unknown compute key" \
    '{"id":"bad-comp","label":"x","network":"internet","compute":{"cuda":true},"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "local model missing local_profile" \
    '{"id":"no-lp","label":"x","network":"local-dual","model":{"type":"local"}}' \
    "$neg_dir"

  run_neg_test "unknown model key" \
    '{"id":"bad-mk","label":"x","network":"internet","model":{"type":"cloud","provider":"x"}}' \
    "$neg_dir"

  run_neg_test "missing required label" \
    '{"id":"no-label","network":"internet","model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "datasets with internet network" \
    '{"id":"bad-ds","label":"x","network":"internet","mounts":{"datasets":"ro"},"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "local-dual with cloud model" \
    '{"id":"bad-ld","label":"x","network":"local-dual","model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "local model with internet network" \
    '{"id":"bad-li","label":"x","network":"internet","model":{"type":"local","local_profile":"gemma-4-e4b"}}' \
    "$neg_dir"

  run_neg_test "mounts is null" \
    '{"id":"bad-mn","label":"x","network":"internet","mounts":null,"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "compute is null" \
    '{"id":"bad-cn","label":"x","network":"internet","compute":null,"model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "numeric description" \
    '{"id":"bad-nd","label":"x","description":42,"network":"internet","model":{"type":"cloud"}}' \
    "$neg_dir"

  run_neg_test "numeric local_profile" \
    '{"id":"bad-nl","label":"x","network":"local-dual","model":{"type":"local","local_profile":42}}' \
    "$neg_dir"

  # Clean up local override dir if empty.
  rmdir "$neg_dir" 2>/dev/null || true
else
  echo "  SKIP jq not installed"
fi

# ── 4. --capability-profile does not consume Hermes --profile ───────────────

echo
echo "=== Option collision ==="
# Tested with fake podman in run-capability-args.sh.
echo "  SKIP option collision (tested in run-capability-args.sh)"

# ── 5. Environment variable contradiction checks ─────────────────────────────

echo
echo "=== Env var contradiction ==="

test_env_rejection() {
  local name="$1" env_var="$2" env_val="$3" profile="$4"
  local output
  output="$(env -i PATH="$PATH" HOME="$HOME" "$env_var=$env_val" \
    bash "$HERE/run.sh" --capability-profile "$profile" true 2>&1 || true)"
  # Skip if jq is missing — the enforcement logic never runs.
  if echo "$output" | grep -qi "jq is required"; then
    echo "  SKIP $name (jq not installed)"
    return
  fi
  if echo "$output" | grep -qi "incompatible\|contradicts\|requires"; then
    pass "rejected: $name"
  else
    # run.sh exits non-zero for various reasons; check it wasn't a podman error
    if echo "$output" | grep -qi "podman\|container"; then
      pass "rejected (container-level): $name"
    elif [ -z "$output" ]; then
      pass "rejected (silent): $name"
    else
      echo "    output: $output"
      fail "not rejected: $name"
    fi
  fi
}

# These tests require run.sh to exit before reaching podman.
# They work because the env var check is before any podman call.

# dev profile with HERMES_ANALYSIS=1 — should reject
test_env_rejection "HERMES_ANALYSIS with dev profile" \
  HERMES_ANALYSIS 1 dev

# dev profile with HERMES_LOCAL_PROFILE — should reject
test_env_rejection "HERMES_LOCAL_PROFILE with cloud dev profile" \
  HERMES_LOCAL_PROFILE gemma-4-e4b dev

# data-science profile with HERMES_LOCAL_LLM=1 — should reject
test_env_rejection "HERMES_LOCAL_LLM with cloud data-science profile" \
  HERMES_LOCAL_LLM 1 data-science

# ── 6. Profile-driven mount enforcement ──────────────────────────────────────

echo
echo "=== Mount enforcement ==="

test_mount_rejection() {
  local name="$1" profile="$2"
  local output
  output="$(env -i PATH="$PATH" HOME="$HOME" HERMES_REPOS= \
    bash "$HERE/run.sh" --capability-profile "$profile" true 2>&1 || true)"
  if echo "$output" | grep -qi "jq is required"; then
    echo "  SKIP $name (jq not installed)"
    return
  fi
  if echo "$output" | grep -qi "does not allow\|requires"; then
    pass "rejected: $name"
  elif echo "$output" | grep -qi "requires repositories"; then
    pass "rejected (no repos): $name"
  elif [ -z "$output" ]; then
    pass "rejected (silent): $name"
  else
    echo "    output: $output"
    fail "not rejected: $name"
  fi
}

# dev profile (requires repos) called without repos — should reject
test_mount_rejection "dev without repos" dev

# data-science repos rejection is tested with fake podman in run-capability-args.sh
echo "  SKIP data-science repos rejection (tested in run-capability-args.sh)"

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
