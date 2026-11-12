#!/usr/bin/env bash
# supervisord program `keycloak-bootstrap` (runs as user `keycloak`), once per boot, after Keycloak is
# ready. The realm is imported only on first boot (--import-realm skips an existing realm); this keeps
# a few settings in line with the environment on every boot:
#
#  1. master realm Frontend URL = KEYCLOAK_ADMIN_URL (cleared without it). KEYCLOAK_ADMIN_URL
#     (KC_HOSTNAME_ADMIN) moves only the admin console and its REST API; the console still signs in
#     through the master realm's frontend URL, KEYCLOAK_URL by default, where Caddy answers 403 outside
#     AGENTICWF_ADMIN_ALLOWED_CIDRS. The master realm is Keycloak's own admins only.
#  2. AgenticWF realm sign-up: User registration / Verify email / Forgot password =
#     KEYCLOAK_REGISTRATION_ALLOWED / KEYCLOAK_VERIFY_EMAIL / KEYCLOAK_RESET_PASSWORD_ALLOWED, each
#     when set; and its email (SMTP) from KEYCLOAK_SMTP_* / KEYCLOAK_EMAIL_* unless KEYCLOAK_EMAIL=off.
#  3. AgenticWF realm default roles (default-roles-<realm>) include the `account` client's roles
#     KEYCLOAK_ACCOUNT_ROLES (default view-profile manage-account), so every user, existing ones
#     included, can open the Account Console (profile, password). Set it empty to leave them alone.
#  4. AgenticWF realm (KEYCLOAK_PROVISION_REALM=1 only): the API client's roles (the scopes) exist and
#     the realm roles `researcher` and `admin` include KEYCLOAK_RESEARCHER_SCOPES / KEYCLOAK_ADMIN_SCOPES.
#     Only adds: scopes removed by hand from a role elsewhere stay as they are unless listed here.
#     If the API client (AUTH_AUDIENCES, default agenticwf-api) is missing, the template's
#     "AgenticWF API" client is renamed to it, with the other clients' audience mappers.
#
# Signs in as KEYCLOAK_ADMIN_USER with /var/lib/agenticwf/secrets/keycloak_admin_password (the first
# boot's admin). Never fails the container: errors are logged as warnings and it exits 0.
set -uo pipefail

# log-prefix.sh (supervisord) puts "[keycloak-bootstrap]" in front of every line.
log()  { echo "$*" >&2; }
warn() { echo "WARNING: $*" >&2; }
stop() { warn "$*"; exit 0; }

host=${LISTEN_HOST:-127.0.0.1}
[[ $host == 0.0.0.0 ]] && host=127.0.0.1
path=${KEYCLOAK_PATH:-/idp}
server="http://${host}:${KEYCLOAK_PORT:-8080}${path}"
mgmt="http://${host}:${KEYCLOAK_MANAGEMENT_PORT:-9000}"
realm=${KEYCLOAK_REALM:-agenticwf}
api_client=${AUTH_AUDIENCES:-agenticwf-api}
api_client=${api_client%% *}; api_client=${api_client%%,*}
# As logto-bootstrap's DEFAULT_ROLES; `admin` also includes `researcher` (realm template).
researcher_scopes=${KEYCLOAK_RESEARCHER_SCOPES:-app:access agent:use knowledge:read knowledge:write code:read dataset:read}
admin_scopes=${KEYCLOAK_ADMIN_SCOPES:-dataset:write compute:submit admin}
declare -A scope_desc=(
    [app:access]="Account approved (policy.yaml required_scopes)"
    [agent:use]="Use the agent: chat sessions, tasks"
    [knowledge:read]="Search the knowledge base"
    [knowledge:write]="Add to and manage knowledge bases"
    [code:read]="Search and read source code repositories; add repositories"
    [dataset:read]="Read datasets"
    [dataset:write]="Change datasets"
    [compute:submit]="Submit compute jobs"
    [admin]="Administer AgenticWF"
)

