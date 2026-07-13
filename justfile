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

# normal Internet-capable mode with exactly one disposable repository writable
repo-run repo:
    HERMES_REPO_REQUIRED=1 HERMES_REPO={{ quote(repo) }} ./run.sh

# restricted analysis, optionally with one repo: `just analysis sdk-rec`
analysis repo="":
    HERMES_REPO={{ quote(repo) }} ./analysis.sh

# restricted shell, optionally with one repo: `just analysis-shell sdk-rec`
analysis-shell repo="":
    HERMES_REPO={{ quote(repo) }} ./analysis.sh bash

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

# create an independent, disposable clone with no remote
repo-create repo:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO={{ quote(repo) }}
    case "$REPO" in
        ""|*[!A-Za-z0-9._-]*)
            echo "repository name may contain only letters, numbers, ., _, and -" >&2
            exit 1
            ;;
    esac
    SRC="$HOME/projects/$REPO"
    DST="$PWD/repos/$REPO"
    git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null
    if [ -e "$DST" ]; then
        echo "destination already exists: $DST" >&2
        exit 1
    fi
    mkdir -p "$PWD/repos"
    git clone --no-hardlinks "$SRC" "$DST"
    git -C "$DST" remote remove origin
    git -C "$DST" tag hermes-base HEAD
    echo "created disposable clone: $DST"

# delete a disposable clone after an explicit confirmation
repo-remove repo:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO={{ quote(repo) }}
    case "$REPO" in
        ""|*[!A-Za-z0-9._-]*)
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
        ""|*[!A-Za-z0-9._-]*)
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
