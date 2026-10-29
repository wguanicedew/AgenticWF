#!/usr/bin/env python3
"""Configure Logto from the container environment (/etc/agenticwf/agenticwf.env) on every boot.

supervisord program `logto-bootstrap` (root), started after Logto. It ensures, idempotently:

  * the API resource (AUTH_AUDIENCES) and its permissions (LOGTO_API_SCOPES)
  * user roles with their permissions (LOGTO_ROLES), and which of them new users get
    (LOGTO_DEFAULT_ROLES; empty = an admin approves every account)
  * applications: "AgenticWF Web" (browser login, unless AUTH_WEB_CLIENT_ID is given), the
    "agenticwf CLI" device-flow app, and machine-to-machine apps (LOGTO_M2M_APPS)
  * "AgenticWF Management": the Management API app authsvc uses for groups and personal access
    tokens (LOGTO_MANAGEMENT_APP; unless AUTH_MGMT_CLIENT_ID is given), and the organization roles
    of groups (AUTH_GROUP_ADMIN_ROLE, AUTH_GROUP_MEMBER_ROLE: `admin`, `member`)
  * sign-up with email + password, the email verified by a code, and password reset by email
    (LOGTO_SIGNUP)
  * the access-token Custom JWT that adds `roles` and `external_identity.groups` (LOGTO_CUSTOM_JWT)
  * Logto's account center: /account/profile, /account/security, /account/sessions
    (LOGTO_ACCOUNT_CENTER, LOGTO_ACCOUNT_CENTER_FIELDS)
  * an AgenticWF admin user with the given roles (LOGTO_APP_ADMIN_EMAIL, LOGTO_APP_ADMIN_PASSWORD)
  * a Logto admin console account (LOGTO_CONSOLE_ADMIN_USERNAME, LOGTO_CONSOLE_ADMIN_PASSWORD), in
    Logto's `admin` tenant, with what Logto gives the first console user; console sign-up is closed

Nothing is ever deleted, and what is not named in the environment is left alone, so the Logto
console stays usable for everything else. For what is named (scopes of the listed roles, the
apps' redirect URIs, the sign-up settings) the environment wins on every boot.

It talks to Logto's Management API with a machine-to-machine app of its own (one per tenant). That
app's secret is written to Logto's database at start (as the database owner) and replaced by an
unknown value at the end, so no credential is kept anywhere. The admin passwords come from files
the entrypoint writes from the environment (LOGTO_*_ADMIN_PASSWORD_FILE) and are applied on every
boot: a password changed elsewhere is set back.

Results for the other programs:
  $DATA_ROOT/secrets/auth_web_client_id, auth_web_client_secret   authsvc's browser login
  $DATA_ROOT/secrets/auth_mgmt_client_id, auth_mgmt_client_secret authsvc's Management API app
  $DATA_ROOT/secrets/logto-apps/<name>.env                       machine-to-machine credentials
  $DATA_ROOT/logto/clients.env                                   CLI settings (not secret)
  /run/agenticwf/logto-bootstrap.done | .failed                  start-authsvc-aio.sh waits for it
"""
from __future__ import annotations

import json
import os
import pwd
import re
import secrets
import string
import sys
import time
import traceback
import urllib.parse
from pathlib import Path

import httpx
import psycopg

DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/var/lib/agenticwf"))
SECRETS = DATA_ROOT / "secrets"
STATE = DATA_ROOT / "logto"
RUN = Path("/run/agenticwf")
TENANT = "default"
MANAGEMENT_API = "https://default.logto.app/api"
ADMIN_TENANT = "admin"   # Logto's own tenant: the admin console's accounts
ADMIN_MANAGEMENT_API = "https://admin.logto.app/api"
# What Logto gives the first console account (OSS): these user roles in the admin tenant, and the
# `admin` role in the organization of the `default` tenant.
CONSOLE_ADMIN_ROLES = ("user", "default:admin")
CONSOLE_ORGANIZATION, CONSOLE_ORGANIZATION_ROLE = "t-default", "admin"
USERNAME_RE = re.compile(r"^[A-Za-z_]\w*$")   # Logto's usernameRegEx
BOOTSTRAP_NAME = "AgenticWF bootstrap (internal)"
JWT_MARKER = "// managed by agenticwf: LOGTO_CUSTOM_JWT (remove this line to keep your own script)"

