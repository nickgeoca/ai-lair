# Hermes Agent in the rootless podman sandbox (see run.sh for details)

# start the interactive chat TUI
run:
    ./run.sh

# first-run wizard: pick provider (OpenRouter), paste API key, choose model
setup:
    ./run.sh setup

# switch provider/model later
model:
    ./run.sh model

# shell inside the sandbox to poke around
shell:
    ./run.sh bash

# normal mode with one or more selected repos; missing clones are created
repo-run +repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    just _repo-ensure "$REPO_WORDS"
    HERMES_REPO_REQUIRED=1 HERMES_REPOS="$REPO_WORDS" ./run.sh

# restricted analysis with zero or more selected repos
analysis *repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    [ -z "$REPO_WORDS" ] || just _repo-ensure "$REPO_WORDS"
    HERMES_REPOS="$REPO_WORDS" ./analysis.sh

# restricted shell with zero or more selected repos
analysis-shell *repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    [ -z "$REPO_WORDS" ] || just _repo-ensure "$REPO_WORDS"
    HERMES_REPOS="$REPO_WORDS" ./analysis.sh bash

# verify that analysis mode can reach only the fixed LLM gateway
analysis-check:
    ./analysis.sh --check

# apply a delegation profile from profiles/<name>.conf, e.g. `just delegation flat`
delegation profile="flat":
    #!/usr/bin/env bash
    set -euo pipefail
    f="profiles/{{ profile }}.conf"
    if [ ! -f "$f" ]; then
        echo "no such profile '{{ profile }}' — available:" >&2
        ls profiles/ | sed 's/\.conf$//' >&2
        exit 1
    fi
    cmd=""
    while IFS='=' read -r k v; do
        k="${k%%#*}"; k="$(echo "$k" | tr -d '[:space:]')"
        v="${v%%#*}"; v="$(echo "$v" | tr -d '[:space:]')"
        [ -z "$k" ] && continue
        cmd+="hermes config set delegation.$k $v && "
    done < "$f"
    just _sandbox "${cmd}true"

# show the current delegation settings from the sandbox config
delegation-show:
    @just _sandbox "python -c \"import yaml; print(yaml.safe_dump({'delegation': (yaml.safe_load(open('/opt/data/config.yaml')) or {}).get('delegation', '(defaults — nothing overridden)')}, sort_keys=False), end='')\""

# run a shell command inside the sandbox: execs into the live hermes
# session if one is running, else does a one-shot container run
_sandbox cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    CMD={{ quote(cmd) }}
    if [ "$(podman inspect -f '{{ '{{.State.Running}}' }}' hermes 2>/dev/null)" = "true" ]; then
        podman exec --user hermes -e HOME=/opt/data hermes \
            bash -c "export PATH=/opt/hermes/.venv/bin:\$PATH; $CMD"
    else
        ./run.sh bash -c "$CMD"
    fi

# internal helper: validate/reuse selected clones and create missing ones
_repo-ensure repo_words:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repo_words) }}
    read -r -a REPOS <<< "$REPO_WORDS"
    for REPO in "${REPOS[@]}"; do
        case "$REPO" in
            .|..|*[!A-Za-z0-9._-]*)
                echo "invalid repository name: $REPO" >&2
                exit 1
                ;;
        esac
        DST="$PWD/repos/$REPO"
        if [ -e "$DST" ]; then
            TOP="$(git -C "$DST" rev-parse --show-toplevel 2>/dev/null || true)"
            if [ ! -d "$DST" ] || [ -L "$DST" ] || [ -z "$TOP" ] || [ "$(readlink -f "$TOP")" != "$(readlink -f "$DST")" ]; then
                echo "refusing invalid disposable repository: $DST" >&2
                exit 1
            fi
            echo "reusing disposable clone: $DST"
        else
            just repo-create "$REPO"
        fi
    done

# create an independent disposable clone of a clean primary checkout
repo-create repo:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO={{ quote(repo) }}
    case "$REPO" in
        ""|.|..|*[!A-Za-z0-9._-]*)
            echo "repository name may contain only letters, numbers, ., _, and -" >&2
            exit 1
            ;;
    esac
    SRC="$HOME/projects/$REPO"
    DST="$PWD/repos/$REPO"
    TOP="$(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$TOP" ] || [ "$(readlink -f "$TOP")" != "$(readlink -f "$SRC")" ]; then
        echo "not a primary Git checkout: $SRC" >&2
        exit 1
    fi
    if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
        echo "primary checkout is dirty; commit or stash its changes first: $SRC" >&2
        exit 1
    fi
    if [ -e "$DST" ]; then
        echo "destination already exists: $DST" >&2
        exit 1
    fi
    mkdir -p "$PWD/repos"
    git clone --no-hardlinks "$SRC" "$DST"
    git -C "$DST" remote remove origin
    git -C "$DST" tag hermes-base HEAD
    echo "created disposable clone: $DST"

