#!/usr/bin/env bash
# supervisord program `authsvc` (runs as user `authsvc`): wait until logto-bootstrap has configured
# Logto (it creates the browser login app), then AgenticWF-auth's start-authsvc.sh.
set -euo pipefail

for _ in $(seq 1 450); do
    [[ -e /run/agenticwf/logto-bootstrap.done || -e /run/agenticwf/logto-bootstrap.failed ]] && break
    sleep 2
done
if [[ -e /run/agenticwf/logto-bootstrap.failed ]]; then
    echo "[authsvc] Logto bootstrap failed: $(cat /run/agenticwf/logto-bootstrap.failed)" >&2
    exit 1
fi
[[ -e /run/agenticwf/logto-bootstrap.done ]] || { echo "[authsvc] Logto bootstrap did not finish" >&2; exit 1; }

# The browser login app created by logto-bootstrap, unless AUTH_WEB_CLIENT_ID is given. Its secret
# is $DATA_ROOT/secrets/auth_web_client_secret, which start-authsvc.sh picks up.
if [[ -z "${AUTH_WEB_CLIENT_ID:-}" && -s "$DATA_ROOT/secrets/auth_web_client_id" ]]; then
    AUTH_WEB_CLIENT_ID=$(cat "$DATA_ROOT/secrets/auth_web_client_id")
    export AUTH_WEB_CLIENT_ID
fi

# The Management API app (groups, personal access tokens) created by logto-bootstrap, unless
# AUTH_MGMT_CLIENT_ID is given; start-authsvc.sh picks up $DATA_ROOT/secrets/auth_mgmt_client_secret.
if [[ -z "${AUTH_MGMT_CLIENT_ID:-}" && -s "$DATA_ROOT/secrets/auth_mgmt_client_id" ]]; then
    AUTH_MGMT_CLIENT_ID=$(cat "$DATA_ROOT/secrets/auth_mgmt_client_id")
    export AUTH_MGMT_CLIENT_ID
fi

# The profile link next to the user's name: Logto's Account Center, which logto-bootstrap turns on
# unless LOGTO_ACCOUNT_CENTER=off. AUTH_ACCOUNT_URL= (empty) hides the link.
if [[ -z "${AUTH_ACCOUNT_URL+x}" && "${LOGTO_ACCOUNT_CENTER:-on}" != "off" && -n "${LOGTO_ENDPOINT:-}" ]]; then
    export AUTH_ACCOUNT_URL="${LOGTO_ENDPOINT%/}/account"
fi

exec /usr/local/bin/start-authsvc.sh