SCOPE_DESCRIPTIONS = {
    "app:access": "Account approved: use AgenticWF at all",
    "agent:use": "Use the agent: chats, tasks, task types, models",
    "knowledge:read": "Read and search the knowledge bases",
    "knowledge:write": "Add to and manage knowledge bases",
    "dataset:read": "Read datasets",
    "dataset:write": "Write datasets",
    "compute:submit": "Submit compute jobs",
    "admin": "Administer AgenticWF",
}
DEFAULT_API_SCOPES = ("app:access agent:use knowledge:read knowledge:write dataset:read dataset:write "
                      "compute:submit admin")
DEFAULT_ROLES = "researcher=app:access agent:use knowledge:read knowledge:write dataset:read; admin=*"
ACCOUNT_CENTER_FIELDS = ("name", "avatar", "profile", "email", "phone", "password", "username", "social",
                         "customData", "mfa", "passkey", "session", "trustedDevice")
# avatar=Edit uploads the picture, which needs a storage provider set up in Logto.
DEFAULT_ACCOUNT_CENTER_FIELDS = ("name=Edit email=Edit password=Edit username=ReadOnly social=Edit mfa=Edit "
                                 "passkey=Edit session=Edit")

CUSTOM_JWT_SCRIPT = JWT_MARKER + """
// Adds `roles` (Logto role names) and `external_identity` (the IdP identity and its groups, e.g.
// INDIGO IAM `wlcg.groups`) to user access tokens. authsvc passes them on: the KB shares with
// `role:<name>` and `idp:<group>` (AgenticWF README, Logto).
const getCustomJwtClaims = async ({ token, context, environmentVariables }) => {
  const user = context.user ?? {};
  const roles = (user.roles ?? []).map((r) => r.name);
  const groups = new Set();
  let provider;
  for (const [target, identity] of Object.entries(user.identities ?? {})) {
    const raw = identity?.details?.rawData ?? {};
    const value = raw['wlcg.groups'] ?? raw.groups ?? [];
    for (const g of Array.isArray(value) ? value : [value]) {
      if (typeof g === 'string' && g.trim()) groups.add(g.trim());
    }
    if (raw.iss && !provider) provider = { target, issuer: raw.iss, subject: raw.sub };
  }
  const claims = { roles };
  if (provider || groups.size) claims.external_identity = { ...provider, groups: [...groups].sort() };
  return claims;
};
"""


class BootstrapError(RuntimeError):
    pass


def log(msg: str) -> None:
    print(f"[logto-bootstrap] {msg}", file=sys.stderr, flush=True)


def env(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    return value.strip() if value and value.strip() else default


def truthy(value: str) -> bool:
    return value.lower() in ("1", "true", "yes", "on")


def secret_from_file(name: str) -> str:
    """The secret the entrypoint wrote from $name to the file named by ${name}_FILE."""
    path = env(f"{name}_FILE")
    return Path(path).read_text().strip() if path and Path(path).is_file() else ""


def random_secret(length: int = 48) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def standard_id() -> str:
    alphabet = string.digits + string.ascii_lowercase
    return "".join(secrets.choice(alphabet) for _ in range(21))


def write_file(path: Path, content: str, owner: str = "root", mode: int = 0o400) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content)
    user = pwd.getpwnam(owner)
    os.chown(tmp, user.pw_uid, user.pw_gid)
    os.chmod(tmp, mode)
    tmp.replace(path)


# --- configuration from the environment ---------------------------------------------------------

def split_words(value: str) -> list[str]:
    return [w for w in re.split(r"[\s,]+", value) if w]


def parse_assignments(spec: str, what: str) -> dict[str, list[str]]:
    """'a=x y; b=*' -> {'a': ['x', 'y'], 'b': ['*']}"""
    result: dict[str, list[str]] = {}
    for part in spec.split(";"):
        if not part.strip():
            continue
        name, sep, scopes = part.partition("=")
        if not sep or not name.strip():
            raise BootstrapError(f"{what}: expected name=scope scope ..., got {part.strip()!r}")
        result[name.strip()] = split_words(scopes)
    return result


def api_indicator() -> str:
    for audience in split_words(env("AUTH_AUDIENCES")):
        if not audience.startswith("urn:logto:"):
            return audience
    raise BootstrapError("AUTH_AUDIENCES names no API resource indicator")


# --- the bootstrap credential (database) --------------------------------------------------------

def connect_db() -> psycopg.Connection:
    password = (SECRETS / "logto_db_password").read_text().strip()
    dsn = (f"postgresql://{env('LOGTO_DB_USER', 'logto')}:{urllib.parse.quote(password, safe='')}"
           f"@127.0.0.1:{env('PGPORT', '5432')}/{env('LOGTO_DB_NAME', 'logto')}")
    return psycopg.connect(dsn)


