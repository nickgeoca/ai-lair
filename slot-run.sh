#!/usr/bin/env bash
# Slot-aware launcher for parallel Hermes TUI sessions.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
SLOT_DIR="${HERMES_SLOT_DIR:-$HERE/data/slots}"
SLOT_CONFIG="${HERMES_SLOT_CONFIG:-$HERE/data/slots.conf}"
DEFAULT_MAX_SLOTS=4
MAX_SLOT_LIMIT=16

mkdir -p "$SLOT_DIR"

read_max_slots() {
  local value="$DEFAULT_MAX_SLOTS"
  if [ -f "$SLOT_CONFIG" ]; then
    value="$(tr -d '[:space:]' < "$SLOT_CONFIG")"
  fi
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || [ "$value" -gt "$MAX_SLOT_LIMIT" ]; then
    echo "invalid slot count in $SLOT_CONFIG: $value" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

slot_state() {
  local slot="$1"
  local name="hermes-slot-$slot"
  local reservation="$SLOT_DIR/$slot.reserve"
  if podman container exists "$name" 2>/dev/null; then
    if [ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; then
      printf 'running'
    else
      printf 'stopped'
    fi
  elif [ -f "$reservation" ]; then
    local pid
    pid="$(tr -d '[:space:]' < "$reservation" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'reserved'
    else
      printf 'stale'
    fi
  else
    printf 'free'
  fi
}

show_status() {
  local max slot state
  max="$(read_max_slots)"
  echo "Hermes slots (max $max)"
  for ((slot = 1; slot <= max; slot++)); do
    state="$(slot_state "$slot")"
    printf '  %s: %-8s home=shared container=hermes-slot-%s\n' \
      "$slot" "$state" "$slot"
  done
}

set_slots() {
  local count="${1:-}"
  if [ -z "$count" ]; then
    show_status
    return
  fi
  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]] || [ "$count" -gt "$MAX_SLOT_LIMIT" ]; then
    echo "slot count must be between 1 and $MAX_SLOT_LIMIT" >&2
    exit 2
  fi
  local current slot state
  current="$(read_max_slots)"
  if [ "$count" -lt "$current" ]; then
    for ((slot = count + 1; slot <= current; slot++)); do
      state="$(slot_state "$slot")"
      if [ "$state" != "free" ] && [ "$state" != "stale" ]; then
        echo "cannot lower slot count while slot $slot is $state" >&2
        exit 1
      fi
    done
  fi
  local tmp="$SLOT_CONFIG.tmp.$$"
  printf '%s\n' "$count" > "$tmp"
  mv "$tmp" "$SLOT_CONFIG"
  echo "maximum parallel Hermes slots: $count"
  show_status
}

