#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(dirname "$(readlink -f "$0")")/.."
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM

ROOT="$TMP/ai-lair"
PRIMARY="$TMP/projects"
mkdir -p "$ROOT/repos" "$ROOT/outbox" "$PRIMARY" "$ROOT/data/slots"
cp "$SOURCE_ROOT/lair" "$ROOT/lair"

cat > "$ROOT/slot-run.sh" <<'EOF'
#!/usr/bin/env bash
printf 'slot-run' >> "$LAIR_TEST_LOG"
printf ' <%s>' "$@" >> "$LAIR_TEST_LOG"
printf '\n' >> "$LAIR_TEST_LOG"
EOF
cat > "$ROOT/get-repo.sh" <<'EOF'
#!/usr/bin/env bash
printf 'get-repo' >> "$LAIR_TEST_LOG"
printf ' <%s>' "$@" >> "$LAIR_TEST_LOG"
printf '\n' >> "$LAIR_TEST_LOG"
EOF
for helper in doctor.sh run.sh; do
  cat > "$ROOT/$helper" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$(basename "$0" .sh)" >> "$LAIR_TEST_LOG"
[ "$#" -eq 0 ] || printf ' <%s>' "$@" >> "$LAIR_TEST_LOG"
printf '\n' >> "$LAIR_TEST_LOG"
EOF
done
chmod +x "$ROOT"/*.sh "$ROOT/lair"

LOG="$TMP/commands.log"
export LAIR_TEST_LOG="$LOG"
export HERMES_PRIMARY_DIR="$PRIMARY"
export HERMES_REPOS_DIR="$ROOT/repos"
export AI_LAIR_OUTBOX_DIR="$ROOT/outbox"

"$ROOT/lair"
"$ROOT/lair" add repo example-api example-web
"$ROOT/lair" add data "$TMP/input file.pdf"
"$ROOT/lair" get repo example-api
"$ROOT/lair" status
"$ROOT/lair" slots 3
"$ROOT/lair" setup
"$ROOT/lair" model
"$ROOT/lair" doctor

grep -Fxq 'slot-run <run>' "$LOG"
grep -Fxq 'slot-run <repo> <example-api> <example-web>' "$LOG"
grep -Fxq "slot-run <data> <$TMP/input file.pdf>" "$LOG"
grep -Fxq 'get-repo <example-api>' "$LOG"
grep -Fxq 'slot-run <status>' "$LOG"
grep -Fxq 'slot-run <slots> <3>' "$LOG"
grep -Fxq 'run <setup>' "$LOG"
grep -Fxq 'run <model>' "$LOG"
grep -Fxq 'doctor' "$LOG"

git -C "$PRIMARY" init -q example-api
git -C "$PRIMARY/example-api" config user.name tester
git -C "$PRIMARY/example-api" config user.email tester@example.invalid
touch "$PRIMARY/example-api/base"
git -C "$PRIMARY/example-api" add base
git -C "$PRIMARY/example-api" commit -qm base
git clone -q "$PRIMARY/example-api" "$ROOT/repos/example-api"
git -C "$ROOT/repos/example-api" config user.name tester
git -C "$ROOT/repos/example-api" config user.email tester@example.invalid
git -C "$ROOT/repos/example-api" tag hermes-base
touch "$ROOT/repos/example-api/ready"
git -C "$ROOT/repos/example-api" add ready
git -C "$ROOT/repos/example-api" commit -qm ready
touch "$ROOT/repos/example-api/uncommitted"
touch "$ROOT/outbox/report.pdf"
mkdir "$ROOT/outbox/charts"

inventory="$({ "$ROOT/lair" get; })"
grep -Fq 'AI Lair inventory' <<<"$inventory"
grep -Eq 'example-api +1 committed, plus uncommitted work' <<<"$inventory"
grep -Fq 'report.pdf' <<<"$inventory"
grep -Fq 'charts/' <<<"$inventory"

add_repos="$({ "$ROOT/lair" __complete add-repo; })"
get_repos="$({ "$ROOT/lair" __complete get-repo; })"
grep -Fxq example-api <<<"$add_repos"
grep -Fxq example-api <<<"$get_repos"

for shell in bash zsh fish; do
  completions="$({ "$ROOT/lair" completions "$shell"; })"
  grep -Fq lair <<<"$completions"
done

grep -Fq 'AI Lair 0.5.0-preview (Hermes harness)' < <("$ROOT/lair" version)

if "$ROOT/lair" add repo >/dev/null 2>&1; then
  echo "lair add repo accepted a missing repository" >&2
  exit 1
fi
if "$ROOT/lair" get data example >/dev/null 2>&1; then
  echo "lair get accepted unsupported data retrieval" >&2
  exit 1
fi

echo "lair CLI tests passed"