# summarize disposable changes; optionally limit to named repos
repo-check *repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    REPOS=()
    if [ -n "$REPO_WORDS" ]; then
        read -r -a REPOS <<< "$REPO_WORDS"
    else
        shopt -s nullglob
        for PATHNAME in "$PWD"/repos/*; do
            [ -d "$PATHNAME" ] && REPOS+=("${PATHNAME##*/}")
        done
    fi
    if [ "${#REPOS[@]}" -eq 0 ]; then
        echo "no disposable repositories"
        exit 0
    fi
    for REPO in "${REPOS[@]}"; do
        case "$REPO" in
            .|..|*[!A-Za-z0-9._-]*)
                echo "invalid repository name: $REPO" >&2
                exit 1
                ;;
        esac
        CLONE="$PWD/repos/$REPO"
        PRIMARY="$HOME/projects/$REPO"
        TOP="$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -z "$TOP" ] || [ "$(readlink -f "$TOP")" != "$(readlink -f "$CLONE")" ]; then
            echo "missing or invalid disposable repository: $CLONE" >&2
            exit 1
        fi
        if ! git -C "$CLONE" rev-parse --verify 'hermes-base^{commit}' >/dev/null 2>&1; then
            echo "missing hermes-base tag: $CLONE" >&2
            exit 1
        fi
        echo
        echo "== $REPO =="
        echo "Working tree:"
        STATUS="$(git -C "$CLONE" status --short)"
        [ -n "$STATUS" ] && printf '%s\n' "$STATUS" || echo "  clean"
        echo "Files changed since clone creation:"
        CHANGED="$(git -C "$CLONE" diff --name-status hermes-base)"
        [ -n "$CHANGED" ] && printf '%s\n' "$CHANGED" || echo "  none"
        echo "Commits created in disposable clone:"
        COMMITS="$(git -C "$CLONE" log --oneline hermes-base..HEAD)"
        [ -n "$COMMITS" ] && printf '%s\n' "$COMMITS" || echo "  none"
        if git -C "$PRIMARY" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            BASE="$(git -C "$CLONE" rev-parse hermes-base)"
            PRIMARY_AHEAD="$(git -C "$PRIMARY" rev-list --count "$BASE"..HEAD 2>/dev/null || echo unknown)"
            CLONE_AHEAD="$(git -C "$CLONE" rev-list --count hermes-base..HEAD)"
            echo "Commits since shared base: primary=$PRIMARY_AHEAD disposable=$CLONE_AHEAD"
        fi
    done

# delete a disposable clone after an explicit confirmation
repo-remove repo:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO={{ quote(repo) }}
    case "$REPO" in
        ""|.|..|*[!A-Za-z0-9._-]*)
            echo "invalid repository name" >&2
            exit 1
            ;;
    esac
    DST="$PWD/repos/$REPO"
    git -C "$DST" rev-parse --is-inside-work-tree >/dev/null
    echo "Changes that exist only in the disposable clone:"
    git -C "$DST" status --short
    git -C "$DST" log --oneline hermes-base..HEAD 2>/dev/null || true
    read -r -p "Type REMOVE to delete $DST: " CONFIRM </dev/tty
    if [ "$CONFIRM" != "REMOVE" ]; then
        echo "not removed"
        exit 1
    fi
    rm -rf -- "$DST"

# fetch one Hermes commit and cherry-pick it into the primary checkout
repo-import repo commit="HEAD":
    #!/usr/bin/env bash
    set -euo pipefail
    REPO={{ quote(repo) }}
    COMMIT={{ quote(commit) }}
    case "$REPO" in
        ""|.|..|*[!A-Za-z0-9._-]*)
            echo "invalid repository name" >&2
            exit 1
            ;;
    esac
    SRC="$PWD/repos/$REPO"
    DST="$HOME/projects/$REPO"
    git -C "$SRC" rev-parse --verify "$COMMIT^{commit}" >/dev/null
    git -C "$DST" rev-parse --is-inside-work-tree >/dev/null
    if [ -n "$(git -C "$DST" status --porcelain)" ]; then
        echo "primary checkout is dirty; commit or stash its changes first" >&2
        exit 1
    fi
    git -C "$DST" fetch "$SRC" "$COMMIT"
    git -C "$DST" show --stat --oneline --summary FETCH_HEAD
    git -C "$DST" cherry-pick FETCH_HEAD
