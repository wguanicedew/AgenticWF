#!/usr/bin/env bash
# Entrypoint of the all-in-one container: prepare persistent state in one pass, then hand over to
# supervisord. It merges the three repos' entrypoints.
#
# AGENTICWF_MODE (default: server where the image has Logto, i.e. linux/amd64, or where
# AGENTICWF_AUTH_PROVIDER is set; else local):
#   server  the shared deployment: identity provider + authsvc + KB + agent behind host Caddy. The
#           KB and the agent trust the context authsvc signs (KB_AUTH_MODE=authsvc,
#           AGENT_AUTH_MODE=authsvc), whichever provider authsvc uses.
#   local   personal use on a laptop/desktop, no identity provider, authsvc or Caddy. The KB runs standalone,
#           the agent in local mode, each with its own access token; both act for one user,
#           AGENTICWF_LOCAL_USER. With AGENTICWF_LOCAL_HINT, their sign-in pages show the token to
#           whoever gives it.
# AGENTICWF_AUTH_PROVIDER (server mode): the identity provider authsvc uses, both in the image:
#   logto     (default) Logto OSS, configured from the environment by logto-bootstrap
#   keycloak  Keycloak under KEYCLOAK_PATH (/idp), the AgenticWF realm imported on first boot
# AGENTICWF_SERVICES picks "agent", "kb" or "agent kb" (default) in both modes; server mode runs
# the identity provider and authsvc besides. The agent reaches the KB (when both run) through the KB's service
# listener on /run/agenticwf-kb/kb.sock.
#
#  1. check settings; create /var/lib/agenticwf/{pgdata,secrets,kb,agent}
#  2. secrets: server: the provider's and authsvc's database passwords, the AuthContext secret (and
#     Keycloak's admin and client secrets); local: the KB's access token. The Fernet keys of the KB and the agent. Generated on first boot.
#  3. one PostgreSQL cluster: TCP 127.0.0.1 with passwords for Logto or Keycloak and authsvc, the Unix socket
#     with peer authentication for kb and agent; pg_search preloaded for the KB
#  4. on every boot: roles, databases and the KB's extensions for the services that run
#  5. Keycloak: the AgenticWF realm for --import-realm
#  6. settings for supervisord (which programs start), then exec it
set -euo pipefail

DATA_ROOT=${DATA_ROOT:-/var/lib/agenticwf}
PGDATA=${PGDATA:-$DATA_ROOT/pgdata}
PGBIN=${PGBIN:-/usr/pgsql-16/bin}
SECRETS_DIR=$DATA_ROOT/secrets
KB_DATA_ROOT=${KB_DATA_ROOT:-$DATA_ROOT/kb}
AGENT_DATA_ROOT=${AGENT_DATA_ROOT:-$DATA_ROOT/agent}
LOGTO_DB_NAME=${LOGTO_DB_NAME:-logto}
LOGTO_DB_USER=${LOGTO_DB_USER:-logto}
KEYCLOAK_DB_NAME=${KEYCLOAK_DB_NAME:-keycloak}
KEYCLOAK_DB_USER=${KEYCLOAK_DB_USER:-keycloak}
KC_DIR=$DATA_ROOT/keycloak
KB_DB_NAME=${KB_DB_NAME:-kb}
AGENT_DB_NAME=${AGENT_DB_NAME:-agent}
KB_SOCKET_DIR=/run/agenticwf-kb
RUN_DIR=/run/agenticwf
DEFAULT_AGENT_CONFIG=/etc/agenticwf/agent.cfg
# PostgreSQL port (127.0.0.1 and the socket name); change it if the host uses 5432 (host networking).
export PGPORT=${PGPORT:-5432}

log() { echo "[entrypoint] $*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
truthy() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }
pg() { runuser -u postgres -- "$PGBIN/$1" "${@:2}"; }

# --- 1. settings and directories -------------------------------------------------------------

# compose.local.yaml passes the shell's AGENTICWF_SERVICES and AGENTICWF_LOCAL_USER under their own
# names, and the host's login as AGENTICWF_HOST_USER: its `environment` would otherwise override the
# same names in ~/.agenticwf/local.env (env_file). The shell's win, then local.env's, then defaults.
AGENTICWF_SERVICES=${AGENTICWF_COMPOSE_SERVICES:-${AGENTICWF_SERVICES:-}}
AGENTICWF_LOCAL_USER=${AGENTICWF_COMPOSE_LOCAL_USER:-${AGENTICWF_LOCAL_USER:-${AGENTICWF_HOST_USER:-}}}
unset AGENTICWF_COMPOSE_SERVICES AGENTICWF_COMPOSE_LOCAL_USER

