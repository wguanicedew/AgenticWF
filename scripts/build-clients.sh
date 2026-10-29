#!/usr/bin/env bash
# Build the three client packages, wheel and sdist, into dist/ (or OUT), from the service checkouts:
#   agenticwf-auth-client    AgenticWF-auth  cli/       the `agenticwf` command, sign-in and tokens
#   agenticwf-kb-client      AgenticWF-KB    client/    KBClient, `agenticwf kb`
#   agenticwf-agent-client   AgenticWF-agent client/    AgentClient, `agenticwf agent`
#
#   scripts/build-clients.sh                 the versions in their pyproject.toml
#   scripts/build-clients.sh 0.2.0           one release version for all three (CI: the tag)
#
# The checkouts are .src/{auth,kb,agent} (scripts/fetch-sources.sh), or AUTH_SRC, KB_SRC and
# AGENT_SRC. They are not modified: each package is built from a copy, where the version is set and
# the KB and agent clients get their dependency on agenticwf-auth-client (pinned to the same
# version), which their repos cannot declare while it is not on PyPI. Then twine checks the
# distributions, and a fresh venv installs the wheels and runs `agenticwf kb -h` and
# `agenticwf agent -h`. Needs: pip install build twine
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=${OUT:-$root/dist}
python=${PYTHON:-python3}
version=${1:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

packages=(
    "agenticwf-auth-client ${AUTH_SRC:-$root/.src/auth}/cli"
    "agenticwf-kb-client ${KB_SRC:-$root/.src/kb}/client"
    "agenticwf-agent-client ${AGENT_SRC:-$root/.src/agent}/client"
)

if [[ -n $version ]]; then
    "$python" -c 'import sys; from packaging.version import Version; Version(sys.argv[1])' "$version" ||
        { echo "build-clients: '$version' is not a PEP 440 version" >&2; exit 2; }
fi

mkdir -p "$out"
for entry in "${packages[@]}"; do
    name=${entry%% *} src=${entry#* }
    [[ -f $src/pyproject.toml ]] || { echo "build-clients: no $name in $src" >&2; exit 1; }
    stage=$work/$name
    # The package's files only: no build/, egg-info or caches from a local checkout.
    mkdir -p "$stage"
    (cd "$src" && tar --exclude=build --exclude=dist --exclude='*.egg-info' --exclude=__pycache__ \
        --exclude=.pytest_cache -cf - .) | tar -xf - -C "$stage"
    "$python" - "$stage/pyproject.toml" "$name" "$version" <<'EOF'
import re, sys, tomllib
path, name, version = sys.argv[1:]
text = open(path).read()
project = tomllib.loads(text)["project"]
assert project["name"] == name, f"{path}: name is {project['name']}, expected {name}"
version = version or project["version"]
text = re.sub(r'(?m)^version = ".*"$', f'version = "{version}"', text, count=1)
if name != "agenticwf-auth-client" and not any(d.startswith("agenticwf-auth-client") for d in project["dependencies"]):
    deps = ", ".join(f'"{d}"' for d in [*project["dependencies"], f"agenticwf-auth-client=={version}"])
    text, n = re.subn(r'(?m)^dependencies = \[.*\]', f"dependencies = [{deps}]", text, count=1)
    assert n == 1, f"{path}: `dependencies = [...]` must be on one line"
open(path, "w").write(text)
assert tomllib.loads(text)["project"]["version"] == version
print(f"[build-clients] {name} {version}")
EOF
    "$python" -m build --outdir "$out" "$stage" >/dev/null
done

"$python" -m twine check --strict "$out"/agenticwf_*_client-*

# The wheels as a user installs them: one `agenticwf` with the kb and agent commands.
"$python" -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --find-links "$out" "$out"/agenticwf_*_client-*.whl
"$work/venv/bin/agenticwf" kb -h >/dev/null
"$work/venv/bin/agenticwf" agent -h >/dev/null
"$work/venv/bin/python" -c 'import agenticwf.kb.client, agenticwf.agent.client, agenticwf_auth_cli'
echo "[build-clients] installed and ran: agenticwf kb, agenticwf agent"
ls -1 "$out"
