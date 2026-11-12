#!/usr/bin/env bash
# supervisord program `authsvc` (runs as user `authsvc`) with the AGENTICWF_AUTH_PROVIDER's provider:
#   keycloak  AgenticWF-auth-keycloak's start-authsvc.sh (the entrypoint has set the realm's clients)
#   logto     wait until logto-bootstrap has configured Logto (it creates the browser login app),
#             then AgenticWF-auth-logto's start-authsvc.sh
set -euo pipefail

case "${AGENTICWF_AUTH_PROVIDER:-logto}" in
    keycloak) exec /usr/local/bin/start-authsvc-keycloak.sh ;;
    logto) ;;
    *) echo "[authsvc] unknown AGENTICWF_AUTH_PROVIDER '${AGENTICWF_AUTH_PROVIDER}'" >&2; exit 1 ;;
esac

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

# The CLI app (device flow) created by logto-bootstrap, unless AUTH_CLI_CLIENT_ID is given: authsvc
# publishes it at /auth/config, so `agenticwf` finds the sign-in from a service's URL alone.
if [[ -z "${AUTH_CLI_CLIENT_ID:-}" && -r "$DATA_ROOT/logto/clients.env" ]]; then
    AUTH_CLI_CLIENT_ID=$(sed -n 's/^AGENTICWF_CLIENT_ID=//p' "$DATA_ROOT/logto/clients.env" | head -n 1)
    export AUTH_CLI_CLIENT_ID
fi

# The profile link next to the user's name: Logto's Account Center, which logto-bootstrap turns on
# unless LOGTO_ACCOUNT_CENTER=off. AUTH_ACCOUNT_URL= (empty) hides the link.
if [[ -z "${AUTH_ACCOUNT_URL+x}" && "${LOGTO_ACCOUNT_CENTER:-on}" != "off" && -n "${LOGTO_ENDPOINT:-}" ]]; then
    export AUTH_ACCOUNT_URL="${LOGTO_ENDPOINT%/}/account"
fi

exec /usr/local/bin/start-authsvc-logto.sh
