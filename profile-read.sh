#!/usr/bin/env bash
# Read and validate declarative capability profiles for the Hermes sandbox.
# Profiles are data, not code. The launcher consumes them to generate Podman flags.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
CATALOG_DIR="${HERMES_CAPABILITY_CATALOG:-$HERE/profiles/capabilities}"
LOCAL_DIR="${HERMES_CAPABILITY_LOCAL:-$HERE/profiles/capabilities.local}"
SCHEMA="$CATALOG_DIR/schema.json"

die() { echo "$*" >&2; exit 1; }
valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

resolve_profile() {
  local id="$1"
  valid_id "$id" || die "invalid capability profile ID: $id"
  if [ -f "$LOCAL_DIR/$id.json" ]; then
    printf '%s\n' "$LOCAL_DIR/$id.json"
  elif [ -f "$CATALOG_DIR/$id.json" ]; then
    printf '%s\n' "$CATALOG_DIR/$id.json"
  else
    die "unknown capability profile: $id"
  fi
}

effective_profiles() {
  local file id
  declare -A files=()
  shopt -s nullglob
  for file in "$CATALOG_DIR"/*.json; do
    [ "$(basename "$file")" = "schema.json" ] && continue
    id="$(basename "$file" .json)"
    files[$id]="$file"
  done
  if [ -d "$LOCAL_DIR" ]; then
    for file in "$LOCAL_DIR"/*.json; do
      id="$(basename "$file" .json)"
      files[$id]="$file"
    done
  fi
  for id in "${!files[@]}"; do
    printf '%s\t%s\n' "$id" "${files[$id]}"
  done | sort
}

validate_one() {
  local file="$1" expected_id="$2"
  [ -f "$file" ] || die "missing profile: $file"
  [ -f "$SCHEMA" ] || die "missing capability schema: $SCHEMA"

  if ! jq -e --arg id "$expected_id" '.id == $id' "$file" >/dev/null 2>&1; then
    die "profile $expected_id: .id does not match filename"
  fi

  # Structural checks: object, required fields, no extra keys.
  jq -e '
    type == "object" and
    (.id       | type == "string") and
    (.label    | type == "string" and length > 0) and
    (.network  | type == "string") and
    (.model    | type == "object")
  ' "$file" >/dev/null 2>&1 || die "profile $expected_id: missing or invalid required fields"

  # Optional fields: must be the correct type if present.
  if jq -e 'has("description")' "$file" >/dev/null 2>&1; then
    jq -e '.description | type == "string"' "$file" >/dev/null 2>&1 || \
      die "profile $expected_id: .description must be a string"
  fi
  if jq -e 'has("mounts")' "$file" >/dev/null 2>&1; then
    jq -e '.mounts | type == "object"' "$file" >/dev/null 2>&1 || \
      die "profile $expected_id: .mounts must be an object (not null, scalar, or array)"
  fi
  if jq -e 'has("compute")' "$file" >/dev/null 2>&1; then
    jq -e '.compute | type == "object"' "$file" >/dev/null 2>&1 || \
      die "profile $expected_id: .compute must be an object (not null, scalar, or array)"
  fi

  # Closed object shape: reject any key not in the schema.
  local allowed_keys extra
  allowed_keys='["id","label","description","network","mounts","compute","model"]'
  extra="$(jq -r --argjson allowed "$allowed_keys" '
    [ keys[] | select(. as $k | $allowed | index($k) | not) ]
    | if length > 0 then join(", ") else empty end
  ' "$file")"
  [ -z "$extra" ] || die "profile $expected_id: unknown top-level key(s): $extra"

  local network
  network="$(jq -r '.network' "$file")"
  case "$network" in
    internet|llm-gateway|local-dual) ;;
    *) die "profile $expected_id: unknown network type '$network'" ;;
  esac

  # Cross-field validation.
  # datasets mount requires llm-gateway network (analysis mode only).
  if jq -e '.mounts.datasets' "$file" >/dev/null 2>&1 && [ "$network" != "llm-gateway" ]; then
    die "profile $expected_id: mounts.datasets requires network=llm-gateway, got '$network'"
  fi
  # local-dual network requires model.type=local.
  local model_type
  model_type="$(jq -r '.model.type' "$file")"
  if [ "$network" = "local-dual" ] && [ "$model_type" != "local" ]; then
    die "profile $expected_id: network=local-dual requires model.type=local, got '$model_type'"
  fi
  # model.type=local requires a local-capable network.
  if [ "$model_type" = "local" ] && [ "$network" != "local-dual" ]; then
    die "profile $expected_id: model.type=local requires network=local-dual, got '$network'"
  fi

  # Model validation.
  case "$model_type" in
    cloud) ;;
    local)
      local local_profile
      jq -e '.model.local_profile | type == "string"' "$file" >/dev/null 2>&1 || \
        die "profile $expected_id: model.local_profile must be a string"
      local_profile="$(jq -r '.model.local_profile' "$file")"
      [ -n "$local_profile" ] || die "profile $expected_id: local model requires model.local_profile"
      valid_id "$local_profile" || die "profile $expected_id: invalid model.local_profile '$local_profile'"
      ;;
    *) die "profile $expected_id: unknown model type '$model_type'" ;;
  esac

  # Reject unknown model keys.
  local model_extra
  model_extra="$(jq -r '
    .model | [ keys[] | select(. as $k | ["type","local_profile"] | index($k) | not) ]
    | if length > 0 then join(", ") else empty end
  ' "$file")"
  [ -z "$model_extra" ] || die "profile $expected_id: unknown model key(s): $model_extra"

  # Mounts validation.
  if jq -e '.mounts' "$file" >/dev/null 2>&1; then
    jq -e '.mounts | type == "object"' "$file" >/dev/null 2>&1 || \
      die "profile $expected_id: .mounts must be an object"

    local mount_keys mount_val
    mount_keys="$(jq -r '.mounts | keys[]' "$file")"
    for key in $mount_keys; do
      case "$key" in
        repos)   mount_val="$(jq -r '.mounts.repos' "$file")"
                 [ "$mount_val" = "rw" ] || die "profile $expected_id: mounts.repos must be \"rw\", got \"$mount_val\"" ;;
        data)    mount_val="$(jq -r '.mounts.data' "$file")"
                 [ "$mount_val" = "ro" ] || die "profile $expected_id: mounts.data must be \"ro\", got \"$mount_val\"" ;;
        datasets) mount_val="$(jq -r '.mounts.datasets' "$file")"
                  [ "$mount_val" = "ro" ] || die "profile $expected_id: mounts.datasets must be \"ro\", got \"$mount_val\"" ;;
        outbox)  mount_val="$(jq -r '.mounts.outbox' "$file")"
                 [ "$mount_val" = "rw" ] || die "profile $expected_id: mounts.outbox must be \"rw\", got \"$mount_val\"" ;;
        *) die "profile $expected_id: unknown mount key '$key'" ;;
      esac
    done

    # Reject extra keys inside mounts object.
    local mount_allowed mount_inner_extra
    mount_allowed='["repos","data","datasets","outbox"]'
    mount_inner_extra="$(jq -r --argjson allowed "$mount_allowed" '
      .mounts | [ keys[] | select(. as $k | $allowed | index($k) | not) ]
      | if length > 0 then join(", ") else empty end
    ' "$file")"
    [ -z "$mount_inner_extra" ] || die "profile $expected_id: unknown mount key(s): $mount_inner_extra"
  fi

  # Compute validation.
  if jq -e '.compute' "$file" >/dev/null 2>&1; then
    jq -e '.compute | type == "object"' "$file" >/dev/null 2>&1 || \
      die "profile $expected_id: .compute must be an object"

    local compute_keys
    compute_keys="$(jq -r '.compute | keys[]' "$file")"
    for key in $compute_keys; do
      case "$key" in
        gpu)
          jq -e '.compute.gpu | type == "boolean"' "$file" >/dev/null 2>&1 || \
            die "profile $expected_id: compute.gpu must be a boolean"
          ;;
        *) die "profile $expected_id: unknown compute key '$key'" ;;
      esac
    done

    # Reject extra keys inside compute object.
    local comp_allowed comp_inner_extra
    comp_allowed='["gpu"]'
    comp_inner_extra="$(jq -r --argjson allowed "$comp_allowed" '
      .compute | [ keys[] | select(. as $k | $allowed | index($k) | not) ]
      | if length > 0 then join(", ") else empty end
    ' "$file")"
    [ -z "$comp_inner_extra" ] || die "profile $expected_id: unknown compute key(s): $comp_inner_extra"
  fi
}

validate_all() {
  local id file count=0
  while IFS=$'\t' read -r id file; do
    [ -n "$id" ] || continue
    validate_one "$file" "$id"
    count=$((count + 1))
  done < <(effective_profiles)
  [ "$count" -gt 0 ] || die "no capability profiles found"
  echo "validated $count capability profile(s)"
}

read_profile() {
  local id="$1" file
  file="$(resolve_profile "$id")"
  validate_one "$file" "$id"
  jq -c '.' "$file"
}

list_profiles() {
  local id file label network description
  while IFS=$'\t' read -r id file; do
    [ -n "$id" ] || continue
    label="$(jq -r '.label' "$file")"
    network="$(jq -r '.network' "$file")"
    description="$(jq -r '.description // ""' "$file")"
    printf '%-16s %-14s %s\n' "$id" "$network" "$label"
    [ -n "$description" ] && printf '  %s\n' "$description"
  done < <(effective_profiles)
}

usage() {
  cat <<'EOSAGE'
usage: profile-read.sh COMMAND [ARGS]

  list                          list available capability profiles
  validate                      validate all profiles
  read ID                       print one profile as JSON
EOSAGE
}

command -v jq >/dev/null 2>&1 || die "missing required command: jq"

MODE="${1:-}"
shift || true

case "$MODE" in
  list)    list_profiles ;;
  validate) validate_all ;;
  read)
    [ "$#" -ge 1 ] || die "profile-read.sh read requires a profile ID"
    read_profile "$1"
    ;;
  *) usage >&2; exit 2 ;;
esac
