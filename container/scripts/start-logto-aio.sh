#!/usr/bin/env bash
# supervisord program `logto` (runs as user `logto`): seed Logto's database, add the default email
# connector (logto-email-connector.py), then AgenticWF-auth's start-logto.sh starts Logto. Its own
# `db seed --swe` is then a no-op.
set -euo pipefail

cd /opt/logto
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

for _ in $(seq 1 60); do
    pg_isready -q -h 127.0.0.1 && break
    sleep 1
done
pg_isready -q -h 127.0.0.1 || { echo "[logto] PostgreSQL not ready" >&2; exit 1; }

# The same environment start-logto.sh gives the Logto CLI.
DB_URL="postgresql://${LOGTO_DB_USER}:$(urlencode "$(cat "$DATA_ROOT/secrets/logto_db_password")")@127.0.0.1:${PGPORT}/${LOGTO_DB_NAME}"
ENDPOINT="$LOGTO_ENDPOINT" ADMIN_ENDPOINT="$LOGTO_ADMIN_ENDPOINT" NODE_ENV=production DB_URL="$DB_URL" \
    node /opt/logto/packages/cli/bin/logto.js db seed --swe

# A failure here must not keep Logto down: sign-in works without an email connector.
/opt/authsvc/venv/bin/python /usr/local/bin/logto-email-connector.py \
    || echo "[logto] WARNING: could not create the default email connector; add one in the Logto console" >&2

exec /usr/local/bin/start-logto.sh
