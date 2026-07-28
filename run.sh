#!/usr/bin/env bash
# Hermes Agent in a rootless podman sandbox.
#
# Image is built from the pinned upstream release tag (src/ checkout).
# Sandbox properties:
#   - rootless podman: an escape lands in an unprivileged user namespace
#   - own network namespace via pasta; --no-map-gw means the container
#     cannot reach services bound on the host (127.0.0.1 or gateway addr)
#   - normal mode mounts only data/, plus explicitly selected disposable
#     repositories or read-only data paths; no access to the real $HOME
#   - analysis mode additionally mounts datasets/ read-only and outbox/ writable
#   - no-new-privileges: nothing inside can gain privileges via setuid
#
# Usage:
#   ./run.sh              interactive hermes CLI (chat)
#   ./run.sh setup        first-run provider/tool setup
#   ./run.sh model        change provider/model
#   ./run.sh bash         shell inside the sandbox
#   HERMES_REPOS="repo1 repo2" ./run.sh
#   ./run.sh --capability-profile dev    use a capability profile (see profile-read.sh list)
#   HERMES_DATA_MANIFEST=/path/to/manifest ./run.sh
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
WORKSPACE_INSTRUCTIONS="$HERE/workspace/AGENTS.md"

# Optional: a .env file next to this script (chmod 600) is passed into the
# container, e.g. OPENROUTER_API_KEY=sk-or-...  Keys entered in `setup`
# are stored inside data/ instead; both work.
ENV_ARGS=()
[ -f "$HERE/.env" ] && ENV_ARGS=(--env-file "$HERE/.env")
MOUNT_ARGS=()
DEVICE_ARGS=()
WORKDIR_ARGS=()
SECRET_ARGS=()
LABEL_ARGS=()
# Keep Hermes's dedicated file tools aligned with the writable mounts. The
# image defaults this to /opt/data, which would reject repository tool writes
# even though the same paths remain writable through the terminal tool.
SAFE_WRITE_ROOTS=(/opt/data)

# --capability-profile <name> selects a declarative capability profile.  The
# profile is validated by profile-read.sh and translated into the internal mode
# variables that the rest of this script already uses.  When the option is not
# set, the existing environment-variable API continues to work unchanged.
CAPABILITY_PROFILE=""
PASSTHROUGH_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --capability-profile)
      [ "$#" -ge 2 ] || { echo "--capability-profile requires a name" >&2; exit 2; }
      CAPABILITY_PROFILE="$2"
      shift 2
      ;;
    --capability-profile=*)
      CAPABILITY_PROFILE="${1#*=}"
      shift
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${PASSTHROUGH_ARGS[@]}"