# The identity provider of server mode: AGENTICWF_AUTH_PROVIDER, else Logto where the image has it,
# else Keycloak.
if [[ -d /opt/logto ]]; then PROVIDER=${AGENTICWF_AUTH_PROVIDER:-logto}; else PROVIDER=${AGENTICWF_AUTH_PROVIDER:-keycloak}; fi
PROVIDER=${PROVIDER,,}
# authsvc settings whose values differ between the providers. One env file can hold both:
# LOGTO_AUTH_X and KEYCLOAK_AUTH_X set AUTH_X for that provider only, and win over a plain AUTH_X
# (which still applies to whichever provider runs).
for name in AUTH_AUDIENCES AUTH_WEB_SCOPES AUTH_WEB_CLIENT_ID AUTH_MGMT_CLIENT_ID AUTH_CLI_CLIENT_ID \
            AUTH_ACCOUNT_URL AUTH_ROLES_CLAIM; do
    for p in LOGTO KEYCLOAK; do
        var=${p}_$name
        [[ -n "${!var+x}" ]] || continue
        if [[ $p == "${PROVIDER^^}" ]]; then
            [[ -z "${!name+x}" || "${!name}" == "${!var}" ]] || log "$var overrides $name"
            export "$name=${!var}"
        fi
        unset "$var"
    done
done
# One image for both modes; without AGENTICWF_MODE, server where the image has Logto (amd64) or a
# provider is chosen, else local (arm64 has no Logto).
if [[ -d /opt/logto || -n ${AGENTICWF_AUTH_PROVIDER:-} ]]; then MODE=${AGENTICWF_MODE:-server}; else MODE=${AGENTICWF_MODE:-local}; fi
# AGENTICWF_SERVICES: the KB and/or the agent (default both); server mode adds auth (the identity
# provider and authsvc).
SERVICES=""
services_spec=${AGENTICWF_SERVICES:-agent kb}
for s in ${services_spec//,/ }; do
    case "$s" in
        agent|kb) [[ " $SERVICES " == *" $s "* ]] || SERVICES="$SERVICES $s" ;;
        both|all) SERVICES=" agent kb" ;;
        *) fail "AGENTICWF_SERVICES: '$s' is not agent or kb" ;;
    esac
done
[[ -n "$SERVICES" ]] || fail "AGENTICWF_SERVICES names no service (agent, kb or \"agent kb\")."
case "$MODE" in
    server)
        SERVICES="auth$SERVICES"
        case "$PROVIDER" in
            logto)
                [[ -d /opt/logto ]] || fail "this image has no Logto ($(uname -m)): it needs linux/amd64 and AUTH_PROVIDERS with logto; use AGENTICWF_AUTH_PROVIDER=keycloak or AGENTICWF_MODE=local."
                : "${LOGTO_ENDPOINT:?LOGTO_ENDPOINT must be set, e.g. https://auth.example.com}"
                : "${AUTH_AUDIENCES:?LOGTO_AUTH_AUDIENCES (or AUTH_AUDIENCES) must be set to the Logto API resource indicator(s)}"
                # Admin console: own public URL, or (default) localhost only, reached via SSH tunnel.
                export LOGTO_ADMIN_ENDPOINT=${LOGTO_ADMIN_ENDPOINT:-http://localhost:3002}
                ;;
            keycloak)
                [[ -d /opt/keycloak ]] || fail "this image has no Keycloak (built without it in AUTH_PROVIDERS); use AGENTICWF_AUTH_PROVIDER=logto."
                : "${KEYCLOAK_URL:?KEYCLOAK_URL must be set to the public URL of Keycloak incl. its path, e.g. https://host.example.org/idp}"
                KEYCLOAK_URL=${KEYCLOAK_URL%/}
                # Built into the image (kc.sh build --http-relative-path); the URL must end with it.
                KEYCLOAK_PATH=${KEYCLOAK_PATH:-/idp}
                [[ "$KEYCLOAK_URL" == *"$KEYCLOAK_PATH" ]] || fail "KEYCLOAK_URL ($KEYCLOAK_URL) must end with the image's Keycloak path $KEYCLOAK_PATH."
                export KEYCLOAK_URL KEYCLOAK_PATH
                export KEYCLOAK_REALM=${KEYCLOAK_REALM:-agenticwf}
                # The clients of the provisioned realm; authsvc and the realm template use the same ids.
                export AUTH_AUDIENCES=${AUTH_AUDIENCES:-agenticwf-api}
                [[ $AUTH_AUDIENCES == *://* ]] && log "AUTH_AUDIENCES ($AUTH_AUDIENCES) looks like a Logto API resource; with Keycloak it is the API client id (default agenticwf-api). Set it as LOGTO_AUTH_AUDIENCES so it applies to Logto only."
                export KEYCLOAK_PROVISION_REALM=${KEYCLOAK_PROVISION_REALM:-1}
                if [[ "$KEYCLOAK_PROVISION_REALM" == 1 ]]; then
                    : "${APP_ORIGIN:?APP_ORIGIN must be set, e.g. https://host.example.org (redirect URIs of the realm)}"
                    export AUTH_WEB_CLIENT_ID=${AUTH_WEB_CLIENT_ID:-agenticwf-web}
                    export AUTH_MGMT_CLIENT_ID=${AUTH_MGMT_CLIENT_ID:-agenticwf-authsvc}
                    export AUTH_CLI_CLIENT_ID=${AUTH_CLI_CLIENT_ID:-agenticwf-cli}
                fi
                ;;
            *) fail "AGENTICWF_AUTH_PROVIDER must be logto or keycloak, not '$PROVIDER'." ;;
        esac
        [[ "${KB_AUTH_MODE:-authsvc}" == authsvc ]] || fail "KB_AUTH_MODE must be authsvc in server mode (AGENTICWF_MODE=local for a personal KB)."
        [[ "${AGENT_AUTH_MODE:-authsvc}" == authsvc ]] || fail "AGENT_AUTH_MODE must be authsvc in server mode (AGENTICWF_MODE=local for a personal agent)."
        ;;
    local) SERVICES=${SERVICES# } ;;
    *) fail "AGENTICWF_MODE must be server or local, not '$MODE'." ;;
