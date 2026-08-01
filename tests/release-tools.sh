#!/usr/bin/env bash
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")/.."
# shellcheck source=images/hermes/metadata.conf
source "$HERE/images/hermes/metadata.conf"

[[ "$HERMES_AGENT_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Hermes source revision is not a full commit ID" >&2
  exit 1
}
[ "$HERMES_AGENT_IMAGE" = 'hermes-agent:v2026.7.1' ] || {
  echo "unexpected Hermes image tag: $HERMES_AGENT_IMAGE" >&2
  exit 1
}

git apply --numstat "$HERE/images/hermes/podman.patch" >/dev/null

# Match the literal source expression in the launchers; expansion is unwanted.
# shellcheck disable=SC2016
EXPECTED_SOURCE='source "$HERE/images/hermes/metadata.conf"'
grep -Fq "$EXPECTED_SOURCE" "$HERE/run.sh"
grep -Fq "$EXPECTED_SOURCE" "$HERE/analysis.sh"
grep -Fq 'HERMES_AGENT_SOURCE_COMMIT' "$HERE/build-hermes-image.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM
mkdir "$TMP/bin"

cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git' >> "$RELEASE_TOOL_LOG"
printf ' <%s>' "$@" >> "$RELEASE_TOOL_LOG"
printf '\n' >> "$RELEASE_TOOL_LOG"
if [ "${1:-}" = init ]; then
  mkdir -p -- "${@: -1}"
fi
EOF
cat > "$TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman' >> "$RELEASE_TOOL_LOG"
printf ' <%s>' "$@" >> "$RELEASE_TOOL_LOG"
printf '\n' >> "$RELEASE_TOOL_LOG"
EOF
chmod +x "$TMP/bin/git" "$TMP/bin/podman"

RELEASE_TOOL_LOG="$TMP/log" PATH="$TMP/bin:$PATH" \
  "$HERE/build-hermes-image.sh" >/dev/null

grep -Fq "fetch> <--quiet> <--depth=1> <origin> <$HERMES_AGENT_SOURCE_COMMIT>" "$TMP/log"
grep -Fq "HERMES_GIT_SHA=$HERMES_AGENT_SOURCE_COMMIT" "$TMP/log"
grep -Fq "org.opencontainers.image.revision=$HERMES_AGENT_SOURCE_COMMIT" "$TMP/log"
grep -Fq -- "--tag> <$HERMES_AGENT_IMAGE>" "$TMP/log"

echo "release tool tests passed"
