#!/usr/bin/env bash
# Container health: PostgreSQL and every service this container runs answer (AGENTICWF_SERVICES;
# server mode adds auth: Logto, authsvc). Settings come from the entrypoint.
set -euo pipefail
# shellcheck source=/dev/null
[[ -r /run/agenticwf/health.env ]] && . /run/agenticwf/health.env
services=" ${AGENTICWF_SERVICES:-auth kb agent} "

# As `postgres`: Docker runs the check as root, and peer authentication has no role "root".
runuser -u postgres -- pg_isready -q -h /run/postgresql -p "${PGPORT:-5432}" -d postgres
host=${LISTEN_HOST:-127.0.0.1}
[[ "$host" == 0.0.0.0 || "$host" == "::" ]] && host=127.0.0.1
if [[ $services == *" auth "* ]]; then
    curl -fsS -o /dev/null "http://${host}:${LOGTO_PORT:-3001}/oidc/.well-known/openid-configuration"
    curl -fsS -o /dev/null "http://${host}:${AUTHSVC_PORT:-8010}/healthz"
fi
if [[ $services == *" kb "* ]]; then
    curl -fsS -o /dev/null "http://${host}:${KB_PORT:-8020}${KB_BASE_PATH:-/kb}/health"
fi
if [[ $services == *" agent "* ]]; then
    curl -fsS -o /dev/null "http://${host}:${AGENT_PORT:-8000}/healthz"
fi