esac
has() { [[ " $SERVICES " == *" $1 "* ]]; }
if [[ $MODE == server ]]; then log "mode $MODE ($PROVIDER): ${SERVICES// /, }"; else log "mode $MODE: ${SERVICES// /, }"; fi

for n in KB_WORKER_PROCESSES AGENT_WORKER_PROCESSES; do
    [[ "${!n:-0}" =~ ^[0-9]+$ ]] || fail "$n must be a number, not '${!n}'."
done
if [[ $MODE == local ]] && (( ${AGENT_WORKER_PROCESSES:-0} > 0 )); then
    fail "AGENT_WORKER_PROCESSES is for the shared deployment, not the personal agent."
fi

install -d -m 0755 "$DATA_ROOT" "$RUN_DIR"
# 0711: services can open their own secret files but cannot list the directories.
install -d -m 0711 -o root -g root "$SECRETS_DIR"
install -d -m 0775 -o postgres -g postgres /run/postgresql
if has kb; then
    install -d -m 0755 "$KB_DATA_ROOT"
    install -d -m 0711 -o root -g root "$KB_DATA_ROOT/secrets"
    install -d -m 0750 -o kb -g kb "$KB_DATA_ROOT/files" "$KB_DATA_ROOT/logs"
    # The KB's service socket: group kb (the agent is a member); setgid keeps the group.
    install -d -m 2770 -o kb -g kb "$KB_SOCKET_DIR"
fi
if has agent; then
    install -d -m 0755 "$AGENT_DATA_ROOT"
    install -d -m 0711 -o root -g root "$AGENT_DATA_ROOT/secrets"
    install -d -m 0750 -o agent -g agent "$AGENT_DATA_ROOT/sandboxes" "$AGENT_DATA_ROOT/logs"
    # Repositories search_code and read_file read (agent.cfg [code] root), cloned by the agent.
    install -d -m 0750 -o agent -g agent "$AGENT_DATA_ROOT/code"
fi

# --- 2. secrets ------------------------------------------------------------------------------

# write_secret NAME FILE OWNER: take $NAME if set, else keep the existing file, else generate.
write_secret() {
    local name=$1 file=$2 owner=$3 value=${!1:-}
    if [[ -n "$value" ]]; then
        printf '%s' "$value" > "$file"
    elif [[ ! -s "$file" ]]; then
        log "generating $name"
        openssl rand -hex 32 | tr -d '\n' > "$file"
    fi
    chown "$owner" "$file"
    chmod 0440 "$file"
    unset "$name"
}

if [[ $MODE == server ]]; then
    write_secret AUTHSVC_DB_PASSWORD "$SECRETS_DIR/authsvc_db_password" "authsvc:authsvc"
    # Shared by authsvc (signs) and the KB and agent (verify): group agenticwf.
    write_secret AUTH_CONTEXT_SECRET "$SECRETS_DIR/auth_context_secret" "root:agenticwf"
    export AUTH_CONTEXT_SECRET_FILE=$SECRETS_DIR/auth_context_secret
    for u in authsvc kb agent; do
        runuser -u "$u" -- test -r "$AUTH_CONTEXT_SECRET_FILE" || fail "$AUTH_CONTEXT_SECRET_FILE is not readable by $u."
    done
fi
if [[ $MODE == server && $PROVIDER == keycloak ]]; then
    write_secret KEYCLOAK_DB_PASSWORD    "$SECRETS_DIR/keycloak_db_password"    "keycloak:keycloak"
    # The first (temporary) master-realm admin, KEYCLOAK_ADMIN_USER (admin).
    write_secret KEYCLOAK_ADMIN_PASSWORD "$SECRETS_DIR/keycloak_admin_password" "keycloak:keycloak"
    # Client secrets of the realm's confidential clients (browser login, Admin API).
    if [[ "$KEYCLOAK_PROVISION_REALM" == 1 || -n "${AUTH_WEB_CLIENT_SECRET:-}" || -s "$SECRETS_DIR/auth_web_client_secret" ]]; then
        write_secret AUTH_WEB_CLIENT_SECRET "$SECRETS_DIR/auth_web_client_secret" "authsvc:authsvc"
    fi
    if [[ "$KEYCLOAK_PROVISION_REALM" == 1 || -n "${AUTH_MGMT_CLIENT_SECRET:-}" || -s "$SECRETS_DIR/auth_mgmt_client_secret" ]]; then
        write_secret AUTH_MGMT_CLIENT_SECRET "$SECRETS_DIR/auth_mgmt_client_secret" "authsvc:authsvc"
    fi
    install -d -m 0750 -o keycloak -g keycloak "$KC_DIR" "$KC_DIR/import"
    # The realm's SMTP password, if any (keycloak-bootstrap sets the realm's email from it).
    if [[ -n "${KEYCLOAK_SMTP_PASSWORD:-}" ]]; then
        write_secret KEYCLOAK_SMTP_PASSWORD "$SECRETS_DIR/keycloak_smtp_password" "keycloak:keycloak"
    fi