if [ -n "$CAPABILITY_PROFILE" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for capability profiles" >&2
    exit 1
  fi
  PROFILE_JSON="$("$HERE/profile-read.sh" read "$CAPABILITY_PROFILE")" || exit 1

  PROFILE_NETWORK="$(jq -r '.network' <<<"$PROFILE_JSON")"
  PROFILE_MODEL_TYPE="$(jq -r '.model.type' <<<"$PROFILE_JSON")"

  # --- Reject contradictory legacy env vars ---
  if [ "${HERMES_ANALYSIS:-0}" = "1" ]; then
    echo "HERMES_ANALYSIS is incompatible with capability profiles; use --capability-profile analysis instead" >&2
    exit 1
  fi
  if [ "${HERMES_LOCAL_LLM:-0}" = "1" ] && [ "$PROFILE_MODEL_TYPE" != "local" ]; then
    echo "HERMES_LOCAL_LLM requires a local-model capability profile" >&2
    exit 1
  fi
  if [ -n "${HERMES_LOCAL_PROFILE:-}" ] && [ "$PROFILE_MODEL_TYPE" != "local" ]; then
    echo "HERMES_LOCAL_PROFILE contradicts cloud-only capability profile '$CAPABILITY_PROFILE'" >&2
    exit 1
  fi

  # --- Network ---
  case "$PROFILE_NETWORK" in
    internet)   ;;  # default pasta:--no-map-gw
    llm-gateway)
      # Delegate to analysis.sh for gateway lifecycle and internal network.
      # run.sh alone cannot orchestrate the gateway; reject early.
      echo "use ./analysis.sh for llm-gateway capability profiles (it manages the gateway lifecycle)" >&2
      echo "or:  HERMES_ANALYSIS=1 ./run.sh" >&2
      exit 1
      ;;
    local-dual)
      # Requires a local model profile and the internal hermes-llm network.
      if [ "$PROFILE_MODEL_TYPE" != "local" ]; then
        echo "network=local-dual requires model.type=local" >&2
        exit 1
      fi
      ;;
    *) echo "internal error: unknown network type '$PROFILE_NETWORK'" >&2; exit 1 ;;
  esac

  # --- Model ---
  if [ "$PROFILE_MODEL_TYPE" = "local" ]; then
    HERMES_LOCAL_PROFILE="$(jq -r '.model.local_profile' <<<"$PROFILE_JSON")"
  fi

  # --- Mounts ---
  # Profiles declare desired mounts; the launcher enforces them.
  PROFILE_MOUNT_REPOS="false"
  PROFILE_MOUNT_DATA="false"
  PROFILE_MOUNT_DATASETS="false"
  PROFILE_MOUNT_OUTBOX="false"

  if jq -e '.mounts.repos' <<<"$PROFILE_JSON" >/dev/null 2>&1; then
    PROFILE_MOUNT_REPOS="true"
  fi
  if jq -e '.mounts.data' <<<"$PROFILE_JSON" >/dev/null 2>&1; then
    PROFILE_MOUNT_DATA="true"
  fi
  if jq -e '.mounts.datasets' <<<"$PROFILE_JSON" >/dev/null 2>&1; then
    PROFILE_MOUNT_DATASETS="true"
  fi
  if jq -e '.mounts.outbox' <<<"$PROFILE_JSON" >/dev/null 2>&1; then
    PROFILE_MOUNT_OUTBOX="true"
  fi

  # --- Compute ---
  if jq -e '.compute.gpu == true' <<<"$PROFILE_JSON" >/dev/null 2>&1; then
    PROFILE_WANTS_GPU=1
  fi
fi

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
  SAFE_WRITE_ROOTS+=("$REPO_DEST")
done

# Normal Internet-capable data mode mounts only the explicit host paths listed
# in a newline-delimited manifest. slot-run.sh validates and creates the
# manifest; run.sh revalidates it so direct callers cannot smuggle malformed
# mount destinations into Podman. Repositories and data are intentionally not
# combined yet.
if [ -n "${HERMES_DATA_MANIFEST:-}" ]; then
  if [ "${#SELECTED_REPOS[@]}" -gt 0 ]; then
    echo "repository and data mounts cannot be combined" >&2
    exit 1
  fi
  if [ ! -f "$HERMES_DATA_MANIFEST" ] || [ -L "$HERMES_DATA_MANIFEST" ]; then
    echo "invalid data manifest: $HERMES_DATA_MANIFEST" >&2
    exit 1
  fi
  declare -A SEEN_DATA_DESTS=()
  DATA_COUNT=0
  while IFS= read -r DATA_PATH || [ -n "$DATA_PATH" ]; do
    [ -n "$DATA_PATH" ] || continue
    RESOLVED_DATA_PATH="$(realpath -e -- "$DATA_PATH" 2>/dev/null || true)"
    if [ -z "$RESOLVED_DATA_PATH" ] || { [ ! -f "$RESOLVED_DATA_PATH" ] && [ ! -d "$RESOLVED_DATA_PATH" ]; }; then
      echo "missing data path: $DATA_PATH" >&2
      exit 1
    fi
    if [[ "$RESOLVED_DATA_PATH" == *:* || "$RESOLVED_DATA_PATH" == *$'\n'* ]]; then
      echo "unsupported ':' or newline in data path: $DATA_PATH" >&2
      exit 1
    fi
    DATA_NAME="$(basename "$RESOLVED_DATA_PATH")"
    if [ -n "${SEEN_DATA_DESTS[$DATA_NAME]:-}" ]; then
      echo "data paths must have unique basenames: $DATA_NAME" >&2
      exit 1
    fi
    SEEN_DATA_DESTS[$DATA_NAME]=1
    DATA_COUNT=$((DATA_COUNT + 1))
    MOUNT_ARGS+=(
      -v "$RESOLVED_DATA_PATH:/workspace/data/$DATA_NAME:ro"
    )
  done < "$HERMES_DATA_MANIFEST"
  if [ "$DATA_COUNT" -eq 0 ]; then
    echo "data manifest contains no paths: $HERMES_DATA_MANIFEST" >&2
    exit 1
  fi
  [ -d "$OUTBOX" ] || { echo "missing outbox directory: $OUTBOX" >&2; exit 1; }
  MOUNT_ARGS+=(
    -v "$OUTBOX:/workspace/outbox:rw"
  )
  SAFE_WRITE_ROOTS+=(/workspace/outbox)
  WORKDIR_ARGS=(--workdir /workspace)
