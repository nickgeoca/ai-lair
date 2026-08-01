# Hermes Agent in the rootless podman sandbox (see run.sh for details)

set positional-arguments

# list available capability profiles
capability-profiles:
    ./profile-read.sh list

# inspect host prerequisites and the pinned Hermes image without changing state
doctor:
    ./doctor.sh

# build the source-pinned Hermes Agent image expected by the launchers
image:
    ./build-hermes-image.sh

# create runtime directories and build the image; pass --rebuild to replace it
bootstrap option="":
    ./bootstrap.sh {{ quote(option) }}

# claim the first available slot and start an interactive Hermes TUI
run:
    ./slot-run.sh run

# use the public AI Lair CLI; for example: just lair add repo example-api
lair *args:
    ./lair {{ args }}

# set the maximum parallel slot count, or show slot status when omitted
slots count="":
    ./slot-run.sh slots {{ quote(count) }}

# show active, reserved, stopped, and free Hermes slots
status:
    ./slot-run.sh status

# list tested local-model profiles and their installation state
local-models:
    ./local-models.sh list

# explicitly install or synchronize one local-model profile
local-setup profile:
    ./local-models.sh setup {{ quote(profile) }}

# run syntax and profile checks without downloading models
test:
    bash -n ./lair ./*.sh ./tests/*.sh
    ./tests/lair.sh
    ./profile-read.sh validate
    ./tests/capability-profiles.sh
    ./tests/run-capability-args.sh
    ./tests/run-safe-roots.sh
    ./tests/pdf-tools.sh
    ./tests/local-models.sh
    ./tests/release-tools.sh
    ./local-models.sh validate

# run with selected disposable repository clones and normal Internet access
run-repo +repos:
    #!/usr/bin/env bash
    set -euo pipefail
    exec ./slot-run.sh repo "$@"

# run with selected files/directories mounted read-only and normal Internet
run-data +paths:
    #!/usr/bin/env bash
    set -euo pipefail
    exec ./slot-run.sh data "$@"

# review and import new commits from disposable clones into current branches
get-repo +repos:
    #!/usr/bin/env bash
    set -euo pipefail
    exec ./get-repo.sh "$@"

# first-run wizard: pick provider (OpenRouter), paste API key, choose model
setup:
    ./run.sh setup

# switch provider/model later
model:
    ./run.sh model

# discover and change common Hermes settings for the default profile
options:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Hermes options"
    echo "1) Show slot status and maximum"
    echo "2) Set maximum parallel slots"
    echo "3) Show delegation settings (default profile)"
    echo "4) Delegation: flat (5 parallel leaf agents, 30 iterations)"
    echo "5) Delegation: default (3 parallel leaf agents, 50 iterations)"
    echo "6) Select default provider/model"
    echo "7) Show full Hermes configuration"
    read -r -p "Select [1-7]: " CHOICE
    case "$CHOICE" in
        1) just status ;;
        2)
            read -r -p "Maximum slots [1-16]: " COUNT
            just slots "$COUNT"
            ;;
        3) just delegation-show ;;
        4) just delegation flat ;;
        5) just delegation default ;;
        6) ./run.sh model ;;
        7) just _sandbox "hermes config show" ;;
        *)
            echo "invalid selection: $CHOICE" >&2
            exit 2
            ;;
    esac

# legacy single-profile model menu
[private]
pick-run:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "1) DeepSeek V4 Flash (default) — OpenRouter / Novita FP8"
    echo "2) DeepSeek V4 Pro — OpenRouter / Novita FP8"
    echo "3) Kimi K3 — OpenRouter / Moonshot AI"
    echo "4) Tencent Hy3 — OpenRouter / DeepInfra FP8 (\$0.14/M input, \$0.58/M output, \$0.035/M cache read)"
    echo "5) Hermes provider/model picker (changes saved default)"
    read -r -p "Select [1-5]: " CHOICE
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
            RESTORE_ROUTE=novita/fp8
            ;;
        4)
            MODEL=tencent/hy3
            ROUTE=deepinfra/fp8
            RESTORE_ROUTE=novita/fp8
            ;;
        5)
            ./run.sh model
            exec ./run.sh --tui
            ;;
        *)
            echo "invalid selection: $CHOICE" >&2
            exit 2
            ;;
    esac
    just _sandbox "hermes config set provider_routing.only.0 $ROUTE"
    if [ -n "${RESTORE_ROUTE:-}" ]; then
        trap 'just _sandbox "hermes config set provider_routing.only.0 novita/fp8"' EXIT
        ./run.sh --tui --model "$MODEL" --provider openrouter
        exit
    fi
    exec ./run.sh --tui --model "$MODEL" --provider openrouter

# legacy manual parallel-profile setup
[private]
parallel-setup profile:
    #!/usr/bin/env bash
    set -euo pipefail
    PROFILE={{ quote(profile) }}
    if [[ ! "$PROFILE" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
        echo "invalid profile name: $PROFILE" >&2
        exit 2
    fi
    just _sandbox "hermes profile create $PROFILE --clone"

# legacy manual parallel-profile launcher
[private]
parallel-pick profile:
    #!/usr/bin/env bash
    set -euo pipefail
    PROFILE={{ quote(profile) }}
    if [[ ! "$PROFILE" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
        echo "invalid profile name: $PROFILE" >&2
        exit 2
    fi
    CONTAINER_NAME="hermes-$PROFILE"
    echo "Parallel profile: $PROFILE"
    echo "1) DeepSeek V4 Flash — OpenRouter / Novita FP8"
    echo "2) DeepSeek V4 Pro — OpenRouter / Novita FP8"
    echo "3) Kimi K3 — OpenRouter / Moonshot AI"
    echo "4) Tencent Hy3 — OpenRouter / DeepInfra FP8 (\$0.14/M input, \$0.58/M output, \$0.035/M cache read)"
    echo "5) Hermes provider/model picker (changes this profile's saved default)"
    read -r -p "Select [1-5]: " CHOICE
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
        4)
            MODEL=tencent/hy3
            ROUTE=deepinfra/fp8
            ;;
        5)
            HERMES_CONTAINER_NAME="$CONTAINER_NAME" ./run.sh --profile "$PROFILE" model
            exec env HERMES_CONTAINER_NAME="$CONTAINER_NAME" ./run.sh --profile "$PROFILE" --tui
            ;;
        *)
            echo "invalid selection: $CHOICE" >&2
            exit 2
            ;;
    esac
    HERMES_CONTAINER_NAME="$CONTAINER_NAME" ./run.sh --profile "$PROFILE" \
        config set provider_routing.only.0 "$ROUTE"
    exec env HERMES_CONTAINER_NAME="$CONTAINER_NAME" ./run.sh \
        --profile "$PROFILE" --tui --model "$MODEL" --provider openrouter

# force the modern terminal UI for the configured default model
[private]
tui:
    ./run.sh --tui

# shell inside the sandbox to poke around
[private]
shell:
    ./run.sh bash

# normal mode with one or more selected repos; missing clones are created
[private]
repo-run +repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    just _repo-ensure "$REPO_WORDS"
    HERMES_REPO_REQUIRED=1 HERMES_REPOS="$REPO_WORDS" ./run.sh --tui

# restricted analysis with zero or more selected repos
[private]
analysis *repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    [ -z "$REPO_WORDS" ] || just _repo-ensure "$REPO_WORDS"
    HERMES_REPOS="$REPO_WORDS" ./analysis.sh

# restricted shell with zero or more selected repos
[private]
analysis-shell *repos:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_WORDS={{ quote(repos) }}
    [ -z "$REPO_WORDS" ] || just _repo-ensure "$REPO_WORDS"
    HERMES_REPOS="$REPO_WORDS" ./analysis.sh bash

# verify that analysis mode can reach only the fixed LLM gateway
[private]
analysis-check:
    ./analysis.sh --check

# apply a delegation profile from profiles/<name>.conf, e.g. `just delegation flat`
[private]
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
[private]
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
            just _repo-create "$REPO"
        fi
    done

# internal helper: clone a clean primary checkout when repo-run needs it
_repo-create repo:
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
[private]
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
[private]
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
[private]
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
