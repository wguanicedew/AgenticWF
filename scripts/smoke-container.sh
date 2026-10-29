#!/usr/bin/env bash
# Acceptance test of a built all-in-one image.
#
#   scripts/smoke-container.sh [image] [server|local]     default: agenticwf:latest server
#
# server: every service starts with `--network host`, and the wiring between them works (Logto
#         configured from the env, a real token through authsvc to the agent, the shared
#         AuthContext secret, the KB's service socket for the agent, the merged policy).
# local:  AGENTICWF_MODE=local with published ports, for "kb", "agent" and "agent kb": the access
#         tokens, no auth programs, and the agent's link to the KB.
# Wherever the KB runs, a keyword-only KB indexes a document and finds it by BM25 (ParadeDB
# pg_search), again after the restart.
# Each ends with a restart on the same volume, which exercises the entrypoint on an existing cluster.
#
# Needs docker (or DOCKER=podman) and curl.
set -euo pipefail

IMAGE=${1:-agenticwf:latest}
SUITE=${2:-server}
DOCKER=${DOCKER:-docker}
NAME=agenticwf-smoke-$$
VOLUME=$NAME-data
# `--network host` as in production; ports offset so they do not clash with a running deployment.
P_PG=15432 P_LOGTO=13001 P_LOGTO_ADMIN=13002 P_AUTHSVC=18010 P_AGENT=18000 P_KB=18020

