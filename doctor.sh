#!/usr/bin/env bash
# Read-only host preflight for the supported AI Lair path.
set -u

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=images/hermes/metadata.conf
source "$HERE/images/hermes/metadata.conf"
FAILURES=0
WARNINGS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 available"
  else
    fail "$1 missing"
  fi
}

echo "AI Lair doctor"
echo

if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  pass "Bash ${BASH_VERSION}"
else
  fail "Bash 4 or newer required (found ${BASH_VERSION})"
fi

for command_name in git just jq openssl podman pasta flock realpath readlink; do
  check_command "$command_name"
done

if command -v podman >/dev/null 2>&1; then
  PODMAN_ROOTLESS="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  case "$PODMAN_ROOTLESS" in
    true) pass "Podman service is usable and rootless" ;;
    false) fail "Podman is usable but not rootless" ;;
    *) fail "Podman service is unavailable for the current user" ;;
  esac

  if podman image exists "$HERMES_AGENT_IMAGE" 2>/dev/null; then
    pass "Hermes image present: $HERMES_AGENT_IMAGE"
    IMAGE_REVISION="$(podman image inspect --format \
      '{{index .Labels "org.opencontainers.image.revision"}}' \
      "$HERMES_AGENT_IMAGE" 2>/dev/null || true)"
    if [ "$IMAGE_REVISION" = "$HERMES_AGENT_SOURCE_COMMIT" ]; then
      pass "Hermes image revision matches the pinned source"
    elif [ -z "$IMAGE_REVISION" ] || [ "$IMAGE_REVISION" = "<no value>" ]; then
      warn "Hermes image has no source-revision label; rebuild with just image"
    else
      fail "Hermes image revision is $IMAGE_REVISION; expected $HERMES_AGENT_SOURCE_COMMIT"
    fi
  else
    fail "Hermes image missing: run just image"
  fi
fi

for runtime_dir in data datasets outbox repos; do
  if [ -d "$HERE/$runtime_dir" ]; then
    pass "runtime directory present: $runtime_dir/"
  else
    warn "runtime directory missing: $runtime_dir/ (run just bootstrap)"
  fi
done

echo
printf 'Result: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
[ "$FAILURES" -eq 0 ]
