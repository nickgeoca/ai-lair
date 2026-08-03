#!/usr/bin/env bash
# Build the sandbox's Hermes Agent image from one exact upstream revision.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=images/hermes/metadata.conf
source "$HERE/images/hermes/metadata.conf"
PATCHES=(
  "$HERE/images/hermes/0001-fix-honor-explicit-local-model-runtime.patch"
  "$HERE/images/hermes/podman.patch"
)

usage() {
  cat <<'EOF'
usage: ./build-hermes-image.sh

Fetch the pinned Hermes Agent source revision, apply the tracked AI Lair
runtime and Podman compatibility patches, and build the image expected by the
sandbox launchers.
The temporary source checkout is removed after the build.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
fi

for command_name in git podman; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done
for patch_path in "${PATCHES[@]}"; do
  [ -f "$patch_path" ] || { echo "missing Hermes patch: $patch_path" >&2; exit 1; }
done

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hermes-agent-build.XXXXXX")"
SOURCE_DIR="$BUILD_ROOT/source"
cleanup() {
  rm -rf -- "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM

echo "Fetching Hermes Agent $HERMES_AGENT_SOURCE_COMMIT"
git init --quiet "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$HERMES_AGENT_SOURCE_URL"
git -C "$SOURCE_DIR" fetch --quiet --depth=1 origin "$HERMES_AGENT_SOURCE_COMMIT"
git -C "$SOURCE_DIR" checkout --quiet --detach FETCH_HEAD

for patch_path in "${PATCHES[@]}"; do
  git -C "$SOURCE_DIR" apply --check "$patch_path"
  git -C "$SOURCE_DIR" apply "$patch_path"
done

echo "Building $HERMES_AGENT_IMAGE"
podman build \
  --build-arg "HERMES_GIT_SHA=$HERMES_AGENT_SOURCE_COMMIT" \
  --label "org.opencontainers.image.revision=$HERMES_AGENT_SOURCE_COMMIT" \
  --label "org.opencontainers.image.source=$HERMES_AGENT_SOURCE_URL" \
  --tag "$HERMES_AGENT_IMAGE" \
  "$SOURCE_DIR"

PARSER_HELP="$(podman run --rm \
  --entrypoint /opt/hermes/.venv/bin/hermes \
  "$HERMES_AGENT_IMAGE" \
  --tui --model local-smoke-test --provider custom \
  --base-url http://local-smoke-test:8080/v1 --help)"
if ! grep -Fq -- '--base-url BASE_URL' <<<"$PARSER_HELP"; then
  echo "built Hermes image does not support the launcher's --base-url override" >&2
  exit 1
fi

echo "Built $HERMES_AGENT_IMAGE from $HERMES_AGENT_SOURCE_COMMIT"
