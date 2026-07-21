#!/usr/bin/env bash
# Review and import committed work from one or more disposable Hermes clones.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
REPOS_DIR="${HERMES_REPOS_DIR:-$HERE/repos}"
PRIMARY_DIR="${HERMES_PRIMARY_DIR:-$HOME/projects}"

normalize_repo() {
  local input="$1"
  local name top expected
  if [[ "$input" == */* ]]; then
    top="$(git -C "$input" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || { echo "not a Git repository: $input" >&2; return 1; }
    name="$(basename "$top")"
    expected="$PRIMARY_DIR/$name"
    if [ "$(readlink -f "$top")" != "$(readlink -f "$expected" 2>/dev/null || true)" ]; then
      echo "repository paths must identify a direct checkout under $PRIMARY_DIR: $input" >&2
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

[ "$#" -gt 0 ] || { echo "usage: $0 REPO [REPO ...]" >&2; exit 2; }

REPOS=()
declare -A SEEN=()
declare -A START_REFS=()
declare -A SOURCE_HEADS=()
declare -A TARGET_BRANCHES=()
declare -A TARGET_HEADS=()
declare -A COMMIT_COUNTS=()
TOTAL_COMMITS=0

# Preflight every repository before changing any primary checkout.
for input in "$@"; do
  repo="$(normalize_repo "$input")"
  if [ -n "${SEEN[$repo]:-}" ]; then
    echo "duplicate repository: $repo" >&2
    exit 2
  fi
  SEEN[$repo]=1
  REPOS+=("$repo")

  clone="$REPOS_DIR/$repo"
  primary="$PRIMARY_DIR/$repo"
  clone_top="$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null || true)"
  primary_top="$(git -C "$primary" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$clone_top" ] || [ "$(readlink -f "$clone_top" 2>/dev/null || true)" != "$(readlink -f "$clone" 2>/dev/null || true)" ]; then
    echo "missing or invalid disposable clone: $clone" >&2
    exit 1
  fi
  if [ -z "$primary_top" ] || [ "$(readlink -f "$primary_top" 2>/dev/null || true)" != "$(readlink -f "$primary" 2>/dev/null || true)" ]; then
    echo "missing or invalid primary checkout: $primary" >&2
    exit 1
  fi
  if [ -n "$(git -C "$clone" status --porcelain)" ]; then
    echo "disposable clone has uncommitted changes; commit them first: $clone" >&2
    git -C "$clone" status --short >&2
    exit 1
  fi
  if [ -n "$(git -C "$primary" status --porcelain)" ]; then
    echo "primary checkout is dirty; commit or stash changes first: $primary" >&2
    git -C "$primary" status --short >&2
    exit 1
  fi
  branch="$(git -C "$primary" symbolic-ref --quiet --short HEAD || true)"
  if [ -z "$branch" ]; then
    echo "primary checkout has detached HEAD; check out a target branch first: $primary" >&2
    exit 1
  fi
  if git -C "$clone" rev-parse --verify refs/hermes/imported >/dev/null 2>&1; then
    start=refs/hermes/imported
  elif git -C "$clone" rev-parse --verify 'hermes-base^{commit}' >/dev/null 2>&1; then
    start=hermes-base
  else
    echo "disposable clone is missing hermes-base: $clone" >&2
    exit 1
  fi
  if ! git -C "$clone" merge-base --is-ancestor "$start" HEAD; then
    echo "import marker is not an ancestor of disposable HEAD: $clone" >&2
    exit 1
  fi
  merges="$(git -C "$clone" rev-list --min-parents=2 "$start"..HEAD)"
  if [ -n "$merges" ]; then
    echo "merge commits are not supported by get-repo: $clone" >&2
    git -C "$clone" log --oneline --merges "$start"..HEAD >&2
    exit 1
  fi
  count="$(git -C "$clone" rev-list --count "$start"..HEAD)"
  head="$(git -C "$clone" rev-parse HEAD)"
  START_REFS[$repo]="$start"
  SOURCE_HEADS[$repo]="$head"
  TARGET_BRANCHES[$repo]="$branch"
  TARGET_HEADS[$repo]="$(git -C "$primary" rev-parse HEAD)"
  COMMIT_COUNTS[$repo]="$count"
  TOTAL_COMMITS=$((TOTAL_COMMITS + count))
done

for repo in "${REPOS[@]}"; do
  clone="$REPOS_DIR/$repo"
  echo
  echo "== $repo =="
  echo "Target: $PRIMARY_DIR/$repo"
  echo "Branch: ${TARGET_BRANCHES[$repo]}"
  echo "New commits: ${COMMIT_COUNTS[$repo]}"
  if [ "${COMMIT_COUNTS[$repo]}" -gt 0 ]; then
    git -C "$clone" log --oneline --reverse "${START_REFS[$repo]}"..HEAD
    echo "Files:"
    git -C "$clone" diff --stat "${START_REFS[$repo]}"..HEAD
  fi
done

if [ "$TOTAL_COMMITS" -eq 0 ]; then
  echo
  echo "nothing new to import"
  exit
fi

echo
echo "This will cherry-pick $TOTAL_COMMITS commit(s) onto the current branch of ${#REPOS[@]} primary checkout(s)."
read -r -p "Type IMPORT to continue: " CONFIRM
if [ "$CONFIRM" != "IMPORT" ]; then
  echo "not imported"
  exit 1
fi

for repo in "${REPOS[@]}"; do
  count="${COMMIT_COUNTS[$repo]}"
  [ "$count" -gt 0 ] || continue
  clone="$REPOS_DIR/$repo"
  primary="$PRIMARY_DIR/$repo"
  source_head="${SOURCE_HEADS[$repo]}"
  start="${START_REFS[$repo]}"

  if [ -n "$(git -C "$primary" status --porcelain)" ] || \
     [ "$(git -C "$primary" symbolic-ref --quiet --short HEAD || true)" != "${TARGET_BRANCHES[$repo]}" ] || \
     [ "$(git -C "$primary" rev-parse HEAD)" != "${TARGET_HEADS[$repo]}" ]; then
    echo "primary checkout changed after preflight; refusing import: $primary" >&2
    exit 1
  fi
  if [ "$(git -C "$clone" rev-parse HEAD)" != "$source_head" ] || \
     [ -n "$(git -C "$clone" status --porcelain)" ]; then
    echo "disposable clone changed after preflight; refusing import: $clone" >&2
    exit 1
  fi

  echo
  echo "Importing $repo onto ${TARGET_BRANCHES[$repo]}..."
  git -C "$primary" fetch "$clone" "$source_head"
  mapfile -t commits < <(git -C "$clone" rev-list --reverse --topo-order "$start".."$source_head")
  git -C "$primary" cherry-pick --allow-empty "${commits[@]}"
  git -C "$clone" update-ref refs/hermes/imported "$source_head"
  echo "Imported $count commit(s) from $repo"
done

echo
echo "Import complete. Disposable clones were retained."