elif [[ $MODE == server ]]; then
    write_secret LOGTO_DB_PASSWORD   "$SECRETS_DIR/logto_db_password"   "logto:logto"
    # Browser login with a web app made by hand (AUTH_WEB_CLIENT_ID); otherwise logto-bootstrap.
    if [[ -n "${AUTH_WEB_CLIENT_SECRET:-}" || -s "$SECRETS_DIR/auth_web_client_secret" ]]; then
        write_secret AUTH_WEB_CLIENT_SECRET "$SECRETS_DIR/auth_web_client_secret" "authsvc:authsvc"
    fi
    # Logto's default email connector (logto-email-connector.py): the SMTP password, if any, and
    # the marker that it was created once.
    if [[ -n "${LOGTO_SMTP_PASSWORD:-}" ]]; then
        write_secret LOGTO_SMTP_PASSWORD "$SECRETS_DIR/logto_smtp_password" "logto:logto"
    fi
    [[ -s "$SECRETS_DIR/logto_smtp_password" ]] && export LOGTO_SMTP_PASSWORD_FILE=$SECRETS_DIR/logto_smtp_password
    # Admin accounts made by logto-bootstrap (root): their passwords, if given.
    for name in LOGTO_CONSOLE_ADMIN_PASSWORD LOGTO_APP_ADMIN_PASSWORD; do
        file=$SECRETS_DIR/${name,,}
        if [[ -n "${!name:-}" ]]; then
            write_secret "$name" "$file" "root:root"
        fi
        if [[ -s "$file" ]]; then
            export "${name}_FILE=$file"
        fi
    done
    install -d -m 0755 -o logto -g logto "$DATA_ROOT/logto"
    # logto-bootstrap's result for this boot (start-authsvc-aio.sh waits for it).
    rm -f "$RUN_DIR/logto-bootstrap.done" "$RUN_DIR/logto-bootstrap.failed"