normalize_repo() {
  local input="$1"
  local name top expected
  if [[ "$input" == */* ]]; then
    top="$(git -C "$input" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || { echo "not a Git repository: $input" >&2; return 1; }
    name="$(basename "$top")"
    expected="$HOME/projects/$name"
    if [ "$(readlink -f "$top")" != "$(readlink -f "$expected" 2>/dev/null || true)" ]; then
      echo "repository paths must identify a direct checkout under $HOME/projects: $input" >&2
      return 1
    fi
  else
    name="$input"
  fi
  case "$name" in
    ""|.|..|*[!A-Za-z0-9._-]*)
      echo "invalid repository name: $name" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$name"
}

claim_slot() {
  local max slot state reservation
  max="$(read_max_slots)"
  exec 9>"$SLOT_DIR/.lock"
  flock 9
  for ((slot = 1; slot <= max; slot++)); do
    state="$(slot_state "$slot")"
    if [ "$state" = "stale" ]; then
      rm -f -- "$SLOT_DIR/$slot.reserve"
      state=free
    fi
    if [ "$state" = "free" ]; then
      reservation="$SLOT_DIR/$slot.reserve"
      printf '%s\n' "$$" > "$reservation"
      SLOT="$slot"
      RESERVATION="$reservation"
      flock -u 9
      return
    fi
  done
  flock -u 9
  show_status >&2
  echo "all $max Hermes slots are occupied" >&2
  exit 1
}

MODE="${1:-run}"
shift || true

case "$MODE" in
  status)
    show_status
    exit
    ;;
  slots)
    set_slots "${1:-}"
    exit
    ;;
  run|repo|data) ;;
  *)
    echo "usage: $0 {run|repo|data|status|slots}" >&2
    exit 2
    ;;
esac

REPO_NAMES=()
DATA_PATHS=()

if [ "$MODE" = "repo" ]; then
  [ "$#" -gt 0 ] || { echo "run-repo requires at least one repository" >&2; exit 2; }
  declare -A SEEN_REPOS=()
  for input in "$@"; do
    name="$(normalize_repo "$input")"
    if [ -n "${SEEN_REPOS[$name]:-}" ]; then
      echo "duplicate repository: $name" >&2
      exit 2
    fi
    SEEN_REPOS[$name]=1
    REPO_NAMES+=("$name")
  done
  just --justfile "$HERE/justfile" _repo-ensure "${REPO_NAMES[*]}"
elif [ "$MODE" = "data" ]; then
  [ "$#" -gt 0 ] || { echo "run-data requires at least one file or directory" >&2; exit 2; }
  declare -A SEEN_DATA_NAMES=()
  for input in "$@"; do
    path="$(realpath -e -- "$input" 2>/dev/null || true)"
    [ -n "$path" ] && { [ -f "$path" ] || [ -d "$path" ]; } || {
      echo "missing file or directory: $input" >&2
      exit 2
    }
    if [[ "$path" == *$'\n'* || "$path" == *:* ]]; then
      echo "unsupported ':' or newline in data path: $input" >&2
      exit 2
    fi
    name="$(basename "$path")"
    if [ -n "${SEEN_DATA_NAMES[$name]:-}" ]; then
      echo "data paths must have unique basenames: $name" >&2
      exit 2
    fi
    SEEN_DATA_NAMES[$name]=1
    DATA_PATHS+=("$path")
  done
fi

SLOT=""
RESERVATION=""
DATA_MANIFEST=""
LOCAL_PROFILE=""
LOCAL_ACQUIRED=false
cleanup() {
  if [ "$LOCAL_ACQUIRED" = true ]; then
    "$HERE/local-models.sh" release "$LOCAL_PROFILE" "${CONTAINER_NAME:-unknown}" || true
  fi
  [ -z "$DATA_MANIFEST" ] || rm -f -- "$DATA_MANIFEST"
  [ -z "$RESERVATION" ] || rm -f -- "$RESERVATION"
}
trap cleanup EXIT INT TERM

claim_slot
CONTAINER_NAME="hermes-slot-$SLOT"

echo "Claimed Hermes slot $SLOT/$(read_max_slots)"
echo "Hermes home: shared default (/opt/data)"
echo "Container: $CONTAINER_NAME"

echo
echo "1) DeepSeek V4 Flash — OpenRouter / Novita FP8"
echo "2) DeepSeek V4 Pro — OpenRouter / Novita FP8"
echo "3) Kimi K3 — OpenRouter / Moonshot AI"
LOCAL_IDS=()
LOCAL_LABELS=()
LOCAL_STATES=()
if command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r id label state origin; do
    [ -n "$id" ] || continue
    LOCAL_IDS+=("$id")
    LOCAL_LABELS+=("$label")
    LOCAL_STATES+=("$state")
  done < <("$HERE/local-models.sh" list --tsv)
else
  echo "Local model profiles hidden: install jq to enable them."
fi
for i in "${!LOCAL_IDS[@]}"; do
  printf '%s) %s [%s]\n' "$((i + 4))" "${LOCAL_LABELS[$i]}" "${LOCAL_STATES[$i]}"
done
PICKER_CHOICE=$((4 + ${#LOCAL_IDS[@]}))
echo "$PICKER_CHOICE) Hermes provider/model picker (changes the shared saved default)"
read -r -p "Select [1-$PICKER_CHOICE, default 1]: " CHOICE
CHOICE="${CHOICE:-1}"
USE_SAVED_MODEL=false
case "$CHOICE" in
  1)
    MODEL=deepseek/deepseek-v4-flash
    ROUTE=novita/fp8
    ;;
  2)
    MODEL=deepseek/deepseek-v4-pro
    ROUTE=novita/fp8
    ;;
  3)
    MODEL=moonshotai/kimi-k3
    ROUTE=moonshotai
    ;;
  "$PICKER_CHOICE")
    HERMES_CONTAINER_NAME="$CONTAINER_NAME" \
      "$HERE/run.sh" model
    USE_SAVED_MODEL=true
    ;;
  *)
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] &&
       [ "$CHOICE" -ge 4 ] && [ "$CHOICE" -lt "$PICKER_CHOICE" ]; then
      index=$((CHOICE - 4))
      LOCAL_PROFILE="${LOCAL_IDS[$index]}"
      if ! "$HERE/local-models.sh" compatible "$LOCAL_PROFILE"; then
        echo
        "$HERE/local-models.sh" setup "$LOCAL_PROFILE"
      fi
      MODEL="$("$HERE/local-models.sh" field "$LOCAL_PROFILE" hermes_model)"
      ROUTE=""
    else
      echo "invalid selection: $CHOICE" >&2
      exit 2
    fi
    ;;
esac

if [ -z "$LOCAL_PROFILE" ] && [ "$USE_SAVED_MODEL" = false ]; then
  HERMES_CONTAINER_NAME="$CONTAINER_NAME" \
    "$HERE/run.sh" config set provider_routing.only.0 "$ROUTE"
fi

if [ "$MODE" = "repo" ]; then
  export HERMES_REPO_REQUIRED=1
  export HERMES_REPOS="${REPO_NAMES[*]}"
elif [ "$MODE" = "data" ]; then
  DATA_MANIFEST="$(mktemp "$SLOT_DIR/data-$SLOT.XXXXXX")"
  printf '%s\n' "${DATA_PATHS[@]}" > "$DATA_MANIFEST"
  export HERMES_DATA_MANIFEST="$DATA_MANIFEST"
fi

# Derive capability profile from mode.  The profile name maps to the
# profiles/capabilities/<name>.json file and is validated by run.sh.
PROFILE_ARG=()
case "$MODE" in
  repo) PROFILE_ARG=(--capability-profile dev) ;;
  data) PROFILE_ARG=(--capability-profile data-science) ;;
  run)  ;;  # no profile for bare shell/chat mode
esac

if [ -n "$LOCAL_PROFILE" ]; then
  "$HERE/local-models.sh" acquire "$LOCAL_PROFILE" "$CONTAINER_NAME" "$$"
  LOCAL_ACQUIRED=true
  HERMES_CONTAINER_NAME="$CONTAINER_NAME" \
    HERMES_LOCAL_PROFILE="$LOCAL_PROFILE" \
    "$HERE/run.sh" --tui "${PROFILE_ARG[@]}" --model "$MODEL" --provider custom
elif [ "$USE_SAVED_MODEL" = true ]; then
  HERMES_CONTAINER_NAME="$CONTAINER_NAME" "$HERE/run.sh" --tui "${PROFILE_ARG[@]}"
else
  HERMES_CONTAINER_NAME="$CONTAINER_NAME" \
    "$HERE/run.sh" --tui "${PROFILE_ARG[@]}" --model "$MODEL" --provider openrouter
fi
