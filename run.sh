#!/usr/bin/env bash
# Hermes Agent in a rootless podman sandbox.
#
# Image is built from the pinned upstream release tag (src/ checkout).
# Sandbox properties:
#   - rootless podman: an escape lands in an unprivileged user namespace
#   - own network namespace via pasta; --no-map-gw means the container
#     cannot reach services bound on the host (127.0.0.1 or gateway addr)
#   - normal mode mounts only data/, plus explicitly selected disposable
#     repositories when HERMES_REPOS is set; no access to the real $HOME
#   - analysis mode additionally mounts datasets/ read-only and outbox/ writable
#   - no-new-privileges: nothing inside can gain privileges via setuid
#
# Usage:
#   ./run.sh              interactive hermes CLI (chat)
#   ./run.sh setup        first-run provider/tool setup
#   ./run.sh model        change provider/model
#   ./run.sh bash         shell inside the sandbox
#   HERMES_REPOS="repo1 repo2" ./run.sh
#   ./analysis.sh         restricted analysis with no general Internet access
#
# Local LLM mode (opt-in, weakens host isolation for this run only):
#   HERMES_LOCAL_LLM=1 ./run.sh
# Drops --no-map-gw so the container can reach an inference server running
# on the host (e.g. ollama on :11434). Inside the container the host is
# reachable as host.containers.internal (fallback: the default-gateway IP).
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
IMAGE=hermes-agent:v2026.7.1
# Override only for parallel smoke tests; ordinary sessions retain the stable
# name used by the justfile's exec-into-running-session helper.
CONTAINER_NAME="${HERMES_CONTAINER_NAME:-hermes}"
DATA="$HERE/data"
DATASETS="$HERE/datasets"
OUTBOX="$HERE/outbox"
REPOS="$HERE/repos"

# Optional: a .env file next to this script (chmod 600) is passed into the
# container, e.g. OPENROUTER_API_KEY=sk-or-...  Keys entered in `setup`
# are stored inside data/ instead; both work.
ENV_ARGS=()
[ -f "$HERE/.env" ] && ENV_ARGS=(--env-file "$HERE/.env")
MOUNT_ARGS=()
DEVICE_ARGS=()

# Repositories are selected by basename and mounted individually. Never bind-
# mount repos/ itself: unrelated disposable clones must remain invisible.
# HERMES_REPO remains supported for compatibility with older commands.
REPO_WORDS="${HERMES_REPOS:-${HERMES_REPO:-}}"
SELECTED_REPOS=()
[ -n "$REPO_WORDS" ] && read -r -a SELECTED_REPOS <<< "$REPO_WORDS"

if [ "${HERMES_REPO_REQUIRED:-0}" = "1" ] && [ "${#SELECTED_REPOS[@]}" -eq 0 ]; then
  echo "a disposable repository name is required" >&2
  exit 1
fi

declare -A SEEN_REPOS=()
for REPO_NAME in "${SELECTED_REPOS[@]}"; do
  case "$REPO_NAME" in
    .|..|*[!A-Za-z0-9._-]*)
      echo "invalid repository name (allowed: A-Z, a-z, 0-9, ., _, -; not . or ..)" >&2
      exit 1
      ;;
  esac
  if [ -n "${SEEN_REPOS[$REPO_NAME]:-}" ]; then
    echo "duplicate repository name: $REPO_NAME" >&2
    exit 1
  fi
  SEEN_REPOS[$REPO_NAME]=1

  REPO="$REPOS/$REPO_NAME"
  if [ ! -d "$REPO" ] || [ -L "$REPO" ]; then
    echo "missing disposable repository: $REPO" >&2
    exit 1
  fi
  REPO_TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$REPO_TOP" ] || [ "$(readlink -f "$REPO_TOP")" != "$(readlink -f "$REPO")" ]; then
    echo "not a Git repository: $REPO" >&2
    exit 1
  fi

  if [ "${#SELECTED_REPOS[@]}" -eq 1 ]; then
    REPO_DEST=/workspace/repo
  else
    REPO_DEST="/workspace/repos/$REPO_NAME"
  fi
  MOUNT_ARGS+=(
    -v "$REPO:$REPO_DEST:rw"
  )
done

# Default: host services unreachable. HERMES_LOCAL_LLM=1 re-enables the
# gateway mapping so Hermes can call a local model server on the host.
NET_ARGS=(--network=pasta:--no-map-gw)
if [ "${HERMES_LOCAL_LLM:-0}" = "1" ]; then
  NET_ARGS=(--network=pasta)
fi

# Restricted analysis mode is started by analysis.sh, which provides a fixed
# LLM gateway on this internal-only network. The normal Internet-capable mode
# never sees the staged datasets.
if [ "${HERMES_ANALYSIS:-0}" = "1" ]; then
  if [ "${HERMES_LOCAL_LLM:-0}" = "1" ]; then
    echo "HERMES_ANALYSIS and HERMES_LOCAL_LLM cannot be combined" >&2
    exit 1
  fi
  [ -d "$DATASETS" ] || { echo "missing dataset directory: $DATASETS" >&2; exit 1; }
  [ -d "$OUTBOX" ] || { echo "missing outbox directory: $OUTBOX" >&2; exit 1; }
  NET_ARGS=(--network=hermes-analysis)
  ENV_ARGS+=(
    -e OPENROUTER_BASE_URL=http://hermes-llm-gateway:8080/api/v1
  )
  MOUNT_ARGS+=(
    -v "$DATASETS:/workspace/data:ro"
    -v "$OUTBOX:/workspace/outbox:rw"
  )
  DEVICE_ARGS=(--device nvidia.com/gpu=all)
fi

exec podman run -it --rm \
  --name "$CONTAINER_NAME" \
  "${ENV_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  --userns=keep-id:uid=10000,gid=10000 \
  --security-opt=no-new-privileges \
  --pids-limit=2048 \
  -v "$DATA:/opt/data" \
  "${DEVICE_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  "$IMAGE" "$@"
