#!/usr/bin/env bash
# Check out the three service repos at the refs pinned in sources.env, into .src/{auth,kb,agent}:
# the build contexts of container/build.sh and the compose files.
#
#   scripts/fetch-sources.sh                  all three
#   scripts/fetch-sources.sh kb               only some
#   KB_REF=my-branch scripts/fetch-sources.sh kb
#
# git uses your own credentials (SSH agent, credential helper), so private repos work as for any
# clone; or set AGENTICWF_TOKEN to a GitHub token with read access to the three repos (as in CI),
# used for https://github.com/ only and never written to .git/config. A checkout with local changes is left alone (with a warning), so you can work in .src/;
# to build from a checkout elsewhere instead, set AUTH_SRC / KB_SRC / AGENT_SRC (README.md, Build).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# The pins, unless the environment overrides them.
while IFS='=' read -r key value; do
    [[ $key =~ ^(AUTH|KB|AGENT)_(REPO|REF)$ ]] || continue
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
done < "$root/sources.env"

# The token as an HTTP header for github.com, through git's environment config (as actions/checkout
# does it), so it is neither on the command line nor stored in the checkouts.
if [[ -n "${AGENTICWF_TOKEN:-}" ]]; then
    n=${GIT_CONFIG_COUNT:-0}
    export "GIT_CONFIG_KEY_$n=http.https://github.com/.extraheader"
    export "GIT_CONFIG_VALUE_$n=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$AGENTICWF_TOKEN" | base64 | tr -d '\n')"
    export GIT_CONFIG_COUNT=$((n + 1))
fi

fetch() {   # fetch <name> <repo> <ref>
    local name=$1 repo=$2 ref=$3 dir=$root/.src/$1
    if [[ ! -d "$dir/.git" ]]; then
        echo "[fetch-sources] cloning $repo into .src/$name"
        git clone --quiet "$repo" "$dir"
    elif [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
        echo "[fetch-sources] WARNING: .src/$name has local changes; left at $(git -C "$dir" rev-parse --short HEAD)" >&2
        return 0
    else
        git -C "$dir" remote set-url origin "$repo"
        git -C "$dir" fetch --quiet --tags --force origin
    fi
    # A branch builds its latest commit on the remote; a tag or commit builds exactly that.
    if git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$ref" >/dev/null; then
        git -C "$dir" checkout --quiet --detach "origin/$ref"
    else
        git -C "$dir" checkout --quiet --detach "$ref"
    fi
    echo "[fetch-sources] .src/$name = $ref ($(git -C "$dir" rev-parse --short HEAD))"
}

names=("$@")
(( ${#names[@]} )) || names=(auth kb agent)
mkdir -p "$root/.src"
for name in "${names[@]}"; do
    case "$name" in
        auth)  fetch auth "$AUTH_REPO" "$AUTH_REF" ;;
        kb)    fetch kb "$KB_REPO" "$KB_REF" ;;
        agent) fetch agent "$AGENT_REPO" "$AGENT_REF" ;;
        *) echo "fetch-sources: unknown source '$name' (auth, kb, agent)" >&2; exit 2 ;;
    esac
done