def management_scope_id(conn: psycopg.Connection, tenant: str = TENANT, indicator: str = MANAGEMENT_API) -> str:
    """The Management API's `all` scope (Logto does not list its own API among the resources)."""
    row = conn.execute(
        """SELECT s.id FROM scopes s JOIN resources r ON r.id = s.resource_id
           WHERE r.tenant_id = %s AND r.indicator = %s AND s.name = 'all'""",
        (tenant, indicator),
    ).fetchone()
    if not row:
        raise BootstrapError(f"Logto has no Management API resource {indicator} (not seeded?)")
    return row[0]


def ensure_bootstrap_app(conn: psycopg.Connection, secret: str, tenant: str = TENANT,
                         indicator: str = MANAGEMENT_API) -> str:
    """A machine-to-machine app with the Management API's `all` scope; returns its id."""
    scope_id = management_scope_id(conn, tenant, indicator)

    row = conn.execute("SELECT id FROM roles WHERE tenant_id = %s AND name = %s", (tenant, BOOTSTRAP_NAME)).fetchone()
    role_id = row[0] if row else standard_id()
    if not row:
        conn.execute(
            "INSERT INTO roles (tenant_id, id, name, description, type) VALUES (%s, %s, %s, %s, 'MachineToMachine')",
            (tenant, role_id, BOOTSTRAP_NAME, "Used by the container to configure Logto at startup"),
        )
    conn.execute(
        """INSERT INTO roles_scopes (tenant_id, id, role_id, scope_id) VALUES (%s, %s, %s, %s)
           ON CONFLICT (tenant_id, role_id, scope_id) DO NOTHING""",
        (tenant, standard_id(), role_id, scope_id),
    )

    row = conn.execute(
        "SELECT id FROM applications WHERE tenant_id = %s AND name = %s AND type = 'MachineToMachine'",
        (tenant, BOOTSTRAP_NAME),
    ).fetchone()
    app_id = row[0] if row else standard_id()
    if not row:
        conn.execute(
            """INSERT INTO applications (tenant_id, id, name, secret, description, type, oidc_client_metadata)
               VALUES (%s, %s, %s, %s, %s, 'MachineToMachine', %s::jsonb)""",
            (tenant, app_id, BOOTSTRAP_NAME, secret,
             "Configures Logto from the container environment at every start; its secret is not kept",
             json.dumps({"redirectUris": [], "postLogoutRedirectUris": []})),
        )
    conn.execute(
        """INSERT INTO applications_roles (tenant_id, id, application_id, role_id) VALUES (%s, %s, %s, %s)
           ON CONFLICT (tenant_id, application_id, role_id) DO NOTHING""",
        (tenant, standard_id(), app_id, role_id),
    )
    set_bootstrap_secret(conn, app_id, secret, tenant)
    return app_id


def set_bootstrap_secret(conn: psycopg.Connection, app_id: str, secret: str, tenant: str = TENANT) -> None:
    # Both the legacy column (oidc-provider's internal check) and the application secret.
    conn.execute("UPDATE applications SET secret = %s WHERE tenant_id = %s AND id = %s", (secret, tenant, app_id))
    conn.execute(
        """INSERT INTO application_secrets (tenant_id, application_id, name, value) VALUES (%s, %s, 'default', %s)
           ON CONFLICT (tenant_id, application_id, name) DO UPDATE SET value = EXCLUDED.value""",
        (tenant, app_id, secret),
    )


# --- the Management API -------------------------------------------------------------------------

class Logto:
    def __init__(self, base: str, host: str | None = None):
        self.base = base.rstrip("/")
        # Logto picks the tenant from the request's host: the admin tenant only answers as one of
        # its own URLs (localhost:<admin port> or LOGTO_ADMIN_ENDPOINT).
        self.http = httpx.Client(timeout=30, headers={"Host": host} if host else None)

    def wait_ready(self, timeout: int = 900) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if self.http.get(f"{self.base}/oidc/.well-known/openid-configuration").status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            time.sleep(3)
        raise BootstrapError(f"Logto did not answer at {self.base} within {timeout}s")

    def login(self, client_id: str, secret: str, resource: str = MANAGEMENT_API) -> None:
        for attempt in range(10):   # the new app can take a moment to be accepted
            r = self.http.post(f"{self.base}/oidc/token", auth=(client_id, secret), data={
                "grant_type": "client_credentials", "resource": resource, "scope": "all"})
            if r.status_code == 200:
                self.http.headers["Authorization"] = f"Bearer {r.json()['access_token']}"
                return
            time.sleep(2 + attempt)
        raise BootstrapError(f"Management API token: {r.status_code} {r.text[:300]}")

    def call(self, method: str, path: str, **kwargs):
        r = self.http.request(method, f"{self.base}/api{path}", **kwargs)
        if r.status_code >= 400:
            raise BootstrapError(f"{method} /api{path}: {r.status_code} {r.text[:500]}")
        # Some answers are not JSON, e.g. 201 "Created" from POST /organizations/{id}/users/roles.
        return r.json() if r.content and "json" in r.headers.get("content-type", "") else None

    def get(self, path, **kw): return self.call("GET", path, **kw)
    def post(self, path, body): return self.call("POST", path, json=body)
    def patch(self, path, body): return self.call("PATCH", path, json=body)
    def put(self, path, body): return self.call("PUT", path, json=body)

    def get_all(self, path: str, params: dict | None = None) -> list:
        items, page = [], 1
        while True:
            batch = self.get(path, params={**(params or {}), "page": page, "page_size": 100})
            items += batch
            if len(batch) < 100:
                return items
            page += 1


