#!/usr/bin/env bash
# Build the all-in-one image from the three service repos.
#
#   container/build.sh [extra docker buildx build args...]
#
#   # from your own working copies of the three repos:
#   AUTH_SRC=../AgenticWF-auth KB_SRC=../AgenticWF-KB AGENT_SRC=../AgenticWF-agent container/build.sh
#
# One image for both modes (AGENTICWF_MODE=server or local at run time), built for this machine's
# architecture: linux/amd64 has Logto (server and local); linux/arm64 has none (local only).
#
# The service repos are checked out at the refs pinned in sources.env into .src/ first
# (scripts/fetch-sources.sh), unless a *_SRC names another checkout.
#
# Environment:
#   IMAGE        image tag                     (default agenticwf:latest)
#   PLATFORM     the platform, e.g. linux/amd64 (default: this machine's)
#   AUTH_SRC     agenticwf-auth checkout       (default .src/auth, fetched)
#   KB_SRC       agenticwf-kb checkout         (default .src/kb, fetched)
#   AGENT_SRC    agenticwf-agent checkout      (default .src/agent, fetched)
#                e.g. AUTH_SRC=../AgenticWF-auth to build your own working copy
#   FETCH        0: build .src/ as it is, without fetching (offline)
#   NETWORK      network of the build's RUN steps (default host: dnf, pip and the downloads use the
#                host's network, for hosts whose firewall blocks bridged containers' outbound
#                traffic); NETWORK=default for Docker's bridge
#   DOCKER       docker or podman              (default docker)
#   AGENTICWF_TOKEN  GitHub token with read access to the private service repos, used to fetch them
#                (and, with docker, for a *_SRC that is a git URL); otherwise your git credentials
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
[[ -z "${TARGET:-}" ]] || echo "build.sh: TARGET is gone: one image runs both modes (AGENTICWF_MODE)" >&2
IMAGE=${IMAGE:-agenticwf:latest}
PLATFORM=${PLATFORM-}
DOCKER=${DOCKER:-docker}

# The pinned sources for every *_SRC that is not given.
fetch=()
[[ -n "${AUTH_SRC:-}" ]] || { AUTH_SRC=$root/.src/auth; fetch+=(auth); }
[[ -n "${KB_SRC:-}" ]] || { KB_SRC=$root/.src/kb; fetch+=(kb); }
[[ -n "${AGENT_SRC:-}" ]] || { AGENT_SRC=$root/.src/agent; fetch+=(agent); }
if (( ${#fetch[@]} )) && [[ "${FETCH:-1}" != 0 ]]; then
    "$root/scripts/fetch-sources.sh" "${fetch[@]}"
fi
for src in "$AUTH_SRC" "$KB_SRC" "$AGENT_SRC"; do
    [[ "$src" == *://* || -d "$src" ]] || { echo "build.sh: no such directory: $src (run scripts/fetch-sources.sh)" >&2; exit 1; }
done
echo "[build] $IMAGE${PLATFORM:+ ($PLATFORM)} from auth=$AUTH_SRC kb=$KB_SRC agent=$AGENT_SRC"

if [[ "$DOCKER" == podman ]]; then
    build=(podman build)
else
    build=("$DOCKER" buildx build --load)
fi
[[ -n "$PLATFORM" ]] && build+=(--platform "$PLATFORM")
NETWORK=${NETWORK:-host}
[[ "$NETWORK" == default ]] || build+=(--network "$NETWORK")
# BuildKit authenticates git URL build contexts on github.com with this secret.
[[ -n "${AGENTICWF_TOKEN:-}" && "$DOCKER" != podman ]] &&
    build+=(--secret id=GIT_AUTH_TOKEN.github.com,env=AGENTICWF_TOKEN)

exec "${build[@]}" \
    -f "$root/container/Dockerfile" \
    --build-context auth="$AUTH_SRC" \
    --build-context kb="$KB_SRC" \
    --build-context agent="$AGENT_SRC" \
    -t "$IMAGE" \
    "$@" \
    "$root"