fi

# Start interactive tools where the selected projects are visible. The image's
# launcher explicitly preserves Podman's working-directory override. Only
# container paths are used here; the host repos/ parent is still never mounted.
if [ -n "${HERMES_DATA_MANIFEST:-}" ]; then
  : # data mode selected its workdir above
elif [ "${#SELECTED_REPOS[@]}" -eq 1 ]; then
  WORKDIR_ARGS=(--workdir /workspace/repo)
elif [ "${#SELECTED_REPOS[@]}" -gt 1 ]; then
  if [ ! -f "$WORKSPACE_INSTRUCTIONS" ]; then
    echo "missing multi-repository workspace instructions: $WORKSPACE_INSTRUCTIONS" >&2
    exit 1
  fi
  WORKDIR_ARGS=(--workdir /workspace/repos)
  # A file-only mount marks the non-Git parent as a coding workspace and tells
  # Hermes to discover its selected child repos. No host directory is exposed.
  MOUNT_ARGS+=(
    -v "$WORKSPACE_INSTRUCTIONS:/workspace/repos/AGENTS.md:ro"
  )
fi

# --- Capability profile mount enforcement ---
# When a capability profile is active, it authorizes which mounts are allowed
# and mandates mounts that don't depend on user input (datasets, outbox).
if [ -n "$CAPABILITY_PROFILE" ]; then
  if [ "$PROFILE_MOUNT_REPOS" = "true" ] && [ "${#SELECTED_REPOS[@]}" -eq 0 ]; then
    echo "capability profile '$CAPABILITY_PROFILE' requires repositories; pass repo names or use just run-repo" >&2
    exit 1
  fi
  if [ "$PROFILE_MOUNT_REPOS" != "true" ] && [ "${#SELECTED_REPOS[@]}" -gt 0 ]; then
    echo "capability profile '$CAPABILITY_PROFILE' does not allow repository mounts" >&2
    exit 1
  fi
  if [ "$PROFILE_MOUNT_DATA" = "true" ] && [ -z "${HERMES_DATA_MANIFEST:-}" ]; then
    echo "capability profile '$CAPABILITY_PROFILE' requires data mounts; use just run-data" >&2
    exit 1
  fi
  if [ "$PROFILE_MOUNT_DATA" != "true" ] && [ -n "${HERMES_DATA_MANIFEST:-}" ]; then
    echo "capability profile '$CAPABILITY_PROFILE' does not allow data mounts" >&2
    exit 1
  fi
  # Profile-mandated mounts that don't depend on user input.
  if [ "$PROFILE_MOUNT_DATASETS" = "true" ]; then
    [ -d "$DATASETS" ] || { echo "missing dataset directory: $DATASETS" >&2; exit 1; }
    MOUNT_ARGS+=(
      -v "$DATASETS:/workspace/data:ro"
    )
  fi
  if [ "$PROFILE_MOUNT_OUTBOX" = "true" ]; then
    [ -d "$OUTBOX" ] || { echo "missing outbox directory: $OUTBOX" >&2; exit 1; }
    MOUNT_ARGS+=(
      -v "$OUTBOX:/workspace/outbox:rw"
    )
  fi