ready() {
    curl -fsS -o /dev/null "$mgmt$path/health/ready" 2>/dev/null || curl -fsS -o /dev/null "$mgmt/health/ready" 2>/dev/null
}
# First boot creates the schema and imports the realm: allow up to 10 minutes.
for _ in $(seq 1 300); do ready && break; sleep 2; done
ready || stop "Keycloak not ready; realms not checked"

kcadm=/opt/keycloak/bin/kcadm.sh
cfg=$(mktemp) || stop "mktemp failed"
trap 'rm -f "$cfg"' EXIT
kc() { "$kcadm" "$@" --config "$cfg"; }
# One field per line, e.g. kc_list clients -r R -q clientId=X --fields id
kc_list() { kc get "$@" --format csv --noquotes 2>/dev/null; }

pw_file="$DATA_ROOT/secrets/keycloak_admin_password"
[[ -r $pw_file ]] || stop "$pw_file not readable"
"$kcadm" config credentials --config "$cfg" --server "$server" --realm master \
    --user "${KEYCLOAK_ADMIN_USER:-admin}" --password "$(cat "$pw_file")" >/dev/null 2>&1 \
    || stop "cannot sign in to the master realm as ${KEYCLOAK_ADMIN_USER:-admin} (admin replaced or password changed?); make these settings in the admin console"

# --- 1. master realm Frontend URL ---------------------------------------------------------------
want=${KEYCLOAK_ADMIN_URL:-}
want=${want%/}
if current=$(kc get realms/master --fields attributes 2>/dev/null \
        | sed -n 's/.*"frontendUrl" *: *"\([^"]*\)".*/\1/p'); then
    if [[ ${current%/} != "$want" ]]; then
        if kc update realms/master -s "attributes.frontendUrl=$want" >/dev/null; then
            log "master realm Frontend URL: ${current:-(default)} -> ${want:-(default, KEYCLOAK_URL)}"
        else
            warn "cannot update the master realm's Frontend URL"
        fi
    fi
else
    warn "cannot read the master realm"
fi

kc get "realms/$realm" --fields realm >/dev/null 2>&1 || stop "realm $realm not found"

# --- 2. Sign-up: User registration, Verify email, Forgot password ------------------------------
# realm_flag VAR FIELD LABEL: realm boolean FIELD = $VAR, when VAR is set.
realm_flag() {
    local var=$1 field=$2 label=$3 val current
    [[ -n ${!var:-} ]] || return 0
    case ${!var,,} in
        1|true|yes|on)  val=true ;;
        0|false|no|off) val=false ;;
        *) warn "$var must be true or false, not '${!var}'"; return 0 ;;
    esac
    current=$(kc_list "realms/$realm" --fields "$field")
    [[ $current == "$val" ]] && return 0
    kc update "realms/$realm" -s "$field=$val" >/dev/null \
        && log "realm $realm: $label ${current:-?} -> $val" \
        || warn "cannot set $label on realm $realm"
}
realm_flag KEYCLOAK_REGISTRATION_ALLOWED registrationAllowed "User registration"
realm_flag KEYCLOAK_VERIFY_EMAIL verifyEmail "Verify email"
realm_flag KEYCLOAK_RESET_PASSWORD_ALLOWED resetPasswordAllowed "Forgot password"