else
    unset AUTH_CONTEXT_SECRET AUTH_CONTEXT_SECRET_FILE
    # Local mode: both services act for one user. Its subject is local:<login> in the KB and in the
    # agent, so what you add in the KB is yours when the agent searches it.
    LOCAL_USER=${AGENTICWF_LOCAL_USER:-user}
    [[ "$LOCAL_USER" =~ ^[A-Za-z0-9._@-]+$ ]] || fail "AGENTICWF_LOCAL_USER '$LOCAL_USER' may only use letters, digits and . _ @ -"
    if has kb; then
        export KB_LOCAL_USER=${KB_LOCAL_USER:-$LOCAL_USER}
        export KB_PUBLIC_URL=${KB_PUBLIC_URL:-http://localhost:8766}
        # Signs the KB's browser cookie; kept so sign-ins survive restarts.
        export KB_STANDALONE_SECRET_FILE=$KB_DATA_ROOT/secrets/standalone_secret
        if [[ ! -s "$KB_STANDALONE_SECRET_FILE" ]]; then
            /opt/kb/venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(48))' > "$KB_STANDALONE_SECRET_FILE"
            chown kb:kb "$KB_STANDALONE_SECRET_FILE"; chmod 0400 "$KB_STANDALONE_SECRET_FILE"
        fi
        # The KB's access token, owned by kb so `agenticwf-kb token --rotate` can replace it;
        # start-kb.sh creates it on first boot. A given KB_TOKEN replaces it.
        export KB_TOKEN_FILE=${KB_TOKEN_FILE:-$KB_DATA_ROOT/secrets/token}
        if [[ -n "${KB_TOKEN:-}" ]]; then
            (( ${#KB_TOKEN} >= 16 )) || fail "KB_TOKEN must be at least 16 characters."
            printf '%s\n' "$KB_TOKEN" > "$KB_TOKEN_FILE"
            unset KB_TOKEN
        fi
        [[ -e "$KB_TOKEN_FILE" ]] || install -m 0600 -o kb -g kb /dev/null "$KB_TOKEN_FILE"
        chown kb:kb "$KB_TOKEN_FILE"; chmod 0600 "$KB_TOKEN_FILE"
    fi
    if has agent; then
        export AGENT_LOCAL_USER=${AGENT_LOCAL_USER:-$LOCAL_USER}
        # The agent's defaults plus knowledge:write (adding to the KB, long-term memory on it).
        export AGENT_LOCAL_SCOPES=${AGENT_LOCAL_SCOPES:-app:access agent:use admin code:read code:write knowledge:read knowledge:write dataset:read dataset:write}
        export AGENT_PUBLIC_URL=${AGENT_PUBLIC_URL:-http://localhost:8765}
        # The personal agent's access token and signing key (`agenticwf-agent serve` creates them).
        export AGENTICWF_AGENT_HOME=${AGENTICWF_AGENT_HOME:-$AGENT_DATA_ROOT/local}
        install -d -m 0700 -o agent -g agent "$AGENTICWF_AGENT_HOME"
    fi
    if has kb && has agent && [[ "$KB_LOCAL_USER" != "$AGENT_LOCAL_USER" ]]; then
        log "WARNING: KB_LOCAL_USER ($KB_LOCAL_USER) and AGENT_LOCAL_USER ($AGENT_LOCAL_USER) differ:"
        log "WARNING: the agent will not see the private items you add in the KB."
    fi
    # What the sign-in pages say to get a token: this container's commands, not the host commands
    # (`agenticwf-agent token`, `agenticwf-kb token`) the services name on their own. Docker makes
    # the hostname the container's short id unless --hostname says otherwise; AGENTICWF_CONTAINER
    # names it instead (e.g. agenticwf for `docker run --name agenticwf`).
    container=${AGENTICWF_CONTAINER:-$(hostname)}
    [[ -n ${AGENTICWF_CONTAINER:-} || $container =~ ^[0-9a-f]{12}$ ]] || container="<container>"
    token_help() {
        printf '%s\n' "# On the machine that runs the container. With docker compose, in the AgenticWF directory:" \
            "docker compose -f compose.local.yaml exec agenticwf agenticwf-links $1" \
            "# Or by the container's name or id (docker ps):" \
            "docker exec $container agenticwf-links $1"
    }
    if has agent; then AGENT_LOCAL_TOKEN_HELP=$(token_help agent) && export AGENT_LOCAL_TOKEN_HELP; fi
    if has kb; then KB_TOKEN_HELP=$(token_help kb) && export KB_TOKEN_HELP; fi
    # AGENTICWF_LOCAL_HINT: a phrase of yours; the sign-in pages show the token to whoever gives it
    # (wrong answers are throttled). Passed to the services only.
    hint=${AGENTICWF_LOCAL_HINT:-}
    unset AGENTICWF_LOCAL_HINT
    if [[ -n $hint ]]; then
        if (( ${#hint} < 8 )); then
            log "WARNING: AGENTICWF_LOCAL_HINT is shorter than 8 characters: ignored"
        else
            if has agent; then export AGENT_LOCAL_HINT=$hint; fi
            if has kb; then export KB_LOCAL_HINT=$hint; fi
            log "sign-in pages: the token shows for AGENTICWF_LOCAL_HINT"
        fi
    fi
fi

# fernet_key FILE OWNER: the key that encrypts secrets a service stores in its database (model API
# keys). Created once; it never enters the database. Back it up with the volume.
fernet_key() {
    local file=$1 owner=$2
    [[ -s "$file" ]] && return 0
    /opt/kb/venv/bin/python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' > "$file"
    chown "$owner" "$file"; chmod 0400 "$file"
    log "created the secrets key $file"
    if [[ -s "$PGDATA/PG_VERSION" ]]; then
        log "WARNING: a NEW secrets key was created for an existing database: secrets stored before"
        log "WARNING: cannot be decrypted with it. Restore the old key into $file and restart."
    fi
}
if has kb; then
    export KB_SECRETS_KEY_FILE=${KB_SECRETS_KEY_FILE:-$KB_DATA_ROOT/secrets/secrets_key}
    fernet_key "$KB_SECRETS_KEY_FILE" kb:kb
fi
if has agent; then
    export AGENT_SECRETS_KEY_FILE=${AGENT_SECRETS_KEY_FILE:-$AGENT_DATA_ROOT/secrets/secrets_key}
    fernet_key "$AGENT_SECRETS_KEY_FILE" agent:agent
fi

# --- 3. PostgreSQL cluster -------------------------------------------------------------------

if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
    log "initialising PostgreSQL cluster in $PGDATA"
    install -d -m 0700 -o postgres -g postgres "$PGDATA"
    pg initdb -D "$PGDATA" --encoding=UTF8 --locale=C.UTF-8 \
        --auth-local=peer --auth-host=scram-sha-256 >/dev/null
    cat >> "$PGDATA/postgresql.conf" <<EOF

# --- agenticwf (all-in-one) ---
# Logto or Keycloak, and authsvc: TCP on 127.0.0.1 with passwords. kb and agent: the Unix socket, peer auth.
listen_addresses = '127.0.0.1'
unix_socket_directories = '/run/postgresql'
password_encryption = 'scram-sha-256'
logging_collector = off
# ParadeDB pg_search (the KB's BM25) must be preloaded on PostgreSQL 16.
shared_preload_libraries = 'pg_search'
# HNSW and BM25 index builds.
maintenance_work_mem = 512MB
max_parallel_maintenance_workers = 2
EOF
fi

# --- 4. roles, databases, extensions (every boot) --------------------------------------------

pg pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -p $PGPORT" -w start >/dev/null
trap 'pg pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true' EXIT
psql_admin() { pg psql -v ON_ERROR_STOP=1 -q -X -h /run/postgresql "$@"; }

ensure_password_db() {  # USER DB PASSWORD_FILE ROLE_OPTIONS
    psql_admin -v user="$1" -v db="$2" -v pw="$(cat "$3")" -v opts="$4" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user') \gexec
SELECT format('ALTER ROLE %I %s PASSWORD %L', :'user', :'opts', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L', :'db', :'user', 'UTF8')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SQL
}
ensure_peer_db() {  # USER DB (OS user = role, no password)
    psql_admin -v user="$1" -v db="$2" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user') \gexec
SELECT format('ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE', :'user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L', :'db', :'user', 'UTF8')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SQL
}

if has auth; then
    if [[ $PROVIDER == keycloak ]]; then
        # Keycloak owns its database (it creates and migrates its schema itself).
        ensure_password_db "$KEYCLOAK_DB_USER" "$KEYCLOAK_DB_NAME" "$SECRETS_DIR/keycloak_db_password" "NOCREATEROLE"
    else
        # Logto's seed creates a `logto_tenant_<db>` role, so the Logto user needs CREATEROLE.
        ensure_password_db "$LOGTO_DB_USER" "$LOGTO_DB_NAME" "$SECRETS_DIR/logto_db_password" "CREATEROLE"
    fi
    # authsvc: browser sessions, personal access tokens, group join requests.
    ensure_password_db authsvc authsvc "$SECRETS_DIR/authsvc_db_password" "NOCREATEROLE"
fi
if has kb; then
    ensure_peer_db kb "$KB_DB_NAME"
    # The kb role is not a superuser, so its extensions are created here.
    psql_admin -d "$KB_DB_NAME" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_search;
ALTER EXTENSION vector UPDATE;
ALTER EXTENSION pg_trgm UPDATE;
ALTER EXTENSION pg_search UPDATE;
SQL
fi
has agent && ensure_peer_db agent "$AGENT_DB_NAME"
pg pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
trap - EXIT
log "PostgreSQL ready"

# --- 5. Keycloak: the AgenticWF realm ---------------------------------------------------------

# Rendered on every boot from the template (AgenticWF-auth-keycloak's container/config) and the
# current settings. Keycloak imports it only while the realm does not exist (first boot): later
# changes are made in its admin console, and a changed setting here (e.g. APP_ORIGIN) is not applied
# to an existing realm.
if has auth && [[ $PROVIDER == keycloak ]]; then
    if [[ "$KEYCLOAK_PROVISION_REALM" == 1 ]]; then
        app_base=${APP_BASE_PATH:-}
        app_base=${app_base#/}; app_base=${app_base%/}
        api_client=${AUTH_AUDIENCES%% *}; api_client=${api_client%%,*}
        REALM_REALM=$KEYCLOAK_REALM \
        REALM_API_CLIENT_ID=$api_client \
        REALM_WEB_CLIENT_ID=$AUTH_WEB_CLIENT_ID \
        REALM_CLI_CLIENT_ID=$AUTH_CLI_CLIENT_ID \
        REALM_MGMT_CLIENT_ID=$AUTH_MGMT_CLIENT_ID \
        REALM_WEB_CLIENT_SECRET=$(cat "$SECRETS_DIR/auth_web_client_secret") \
        REALM_MGMT_CLIENT_SECRET=$(cat "$SECRETS_DIR/auth_mgmt_client_secret") \
        REALM_APP_ORIGIN=${APP_ORIGIN%/} \
        REALM_APP_URL=${APP_ORIGIN%/}${app_base:+/$app_base} \
        REALM_REGISTRATION_ALLOWED=${KEYCLOAK_REGISTRATION_ALLOWED:-false} \
            /opt/authsvc/venv/bin/python /usr/local/bin/render-realm.py /etc/agenticwf/keycloak/realm-agenticwf.json \
                "$KC_DIR/import/$KEYCLOAK_REALM-realm.json"
        chown keycloak:keycloak "$KC_DIR/import/$KEYCLOAK_REALM-realm.json"
        chmod 0400 "$KC_DIR/import/$KEYCLOAK_REALM-realm.json"
        # What the `agenticwf` CLI needs (also published at <application URL>/auth/config).
        cat > "$KC_DIR/clients.env" <<EOF
AGENTICWF_AUTH_URL=$KEYCLOAK_URL/realms/$KEYCLOAK_REALM
AGENTICWF_API_URL=${APP_ORIGIN%/}${app_base:+/$app_base}
AGENTICWF_CLIENT_ID=$AUTH_CLI_CLIENT_ID
EOF
        chmod 0644 "$KC_DIR/clients.env"
    else
        rm -f "$KC_DIR/import/"*.json
    fi
fi

# --- 6. settings for supervisord and the programs --------------------------------------------

export DATA_ROOT PGDATA PGBIN KB_DATA_ROOT LOGTO_DB_NAME LOGTO_DB_USER KB_DB_NAME AGENT_DB_NAME
export KEYCLOAK_DB_NAME KEYCLOAK_DB_USER
export AGENTICWF_MODE=$MODE AGENTICWF_SERVICES=$SERVICES AGENTICWF_AUTH_PROVIDER=$PROVIDER
if [[ $MODE == server ]]; then
    export KB_AUTH_MODE=authsvc AGENT_AUTH_MODE=authsvc
    # The listeners Caddy reaches. Server mode runs with `--network host`: 127.0.0.1 keeps the
    # services off the host's public interfaces, and Logto reaches the host's MTA on 127.0.0.1:25.
    # (Keycloak binds LISTEN_HOST too, KC_HTTP_HOST.)
    export LISTEN_HOST=${LISTEN_HOST:-127.0.0.1}
else
    export KB_AUTH_MODE=standalone AGENT_AUTH_MODE=local
    # Local mode publishes ports (-p 127.0.0.1:8765:8000 -p 127.0.0.1:8766:8020): the host side
    # decides who reaches them.
    export LISTEN_HOST=${LISTEN_HOST:-0.0.0.0}
fi
export LOG_LEVEL=${LOG_LEVEL:-info}
export LOGTO_PORT=${LOGTO_PORT:-3001} LOGTO_ADMIN_PORT=${LOGTO_ADMIN_PORT:-3002}
export KEYCLOAK_PORT=${KEYCLOAK_PORT:-8080} KEYCLOAK_MANAGEMENT_PORT=${KEYCLOAK_MANAGEMENT_PORT:-9000}
export AUTHSVC_PORT=${AUTHSVC_PORT:-8010}
export KB_PORT=${KB_PORT:-8020} AGENT_PORT=${AGENT_PORT:-8000}
ports="$PGPORT $KB_PORT $AGENT_PORT"
if has auth; then
    ports="$ports $AUTHSVC_PORT"
    if [[ $PROVIDER == keycloak ]]; then
        ports="$ports $KEYCLOAK_PORT $KEYCLOAK_MANAGEMENT_PORT"
    else
        ports="$ports $LOGTO_PORT $LOGTO_ADMIN_PORT"
    fi
fi
[[ $(tr ' ' '\n' <<<"$ports" | sort | uniq -d) ]] && fail "ports must differ: $ports"
unset PORT

# Which supervisord programs start.
bool() { if "$@"; then echo true; else echo false; fi; }
AUTH_AUTOSTART=$(bool has auth) KB_AUTOSTART=$(bool has kb) AGENT_AUTOSTART=$(bool has agent)
LOGTO_AUTOSTART=$(bool eval 'has auth && [[ $PROVIDER == logto ]]')
KEYCLOAK_AUTOSTART=$(bool eval 'has auth && [[ $PROVIDER == keycloak ]]')
export AUTH_AUTOSTART KB_AUTOSTART AGENT_AUTOSTART LOGTO_AUTOSTART KEYCLOAK_AUTOSTART

if has auth; then
    export AUTH_POLICY_FILE=${AUTH_POLICY_FILE:-/etc/agenticwf/policy.yaml}
    export AUTHSVC_WORKERS=${AUTHSVC_WORKERS:-2}
    export AUTHSVC_LOG_LEVEL=${AUTHSVC_LOG_LEVEL:-$LOG_LEVEL}
fi

# The KB's service listener for the agent (no authentication; X-KB-Principal names the user),
# when both run. agent.cfg [knowledge] url points at this socket; change both together.
if has kb && has agent; then
    export KB_SERVICE_LISTEN=${KB_SERVICE_LISTEN:-unix:$KB_SOCKET_DIR/kb.sock}
    if [[ "$KB_SERVICE_LISTEN" != unix:* ]]; then
        host=${KB_SERVICE_LISTEN%:*}
        [[ "$host" == 127.* || "$host" == localhost ]] || truthy "${KB_SERVICE_ALLOW_REMOTE:-false}" \
            || fail "KB_SERVICE_LISTEN=$KB_SERVICE_LISTEN is not loopback or a Unix socket (no authentication)."
    fi
    export KB_SERVICE_AUTOSTART=true
else
    unset KB_SERVICE_LISTEN
    export KB_SERVICE_AUTOSTART=false
fi
# The agent without the KB: switch its [knowledge] section off (only in the image's own agent.cfg;
# a mounted one is used as it is).
if has agent && ! has kb && [[ "${AGENTICWF_CONFIG:-$DEFAULT_AGENT_CONFIG}" == "$DEFAULT_AGENT_CONFIG" ]]; then
    sed 's|^url = unix:/run/agenticwf-kb/kb.sock$|url =|' "$DEFAULT_AGENT_CONFIG" > "$RUN_DIR/agent.cfg"
    chmod 0644 "$RUN_DIR/agent.cfg"
    export AGENTICWF_CONFIG=$RUN_DIR/agent.cfg
fi
# The KB's web search, wiki and memory, on unless KB_WEB / KB_WIKI / KB_MEMORY say otherwise:
# the [features] switches, and for the wiki and memory what a new document KB starts with
# ([knowledge_bases]; each KB's owner can still switch them off). Chat models ([models.chat.*])
# that don't say get supports_tools = true, which agentic search's smart preset needs. Embedding
# calls get 180 s ([models] embedding_timeout) and at most 2 at a time per model and process
# (max_concurrency), unless kb.cfg says otherwise: a shared gateway's e5-large-v2 times out at the
# KB's 60 s and 4 when a document and its wiki ingest embed at once. Written
# into a copy of kb.cfg (the image's or a mounted one), so these win over it.
if has kb; then
    KB_WEB=$(bool truthy "${KB_WEB:-true}") KB_WIKI=$(bool truthy "${KB_WIKI:-true}")
    KB_MEMORY=$(bool truthy "${KB_MEMORY:-true}")
    /opt/kb/venv/bin/python - "${AGENTICWF_KB_CONFIG:-/etc/agenticwf/kb.cfg}" "$RUN_DIR/kb.cfg" \
        "$KB_WEB" "$KB_WIKI" "$KB_MEMORY" <<'PY'
import configparser, sys
src, dst, web, wiki, memory = sys.argv[1:]
cfg = configparser.RawConfigParser()
cfg.optionxform = str
if not cfg.read(src):
    sys.exit(f"cannot read {src}")
for section, values in {"features": {"web": web, "wiki": wiki, "memory": memory},
                        "knowledge_bases": {"wiki_enabled": wiki, "memory_enabled": memory}}.items():
    if not cfg.has_section(section):
        cfg.add_section(section)
    for key, value in values.items():
        cfg.set(section, key, value)
if not cfg.has_section("models"):
    cfg.add_section("models")
if not cfg.has_option("models", "embedding_timeout"):
    cfg.set("models", "embedding_timeout", "180")
for section in cfg.sections():
    if section.startswith("models.chat.") and not cfg.has_option(section, "supports_tools"):
        cfg.set(section, "supports_tools", "true")
    if (section.startswith("models.embedding.") and not cfg.has_option(section, "max_concurrency")
            and not cfg.has_option("models", "max_concurrency")):
        cfg.set(section, "max_concurrency", "2")
with open(dst, "w") as out:
    cfg.write(out)
PY
    chmod 0644 "$RUN_DIR/kb.cfg"
    export AGENTICWF_KB_CONFIG=$RUN_DIR/kb.cfg
    log "KB web $KB_WEB, wiki $KB_WIKI, memory $KB_MEMORY (KB_WEB / KB_WIKI / KB_MEMORY)"
    # The agent's long-term memory is the KB's temporal memory ([knowledge] memory = true); without
    # it, the agent keeps memories in its own database (only in the image's own agent.cfg).
    if has agent && [[ $KB_MEMORY == false ]] && [[ "${AGENTICWF_CONFIG:-$DEFAULT_AGENT_CONFIG}" == "$DEFAULT_AGENT_CONFIG" ]]; then
        sed 's|^memory = true$|memory = false|' "$DEFAULT_AGENT_CONFIG" > "$RUN_DIR/agent.cfg"
        chmod 0644 "$RUN_DIR/agent.cfg"
        export AGENTICWF_CONFIG=$RUN_DIR/agent.cfg
        log "agent memory in its own database (KB_MEMORY=false)"
    fi
fi

# Worker processes beside each API process; 0 (default) runs the jobs in the API process.
KB_WORKER_PROCESSES=${KB_WORKER_PROCESSES:-0}
if has kb && (( KB_WORKER_PROCESSES > 0 )); then
    export KB_RUN_WORKERS=false KB_WORKERS_AUTOSTART=true KB_WORKER_SLOTS=$KB_WORKER_PROCESSES
else
    export KB_RUN_WORKERS=true KB_WORKERS_AUTOSTART=false KB_WORKER_SLOTS=1   # numprocs >= 1
fi
AGENT_WORKER_PROCESSES=${AGENT_WORKER_PROCESSES:-0}
if has agent && (( AGENT_WORKER_PROCESSES > 0 )); then
    export AGENT_HARNESS_SHARED=true AGENT_WORKERS_AUTOSTART=true AGENT_WORKER_PROCESSES_SLOTS=$AGENT_WORKER_PROCESSES
else
    export AGENT_WORKERS_AUTOSTART=false AGENT_WORKER_PROCESSES_SLOTS=1      # numprocs >= 1
fi

# For healthcheck.sh and agenticwf-links (`docker exec` does not see this environment).
{
    for v in AGENTICWF_MODE AGENTICWF_SERVICES AGENTICWF_AUTH_PROVIDER LISTEN_HOST PGPORT LOGTO_PORT \
             KEYCLOAK_MANAGEMENT_PORT KEYCLOAK_PATH AUTHSVC_PORT KB_PORT AGENT_PORT \
             KB_PUBLIC_URL AGENT_PUBLIC_URL KB_TOKEN_FILE AGENTICWF_AGENT_HOME; do
        printf '%s=%q\n' "$v" "${!v:-}"
    done
} > "$RUN_DIR/health.env"

exec "$@"