def ensure_resource(api: Logto, indicator: str) -> dict[str, str]:
    """The API resource and its scopes; returns {scope name: scope id}."""
    name = env("LOGTO_API_NAME", "AgenticWF API")
    ttl = int(env("LOGTO_API_TOKEN_TTL", "3600"))
    resource = next((r for r in api.get_all("/resources") if r["indicator"] == indicator), None)
    if resource is None:
        resource = api.post("/resources", {"name": name, "indicator": indicator, "accessTokenTtl": ttl})
        log(f"created API resource {indicator}")
    elif resource["name"] != name or resource["accessTokenTtl"] != ttl:
        api.patch(f"/resources/{resource['id']}", {"name": name, "accessTokenTtl": ttl})

    existing = {s["name"]: s["id"] for s in api.get_all(f"/resources/{resource['id']}/scopes")}
    for scope in split_words(env("LOGTO_API_SCOPES", DEFAULT_API_SCOPES)):
        if scope not in existing:
            created = api.post(f"/resources/{resource['id']}/scopes",
                               {"name": scope, "description": SCOPE_DESCRIPTIONS.get(scope, scope)})
            existing[scope] = created["id"]
            log(f"created permission {scope}")
    return existing


def scope_ids_for(names: list[str], scopes: dict[str, str], what: str) -> list[str]:
    if names == ["*"]:
        return sorted(scopes.values())
    unknown = [n for n in names if n not in scopes]
    if unknown:
        raise BootstrapError(f"{what}: unknown permissions {unknown}; add them to LOGTO_API_SCOPES")
    return [scopes[n] for n in names]


def ensure_role(api: Logto, roles: dict[str, dict], name: str, scope_ids: list[str], role_type: str,
                description: str, is_default: bool | None = None) -> str:
    role = roles.get(name)
    if role is None:
        body = {"name": name, "description": description, "type": role_type, "scopeIds": scope_ids}
        role = api.post("/roles", body)
        roles[name] = role
        log(f"created role {name}")
    elif role["type"] != role_type:
        raise BootstrapError(f"role {name} exists with type {role['type']}, not {role_type}")
    else:
        have = {s["id"] for s in api.get_all(f"/roles/{role['id']}/scopes")}
        missing = [s for s in scope_ids if s not in have]
        if missing:
            api.post(f"/roles/{role['id']}/scopes", {"scopeIds": missing})
            log(f"role {name}: added {len(missing)} permission(s)")
    if is_default is not None and role_type == "User" and bool(role.get("isDefault")) != is_default:
        api.patch(f"/roles/{role['id']}", {"isDefault": is_default})
        log(f"role {name}: default for new users = {is_default}")
    return role["id"]


def ensure_app(api: Logto, apps: list[dict], name: str, app_type: str, redirect_uris=(), post_logout_uris=(),
               custom: dict | None = None, description: str = "") -> dict:
    app = next((a for a in apps if a["name"] == name and a["type"] == app_type), None)
    if app is None:
        app = api.post("/applications", {
            "name": name, "type": app_type, "description": description,
            "oidcClientMetadata": {"redirectUris": list(redirect_uris), "postLogoutRedirectUris": list(post_logout_uris)},
            "customClientMetadata": custom or {},
        })
        apps.append(app)
        log(f"created application {name} ({app_type}): {app['id']}")
        return app
    meta = app.get("oidcClientMetadata") or {}
    redirects = list(dict.fromkeys([*meta.get("redirectUris", []), *redirect_uris]))
    logouts = list(dict.fromkeys([*meta.get("postLogoutRedirectUris", []), *post_logout_uris]))
    custom_now = app.get("customClientMetadata") or {}
    patch: dict = {}
    if redirects != meta.get("redirectUris", []) or logouts != meta.get("postLogoutRedirectUris", []):
        patch["oidcClientMetadata"] = {**meta, "redirectUris": redirects, "postLogoutRedirectUris": logouts}
    if custom and any(custom_now.get(k) != v for k, v in custom.items()):
        patch["customClientMetadata"] = {**custom_now, **custom}
    if patch:
        app = api.patch(f"/applications/{app['id']}", patch)
        log(f"application {name}: updated its settings")
    return app