# Email (SMTP) for verification and password-reset mails: set on every boot from KEYCLOAK_SMTP_* /
# KEYCLOAK_EMAIL_*, unless KEYCLOAK_EMAIL=off (then the realm's email settings are left alone).
json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
if [[ ${KEYCLOAK_EMAIL:-smtp} == smtp ]]; then
    smtp_host=${KEYCLOAK_SMTP_HOST:-127.0.0.1}
    smtp_port=${KEYCLOAK_SMTP_PORT:-25}
    case $smtp_host in 127.*|localhost|::1) tls_default=none ;; *) tls_default=starttls ;; esac
    smtp_tls=${KEYCLOAK_SMTP_TLS:-$tls_default}
    ssl=false starttls=false
    case $smtp_tls in
        tls) ssl=true ;;
        starttls) starttls=true ;;
        none) ;;
        *) warn "KEYCLOAK_SMTP_TLS must be none, starttls or tls, not '$smtp_tls'; using none" ;;
    esac
    from=${KEYCLOAK_EMAIL_FROM:-agenticwf-noreply@$(hostname -f 2>/dev/null || hostname)}
    from_name=${KEYCLOAK_EMAIL_BRAND:-AgenticWF}
    # Keycloak's `from` is a bare address (anything else fails every mail with a NullPointerException
    # in Keycloak 26.4); "Name <addr>" (as LOGTO_EMAIL_FROM) gives the display name and the address.
    if [[ $from =~ ^[[:space:]]*\"?([^\"<]*[^\"<[:space:]])?\"?[[:space:]]*\<([^>]+)\>[[:space:]]*$ ]]; then
        [[ -n ${BASH_REMATCH[1]} ]] && from_name=${BASH_REMATCH[1]}
        from=${BASH_REMATCH[2]}
    fi
    [[ $from =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || warn "KEYCLOAK_EMAIL_FROM '$from' is not an email address; Keycloak cannot send mail with it"
    smtp_user=${KEYCLOAK_SMTP_USER:-}
    smtp_pw=
    [[ -n $smtp_user && -r $DATA_ROOT/secrets/keycloak_smtp_password ]] && smtp_pw=$(cat "$DATA_ROOT/secrets/keycloak_smtp_password")
    smtp_json=$(mktemp) || stop "mktemp failed"
    trap 'rm -f "$cfg" "$smtp_json"' EXIT
    {
        printf '{"smtpServer":{"host":%s,"port":%s,"from":%s,"fromDisplayName":%s,"replyTo":%s,' \
            "$(json_str "$smtp_host")" "$(json_str "$smtp_port")" "$(json_str "$from")" \
            "$(json_str "$from_name")" "$(json_str "${KEYCLOAK_EMAIL_REPLY_TO:-}")"
        printf '"ssl":"%s","starttls":"%s","auth":"%s"' "$ssl" "$starttls" "$([[ -n $smtp_user ]] && echo true || echo false)"
        [[ -n $smtp_user ]] && printf ',"user":%s,"password":%s' "$(json_str "$smtp_user")" "$(json_str "$smtp_pw")"
        printf '}}'
    } > "$smtp_json"
    kc update "realms/$realm" -f "$smtp_json" >/dev/null \
        && log "realm $realm: email via $smtp_host:$smtp_port ($smtp_tls${smtp_user:+, user $smtp_user}), from $from_name <$from>" \
        || warn "cannot set the email (SMTP) settings of realm $realm"
fi

# --- 3. Account Console roles of every user ------------------------------------------------------
# The realm import leaves the `account` client's roles out of default-roles-<realm> (the template
# defines its own realm roles): without view-profile / manage-account the Account Console refuses.
account_roles=${KEYCLOAK_ACCOUNT_ROLES-view-profile manage-account}
default_role=default-roles-${realm}
if [[ -n ${account_roles// /} ]]; then
    acid=$(kc_list clients -r "$realm" -q clientId=account --fields id | head -1)
    if [[ -z $acid ]]; then
        warn "client account not found in realm $realm; Account Console roles not assigned"
    elif ! kc get "roles/$default_role" -r "$realm" >/dev/null 2>&1; then
        warn "realm role $default_role not found in realm $realm; Account Console roles not assigned"
    else
        have=" $(kc_list "roles/$default_role/composites/clients/$acid" -r "$realm" --fields name | tr '\n' ' ') "
        args=() missing=()
        for r in $account_roles; do
            [[ $have == *" $r "* ]] || { missing+=("$r"); args+=(--rolename "$r"); }
        done
        if (( ${#missing[@]} )); then
            kc add-roles -r "$realm" --rname "$default_role" --cclientid account "${args[@]}" >/dev/null \
                && log "realm $realm: role $default_role += account/${missing[*]}" \
                || warn "cannot add account/${missing[*]} to realm role $default_role"
        fi
    fi
fi

# --- 4. Scopes of the realm roles -------------------------------------------------------------------
[[ ${KEYCLOAK_PROVISION_REALM:-1} == 1 ]] || { log "done (KEYCLOAK_PROVISION_REALM=0: roles not managed)"; exit 0; }

cid=$(kc_list clients -r "$realm" -q "clientId=$api_client" --fields id | head -1)
if [[ -z $cid ]]; then
    # The API client was imported under another id (e.g. a Logto-style AUTH_AUDIENCES URL that applied
    # to Keycloak too): rename the template's "AgenticWF API" client to the configured id, and point
    # the audience mappers of the other clients at it. Its roles and the role composites keep working
    # (they refer to the client's internal id). Tokens issued before carry the old audience.
    mapfile -t found < <(kc_list clients -r "$realm" --fields id,clientId,name | grep ',AgenticWF API$')
    (( ${#found[@]} == 1 )) || stop "client $api_client not found in realm $realm (and no single \"AgenticWF API\" client to rename)"
    cid=${found[0]%%,*}
    old=${found[0]#*,}; old=${old%,AgenticWF API}
    kc update "clients/$cid" -r "$realm" -s "clientId=$api_client" >/dev/null \
        || stop "cannot rename client $old to $api_client"
    log "realm $realm: API client $old renamed to $api_client"
    while IFS=, read -r ocid oname; do
        while IFS=, read -r mid mtype; do
            [[ $mtype == oidc-audience-mapper ]] || continue
            kc get "clients/$ocid/protocol-mappers/models/$mid" -r "$realm" 2>/dev/null \
                | grep -qF "\"included.client.audience\" : \"$old\"" || continue
            kc update "clients/$ocid/protocol-mappers/models/$mid" -r "$realm" \
                -s "config.\"included.client.audience\"=$api_client" >/dev/null \
                && log "realm $realm: audience mapper of client $oname -> $api_client" \
                || warn "cannot update the audience mapper $mid of client $oname (set Included Client Audience to $api_client by hand)"
        done < <(kc_list "clients/$ocid/protocol-mappers/models" -r "$realm" --fields id,protocolMapper)
    done < <(kc_list clients -r "$realm" --fields id,clientId)
fi

have_roles=" $(kc_list "clients/$cid/roles" -r "$realm" --fields name | tr '\n' ' ') "
for s in $researcher_scopes $admin_scopes; do
    [[ $have_roles == *" $s "* ]] && continue
    kc create "clients/$cid/roles" -r "$realm" -s "name=$s" -s "description=${scope_desc[$s]:-$s}" >/dev/null 2>&1 \
        && { log "realm $realm: client role $api_client/$s created"; have_roles+="$s "; } \
        || warn "cannot create client role $api_client/$s"
done

# ensure_role ROLE SCOPES...: realm role ROLE includes these client roles of the API client.
ensure_role() {
    local role=$1; shift
    kc get "roles/$role" -r "$realm" >/dev/null 2>&1 || { warn "realm role $role not found in realm $realm"; return; }
    local have missing=() s
    have=" $(kc_list "roles/$role/composites/clients/$cid" -r "$realm" --fields name | tr '\n' ' ') "
    for s in "$@"; do [[ $have == *" $s "* ]] || missing+=("$s"); done
    (( ${#missing[@]} )) || return 0
    local args=()
    for s in "${missing[@]}"; do args+=(--rolename "$s"); done
    kc add-roles -r "$realm" --rname "$role" --cclientid "$api_client" "${args[@]}" >/dev/null \
        && log "realm $realm: role $role += ${missing[*]}" \
        || warn "cannot add ${missing[*]} to realm role $role"
}
# shellcheck disable=SC2086
ensure_role researcher $researcher_scopes
# shellcheck disable=SC2086
ensure_role admin $admin_scopes
log "done"