fi

# Default: host services unreachable. HERMES_LOCAL_LLM=1 re-enables the
# gateway mapping so Hermes can call a local model server on the host.
NET_ARGS=(--network=pasta:--no-map-gw)
if [ "${HERMES_LOCAL_LLM:-0}" = "1" ]; then
  NET_ARGS=(--network=pasta)
fi

# Catalog-backed local models use an internal container network for inference
# and the ordinary rootless Podman bridge for tool egress. Profile fields are
# resolved by the trusted launcher rather than accepted as arbitrary URLs,
# container names, or secret names from the environment.
LOCAL_PROFILE="${HERMES_LOCAL_PROFILE:-}"
if [ -n "$LOCAL_PROFILE" ]; then
  if [ "${HERMES_LOCAL_LLM:-0}" = "1" ]; then
    echo "HERMES_LOCAL_PROFILE and HERMES_LOCAL_LLM cannot be combined" >&2
    exit 1
  fi
  if [ "${HERMES_ANALYSIS:-0}" = "1" ]; then
    echo "catalog local models and restricted analysis mode cannot be combined" >&2
    exit 1
  fi
  LOCAL_CONTAINER="$("$HERE/local-models.sh" field "$LOCAL_PROFILE" container)"
  LOCAL_SECRET="$("$HERE/local-models.sh" field "$LOCAL_PROFILE" secret)"
  LOCAL_NETWORK="${HERMES_LOCAL_NETWORK:-hermes-llm}"
  if ! podman network exists "$LOCAL_NETWORK" 2>/dev/null ||
     [ "$(podman network inspect -f '{{.Internal}}' "$LOCAL_NETWORK")" != "true" ]; then
    echo "missing or non-internal local-model network: $LOCAL_NETWORK" >&2
    exit 1
  fi
  NET_ARGS=(--network podman --network "$LOCAL_NETWORK")
  ENV_ARGS+=(
    -e "OPENAI_BASE_URL=http://$LOCAL_CONTAINER:8080/v1"
  )
  SECRET_ARGS+=(
    --secret="$LOCAL_SECRET,type=env,target=OPENAI_API_KEY"
  )
  LABEL_ARGS+=(
    --label io.hermes.local-session=true
    --label "io.hermes.local-model=$LOCAL_PROFILE"
  )
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
  SAFE_WRITE_ROOTS+=(/workspace/outbox)
  DEVICE_ARGS=(--device nvidia.com/gpu=all)
fi

SAFE_WRITE_ROOTS_VALUE="${SAFE_WRITE_ROOTS[0]}"
for SAFE_WRITE_ROOT in "${SAFE_WRITE_ROOTS[@]:1}"; do
  SAFE_WRITE_ROOTS_VALUE="$SAFE_WRITE_ROOTS_VALUE:$SAFE_WRITE_ROOT"
done
ENV_ARGS+=(
  -e "HERMES_WRITE_SAFE_ROOT=$SAFE_WRITE_ROOTS_VALUE"
)

# Profiles may request GPU without the full analysis-mode restrictions.
if [ "${PROFILE_WANTS_GPU:-0}" = "1" ] && [ "${#DEVICE_ARGS[@]}" -eq 0 ]; then
  DEVICE_ARGS=(--device nvidia.com/gpu=all)
fi

exec podman run -it --rm \
  --name "$CONTAINER_NAME" \
  "${ENV_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  "${WORKDIR_ARGS[@]}" \
  --userns=keep-id:uid=10000,gid=10000 \
  --security-opt=no-new-privileges \
  --pids-limit=2048 \
  -v "$DATA:/opt/data" \
  "${DEVICE_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  "${SECRET_ARGS[@]}" \
  "${LABEL_ARGS[@]}" \
  "$IMAGE" "$@"
