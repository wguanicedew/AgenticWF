#!/usr/bin/env python3
"""Create Logto's default email connector (SMTP) once, so sign-up verification and "forgot
password" mails work out of the box. Run by start-logto-aio.sh after `logto db seed`, before Logto
starts, as user `logto` (the owner of Logto's database).

The connector is created only when
  * LOGTO_EMAIL_CONNECTOR is `smtp` (the default; `off` disables this),
  * this script has not created one before (marker file), so a connector deleted or replaced in
    the Logto console stays that way, and
  * Logto has no email connector yet (any connector id containing "mail").
After that, the Logto console owns it: Connectors -> Email and SMS connectors.

Environment (defaults suit `--network host` with the host's MTA on 127.0.0.1:25, e.g. Postfix):
  LOGTO_SMTP_HOST          127.0.0.1
  LOGTO_SMTP_PORT          25
  LOGTO_SMTP_TLS           none (loopback host) or starttls; also `tls` (implicit TLS, port 465)
  LOGTO_SMTP_USER          empty: no SMTP AUTH (a local relay)
  LOGTO_SMTP_PASSWORD_FILE written by the entrypoint from LOGTO_SMTP_PASSWORD
  LOGTO_EMAIL_FROM         "AgenticWF <agenticwf-noreply@<host FQDN>>"
  LOGTO_EMAIL_REPLY_TO     empty
  LOGTO_EMAIL_BRAND        AgenticWF (in subjects and texts)
"""
import json
import os
import secrets
import socket
import string
import sys
import urllib.parse
from pathlib import Path

import psycopg

SMTP_CONNECTOR_ID = "simple-mail-transfer-protocol"
TENANT_ID = "default"


def log(msg: str) -> None:
    print(f"[logto-email] {msg}", file=sys.stderr, flush=True)


def standard_id() -> str:
    """Logto's generateStandardId(): 21 characters of [0-9a-z]."""
    alphabet = string.digits + string.ascii_lowercase
    return "".join(secrets.choice(alphabet) for _ in range(21))


def templates(brand: str) -> list[dict]:
    # Logto requires Register, SignIn, ForgotPassword and Generic; each needs {{code}}.
    texts = {
        "SignIn": ("sign-in verification code", "Your {b} sign-in verification code is {{{{code}}}}."),
        "Register": ("sign-up verification code", "Your {b} sign-up verification code is {{{{code}}}}."),
        "ForgotPassword": ("password reset code", "Your {b} password reset code is {{{{code}}}}."),
        "Generic": ("verification code", "Your {b} verification code is {{{{code}}}}."),
        "OrganizationInvitation": ("organization invitation", "Your {b} organization invitation code is {{{{code}}}}."),
        "UserPermissionValidation": ("permission validation code", "Your {b} permission validation code is {{{{code}}}}."),
        "BindNewIdentifier": ("verification code", "Your {b} code to link a new email address is {{{{code}}}}."),
        "MfaVerification": ("two-step verification code", "Your {b} two-step verification code is {{{{code}}}}."),
        "BindMfa": ("two-step verification setup code", "Your {b} code to set up two-step verification is {{{{code}}}}."),
    }
    tail = (" The code will remain active for 10 minutes.\n\n"
            "If you did not request it, you can ignore this email.")
    return [{"usageType": usage, "contentType": "text/plain",
             "subject": f"{brand} {subject}", "content": content.format(b=brand) + tail}
            for usage, (subject, content) in texts.items()]


def smtp_config() -> dict:
    host = os.environ.get("LOGTO_SMTP_HOST") or "127.0.0.1"
    port = int(os.environ.get("LOGTO_SMTP_PORT") or 25)
    loopback = host in ("localhost", "::1") or host.startswith("127.")
    tls = (os.environ.get("LOGTO_SMTP_TLS") or ("none" if loopback else "starttls")).lower()
    if tls not in ("none", "starttls", "tls"):
        raise SystemExit(f"LOGTO_SMTP_TLS must be none, starttls or tls, not {tls!r}")
    brand = os.environ.get("LOGTO_EMAIL_BRAND") or "AgenticWF"
    sender = os.environ.get("LOGTO_EMAIL_FROM") or f"{brand} <agenticwf-noreply@{socket.getfqdn()}>"

    auth: dict = {}
    user = os.environ.get("LOGTO_SMTP_USER")
    if user:
        auth = {"type": "login", "user": user}
        pw_file = os.environ.get("LOGTO_SMTP_PASSWORD_FILE")
        if pw_file and Path(pw_file).is_file():
            auth["pass"] = Path(pw_file).read_text().strip()

    config = {
        "host": host,
        "port": port,
        "auth": auth,
        "fromEmail": sender,
        "secure": tls == "tls",
        "templates": templates(brand),
    }
    if tls == "none":
        # A local relay often offers STARTTLS with a self-signed certificate; on loopback skip it.
        config["ignoreTLS"] = True
    elif tls == "starttls":
        config["requireTLS"] = True
    if os.environ.get("LOGTO_EMAIL_REPLY_TO"):
        config["replyTo"] = os.environ["LOGTO_EMAIL_REPLY_TO"]
    return config


def main() -> None:
    mode = (os.environ.get("LOGTO_EMAIL_CONNECTOR") or "smtp").lower()
    if mode == "off":
        return
    if mode != "smtp":
        raise SystemExit(f"LOGTO_EMAIL_CONNECTOR must be smtp or off, not {mode!r}")

    marker = Path(os.environ.get("DATA_ROOT", "/var/lib/agenticwf")) / "logto" / "email-connector-created"
    if marker.exists():
        return

    password = (Path(os.environ["DATA_ROOT"]) / "secrets" / "logto_db_password").read_text().strip()
    dsn = (f"postgresql://{os.environ['LOGTO_DB_USER']}:{urllib.parse.quote(password, safe='')}"
           f"@127.0.0.1:{os.environ.get('PGPORT', '5432')}/{os.environ['LOGTO_DB_NAME']}")
    config = smtp_config()
    with psycopg.connect(dsn) as conn:
        existing = conn.execute(
            "SELECT connector_id FROM connectors WHERE tenant_id = %s AND connector_id ILIKE %s",
            (TENANT_ID, "%mail%"),
        ).fetchall()
        if existing:
            log(f"an email connector exists already ({', '.join(r[0] for r in existing)}); not adding one")
        else:
            conn.execute(
                "INSERT INTO connectors (tenant_id, id, connector_id, config) VALUES (%s, %s, %s, %s::jsonb)",
                (TENANT_ID, standard_id(), SMTP_CONNECTOR_ID, json.dumps(config)),
            )
            log(f"created the SMTP email connector: {config['host']}:{config['port']}, from {config['fromEmail']}"
                " (change it in the Logto console: Connectors -> Email and SMS connectors)")
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()


if __name__ == "__main__":
    main()