def app_secret(api: Logto, app_id: str) -> str:
    for item in api.get(f"/applications/{app_id}/secrets"):
        if not item.get("expiresAt") or item["expiresAt"] > time.time() * 1000:
            return item["value"]
    return api.post(f"/applications/{app_id}/secrets", {"name": "default"})["value"]


def ensure_sign_up(api: Logto) -> None:
    mode = env("LOGTO_SIGNUP", "email").lower()
    if mode == "unmanaged":
        return
    if mode not in ("email", "closed"):
        raise BootstrapError(f"LOGTO_SIGNUP must be email, closed or unmanaged, not {mode!r}")
    current = api.get("/sign-in-exp")
    if mode == "closed":
        if current.get("signInMode") != "SignIn":
            api.patch("/sign-in-exp", {"signInMode": "SignIn"})
            log("sign-up closed: accounts are created by admins (or exist already)")
        return

    sign_up = current.get("signUp") or {}
    secondary = [s for s in sign_up.get("secondaryIdentifiers") or []
                 if s.get("identifier") not in ("email", "emailOrPhone")]
    want_sign_up = {**sign_up, "identifiers": ["email"], "password": True, "verify": True,
                    "secondaryIdentifiers": secondary}
    methods = list((current.get("signIn") or {}).get("methods") or [])
    email = {"identifier": "email", "password": True, "verificationCode": False, "isPasswordPrimary": True}
    if not any(m.get("identifier") == "email" for m in methods):
        methods.insert(0, email)
    forgot = list(dict.fromkeys([*(current.get("forgotPasswordMethods") or []), "EmailVerificationCode"]))
    body = {"signInMode": "SignInAndRegister", "signUp": want_sign_up, "signIn": {"methods": methods},
            "forgotPasswordMethods": forgot}
    if any(current.get(k) != v for k, v in body.items()):
        try:
            api.patch("/sign-in-exp", body)
        except BootstrapError as exc:
            if "enabled_connector_not_found" in str(exc):
                log("ERROR: email sign-up needs an email connector; set one up (README, Email) and restart."
                    " Sign-up settings left unchanged.")
                return
            raise
        log("sign-up: email + password, email verified by code; password reset by email")


def ensure_custom_jwt(api: Logto) -> None:
    if not truthy(env("LOGTO_CUSTOM_JWT", "true")):
        return
    try:
        current = api.get("/configs/jwt-customizer/access-token")
    except BootstrapError as exc:
        if ": 404 " not in str(exc):
            raise
        current = None
    if current and not current.get("script", "").startswith(JWT_MARKER):
        log("Custom JWT (access token) was changed in the console; leaving it")
        return
    if current and current.get("script") == CUSTOM_JWT_SCRIPT:
        return
    api.put("/configs/jwt-customizer/access-token", {"script": CUSTOM_JWT_SCRIPT, "environmentVariables": {}})
    log("Custom JWT: access tokens carry roles and external_identity.groups")