cleanup() { $DOCKER rm -f "$NAME" >/dev/null 2>&1 || true; $DOCKER volume rm -f "$VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; $DOCKER logs "$NAME" 2>&1 | tail -80 >&2 || true; exit 1; }
status() { curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' "$@"; }

start() {
    $DOCKER run -d --name "$NAME" --network host \
        -e LOGTO_ENDPOINT=http://localhost:$P_LOGTO \
        -e LOGTO_ADMIN_ENDPOINT=http://localhost:$P_LOGTO_ADMIN \
        -e AUTH_AUDIENCES=https://api.example.org \
        -e APP_ORIGIN=http://localhost:18443 -e APP_BASE_PATH=/app \
        -e LOGTO_M2M_APPS="ci=app:access agent:use knowledge:read" \
        -e PGPORT=$P_PG -e LOGTO_PORT=$P_LOGTO -e LOGTO_ADMIN_PORT=$P_LOGTO_ADMIN \
        -e AUTHSVC_PORT=$P_AUTHSVC -e AGENT_PORT=$P_AGENT -e KB_PORT=$P_KB \
        -v "$VOLUME:/var/lib/agenticwf" "$IMAGE" >/dev/null
}

# The image's own HEALTHCHECK covers PostgreSQL, Logto, authsvc, the KB and the agent. Logto seeds
# its database on first boot, which takes a few minutes.
wait_healthy() {
    local state
    for _ in $(seq 1 120); do
        state=$($DOCKER inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo gone)
        [[ $state == running ]] || fail "container is $state"
        $DOCKER exec "$NAME" /usr/local/bin/healthcheck.sh >/dev/null 2>&1 && return 0
        sleep 5
    done
    fail "not healthy after 10 minutes"
}

# sign <method> <path>: an AuthContext for user ci-user, signed with the container's shared secret
# the way authsvc signs it for Caddy. Prints "X-Auth-Context: ..." and "X-Auth-Context-Sig: ..." lines.
sign() {
    $DOCKER exec -i "$NAME" /opt/authsvc/venv/bin/python - "$1" "$2" <<'EOF'
import sys, time
from agenticwf.auth.context import AuthContext, encode_context
secret = open("/var/lib/agenticwf/secrets/auth_context_secret", "rb").read().strip()
ctx = AuthContext(subject="ci-user", user_id="ci-user",
                  scopes=frozenset({"app:access", "agent:use", "knowledge:read"}),
                  expires_at=int(time.time()) + 600)
payload, sig = encode_context(ctx, secret, 60, sys.argv[1], sys.argv[2])
print(f"X-Auth-Context: {payload}\nX-Auth-Context-Sig: {sig}")
EOF
}

check_endpoints() {
    curl -fsS -o /dev/null "http://127.0.0.1:$P_LOGTO/oidc/.well-known/openid-configuration" || fail "Logto OIDC discovery"
    curl -fsS -o /dev/null "http://127.0.0.1:$P_AUTHSVC/healthz" || fail "authsvc /healthz"
    curl -fsS -o /dev/null "http://127.0.0.1:$P_AGENT/healthz" || fail "agent /healthz"
    curl -fsS -o /dev/null "http://127.0.0.1:$P_KB/kb/health" || fail "KB /kb/health"
    echo "   ok: Logto, authsvc, agent and KB answer"
}

check_policy() {
    local code
    # The merged policy: agent and KB routes need a credential; public routes do not.
    for path in /api/v1/tasks /kb/api/v1/knowledge-bases; do
        code=$(status -H "X-Forwarded-Method: GET" -H "X-Forwarded-Uri: $path" "http://127.0.0.1:$P_AUTHSVC/verify")
        [[ $code == 401 ]] || fail "authsvc /verify $path without a credential gave $code, expected 401"
    done
    for path in /healthz /kb/health; do
        code=$(status -H "X-Forwarded-Method: GET" -H "X-Forwarded-Uri: $path" "http://127.0.0.1:$P_AUTHSVC/verify")
        [[ $code == 2* ]] || fail "authsvc /verify public $path gave $code"
    done
    echo "   ok: merged policy (agent and KB routes protected, health public)"
}

check_signed_context() {
    local headers=() line
    # The agent and the KB accept a context signed with authsvc's secret, and nothing else.
    while IFS= read -r line; do headers+=(-H "$line"); done < <(sign GET /api/v1/me)
    curl -fsS "${headers[@]}" "http://127.0.0.1:$P_AGENT/api/v1/me" | grep -q '"subject":"ci-user"' \
        || fail "agent /api/v1/me with a signed context"
    headers=()
    while IFS= read -r line; do headers+=(-H "$line"); done < <(sign GET /kb/api/v1/me)
    curl -fsS "${headers[@]}" "http://127.0.0.1:$P_KB/kb/api/v1/me" | grep -q '"subject":"ci-user"' \
        || fail "KB /kb/api/v1/me with a signed context"
    local code
    code=$(status "http://127.0.0.1:$P_AGENT/api/v1/me")
    [[ $code == 401 || $code == 403 ]] || fail "agent /api/v1/me without a context gave $code"
    code=$(status -H "X-Auth-Context: forged" -H "X-Auth-Context-Sig: forged" "http://127.0.0.1:$P_KB/kb/api/v1/me")
    [[ $code == 401 || $code == 403 ]] || fail "KB /kb/api/v1/me with a forged context gave $code"
    echo "   ok: agent and KB verify authsvc's signed context (shared secret)"
}

check_kb_socket() {
    local principal
    # What the agent does: X-KB-Principal over the KB's service socket, as the OS user `agent`.
    principal=$(printf '{"subject":"ci-user","user_id":"ci-user","scopes":["knowledge:read"]}' | base64 | tr '+/' '-_' | tr -d '=\n')
    for _ in $(seq 1 30); do
        $DOCKER exec "$NAME" test -S /run/agenticwf-kb/kb.sock && break; sleep 2
    done
    $DOCKER exec -u agent "$NAME" curl -fsS --unix-socket /run/agenticwf-kb/kb.sock \
        -H "X-KB-Principal: $principal" http://kb/kb/api/v1/me | grep -q '"subject":"ci-user"' \
        || fail "the agent user reaching the KB's service socket"
    if $DOCKER exec -u authsvc "$NAME" curl -fsS -o /dev/null --unix-socket /run/agenticwf-kb/kb.sock \
            http://kb/kb/health 2>/dev/null; then
        fail "user authsvc can open the KB's service socket (only kb and agent should)"
    fi
    echo "   ok: KB service socket reachable by the agent only"
}

# kb_bm25 <user> <credential> index|search [kb id]: keyword search on the KB, run in the container.
# The credential is "token:<local access token>" (the KB on 127.0.0.1:8020) or "principal:<value>"
# (X-KB-Principal over the service socket, as the agent sends it). The image sets no default
# embedding model, so a new KB is keyword-only: its search is ParadeDB pg_search's BM25 alone.
# index: create the KB, add a document, wait until it is indexed, print the KB id.
kb_bm25() {
    $DOCKER exec -i -u "$1" "$NAME" /opt/kb/venv/bin/python - "${@:2}" <<'EOF'
import http.client, json, socket, sys, time
cred, cmd = sys.argv[1], sys.argv[2]

class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect("/run/agenticwf-kb/kb.sock")

def call(method, path, body=None):
    kind, _, value = cred.partition(":")
    if kind == "token":
        conn, headers = http.client.HTTPConnection("127.0.0.1", 8020, timeout=30), {"Authorization": f"Bearer {value}"}
    else:
        conn, headers = UnixConnection("kb", timeout=30), {"X-KB-Principal": value}
    headers["Content-Type"] = "application/json"
    conn.request(method, "/kb/api/v1" + path, json.dumps(body) if body is not None else None, headers)
    resp = conn.getresponse()
    text = resp.read().decode()
    if resp.status >= 300:
        sys.exit(f"{method} {path}: {resp.status} {text[:300]}")
    return json.loads(text)["data"]

def search(kb, query):
    return call("POST", "/knowledge-search", {"query": query, "knowledge_base_ids": [kb],
                                              "disable_vector_match": True, "match_count": 5})

if cmd == "index":
    kb = call("POST", "/knowledge-bases", {"name": "BM25 smoke test"})
    if kb.get("embedding_model_id"):
        sys.exit(f"the KB has embedding model {kb['embedding_model_id']}: not a keyword-only test")
    item = call("POST", f"/knowledge-bases/{kb['id']}/knowledge/manual", {
        "title": "Cryostat runbook", "status": "publish",
        "content": "# Cryostat runbook\n\nWhen the zymurgic sensor alarms, the shifter refills the cryostat "
                   "with liquid argon and logs the event in the elog."})
    for _ in range(120):
        state = call("GET", f"/knowledge/{item['id']}")
        if state["parse_status"] in ("completed", "failed"):
            break
        time.sleep(1)
    if state["parse_status"] != "completed":
        sys.exit(f"document not indexed: {state['parse_status']} {state.get('error_message') or ''}")
    print(kb["id"])
else:
    kb = sys.argv[3]
    hits = search(kb, "zymurgic cryostat")
    if not hits or not any("zymurgic" in h["content"] for h in hits):
        sys.exit(f"BM25 search found nothing: {hits}")
    if any(h["match_type"] != "keyword" for h in hits):
        sys.exit(f"expected keyword matches only: {[h['match_type'] for h in hits]}")
    if search(kb, "photomultiplier"):
        sys.exit("BM25 search for a word not in the KB returned results")
EOF
}

kb_principal() {   # the agent's X-KB-Principal for ci-user, allowed to write
    printf '{"subject":"ci-user","user_id":"ci-user","scopes":["knowledge:read","knowledge:write"]}' | base64 | tr '+/' '-_' | tr -d '=\n'
}
kb_token() { $DOCKER exec "$NAME" agenticwf-kb token; }

# check_kb_search <user> <credential> [kb id]: without a KB id, index a document first. Sets KB_ID.
check_kb_search() {
    local version
    if [[ -z ${3:-} ]]; then
        KB_ID=$(kb_bm25 "$1" "$2" index) || fail "KB: create a keyword-only KB and index a document"
    fi
    kb_bm25 "$1" "$2" search "$KB_ID" || fail "KB: BM25 keyword search"
    version=$($DOCKER exec "$NAME" sh -c 'runuser -u postgres -- psql -h /run/postgresql -p "${PGPORT:-5432}" -d kb -tAX \
        -c "SELECT extversion FROM pg_extension WHERE extname = '"'pg_search'"'"')
    [[ -n $version ]] || fail "KB: extension pg_search not in database kb"
    echo "   ok: KB BM25 keyword search (pg_search $version)"
}

check_email_connector() {
    local rows
    # Exactly one SMTP connector, created on first boot and not again on restart.
    rows=$($DOCKER exec "$NAME" runuser -u postgres -- psql -h /run/postgresql -p "$P_PG" -d logto -tAX \
        -c "SELECT config->>'host', config->>'port', config->>'ignoreTLS' FROM connectors
            WHERE connector_id = 'simple-mail-transfer-protocol'")
    [[ $(grep -c . <<<"$rows") == 1 ]] || fail "expected one SMTP connector, found: ${rows:-none}"
    [[ $rows == "127.0.0.1|25|true" ]] || fail "SMTP connector defaults: $rows"
    echo "   ok: default Logto email connector (127.0.0.1:25)"
}

logto_sql() {
    $DOCKER exec "$NAME" runuser -u postgres -- psql -h /run/postgresql -p "$P_PG" -d logto -tAX -c "$1"
}

check_logto_bootstrap() {
    local v
    # What logto-bootstrap.py configured from the environment, once (not again on restart).
    v=$(logto_sql "SELECT count(*) FROM resources WHERE indicator = 'https://api.example.org'")
    [[ $v == 1 ]] || fail "API resource: $v"
    v=$(logto_sql "SELECT string_agg(s.name, ' ' ORDER BY s.name) FROM roles r JOIN roles_scopes rs ON rs.role_id = r.id
                   JOIN scopes s ON s.id = rs.scope_id WHERE r.tenant_id = 'default' AND r.name = 'researcher'")
    [[ $v == "agent:use app:access dataset:read knowledge:read knowledge:write" ]] || fail "role researcher: $v"
    v=$(logto_sql "SELECT count(*) FROM roles WHERE tenant_id = 'default' AND name IN ('researcher', 'admin', 'ci (machine)')")
    [[ $v == 3 ]] || fail "roles: $v"
    v=$(logto_sql "SELECT string_agg(name || ':' || type, ',' ORDER BY name) FROM applications
                   WHERE tenant_id = 'default' AND name IN ('AgenticWF Web', 'agenticwf CLI', 'ci')")
    [[ $v == "AgenticWF Web:Traditional,agenticwf CLI:Native,ci:MachineToMachine" ]] || fail "applications: $v"
    v=$(logto_sql "SELECT oidc_client_metadata->'redirectUris'->>0 FROM applications WHERE name = 'AgenticWF Web'")
    [[ $v == "http://localhost:18443/app/auth/callback" ]] || fail "web redirect URI: $v"
    v=$(logto_sql "SELECT sign_in_mode || ' ' || (sign_up->'identifiers')::text || ' verify=' || (sign_up->>'verify')
                   FROM sign_in_experiences WHERE tenant_id = 'default'")
    [[ $v == 'SignInAndRegister ["email"] verify=true' ]] || fail "sign-up: $v"
    v=$(logto_sql "SELECT count(*) FROM logto_configs WHERE tenant_id = 'default' AND key = 'jwt.accessToken'")
    [[ $v == 1 ]] || fail "Custom JWT: $v"
    $DOCKER exec "$NAME" test -s /var/lib/agenticwf/secrets/auth_web_client_secret || fail "web app secret not written"
    $DOCKER exec "$NAME" grep -q '^AGENTICWF_CLIENT_ID=' /var/lib/agenticwf/logto/clients.env || fail "clients.env"
    echo "   ok: Logto configured (API resource, roles, apps, email sign-up, Custom JWT)"
}

check_m2m_token() {
    local creds id secret token headers=() line
    # A real Logto token for the `ci` app (LOGTO_M2M_APPS) -> authsvc /verify -> the agent.
    creds=$($DOCKER exec "$NAME" cat /var/lib/agenticwf/secrets/logto-apps/ci.env)
    id=$(sed -n 's/^AGENTICWF_CLIENT_ID=//p' <<<"$creds")
    secret=$(sed -n 's/^AGENTICWF_CLIENT_SECRET=//p' <<<"$creds")
    token=$(curl -fsS -u "$id:$secret" -d grant_type=client_credentials -d resource=https://api.example.org \
        -d "scope=app:access agent:use" "http://127.0.0.1:$P_LOGTO/oidc/token" \
        | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
    [[ -n $token ]] || fail "client_credentials token for the ci app"
    while IFS= read -r line; do
        line=${line%$'\r'}
        [[ ${line,,} == x-auth-context:* || ${line,,} == x-auth-context-sig:* ]] && headers+=(-H "$line")
    done < <(curl -fsS -D - -o /dev/null -H "Authorization: Bearer $token" \
        -H "X-Forwarded-Method: GET" -H "X-Forwarded-Uri: /api/v1/me" "http://127.0.0.1:$P_AUTHSVC/verify")
    (( ${#headers[@]} == 4 )) || fail "authsvc /verify did not sign a context for the ci app's token"
    curl -fsS "${headers[@]}" "http://127.0.0.1:$P_AGENT/api/v1/me" | grep -q "\"subject\":\"$id\"" \
        || fail "agent /api/v1/me with the context authsvc signed"
    echo "   ok: Logto token -> authsvc /verify -> agent (machine app $id)"
}

check_no_fatal() {
    local out
    # Worker programs are STOPPED unless *_WORKER_PROCESSES > 0, logto-bootstrap EXITED (it runs
    # once); nothing may be failing.
    out=$($DOCKER exec "$NAME" supervisorctl -c /etc/supervisord.conf status 2>&1 || true)
    out=$(sed -E 's/^[a-z]+://' <<<"$out")   # auth:logto -> logto (groups.ini)
    if grep -E 'FATAL|BACKOFF|EXITED' <<<"$out" | grep -v '^logto-bootstrap '; then
        fail "supervisord programs not running"
    fi
    $DOCKER exec "$NAME" test -e /run/agenticwf/logto-bootstrap.done || fail "logto-bootstrap did not succeed"
    for p in postgres logto authsvc kb kb-service agent; do
        grep -Eq "^$p +RUNNING" <<<"$out" || fail "supervisord program $p is not RUNNING: $out"
    done
    echo "   ok: supervisord programs running"
}

# --- local mode -----------------------------------------------------------------------------------
L_AGENT=18765 L_KB=18766

start_local() {   # start_local <services>
    $DOCKER run -d --name "$NAME" -e AGENTICWF_MODE=local -e AGENTICWF_SERVICES="$1" \
        -e AGENTICWF_LOCAL_USER=ci-user \
        -e AGENT_PUBLIC_URL=http://localhost:$L_AGENT -e KB_PUBLIC_URL=http://localhost:$L_KB \
        -p 127.0.0.1:$L_AGENT:8000 -p 127.0.0.1:$L_KB:8020 \
        -v "$VOLUME:/var/lib/agenticwf" "$IMAGE" >/dev/null
}

check_local_programs() {   # check_local_programs <services>
    local out p
    out=$($DOCKER exec "$NAME" supervisorctl -c /etc/supervisord.conf status 2>&1 || true)
    out=$(sed -E 's/^[a-z]+://' <<<"$out")   # auth:logto -> logto (groups.ini)
    grep -E 'FATAL|BACKOFF|EXITED' <<<"$out" && fail "supervisord programs failing"
    for p in logto logto-bootstrap authsvc; do
        grep -Eq "^$p +RUNNING" <<<"$out" && fail "$p runs in local mode"
    done
    for p in postgres $1; do
        grep -Eq "^$p +RUNNING" <<<"$out" || fail "program $p is not RUNNING: $out"
    done
    if [[ " $1 " == *" kb "* && " $1 " == *" agent "* ]]; then
        grep -Eq "^kb-service +RUNNING" <<<"$out" || fail "kb-service (the agent's KB listener) is not RUNNING"
    else
        grep -Eq "^kb-service +RUNNING" <<<"$out" && fail "kb-service runs without the agent"
    fi
    echo "   ok: programs for '$1' only (no Logto, authsvc)"
}

check_local_kb() {
    local token code
    token=$($DOCKER exec "$NAME" agenticwf-kb token)
    curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$L_KB/kb/api/v1/me" | grep -q '"subject":"local:ci-user"' \
        || fail "KB /kb/api/v1/me with its token"
    code=$(status "http://127.0.0.1:$L_KB/kb/api/v1/me")
    [[ $code == 401 ]] || fail "KB /kb/api/v1/me without the token gave $code"
    $DOCKER exec "$NAME" agenticwf-links | grep -q "^KB:    http://localhost:$L_KB/kb/?token=$token\$" || fail "agenticwf-links (KB)"
    echo "   ok: KB with its access token (local:ci-user)"
}

check_local_agent() {
    local token code
    token=$($DOCKER exec "$NAME" cat /var/lib/agenticwf/agent/local/token)
    curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$L_AGENT/api/v1/me" | grep -q '"subject":"local:ci-user"' \
        || fail "agent /api/v1/me with its token"
    code=$(status "http://127.0.0.1:$L_AGENT/api/v1/me")
    [[ $code == 401 ]] || fail "agent /api/v1/me without the token gave $code"
    $DOCKER exec "$NAME" agenticwf-links | grep -q "^Agent: http://localhost:$L_AGENT/?token=$token\$" || fail "agenticwf-links (agent)"
    echo "   ok: agent with its access token (local:ci-user)"
}

check_local_knowledge() {   # check_local_knowledge <services>
    local principal
    if [[ " $1 " == *" kb "* ]]; then
        # What the agent does: the user's context over the KB's service socket, as the OS user `agent`.
        principal=$(printf '{"subject":"local:ci-user","scopes":["knowledge:read","knowledge:write"]}' \
            | base64 | tr '+/' '-_' | tr -d '=\n')
        for _ in $(seq 1 30); do $DOCKER exec "$NAME" test -S /run/agenticwf-kb/kb.sock && break; sleep 2; done
        $DOCKER exec -u agent "$NAME" curl -fsS --unix-socket /run/agenticwf-kb/kb.sock \
            -H "X-KB-Principal: $principal" http://kb/kb/api/v1/me | grep -q '"subject":"local:ci-user"' \
            || fail "the agent reaching the KB as local:ci-user"
        $DOCKER exec "$NAME" test ! -e /run/agenticwf/agent.cfg || fail "agent.cfg replaced although the KB runs"
        $DOCKER exec "$NAME" grep -qx 'wiki_enabled = true' /run/agenticwf/kb.cfg || fail "kb.cfg: wiki not on by default"
        $DOCKER exec "$NAME" grep -qx 'memory_enabled = true' /run/agenticwf/kb.cfg || fail "kb.cfg: memory not on by default"
        $DOCKER exec "$NAME" grep -qx 'web = true' /run/agenticwf/kb.cfg || fail "kb.cfg: web search not on by default"
        $DOCKER exec "$NAME" grep -qx 'embedding_timeout = 180' /run/agenticwf/kb.cfg || fail "kb.cfg: embedding_timeout not 180 by default"
        $DOCKER exec "$NAME" grep -qx 'max_concurrency = 2' /run/agenticwf/kb.cfg || fail "kb.cfg: embedding max_concurrency not 2 by default"
        echo "   ok: agent -> KB over the service socket, same user"
    else
        $DOCKER exec "$NAME" grep -qx 'url =' /run/agenticwf/agent.cfg || fail "agent.cfg [knowledge] not switched off"
        echo "   ok: agent without KB: [knowledge] off"
    fi
}

run_local() {   # run_local <services>
    local services=$1
    NAME=agenticwf-smoke-$$-${services// /-}; VOLUME=$NAME-data
    echo "== local: $services ($IMAGE)"
    start_local "$services"
    wait_healthy
    check_local_programs "$services"
    if [[ " $services " == *" kb "* ]]; then check_local_kb; check_kb_search kb "token:$(kb_token)"; fi
    if [[ " $services " == *" agent "* ]]; then check_local_agent; check_local_knowledge "$services"; fi
    echo "   restart on the same volume"
    $DOCKER restart "$NAME" >/dev/null
    wait_healthy
    check_local_programs "$services"
    if [[ " $services " == *" kb "* ]]; then check_local_kb; check_kb_search kb "token:$(kb_token)" "$KB_ID"; fi
    [[ " $services " == *" agent "* ]] && check_local_agent
    cleanup
}

run_server() {
    echo "== first boot ($IMAGE)"
    start
    wait_healthy
    check_endpoints
    check_no_fatal
    check_policy
    check_signed_context
    check_kb_socket
    check_kb_search agent "principal:$(kb_principal)"
    check_email_connector
    check_logto_bootstrap
    check_m2m_token

    echo "== restart on the same volume"
    $DOCKER restart "$NAME" >/dev/null
    wait_healthy
    check_endpoints
    check_no_fatal
    check_signed_context
    check_kb_search agent "principal:$(kb_principal)" "$KB_ID"
    check_email_connector
    check_logto_bootstrap
    check_m2m_token
}

case "$SUITE" in
    server) run_server ;;
    local) run_local kb; run_local agent; run_local "agent kb" ;;
    *) echo "suite must be server or local, not '$SUITE'" >&2; exit 2 ;;
esac
echo "PASS ($SUITE)"
