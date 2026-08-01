#!/usr/bin/env bash
# Prepare ignored runtime directories and the pinned Hermes Agent image.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=images/hermes/metadata.conf
source "$HERE/images/hermes/metadata.conf"
REBUILD=false

case "${1:-}" in
  "") ;;
  --rebuild) REBUILD=true ;;
  -h|--help)
    echo "usage: ./bootstrap.sh [--rebuild]"
    exit 0
    ;;
  *)
    echo "usage: ./bootstrap.sh [--rebuild]" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || { echo "usage: ./bootstrap.sh [--rebuild]" >&2; exit 2; }

for runtime_dir in data datasets outbox repos; do
  if [ ! -d "$HERE/$runtime_dir" ]; then
    mkdir -m 700 -- "$HERE/$runtime_dir"
    echo "Created $runtime_dir/"
  fi
done

if [ "$REBUILD" = true ] || ! podman image exists "$HERMES_AGENT_IMAGE" 2>/dev/null; then
  "$HERE/build-hermes-image.sh"
else
  echo "Reusing $HERMES_AGENT_IMAGE (pass --rebuild to replace it)"
fi

"$HERE/doctor.sh"