def ensure_account_center(api: Logto) -> None:
    """Logto's prebuilt account pages ({LOGTO_ENDPOINT}/account/profile, /security, /sessions)."""
    mode = env("LOGTO_ACCOUNT_CENTER", "on").lower()
    if mode == "unmanaged":
        return
    if mode not in ("on", "off"):
        raise BootstrapError(f"LOGTO_ACCOUNT_CENTER must be on, off or unmanaged, not {mode!r}")
    current = api.get("/account-center")
    if mode == "off":
        if current.get("enabled"):
            api.patch("/account-center", {"enabled": False})
            log("account center: off")
        return

    fields: dict[str, str] = {}
    for word in split_words(env("LOGTO_ACCOUNT_CENTER_FIELDS", DEFAULT_ACCOUNT_CENTER_FIELDS)):
        name, _, control = word.partition("=")
        if name not in ACCOUNT_CENTER_FIELDS or control not in ("Off", "ReadOnly", "Edit"):
            raise BootstrapError(f"LOGTO_ACCOUNT_CENTER_FIELDS: expected field=Off|ReadOnly|Edit with a field of "
                                 f"{' '.join(ACCOUNT_CENTER_FIELDS)}, got {word!r}")
        fields[name] = control

    # The profile page shows `profileFields`, which must name entries of the custom profile field
    # catalog: add `name` and `avatar` there. Sign-up with no `signUpProfileFields` (Logto's
    # default) collects the whole catalog, so pin it to what it collected before.
    catalog = {f["name"] for f in api.get("/custom-profile-fields")}
    profile = [n for n in ("name", "avatar") if fields.get(n, current["fields"].get(n, "Off")) != "Off"]
    missing = [n for n in profile if n not in catalog]
    if missing:
        sign_in_exp = api.get("/sign-in-exp")
        if sign_in_exp.get("signUpProfileFields") is None:
            api.patch("/sign-in-exp", {"signUpProfileFields": [{"name": n} for n in sorted(catalog)]})
        for name in missing:
            api.post("/custom-profile-fields", {"name": name, "required": False,
                                                "type": "Url" if name == "avatar" else "Text"})
    profile_fields = current.get("profileFields") or []
    shown = {f["name"] for f in profile_fields}
    profile_fields = [*({"name": n} for n in profile if n not in shown), *profile_fields]

    body = {"enabled": True, "fields": {**current["fields"], **fields}, "profileFields": profile_fields}
    if any(current.get(k) != v for k, v in body.items()):
        api.patch("/account-center", body)
        log(f"account center: {env('LOGTO_ENDPOINT').rstrip('/')}/account ("
            + " ".join(f"{k}={v}" for k, v in fields.items()) + ")")


def find_user(api: Logto, field: str, value: str) -> dict | None:
    users = api.get("/users", params={f"search.{field}": value, f"mode.{field}": "exact"})
    return next((u for u in users if (u.get(field) or "").lower() == value.lower()), None)


def ensure_password(api: Logto, user: dict, password: str, label: str) -> None:
    try:
        api.post(f"/users/{user['id']}/password/verify", {"password": password})
        return
    except BootstrapError as exc:
        if ": 422 " not in str(exc):
            raise
    api.patch(f"/users/{user['id']}/password", {"password": password})
    log(f"{label}: password set from the environment")


def ensure_user_roles(api: Logto, user: dict, role_ids: dict[str, str], label: str) -> None:
    have = {r["id"] for r in api.get_all(f"/users/{user['id']}/roles")}
    missing = [name for name, rid in role_ids.items() if rid not in have]
    if missing:
        api.post(f"/users/{user['id']}/roles", {"roleIds": [role_ids[n] for n in missing]})
        log(f"{label}: added role(s) {', '.join(missing)}")


def ensure_management_app(api: Logto, apps: list[dict], roles: dict[str, dict], scope_id: str) -> None:
    """authsvc's Management API app (groups, personal access tokens), and the organization roles
    of groups. Its credentials go to $DATA_ROOT/secrets for start-authsvc-aio.sh."""
    if not truthy(env("LOGTO_MANAGEMENT_APP", "true")):
        return
    have = {r["name"] for r in api.get_all("/organization-roles")}
    for name, description in ((env("AUTH_GROUP_ADMIN_ROLE", "admin"), "Group admin: manages the group's members"),
                              (env("AUTH_GROUP_MEMBER_ROLE", "member"), "Group member")):
        if name not in have:
            api.post("/organization-roles", {"name": name, "description": description})
            log(f"created organization role {name}")
    if env("AUTH_MGMT_CLIENT_ID"):
        log("AUTH_MGMT_CLIENT_ID is set: the Management API app is configured by hand")
        return
    role_id = ensure_role(api, roles, "AgenticWF management (machine)", [scope_id], "MachineToMachine",
                          "authsvc: groups and personal access tokens (Logto Management API)")
    app = ensure_app(api, apps, env("LOGTO_MANAGEMENT_APP_NAME", "AgenticWF Management"), "MachineToMachine",
                     description="authsvc: groups and personal access tokens (Logto Management API)")
    if role_id not in {r["id"] for r in api.get_all(f"/applications/{app['id']}/roles")}:
        api.post(f"/applications/{app['id']}/roles", {"roleIds": [role_id]})
    write_file(SECRETS / "auth_mgmt_client_id", app["id"], "authsvc", 0o440)
    write_file(SECRETS / "auth_mgmt_client_secret", app_secret(api, app["id"]), "authsvc", 0o440)


