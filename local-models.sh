#!/usr/bin/env bash
# Provision and coordinate optional local llama.cpp backends for Hermes.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
CATALOG_DIR="${HERMES_MODEL_CATALOG:-$HERE/local-models/profiles}"
LOCAL_DIR="${HERMES_LOCAL_MODEL_DIR:-$HERE/local-models.local}"
RUNTIME_DIR="${HERMES_LOCAL_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hermes-local-models}"
NETWORK="${HERMES_LOCAL_NETWORK:-hermes-llm}"
LOCK_FILE="$RUNTIME_DIR/lifecycle.lock"
RESERVATION_DIR="$RUNTIME_DIR/reservations"
SESSION_LABEL="io.hermes.local-session"
BACKEND_LABEL="io.hermes.local-backend"
DOWNLOAD_CONTAINER=""

die() {
  echo "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

valid_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

resolve_profile() {
  local id="$1"
  valid_id "$id" || die "invalid local-model profile ID: $id"
  if [ -f "$LOCAL_DIR/$id.json" ]; then
    printf '%s\n' "$LOCAL_DIR/$id.json"
  elif [ -f "$CATALOG_DIR/$id.json" ]; then
    printf '%s\n' "$CATALOG_DIR/$id.json"
  else
    die "unknown local-model profile: $id"
  fi
}

effective_profiles() {
  local file id
  declare -A files=()
  shopt -s nullglob
  for file in "$CATALOG_DIR"/*.json; do
    id="$(basename "$file" .json)"
    files[$id]="$file"
  done
  for file in "$LOCAL_DIR"/*.json; do
    id="$(basename "$file" .json)"
    files[$id]="$file"
  done
  for id in "${!files[@]}"; do
    printf '%s\t%s\n' "$id" "${files[$id]}"
  done | sort
}

validate_profile() {
  local file="$1" expected_id="$2" arg
  [ -f "$file" ] || die "missing profile: $file"
  jq -e --arg id "$expected_id" '
    type == "object" and
    ((keys | sort) == ([
      "container", "download_gib", "hermes_model", "id", "image",
      "context", "label", "llama_args", "model_source", "secret",
      "tested_hardware", "volume"
    ] | sort)) and
    .id == $id and (.id | test("^[a-z0-9][a-z0-9-]{0,62}$")) and
    ([.label, .hermes_model, .image, .model_source, .container, .volume,
      .secret, .tested_hardware] | all(type == "string" and length > 0 and
      (contains("\\n") | not) and (contains("\\t") | not))) and
    (.image | test("@sha256:[a-f0-9]{64}$")) and
    ([.container, .volume, .secret] |
      all(test("^[A-Za-z0-9][A-Za-z0-9_.-]*$"))) and
    (.download_gib | type == "number" and . > 0) and
    (
      (.context.mode == "fit" and
       (.context | keys | sort) == ["minimum_tokens", "mode", "target_free_mib"] and
       (.context.target_free_mib | type == "number" and floor == . and . >= 0) and
       (.context.minimum_tokens | type == "number" and floor == . and . >= 512))
      or
      (.context.mode == "fixed" and
       (.context | keys | sort) == ["mode", "tokens"] and
       (.context.tokens | type == "number" and floor == . and . >= 512))
    ) and
    (.llama_args | type == "array" and all(type == "string" and
      (contains("\\n") | not) and (contains("\\t") | not)))
  ' "$file" >/dev/null || die "invalid local-model profile: $file"

  while IFS= read -r arg; do
    case "$arg" in
      -hf|-hf=*|--hf-repo|--hf-repo=*|--host|--host=*|--port|--port=*|\
      --api-key|--api-key=*|--api-key-file|--api-key-file=*|--offline|\
      --offline=*|--sleep-idle-seconds|--sleep-idle-seconds=*|--webui|\
      --no-webui|--agent|--no-agent|-c|-c=*|--ctx-size|--ctx-size=*|\
      -fit|-fit=*|--fit|--fit=*|-fitt|-fitt=*|--fit-target|\
      --fit-target=*|-fitc|-fitc=*|--fit-ctx|--fit-ctx=*)
        die "profile $expected_id uses launcher-reserved argument: $arg"
        ;;
    esac
  done < <(jq -r '.llama_args[]' "$file")
}

validate_all() {
  local id file value key
  local count=0
  declare -A owners=()
  while IFS=$'\t' read -r id file; do
    [ -n "$id" ] || continue
    validate_profile "$file" "$id"
    for key in container volume secret; do
      value="$(jq -r ".$key" "$file")"
      if [ -n "${owners[$key:$value]:-}" ] && [ "${owners[$key:$value]}" != "$id" ]; then
        die "$key '$value' is shared by profiles ${owners[$key:$value]} and $id"
      fi
      owners[$key:$value]="$id"
    done
    count=$((count + 1))
  done < <(effective_profiles)
  [ "$count" -gt 0 ] || die "no local-model profiles found"
  echo "validated $count local-model profile(s)"
}

profile_json() {
  local id="$1" file
  file="$(resolve_profile "$id")"
  validate_profile "$file" "$id"
  jq -c . "$file"
}

profile_field() {
  local id="$1" field="$2" file
  case "$field" in
    id|label|hermes_model|image|model_source|container|volume|secret|\
    download_gib|tested_hardware|context|llama_args) ;;
    *) die "unknown local-model profile field: $field" ;;
  esac
  file="$(resolve_profile "$id")"
  validate_profile "$file" "$id"
  jq -er --arg field "$field" '.[$field]' "$file"
}

container_running() {
  local container="$1"
  [ "$(podman inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = "true" ]
}

backend_context_value() {
  local container="$1" props
  props="$(podman exec "$container" sh -c \
    'exec curl -fsS -H "Authorization: Bearer $(sed -n "1p" /run/secrets/llama-api-key)" http://127.0.0.1:8080/props')" ||
    return 1
  jq -er '.default_generation_settings.n_ctx |
    select(type == "number" and floor == . and . > 0)' <<<"$props"
}

is_installed() {
  local id="$1" container
  container="$(profile_field "$id" container)"
  podman container exists "$container" 2>/dev/null
}

model_cache_present() {
  local id="$1" file volume mountpoint cached_file
  file="$(resolve_profile "$id")"
  volume="$(jq -r .volume "$file")"
  podman volume exists "$volume" 2>/dev/null || return 1
  mountpoint="$(podman volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null)" || return 1
  [ -d "$mountpoint" ] || return 1
  cached_file="$(find "$mountpoint" -type f -size +1M -print -quit 2>/dev/null || true)"
  [ -n "$cached_file" ]
}

runtime_args_json() {
  local file="$1"
  jq -c '
    .llama_args +
    if .context.mode == "fit" then
      ["--fit", "on",
       "--fit-target", (.context.target_free_mib | tostring),
       "--fit-ctx", (.context.minimum_tokens | tostring)]
    else
      ["--fit", "off", "--ctx-size", (.context.tokens | tostring)]
    end
  ' "$file"
}

expected_args_json() {
  local file="$1" runtime
  runtime="$(runtime_args_json "$file")"
  jq -cn --arg source "$(jq -r .model_source "$file")" --argjson runtime "$runtime" '
    ["-hf", $source, "--offline"] + $runtime +
    ["--no-webui", "--no-agent", "--host", "0.0.0.0", "--port", "8080",
     "--api-key-file", "/run/secrets/llama-api-key",
     "--sleep-idle-seconds", "60"]'
}

container_compatible() {
  local id="$1" file container image volume secret expected inspect
  file="$(resolve_profile "$id")"
  validate_profile "$file" "$id"
  container="$(jq -r .container "$file")"
  image="$(jq -r .image "$file")"
  volume="$(jq -r .volume "$file")"
  secret="$(jq -r .secret "$file")"
  podman secret inspect "$secret" >/dev/null 2>&1 || return 1
  expected="$(expected_args_json "$file")"
  inspect="$(podman inspect "$container" 2>/dev/null)" || return 1
  jq -e --arg image "$image" --arg volume "$volume" --arg secret "$secret" \
    --arg network "$NETWORK" \
    --argjson expected "$expected" '
      .[0] as $c |
      $c.ImageName == $image and
      $c.Args == $expected and
      $c.HostConfig.ReadonlyRootfs == true and
      $c.HostConfig.PidsLimit == 512 and
      ($c.HostConfig.SecurityOpt | index("no-new-privileges") != null) and
      ([$c.Mounts[] | select(.Type == "volume" and .Name == $volume and
        .Destination == "/root/.cache" and .RW == false)] | length == 1) and
      ([$c.Config.Secrets[]? | select(.Name == $secret)] | length == 1) and
      ($c.NetworkSettings.Networks | has($network)) and
      (($c.HostConfig.PortBindings // {}) | length == 0) and
      (([$c.HostConfig.Devices[]?.PathInContainer |
          select(startswith("/dev/nvidia"))] | length > 0) or
       (($c.Config.CreateCommand // []) as $cmd |
        ($cmd | index("--device")) as $device_index |
        $device_index != null and
        $cmd[$device_index + 1] == "nvidia.com/gpu=all"))
    ' <<<"$inspect" >/dev/null
}

container_managed_for() {
  local id="$1" file container image source volume owner inspect
  file="$(resolve_profile "$id")"
  container="$(jq -r .container "$file")"
  image="$(jq -r .image "$file")"
  source="$(jq -r .model_source "$file")"
  volume="$(jq -r .volume "$file")"
  inspect="$(podman inspect "$container" 2>/dev/null)" || return 1
  owner="$(jq -r --arg label "$BACKEND_LABEL" \
    '.[0].Config.Labels[$label] // ""' <<<"$inspect")"
  [ "$owner" = "$id" ] && return 0
  [ -z "$owner" ] || return 1

  # Backends created before ownership labels were introduced are recognized by
  # the full Hermes-specific image, model, volume, and isolation signature.
  jq -e --arg image "$image" --arg source "$source" --arg volume "$volume" '
      .[0] as $c |
      $c.ImageName == $image and
      $c.Args[0:2] == ["-hf", $source] and
      ([$c.Mounts[] | select(.Type == "volume" and .Name == $volume and
        .Destination == "/root/.cache")] | length == 1) and
      (($c.HostConfig.PortBindings // {}) | length == 0) and
      $c.HostConfig.Privileged == false and
      $c.HostConfig.ReadonlyRootfs == true and
      $c.HostConfig.PidsLimit == 512 and
      ($c.HostConfig.SecurityOpt | index("no-new-privileges") != null)
    ' <<<"$inspect" >/dev/null
}

list_profiles() {
  local tsv="${1:-}" id file label container state origin
  while IFS=$'\t' read -r id file; do
    [ -n "$id" ] || continue
    validate_profile "$file" "$id"
    label="$(jq -r .label "$file")"
    container="$(jq -r .container "$file")"
    origin=tracked
    [[ "$file" == "$LOCAL_DIR/"* ]] && origin=local
    if ! podman container exists "$container" 2>/dev/null; then
      state="not installed"
    elif container_compatible "$id"; then
      if container_running "$container"; then
        state=running
      else
        state=installed
      fi
    elif container_managed_for "$id"; then
      state="update needed"
    else
      state="name conflict"
    fi
    if [ "$tsv" = "--tsv" ]; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$state" "$origin"
    else
      printf '%-18s %-14s %-7s %s\n' "$id" "$state" "$origin" "$label"
    fi
  done < <(effective_profiles)
}

ensure_network() {
  if podman network exists "$NETWORK" 2>/dev/null; then
    [ "$(podman network inspect -f '{{.Internal}}' "$NETWORK")" = "true" ] ||
      die "refusing non-internal Podman network: $NETWORK"
  else
    podman network create --internal "$NETWORK" >/dev/null
  fi
}

ensure_secret() {
  local secret="$1"
  if ! podman secret inspect "$secret" >/dev/null 2>&1; then
    require_command openssl
    openssl rand -hex 32 | podman secret create "$secret" - >/dev/null
  fi
}

cleanup_download() {
  if [ -n "$DOWNLOAD_CONTAINER" ] && podman container exists "$DOWNLOAD_CONTAINER" 2>/dev/null; then
    podman stop --time 2 "$DOWNLOAD_CONTAINER" >/dev/null 2>&1 || true
    podman rm -f "$DOWNLOAD_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup_download EXIT INT TERM

download_profile() {
  local id="$1" cache_present="$2" file label image source volume
  local -a args=()
  file="$(resolve_profile "$id")"
  image="$(jq -r .image "$file")"
  label="$(jq -r .label "$file")"
  source="$(jq -r .model_source "$file")"
  volume="$(jq -r .volume "$file")"
  mapfile -t args < <(runtime_args_json "$file" | jq -r '.[]')
  DOWNLOAD_CONTAINER="hermes-model-download-$id-$$"
  if [ "$cache_present" = true ]; then
    echo "Verifying cached $label model data; missing files will be repaired if needed..."
  else
    echo "Downloading and verifying $label model data..."
  fi
  podman run --detach \
    --name "$DOWNLOAD_CONTAINER" \
    --network=pasta:--no-map-gw \
    --device nvidia.com/gpu=all \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1g \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=512 \
    -v "$volume:/root/.cache:rw" \
    "$image" \
    -hf "$source" "${args[@]}" \
    --no-webui --no-agent --host 0.0.0.0 --port 8080 >/dev/null

  local ready=false i
  for ((i = 1; i <= 3600; i++)); do
    if ! container_running "$DOWNLOAD_CONTAINER"; then
      podman logs "$DOWNLOAD_CONTAINER" >&2 || true
      die "model download/verification container exited: $id"
    fi
    if podman exec "$DOWNLOAD_CONTAINER" \
      curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
      ready=true
      break
    fi
    if ((i % 10 == 0)); then
      if [ "$cache_present" = true ]; then
        echo "  still verifying/loading ($i seconds)"
      else
        echo "  still downloading/loading ($i seconds)"
      fi
    fi
    sleep 1
  done
  [ "$ready" = true ] || die "timed out downloading/loading model: $id"
  podman stop --time 10 "$DOWNLOAD_CONTAINER" >/dev/null
  podman rm "$DOWNLOAD_CONTAINER" >/dev/null
  DOWNLOAD_CONTAINER=""
}

create_backend() {
  local id="$1" file image source container volume secret
  local -a args=()
  file="$(resolve_profile "$id")"
  image="$(jq -r .image "$file")"
  source="$(jq -r .model_source "$file")"
  container="$(jq -r .container "$file")"
  volume="$(jq -r .volume "$file")"
  secret="$(jq -r .secret "$file")"
  mapfile -t args < <(runtime_args_json "$file" | jq -r '.[]')
  podman create \
    --name "$container" \
    --label "$BACKEND_LABEL=$id" \
    --network "$NETWORK" \
    --device nvidia.com/gpu=all \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=1g \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=512 \
    --restart=no \
    -v "$volume:/root/.cache:ro" \
    --secret "$secret,target=llama-api-key" \
    "$image" \
    -hf "$source" --offline "${args[@]}" \
    --no-webui --no-agent --host 0.0.0.0 --port 8080 \
    --api-key-file /run/secrets/llama-api-key \
    --sleep-idle-seconds 60 >/dev/null
}

setup_profile() {
  local id="$1" file label image container volume secret size hardware answer
  local cache_present=false replacing=false
  file="$(resolve_profile "$id")"
  validate_profile "$file" "$id"
  label="$(jq -r .label "$file")"
  image="$(jq -r .image "$file")"
  container="$(jq -r .container "$file")"
  volume="$(jq -r .volume "$file")"
  secret="$(jq -r .secret "$file")"
  size="$(jq -r .download_gib "$file")"
  hardware="$(jq -r .tested_hardware "$file")"

  if podman container exists "$container" 2>/dev/null && container_compatible "$id"; then
    echo "$label is already installed and matches its profile."
    return
  fi

  if podman container exists "$container" 2>/dev/null; then
    if container_managed_for "$id"; then
      replacing=true
    else
      die "container name '$container' is already in use and is not managed by Hermes; rename or remove it, then retry"
    fi
  fi

  if model_cache_present "$id"; then
    cache_present=true
  fi

  echo "Local model: $label"
  echo "Tested hardware: $hardware"
  if [ "$cache_present" = true ]; then
    echo "Model cache: Found; it will be verified before use."
  else
    echo "Download required: approximately $size GiB"
    echo "Storage: Podman-managed model cache"
    read -r -p "Download and prepare this model? [y/N]: " answer
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) die "setup cancelled" ;;
    esac
  fi
  if [ "$replacing" = true ]; then
    echo "Updating local runtime configuration..."
  else
    echo "Preparing local runtime..."
  fi

  ensure_network
  ensure_secret "$secret"
  if ! podman image exists "$image"; then
    podman pull "$image"
  fi
  if ! podman volume exists "$volume"; then
    podman volume create "$volume" >/dev/null
  fi
  if [ "$replacing" = true ]; then
    podman stop --time 10 "$container" >/dev/null 2>&1 || true
  fi
  # Verification also repairs a pre-existing but incomplete cache.
  download_profile "$id" "$cache_present"
  if [ "$replacing" = true ]; then
    podman rm "$container" >/dev/null
  fi
  create_backend "$id"
  echo "Ready: $label"
}

prune_reservations() {
  local reservation pid id
  mkdir -p "$RESERVATION_DIR"
  shopt -s nullglob
  for reservation in "$RESERVATION_DIR"/*; do
    read -r pid id < "$reservation" || true
    if ! [[ "${pid:-}" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" 2>/dev/null ||
       ! valid_id "${id:-}"; then
      rm -f -- "$reservation"
    fi
  done
}

active_profile_conflict() {
  local wanted="$1" reservation pid active
  shopt -s nullglob
  for reservation in "$RESERVATION_DIR"/*; do
    read -r pid active < "$reservation" || continue
    if [ "$active" != "$wanted" ]; then
      printf '%s\n' "$active"
      return 0
    fi
  done
  return 1
}

acquire_profile() {
  local id="$1" session="$2" owner_pid="$3" container conflict context
  local other_id other_file other_container
  valid_id "$id" || die "invalid local-model profile ID: $id"
  [[ "$session" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid session name"
  [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || die "invalid reservation PID"
  container="$(profile_field "$id" container)"
  podman container exists "$container" 2>/dev/null ||
    die "local model '$id' is not installed; run: just local-setup $id"
  podman network exists "$NETWORK" 2>/dev/null &&
    [ "$(podman network inspect -f '{{.Internal}}' "$NETWORK")" = "true" ] ||
    die "missing or non-internal local-model network: $NETWORK"
  container_compatible "$id" ||
    die "local model '$id' has configuration drift; run: just local-setup $id"

  mkdir -p "$RESERVATION_DIR"
  exec 9>"$LOCK_FILE"
  flock 9
  prune_reservations
  conflict="$(active_profile_conflict "$id" || true)"
  if [ -n "$conflict" ]; then
    flock -u 9
    die "cannot start $id while local model $conflict is reserved by another Hermes session"
  fi

  while IFS=$'\t' read -r other_id other_file; do
    [ -n "$other_id" ] && [ "$other_id" != "$id" ] || continue
    other_container="$(jq -r .container "$other_file")"
    if container_running "$other_container"; then
      echo "Stopping stale local backend: $other_container"
      podman stop --time 10 "$other_container" >/dev/null
    fi
  done < <(effective_profiles)

  printf '%s %s\n' "$owner_pid" "$id" > "$RESERVATION_DIR/$session"
  if ! container_running "$container"; then
    echo "Starting local backend: $container"
    if ! podman start "$container" >/dev/null; then
      rm -f -- "$RESERVATION_DIR/$session"
      flock -u 9
      die "failed to start local backend: $container"
    fi
  else
    echo "Reusing local backend: $container"
  fi

  local ready=false i
  for ((i = 1; i <= 900; i++)); do
    if ! container_running "$container"; then
      rm -f -- "$RESERVATION_DIR/$session"
      flock -u 9
      die "local backend exited while loading: $container"
    fi
    if podman exec "$container" curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
      ready=true
      break
    fi
    if ((i % 10 == 0)); then
      echo "  waiting for $container ($i seconds)"
    fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    rm -f -- "$RESERVATION_DIR/$session"
    podman stop --time 10 "$container" >/dev/null 2>&1 || true
    flock -u 9
    die "timed out waiting for local backend: $container"
  fi
  context="$(backend_context_value "$container" 2>/dev/null || true)"
  if [ -n "$context" ]; then
    printf 'Local context: %s tokens\n' "$context"
  fi
  flock -u 9
}

release_profile() {
  local id="$1" session="$2" container reservation pid active in_use=false
  valid_id "$id" || die "invalid local-model profile ID: $id"
  [[ "$session" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid session name"
  container="$(profile_field "$id" container)"
  mkdir -p "$RESERVATION_DIR"
  exec 9>"$LOCK_FILE"
  flock 9
  rm -f -- "$RESERVATION_DIR/$session"
  prune_reservations
  shopt -s nullglob
  for reservation in "$RESERVATION_DIR"/*; do
    read -r pid active < "$reservation" || continue
    if [ "$active" = "$id" ]; then
      in_use=true
      break
    fi
  done
  if [ "$in_use" = false ] && container_running "$container"; then
    echo "Stopping $container; no Hermes sessions are using it."
    podman stop --time 10 "$container" >/dev/null
  fi
  flock -u 9
}

usage() {
  cat <<'EOF'
usage: local-models.sh COMMAND [ARGS]

  list [--tsv]                 list effective profiles and installation state
  validate                     validate tracked and local profiles
  profile ID                   print one effective profile as JSON
  field ID FIELD               print one validated profile field
  installed ID                 succeed when the profile container exists
  compatible ID                succeed when the installed container matches
  setup ID                     explicitly install/synchronize one profile
  acquire ID SESSION PID       reserve and start one profile backend
  release ID SESSION           release and possibly stop one profile backend
EOF
}

require_command jq
require_command podman

command_name="${1:-}"
shift || true
case "$command_name" in
  list) list_profiles "${1:-}" ;;
  validate) [ "$#" -eq 0 ] || die "validate takes no arguments"; validate_all ;;
  profile) [ "$#" -eq 1 ] || die "profile requires ID"; profile_json "$1" ;;
  field) [ "$#" -eq 2 ] || die "field requires ID and FIELD"; profile_field "$1" "$2" ;;
  installed) [ "$#" -eq 1 ] || die "installed requires ID"; is_installed "$1" ;;
  compatible) [ "$#" -eq 1 ] || die "compatible requires ID"; container_compatible "$1" ;;
  setup) [ "$#" -eq 1 ] || die "setup requires exactly one profile ID"; setup_profile "$1" ;;
  acquire) [ "$#" -eq 3 ] || die "acquire requires ID, SESSION, and PID"; acquire_profile "$1" "$2" "$3" ;;
  release) [ "$#" -eq 2 ] || die "release requires ID and SESSION"; release_profile "$1" "$2" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