def ensure_app_admin(api: Logto, roles: dict[str, dict]) -> None:
    """An AgenticWF user (default tenant) with LOGTO_APP_ADMIN_ROLES. Without a password only an
    existing user (e.g. one who signed up) gets the roles."""
    email = env("LOGTO_APP_ADMIN_EMAIL")
    password = secret_from_file("LOGTO_APP_ADMIN_PASSWORD")
    if not email:
        if password:
            log("WARNING: LOGTO_APP_ADMIN_PASSWORD is set without LOGTO_APP_ADMIN_EMAIL; no admin user")
        return
    names = split_words(env("LOGTO_APP_ADMIN_ROLES", "admin"))
    unknown = [n for n in names if n not in roles or roles[n]["type"] != "User"]
    if unknown:
        raise BootstrapError(f"LOGTO_APP_ADMIN_ROLES: no such user roles {unknown}; add them to LOGTO_ROLES")
    label = f"admin user {email}"
    user = find_user(api, "primaryEmail", email)
    if user is None:
        if not password:
            log(f"{label} does not exist yet; it gets its roles on the first start after it signs up")
            return
        user = api.post("/users", {"primaryEmail": email, "password": password, "name": "AgenticWF admin"})
        log(f"created {label}")
    elif password:
        ensure_password(api, user, password, label)
    ensure_user_roles(api, user, {n: roles[n]["id"] for n in names}, label)


def ensure_console_admin() -> None:
    """A Logto admin console account (admin tenant), like the one Logto's first visitor creates."""
    password = secret_from_file("LOGTO_CONSOLE_ADMIN_PASSWORD")
    if not password:
        return
    username = env("LOGTO_CONSOLE_ADMIN_USERNAME", "admin")
    if not USERNAME_RE.match(username):
        raise BootstrapError(f"LOGTO_CONSOLE_ADMIN_USERNAME {username!r}: letters, digits and _, not starting with a digit")
    port = env("LOGTO_ADMIN_PORT", "3002")
    api = Logto(f"http://127.0.0.1:{port}", host=f"localhost:{port}")
    api.wait_ready()

    secret = random_secret()
    with connect_db() as conn:
        app_id = ensure_bootstrap_app(conn, secret, ADMIN_TENANT, ADMIN_MANAGEMENT_API)
    try:
        api.login(app_id, secret, ADMIN_MANAGEMENT_API)
        label = f"console admin {username}"
        user = find_user(api, "username", username)
        if user is None:
            user = api.post("/users", {"username": username, "password": password})
            log(f"created {label}")
        else:
            ensure_password(api, user, password, label)

        roles = {r["name"]: r["id"] for r in api.get_all("/roles") if r["type"] == "User"}
        missing = [n for n in CONSOLE_ADMIN_ROLES if n not in roles]
        if missing:
            raise BootstrapError(f"Logto's admin tenant has no roles {missing} (not seeded?)")
        ensure_user_roles(api, user, {n: roles[n] for n in CONSOLE_ADMIN_ROLES}, label)
        # Both ignore what exists already.
        api.post(f"/organizations/{CONSOLE_ORGANIZATION}/users", {"userIds": [user["id"]]})
        api.post(f"/organizations/{CONSOLE_ORGANIZATION}/users/roles",
                 {"userIds": [user["id"]], "organizationRoleIds": [CONSOLE_ORGANIZATION_ROLE]})

        # What Logto does after its first console account: no more sign-up on the console.
        if api.get("/sign-in-exp").get("signInMode") != "SignIn":
            api.patch("/sign-in-exp", {"signInMode": "SignIn"})
            log("admin console: sign-up closed")
    finally:
        try:
            with connect_db() as conn:
                set_bootstrap_secret(conn, app_id, random_secret(), ADMIN_TENANT)
        except Exception as exc:   # noqa: BLE001 - the main error matters more
            log(f"WARNING: could not replace the admin tenant's bootstrap secret: {exc}")


# --- main ---------------------------------------------------------------------------------------

def run() -> None:
    indicator = api_indicator()
    roles_spec = parse_assignments(env("LOGTO_ROLES", DEFAULT_ROLES), "LOGTO_ROLES")
    default_roles = set(split_words(env("LOGTO_DEFAULT_ROLES")))
    if default_roles - roles_spec.keys():
        raise BootstrapError(f"LOGTO_DEFAULT_ROLES names roles not in LOGTO_ROLES: {sorted(default_roles - roles_spec.keys())}")
    m2m_spec = parse_assignments(env("LOGTO_M2M_APPS"), "LOGTO_M2M_APPS")

    api = Logto(f"http://127.0.0.1:{env('LOGTO_PORT', '3001')}")
    api.wait_ready()

    secret = random_secret()
    with connect_db() as conn:
        app_id = ensure_bootstrap_app(conn, secret)
        management_scope = management_scope_id(conn)
    try:
        api.login(app_id, secret)

        scopes = ensure_resource(api, indicator)
        roles = {r["name"]: r for r in api.get_all("/roles")}
        for name, names in roles_spec.items():
            ensure_role(api, roles, name, scope_ids_for(names, scopes, f"LOGTO_ROLES {name}"), "User",
                        f"AgenticWF {name}", is_default=name in default_roles)

        apps = api.get_all("/applications")
        origin, base = env("APP_ORIGIN").rstrip("/"), env("APP_BASE_PATH").rstrip("/")
        if env("AUTH_WEB_CLIENT_ID"):
            log("AUTH_WEB_CLIENT_ID is set: the browser login app is configured by hand")
        elif not origin:
            log("APP_ORIGIN is not set: no browser login app (set APP_ORIGIN and APP_BASE_PATH)")
        else:
            web = ensure_app(api, apps, env("LOGTO_WEB_APP_NAME", "AgenticWF Web"), "Traditional",
                             [f"{origin}{base}/auth/callback"], [f"{origin}{base}/"],
                             {"alwaysIssueRefreshToken": True}, "Browser login (authsvc)")
            write_file(SECRETS / "auth_web_client_id", web["id"], "authsvc", 0o440)
            write_file(SECRETS / "auth_web_client_secret", app_secret(api, web["id"]), "authsvc", 0o440)

        common = [f"AGENTICWF_AUTH_URL={env('LOGTO_ENDPOINT')}", f"AGENTICWF_RESOURCE={indicator}"]
        if origin:
            common.append(f"AGENTICWF_API_URL={origin}{base}")
        clients = list(common)
        if truthy(env("LOGTO_CLI_APP", "true")):
            cli = ensure_app(api, apps, env("LOGTO_CLI_APP_NAME", "agenticwf CLI"), "Native",
                             custom={"isDeviceFlow": True}, description="agenticwf CLI (device flow)")
            clients.append(f"AGENTICWF_CLIENT_ID={cli['id']}")
        write_file(STATE / "clients.env", "# agenticwf CLI settings (logto-bootstrap)\n" + "\n".join(clients) + "\n",
                   "root", 0o644)

        for name, names in m2m_spec.items():
            role_id = ensure_role(api, roles, f"{name} (machine)", scope_ids_for(names, scopes, f"LOGTO_M2M_APPS {name}"),
                                  "MachineToMachine", f"Permissions of the {name} application")
            app = ensure_app(api, apps, name, "MachineToMachine", description="Machine-to-machine (LOGTO_M2M_APPS)")
            api.post(f"/applications/{app['id']}/roles", {"roleIds": [role_id]})
            write_file(SECRETS / "logto-apps" / f"{name}.env",
                       "\n".join([*common, f"AGENTICWF_CLIENT_ID={app['id']}",
                                  f"AGENTICWF_CLIENT_SECRET={app_secret(api, app['id'])}", ""]))

        ensure_management_app(api, apps, roles, management_scope)
        ensure_sign_up(api)
        ensure_custom_jwt(api)
        ensure_account_center(api)
        ensure_app_admin(api, roles)
    finally:
        try:
            with connect_db() as conn:
                set_bootstrap_secret(conn, app_id, random_secret())
        except Exception as exc:   # noqa: BLE001 - the main error matters more
            log(f"WARNING: could not replace the bootstrap secret: {exc}")

    # Logto and AgenticWF work without it, so a failure here does not stop the container.
    try:
        ensure_console_admin()
    except Exception as exc:   # noqa: BLE001 - report every failure the same way
        if not isinstance(exc, BootstrapError):
            traceback.print_exc()
        log(f"ERROR: admin console account: {exc}")


def main() -> None:
    RUN.mkdir(parents=True, exist_ok=True)
    for marker in ("done", "failed"):
        (RUN / f"logto-bootstrap.{marker}").unlink(missing_ok=True)
    if not truthy(env("LOGTO_BOOTSTRAP", "true")):
        log("LOGTO_BOOTSTRAP is off: Logto is configured in its console")
        (RUN / "logto-bootstrap.done").touch()
        return
    try:
        run()
    except Exception as exc:   # noqa: BLE001 - report every failure the same way
        if not isinstance(exc, BootstrapError):
            traceback.print_exc()
        log(f"FAILED: {exc}")
        (RUN / "logto-bootstrap.failed").write_text(str(exc))
        sys.exit(1)
    (RUN / "logto-bootstrap.done").touch()
    log("Logto configured")


if __name__ == "__main__":
    main()
