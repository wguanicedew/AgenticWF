# AgenticWF

One container running the whole AgenticWF stack:

| Service | Repo | Port | Health |
|---|---|---|---|
| Logto (OIDC, sign-in) | AgenticWF-auth | 3001 | `/oidc/.well-known/openid-configuration` |
| Logto admin console | AgenticWF-auth | 3002 | |
| authsvc (`forward_auth`, browser login) | AgenticWF-auth | 8010 | `/healthz` |
| Knowledge service (`KB_AUTH_MODE=authsvc`) | AgenticWF-KB | 8020 | `/kb/health` |
| Agent (`AGENT_AUTH_MODE=authsvc`) | AgenticWF-agent | 8000 | `/healthz` |

supervisord runs them all, with one PostgreSQL 16 cluster (pgvector, pg_search) holding the
databases `logto`, `authsvc`, `kb` and `agent`. The agent uses the KB through the KB's service
listener on the in-container socket `/run/agenticwf-kb/kb.sock` (`agent.cfg [knowledge]`). All
state lives in the volume `/var/lib/agenticwf`.

For **personal use on a laptop or desktop** (the agent, the KB or both, without Logto, authsvc
or Caddy), see [Local use](#local-use).

## Build

Only this repo needs to be cloned. The three service repos (AgenticWF-auth, AgenticWF-KB,
AgenticWF-agent) and the ref of each are pinned in [sources.env](sources.env).
[scripts/fetch-sources.sh](scripts/fetch-sources.sh) clones or updates them into `.src/` (ignored
by git), and `container/build.sh` runs it first. CI reads the same file.

```sh
git clone https://github.com/InnovateAILab/AgenticWF.git && cd AgenticWF
container/build.sh                      # fetches .src/{auth,kb,agent}, then builds
```

- **Choosing versions.** To build other versions, change the refs in `sources.env` (a branch,
  tag or commit) and commit them. A commit of this repo then always builds the same services.
  For a release, pin tags or commits rather than `main`. For a single build, the environment
  overrides the file, e.g. `KB_REF=my-branch container/build.sh`. ParadeDB `pg_search` (the KB's
  BM25) is installed at the version the KB's own `container/Dockerfile` pins
  (`ARG PG_SEARCH_VERSION`), so the KB ref decides it too; `--build-arg PG_SEARCH_VERSION=…`
  builds another.
- **Your own working copies.** `AUTH_SRC=../AgenticWF-auth`, `KB_SRC=…` and `AGENT_SRC=…` build
  those checkouts instead; nothing is fetched for them. For compose, put these lines in a `.env`
  file next to `compose.yaml` (git ignores it). You can also edit inside `.src/`: a checkout with
  local changes is never overwritten.
- **Credentials and offline builds.** `git` uses your usual credentials, so private repos work.
  `FETCH=0` builds what's already in `.src/`, without going online.
- **Compose.** Run `scripts/fetch-sources.sh` before `docker compose … build`.
- **Build network.** Builds use `--network host` (`build.sh`, and `build.network` in both compose
  files): dnf, pip and the Node/Logto downloads go out through the host's network. That's needed
  on hosts whose firewall blocks bridged containers' outbound traffic (e.g. Puppet-managed
  nftables). `NETWORK=default container/build.sh` uses Docker's bridge instead. Docker's default
  builder allows host networking. A buildx builder with the `docker-container` driver only allows
  it if created with
  `docker buildx create --use --buildkitd-flags '--allow-insecure-entitlement network.host'`,
  and the build then also needs `--allow network.host`
  (`container/build.sh --allow network.host`).

One image, `agenticwf`, runs either mode; the environment picks it when the container starts:

| `AGENTICWF_MODE` | For | Services |
|---|---|---|
| `server` (default) | the shared deployment behind Caddy | Logto + authsvc, plus `AGENTICWF_SERVICES` |
| `local` | personal use on a laptop/desktop, no Logto | `AGENTICWF_SERVICES` |

`AGENTICWF_SERVICES` is `agent kb` (default), `kb` or `agent`, in both modes.

| Platform | Has Logto | Modes |
|---|---|---|
| linux/amd64 | yes | server and local |
| linux/arm64 (Apple silicon) | no (Logto ships x64 native addons) | local only; the default mode there |

```sh
container/build.sh                          # agenticwf:latest for this machine's architecture
PLATFORM=linux/amd64 container/build.sh     # for a server, from an Apple silicon Mac (emulated)
# or
docker compose build                        # linux/amd64 (compose.yaml pins it)
docker compose -f compose.local.yaml build  # this machine's architecture
```

Other settings: `IMAGE`, `PLATFORM`, `FETCH`, `DOCKER=podman`. All three repos are fetched even
for local use, because the KB and the agent import AgenticWF-auth's AuthContext code. The amd64
image also carries Node.js and Logto in local mode, so it is larger than the arm64 one.

### CI

[.github/workflows/build-container.yml](.github/workflows/build-container.yml) runs on every push and pull request:

- **Checks:** shellcheck, the policy merge validated with authsvc's loader, and `caddy validate`
  for each site layout.
- **Build and smoke test:** builds the image and runs
  [scripts/smoke-container.sh](scripts/smoke-container.sh). The test waits until the image reports
  healthy, then checks the merged policy, the signed context (shared secret) on the agent and the
  KB, that the KB's service socket works for user `agent` only, and that a keyword-only KB finds
  a document by BM25 search (`pg_search`). It then restarts the container
  on the same volume and checks again.
- **Local mode:** the same image, through the smoke test's `local` suite. It starts the
  container three times (KB only, agent only, both) and checks the access tokens, that Logto and
  authsvc don't run, and the agent's link to the KB. Each run ends with a restart.
- **Publish:** a pushed tag publishes `ghcr.io/<owner>/agenticwf` for linux/amd64 and
  linux/arm64 (the arm64 image has no Logto). The image labels record each service repo's commit.
- **Client packages:** [scripts/build-clients.sh](scripts/build-clients.sh) builds
  `agenticwf-auth-client`, `agenticwf-kb-client` and `agenticwf-agent-client` (wheel and sdist)
  from the same service commits, with one version, the KB and agent clients depending on the auth
  client of that version. It checks them with `twine check` and installs the wheels in a fresh
  venv to run `agenticwf kb` and `agenticwf agent`. The `python-clients` artifact holds them.
- **Publish the clients:** a pushed tag, once the image passed its smoke tests, uploads them to
  PyPI with the tag as version (`v0.2.0` → `0.2.0`). A manual run with `publish_clients` uploads
  `<version>.dev<run number>` to TestPyPI. Both use twine with an API token, as iDDS does: add the
  secrets `PYPI_TOKEN` (pypi.org) and `TEST_PYPI_TOKEN` (test.pypi.org) under Settings → Secrets
  and variables → Actions. The first upload of a new project needs an account-scoped token.

Which service commits get built comes from [sources.env](sources.env), the same file local
builds use. A manual run's inputs, or the repository variables `AUTH_REF`, `KB_REF` and
`AGENT_REF` (Settings → Variables), override it. A tag build that still uses `main` gets a
warning. If the service repos are private, add a token that can read them as the secret
`AGENTICWF_TOKEN`.

The smoke test also runs locally: `container/build.sh && scripts/smoke-container.sh` (server,
amd64 only), and `scripts/smoke-container.sh agenticwf:latest local`.

## Local use

With `AGENTICWF_MODE=local`, the image runs the **agent**, the **KB**, or **both** for one person
on a laptop or desktop, with no Logto, authsvc or Caddy. Each service has its own access token: the link to
open is printed once, and after that a cookie keeps you signed in. Only your machine can reach
the services, because the ports are published on `127.0.0.1`.

```sh
docker compose -f compose.local.yaml up -d --build                   # agent + KB
docker compose -f compose.local.yaml exec agenticwf agenticwf-links  # the sign-in links
```

```
Agent: http://localhost:8765/?token=…
KB:    http://localhost:8766/kb/?token=…
```

Only one of them, or another user name:

```sh
AGENTICWF_SERVICES=kb    docker compose -f compose.local.yaml up -d   # just the KB
AGENTICWF_SERVICES=agent docker compose -f compose.local.yaml up -d   # just the agent
AGENTICWF_LOCAL_USER=agenticwf docker compose -f compose.local.yaml up -d # you are local:agenticwf
```

or with `docker run`:

```sh
docker run -d --name agenticwf --restart unless-stopped \
    -e AGENTICWF_MODE=local -e AGENTICWF_SERVICES="agent kb" \
    -e AGENTICWF_LOCAL_USER="$USER" -e AGENTICWF_CONTAINER=agenticwf \
    -p 127.0.0.1:8765:8000 -p 127.0.0.1:8766:8020 \
    -v agenticwf-local-data:/var/lib/agenticwf agenticwf:latest
docker exec agenticwf agenticwf-links
```

To get the token on the sign-in page itself, without a command, set a hint: a phrase of yours, at
least 8 characters. Recreate the container afterwards:

```sh
echo 'AGENTICWF_LOCAL_HINT=my blue whale 42' >> ~/.agenticwf/local.env
docker compose -f compose.local.yaml up -d --force-recreate
# docker run: add  -e AGENTICWF_LOCAL_HINT='my blue whale 42'
```

- **Signing in.** Opening a service without its token shows its sign-in page, with the commands
  that print its link and token: `agenticwf-links agent` or `agenticwf-links kb` (link, then the
  token alone to paste), run with `docker compose … exec agenticwf` or `docker exec <container>`.
  The page names the container by its id, or by `AGENTICWF_CONTAINER` when set.
- **Hint.** With `AGENTICWF_LOCAL_HINT` set (at least 8 characters; shorter is ignored with a
  warning), both sign-in pages also ask for it. The right hint signs that browser in and shows
  the token, for scripts and other browsers. A wrong one gets the `agenticwf-links` commands
  instead. Wrong answers are throttled: after 5 in a row, one try a minute. Treat the hint like a
  password, since it gives the token. Set it in `~/.agenticwf/local.env` or with
  `docker run -e`; compose does not take it from the shell. Unset, the pages show only the
  commands.
- **One user.** `AGENTICWF_LOCAL_USER` makes you `local:<login>` in both services. Documents you add
  in the KB are therefore yours when the agent searches them. With compose it comes from the shell,
  else `~/.agenticwf/local.env`, else your login on this machine (`$USER`); `AGENTICWF_SERVICES`
  the same way (default `agent kb`). Changing it makes you a new user: what the old name added
  stays with that name. The agent reaches the KB inside the container, over its service socket.
- **Agent only.** The agent's knowledge tools are switched off, so it doesn't look for a KB.
  **KB only** runs just the KB and its sign-in page.
- **Settings.** Put model API keys and other options in `~/.agenticwf/local.env`, which
  `compose.local.yaml` reads; see
  [container/agenticwf-local.env.example](container/agenticwf-local.env.example). To add models
  or change other agent settings, mount your own `agent.cfg` at `/etc/agenticwf/agent.cfg`. If
  you do that with the agent alone, comment out its `[knowledge]` `url`. Models can also be
  added on the agent's admin page; their keys are stored encrypted in its database.
- **Tokens.** `docker exec agenticwf agenticwf-kb token --rotate` gives the KB a new token. For
  the agent, delete `/var/lib/agenticwf/agent/local/token` in the container and restart it.
- **Ports.** `AGENT_HOST_PORT` and `KB_HOST_PORT` (compose) change the host ports, 8765 and
  8766 by default.
- **Data.** Everything is in the volume `agenticwf-local-data`. Back it up with the secrets keys
  inside it (`…/secrets/secrets_key`): without them, stored API keys can't be decrypted.
- **Image.** The same `agenticwf` image as the server; `AGENTICWF_MODE=local` selects this mode
  (compose.local.yaml sets it). On Apple silicon it builds natively for arm64, without Logto.
  An image built before the two were merged, `agenticwf-local`, can be removed
  (`docker image rm agenticwf-local:latest`); the data volume stays as it is.
  `compose.local.yaml` needs Docker Compose 2.24 or later (optional `env_file`).

## Run

```sh
sudo install -d -m 0750 /etc/agenticwf
sudo install -m 0600 container/agenticwf.env.example /etc/agenticwf/agenticwf.env   # then edit it
# The image's agent.cfg and kb.cfg, to edit on the host (models: [llm] and [models])
for f in agent.cfg kb.cfg; do docker run --rm --entrypoint cat agenticwf:latest /etc/agenticwf/$f \
    | sudo tee /etc/agenticwf/$f > /dev/null; done
docker compose up -d
```

or without compose:

```sh
docker run -d --name agenticwf --network host --restart unless-stopped \
    --env-file /etc/agenticwf/agenticwf.env -v agenticwf-data:/var/lib/agenticwf \
    -v /etc/agenticwf/agent.cfg:/etc/agenticwf/agent.cfg:ro \
    -v /etc/agenticwf/kb.cfg:/etc/agenticwf/kb.cfg:ro agenticwf:latest
```

`compose.yaml` mounts `/etc/agenticwf/agent.cfg` and `/etc/agenticwf/kb.cfg` over the image's own,
so the agent's and the KB's settings (models in `[llm]`, see the agent's `docs/agent-models.md`;
in `[models]`, see the KB's `docs/configuration.md`) are edited on the host. Both must exist
before `docker compose up`. Copy them from the image, not from `.src/`: the build switches the
agent's `[knowledge]` section on (the KB's socket), and a copy from the sources leaves the agent
without knowledge bases. Keys stay in `agenticwf.env`, named by `api_key_env`. Compose doesn't
notice edits to the files: apply them with `docker compose up -d --force-recreate`.

For example, in `agent.cfg`, a model behind an OpenAI-compatible gateway (here CERN's LiteLLM gateway), and the
gateway allowed for models people add on the agent's admin page:

```ini
[llm]
default = cern-qwen38
# Hosts that models added on the admin page may point at.
allowed_hosts = aigw.cern.ch

# provider vllm: OpenAI-compatible, sends max_tokens. model: the id the gateway's /models lists.
# base_url: the client appends /chat/completions. The key: CERN_AIGW_API_KEY in agenticwf.env.
[llm.model.cern-qwen38]
provider = vllm
model = qwen3.8-27b-fp16
label = Qwen 3.8 27B (CERN)
base_url = https://aigw.cern.ch
api_key_env = CERN_AIGW_API_KEY
```

And in `kb.cfg`, the gateway's embedding and chat models:

```ini
[models]
default_embedding = cern-e5
default_chat = cern-qwen38

[models.embedding.cern-e5]
provider = openai_compat
base_url = https://aigw.cern.ch
model = e5-large-v2
dimension = 1024
api_key_env = CERN_AIGW_API_KEY

[models.chat.cern-qwen38]
provider = openai_compat
base_url = https://aigw.cern.ch
model = qwen3.8-27b-fp16
api_key_env = CERN_AIGW_API_KEY
supports_tools = true
```

`default_embedding` applies to new KBs. An existing KB keeps its embedding model and dimension
once its first item is indexed; changing them means a reindex (the KB's `docs/ingestion.md`).
Images built from older agent or KB sources read a `#` after a value as part of the value; keep
comments on their own lines there.

`docker restart` doesn't re-read the env file. After editing it, recreate the container:
`docker compose up -d`, or `docker rm -f agenticwf` followed by the `docker run` again.

The container uses **host networking**. Its services listen on `127.0.0.1` only
(`LISTEN_HOST`), where host Caddy reaches them, and Logto sends mail through the host's MTA. Ports
3001, 3002, 8010, 8000, 8020 and `PGPORT` (5432) must be free on the host. Each one can be moved
with an env variable (`LOGTO_PORT`, `LOGTO_ADMIN_PORT`, `AUTHSVC_PORT`, `AGENT_PORT`, `KB_PORT`,
`PGPORT`). Don't set `LISTEN_HOST=0.0.0.0` with host networking: only Caddy may reach the services.
The KB and the agent trust the identity authsvc signs, which Caddy obtains with `forward_auth` on
every request.

## Email (Logto)

On first boot the container creates an SMTP email connector in Logto. Logto uses it for sign-up
verification codes and "forgot password". By default it sends through the host's MTA on
`127.0.0.1:25` with no login and no TLS (loopback only), from
`AgenticWF <agenticwf-noreply@<host FQDN>>`. The host must already deliver mail, which you can
check with `echo test | mail -s test you@example.org`. Postfix listens on `127.0.0.1:25` by
default (`ss -ltn | grep ':25 '`).

- **Settings:** `LOGTO_EMAIL_FROM`, `LOGTO_SMTP_HOST`, `LOGTO_SMTP_PORT`, `LOGTO_SMTP_TLS`,
  `LOGTO_SMTP_USER` and `LOGTO_SMTP_PASSWORD`, for example to use `smtp.cern.ch:587` with a
  service account. `LOGTO_EMAIL_CONNECTOR=off` skips the connector. See
  [container/agenticwf.env.example](container/agenticwf.env.example).
- **Applied once:** the connector is created only if Logto has no email connector yet, and only
  once (marker `/var/lib/agenticwf/logto/email-connector-created`). After that the Logto console
  owns it: *Connectors → Email and SMS connectors*, where *Send test email* checks delivery.
  Delete the marker to have the env settings applied again on the next start, once no email
  connector is left in Logto.
- **Test from the container:**

  ```sh
  docker exec agenticwf /opt/authsvc/venv/bin/python -c 'import smtplib; from email.message import EmailMessage as M
  m = M(); m["From"] = "agenticwf-noreply@'"$(hostname -f)"'"; m["To"] = "you@example.org"; m["Subject"] = "test"; m.set_content("test")
  s = smtplib.SMTP("127.0.0.1", 25); s.send_message(m); s.quit()'
  ```

  `{}` from `send_message` means only that Postfix queued the message. Whether it went out is in
  the host's mail log: `journalctl -u postfix --since -5min | grep status=` (or
  `/var/log/maillog`).
- **CERN hosts:** CERN's mail gateway rejects senders at the host's own domain
  (`status=bounced ... 550 TRANSPORT.RULES.RejectMessage; the message was rejected by organization
  policy`), so the default `agenticwf-noreply@<host FQDN>` fails there. `mail` still works, because
  the host's Postfix rewrites a bare local sender (`root`) to `root_<short host>@cern.ch`, and a
  sender that already has a domain isn't rewritten. Use that form:
  `LOGTO_EMAIL_FROM=AgenticWF <agenticwf-noreply_<short host>@cern.ch>`, for example
  `agenticwf-noreply_aipanda107@cern.ch`. If the connector already exists, change *From* in the
  Logto console instead (see *Applied once*).

Sign-up with email verification is switched on by the Logto configuration below
(`LOGTO_SIGNUP=email`).

## Logto configuration at startup

On every start, once Logto is up, the `logto-bootstrap` program configures Logto from
`/etc/agenticwf/agenticwf.env`. That replaces the manual console steps of AgenticWF-auth
`docs/deployment.md` §4.1–4.3 and §4.4c:

| What | From | Default |
|---|---|---|
| API resource (`AUTH_AUDIENCES`) and its permissions | `LOGTO_API_NAME`, `LOGTO_API_SCOPES`, `LOGTO_API_TOKEN_TTL` | `AgenticWF API`; `app:access agent:use knowledge:read knowledge:write dataset:read dataset:write compute:submit admin` |
| User roles and their permissions | `LOGTO_ROLES` (`name=permissions; …`, `*` = all) | `researcher`: everything except `dataset:write`, `compute:submit` and `admin`; `admin`: all |
| Roles new users get | `LOGTO_DEFAULT_ROLES` | none, so an admin approves each account by assigning a role |
| Browser login app (Traditional), redirect URIs from `APP_ORIGIN` + `APP_BASE_PATH` | `LOGTO_WEB_APP_NAME` | `AgenticWF Web`. Its ID and secret go to authsvc automatically. Skipped if you set `AUTH_WEB_CLIENT_ID` |
| CLI app (Native, device flow) | `LOGTO_CLI_APP`, `LOGTO_CLI_APP_NAME` | `agenticwf CLI` |
| Machine-to-machine apps, each with its own role | `LOGTO_M2M_APPS` (`name=permissions; …`) | none |
| authsvc's Management API app (groups, personal access tokens) and the organization roles of groups | `LOGTO_MANAGEMENT_APP`, `AUTH_GROUP_ADMIN_ROLE`, `AUTH_GROUP_MEMBER_ROLE` | on: `AgenticWF Management`, its ID and secret go to authsvc; roles `admin`, `member`. Skipped if you set `AUTH_MGMT_CLIENT_ID` |
| Sign-up | `LOGTO_SIGNUP`: `email`, `closed` or `unmanaged` | `email`: email + password, the email verified by a code, password reset by email |
| Custom JWT: `roles` and `external_identity.groups` in access tokens | `LOGTO_CUSTOM_JWT` | on |
| Account center for users: `$LOGTO_ENDPOINT/account/profile`, `/account/security`, `/account/sessions` | `LOGTO_ACCOUNT_CENTER`: `on`, `off` or `unmanaged`; `LOGTO_ACCOUNT_CENTER_FIELDS` (`field=Off\|ReadOnly\|Edit …`) | on: edit the display name, email, password, social sign-ins, MFA, passkeys and sessions; the username is read-only |
| AgenticWF admin user (email + password, with roles) | `LOGTO_APP_ADMIN_EMAIL`, `LOGTO_APP_ADMIN_PASSWORD`, `LOGTO_APP_ADMIN_ROLES` | none; roles `admin` |
| Logto admin console account | `LOGTO_CONSOLE_ADMIN_USERNAME`, `LOGTO_CONSOLE_ADMIN_PASSWORD` | none; username `admin` |

- **Applied on every start, never deleting anything.** Missing things are created. Listed
  roles get any missing permissions, listed apps any missing redirect URIs, and the sign-up
  settings are set. Anything the env doesn't name stays as configured in the console. So edit
  the env, not the console, for what the env names. The exception is the Custom JWT: once you
  edit it in the console and remove its first line (`// managed by agenticwf…`), it's left alone.
  `LOGTO_BOOTSTRAP=false` turns all of this off.
- **What it produces:**
  - `/var/lib/agenticwf/logto/clients.env`: the CLI settings for laptops (`AGENTICWF_AUTH_URL`,
    `AGENTICWF_API_URL`, `AGENTICWF_RESOURCE`, `AGENTICWF_CLIENT_ID`):
    `docker exec agenticwf cat /var/lib/agenticwf/logto/clients.env`.
    With them, the client packages (`agenticwf-auth-client` from AgenticWF-auth `cli/`, plus
    `agenticwf-kb-client` and `agenticwf-agent-client` from the `client/` of each service repo) give
    `agenticwf login`, `agenticwf token`, `agenticwf kb …` and `agenticwf agent …`.
  - `/var/lib/agenticwf/secrets/logto-apps/<name>.env`: each machine app's
    `AGENTICWF_CLIENT_ID` and `AGENTICWF_CLIENT_SECRET` (root only).
- **How it talks to Logto.** It uses Logto's Management API through its own
  machine-to-machine app, `AgenticWF bootstrap (internal)`, which you'll see in the console. The
  app's secret is set directly in Logto's database at start and replaced by an unknown value
  when the bootstrap ends, so no credential is kept. Don't delete the app or its role; they're
  recreated on the next start anyway.
- **If it fails** (e.g. an unknown permission in `LOGTO_ROLES`), the log says why, authsvc
  doesn't start, and the container stops, so the restart policy retries after you fix the env:
  `docker logs agenticwf 2>&1 | grep logto-bootstrap`. An exception: if email sign-up can't be
  enabled because there's no email connector, it logs an error and carries on.
- **Admin accounts.** With `LOGTO_CONSOLE_ADMIN_PASSWORD`, the Logto admin console account is
  created at boot, with what Logto gives the first visitor (full rights on the `default` tenant),
  and console sign-up is closed. Without it, the account is created on your first visit to the
  console, so open it before anyone else can. With `LOGTO_APP_ADMIN_EMAIL` and
  `LOGTO_APP_ADMIN_PASSWORD`, an AgenticWF user with that email and password gets
  `LOGTO_APP_ADMIN_ROLES` (default `admin`), with no sign-up or approval. With only the email, an
  existing user with it gets the roles.
  - The passwords move into `/var/lib/agenticwf/secrets/logto_{console,app}_admin_password`
    on first boot. They're applied on **every** boot, so a password changed in the console or
    reset by email is set back. Change it in the env, or delete the secrets file to stop managing
    it. The accounts and roles are never removed.
  - A failure with the console account is logged (`ERROR: admin console account`) and the
    container carries on.
- **Not covered.** Assigning roles to other users (approval) and the INDIGO IAM / GitHub
  connectors stay console steps.

## Caddy on the host

Caddy terminates TLS and sends every application request through authsvc (`forward_auth`) before
it reaches the agent or the KB. The files are in [deploy/caddy/](deploy/caddy). Pick **one**
layout:

| | **A. Single hostname** (`agenticwf-single-host.caddyfile`) | **B. Separate hostnames** (`agenticwf-multi-host.caddyfile`) |
|---|---|---|
| Needs | 1 DNS name, port 443 only | 3 DNS names (same IP is fine) |
| Logto | `https://host.example.org/` | `https://auth.example.org/` |
| Agent (UI, REST, SSE, WebSocket) | `https://host.example.org/app/` | `https://app.example.org/` |
| Knowledge service | `https://host.example.org/app/kb/` | `https://app.example.org/kb/` |
| Browser login | `https://host.example.org/app/auth/*` | `https://app.example.org/auth/*` |
| Logto admin console | SSH tunnel (`ssh -L 3002:127.0.0.1:3002 host`); optional `:8443` add-on | `https://auth-admin.example.org` (IP-restricted) |
| Caddy environment | `AGENTICWF_HOST`, `AGENTICWF_ACME_EMAIL` | `AGENTICWF_LOGTO_HOST`, `AGENTICWF_LOGTO_ADMIN_HOST`, `AGENTICWF_APP_HOST`, `AGENTICWF_ADMIN_ALLOWED_CIDRS`, `AGENTICWF_ACME_EMAIL` |
| Container env | `LOGTO_ENDPOINT=https://host.example.org`, `APP_ORIGIN=https://host.example.org`, `APP_BASE_PATH=/app` | `LOGTO_ENDPOINT=https://auth.example.org`, `LOGTO_ADMIN_ENDPOINT=https://auth-admin.example.org`, `APP_ORIGIN=https://app.example.org`, `APP_BASE_PATH=` |

In layout A Logto owns `/` (it cannot run under a path prefix), so the application lives under
`/app`. Caddy strips `/app`, so authsvc, `policy.yaml` and the services see plain `/api/v1/...`
and `/kb/...` paths. Requests for `/kb` and `/kb/*` go to the KB (8020) and everything else to the
agent (8000). The KB keeps its `/kb` prefix because that's the path authsvc signed.

```bash
sudo cp deploy/caddy/Caddyfile /etc/caddy/Caddyfile        # optional: the EL9 default already imports Caddyfile.d
sudo rm -f /etc/caddy/Caddyfile.d/agenticwf-*.caddyfile    # switching layouts: remove the other one
sudo cp deploy/caddy/sites/agenticwf-single-host.caddyfile /etc/caddy/Caddyfile.d/     # layout A
#   or: sudo cp deploy/caddy/sites/agenticwf-multi-host.caddyfile /etc/caddy/Caddyfile.d/   # layout B

# Caddy's environment (hostnames, ACME contact); no defaults on purpose
sudo cp deploy/caddy/agenticwf-caddy.env.example /etc/caddy/agenticwf.env    # then edit it
sudo mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/agenticwf.env\n' \
    | sudo tee /etc/systemd/system/caddy.service.d/agenticwf.conf >/dev/null
sudo systemctl daemon-reload

sudo bash -c 'set -a; . /etc/caddy/agenticwf.env; caddy validate --config /etc/caddy/Caddyfile'
sudo systemctl restart caddy        # restart, not reload, after changing the environment
```

- **Certificates.** By default the site files use ACME (Let's Encrypt, TLS-ALPN on 443). For a
  host reachable only inside a site network, replace `tls {$AGENTICWF_ACME_EMAIL}` with
  `tls /etc/caddy/certs/hostcert.pem /etc/caddy/certs/hostkey.pem`. In layout A it's in the site
  block; in layout B it's in the `(agenticwf_common)` snippet. The `caddy` user must be able to
  read both files.
- **Missing environment.** If a hostname variable is unset, Caddy refuses to load with
  `server block without any key is global configuration`. That means the env file didn't reach
  Caddy. An unset `AGENTICWF_ADMIN_ALLOWED_CIDRS` fails closed: the admin console answers 403.
- **Admin console on :8443 (layout A, development).** Also install
  `sites/agenticwf-admin-console.caddyfile`, set `AGENTICWF_ADMIN_ALLOWED_CIDRS`, and set
  `LOGTO_ADMIN_ENDPOINT=https://host.example.org:8443` in the container env. Port 8443 must be
  open in the host firewall.
- **Ports.** The site files use the container's default ports (3001, 3002, 8010, 8000, 8020). If
  you change `LOGTO_PORT`, `AUTHSVC_PORT`, `AGENT_PORT` or `KB_PORT`, change the site file too.
- **Tracing (optional).** Caddy can start an OpenTelemetry trace for each application request
  and send it to Jaeger; see [Tracing](#tracing).

## Tracing

[Jaeger](https://www.jaegertracing.io/) runs in its own container ([compose.jaeger.yaml](compose.jaeger.yaml),
config in [deploy/jaeger/jaeger.yaml](deploy/jaeger/jaeger.yaml)), with host networking like the
agenticwf container, so no Docker bridge or iptables rules are involved. Caddy and the agenticwf
container send it their spans, and its UI shows them. Caddy's `traceparent` reaches both authsvc's
`/verify` and the agent or KB, so each browser or API request becomes one trace: `caddy` →
`agenticwf-auth` and `agenticwf-agent` / `agenticwf-kb`.

| Port (host's 127.0.0.1) | | From |
|---|---|---|
| 4317 | OTLP/gRPC | host Caddy |
| 4318 | OTLP/HTTP | authsvc, KB, agent (the container uses host networking) |
| 16686 | UI (dashboard), under `JAEGER_BASE_PATH` | Caddy (one of three options below), or an SSH tunnel |
| 13133, 16685 | health check, query gRPC | (unused; must be free too) |

```bash
# 1. Jaeger. Its UI is under JAEGER_BASE_PATH (default /jaeger; see the dashboard options below)
docker compose -f compose.jaeger.yaml up -d
#    or, for the jaeger-ui-app.d files in layout A (/app/jaeger/):
JAEGER_BASE_PATH=/app/jaeger docker compose -f compose.jaeger.yaml up -d --force-recreate

# 2. The services: uncomment in /etc/agenticwf/agenticwf.env
#      OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
#    and recreate the container (docker restart doesn't re-read the env file)
docker compose up -d --force-recreate

# 3. Caddy: the tracing file, and the OTEL_* lines in /etc/caddy/agenticwf.env uncommented
sudo mkdir -p /etc/caddy/tracing.d
sudo cp deploy/caddy/tracing/agenticwf-tracing.caddy /etc/caddy/tracing.d/
sudo systemctl restart caddy        # restart: the environment changed

# 4. The dashboard through Caddy: ONE of the three options below, e.g. without login at /jaeger/
sudo mkdir -p /etc/caddy/jaeger-ui.d
sudo cp deploy/caddy/jaeger-ui/agenticwf-jaeger-ui.caddy /etc/caddy/jaeger-ui.d/
sudo systemctl reload caddy
#    or without Caddy: ssh -N -L 16686:127.0.0.1:16686 <user>@host.example.org
#    then http://localhost:16686/jaeger/   (the JAEGER_BASE_PATH)
```

The dashboard: install **one** file from [deploy/caddy/jaeger-ui/](deploy/caddy/jaeger-ui), as
suits your setup. Jaeger has no login, and traces show paths, user ids and timings, so each option
guards it.

| | `agenticwf-jaeger-ui.caddy` | `agenticwf-jaeger-ui-network.caddy` | `agenticwf-jaeger-ui-logto.caddy` |
|---|---|---|---|
| Install into | `/etc/caddy/jaeger-ui.d/` | `/etc/caddy/jaeger-ui-app.d/` | `/etc/caddy/jaeger-ui-app.d/` |
| Layout A URL | `https://host.example.org/jaeger/` | `https://host.example.org/app/jaeger/` | `https://host.example.org/app/jaeger/` |
| Layout B URL | `https://app.example.org/jaeger/` | the same | the same |
| `JAEGER_BASE_PATH` | `/jaeger` (default) | A: `/app/jaeger`; B: `/jaeger` | A: `/app/jaeger`; B: `/jaeger` |
| Who gets in | `AGENTICWF_ADMIN_ALLOWED_CIDRS` | `AGENTICWF_ADMIN_ALLOWED_CIDRS` | Signed-in users with the `admin` permission (people, not M2M apps) |
| Needs | Caddy, Jaeger | Caddy, Jaeger | Also Logto, authsvc, and an image with [deploy/policy.jaeger.yaml](deploy/policy.jaeger.yaml) |

- **Without login** (the first two): Caddy checks `remote_ip`; an unset
  `AGENTICWF_ADMIN_ALLOWED_CIDRS` means 403 for everyone. They differ only in where the UI lives in
  layout A: beside Logto on the site root, or inside the application under `/app`. Neither needs
  Logto or authsvc, so they keep working while those are down.
- **With Logto**: Caddy sends each request through authsvc's `/verify`, like the application's. A
  browser without a session is sent to sign in and back; the `/jaeger/**` rule asks for `admin`.
  Jaeger never gets the session cookie or the bearer token. To require operator networks too,
  uncomment the `@outside` lines. Each UI request also makes an `agenticwf-auth` `/verify` trace.
  It lives inside the application because authsvc sends people back to `${APP_BASE_PATH}/...`
  after sign-in.
- **Paths.** Jaeger serves under the full browser path (`JAEGER_BASE_PATH`), so set it to match the
  option: `JAEGER_BASE_PATH=/app/jaeger docker compose -f compose.jaeger.yaml up -d --force-recreate`
  for the `jaeger-ui-app.d` files in layout A. With `sudo`, put the variable after it
  (`sudo JAEGER_BASE_PATH=… docker compose …`): sudo drops it otherwise. To keep it for later
  `up`s, write `JAEGER_BASE_PATH=/app/jaeger` into `.env` beside the compose files. Check with
  `curl -sI http://127.0.0.1:16686/app/jaeger/` (200). If `APP_BASE_PATH` changes, change it too. An empty or
  missing `jaeger-ui.d` / `jaeger-ui-app.d` only makes Caddy log "No files matching import glob
  pattern" once per load.
- **Caddy tracing is opt-in by file.** The site files' `agenticwf_trace` snippet imports
  `/etc/caddy/tracing.d/*.caddy`; without a file there is no `tracing`, and Caddy logs "No files
  matching import glob pattern" once per load. An environment switch would not work on EL9's Caddy
  2.6, which ignores `OTEL_TRACES_EXPORTER` and always exports over gRPC; 2.11 and later default
  to http/protobuf, hence `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`. The site files always drop
  `traceparent`, `tracestate` and `baggage` sent by clients, so every trace starts at Caddy.
- **Service names.** Leave `OTEL_SERVICE_NAME` unset in the container's env: it would give every
  service the same name. Each names itself (`agenticwf-auth`, `agenticwf-kb`,
  `agenticwf-kb-worker`, `agenticwf-agent`, `agenticwf-agent-worker`). Caddy's is `caddy`.
- **Retention.** Spans are kept in Badger on the `jaeger-data` volume for `JAEGER_TRACES_TTL`
  (default `168h`): `JAEGER_TRACES_TTL=72h docker compose -f compose.jaeger.yaml up -d`.
- **Switching off.** Comment out `OTEL_EXPORTER_OTLP_ENDPOINT` and recreate the container; remove
  `/etc/caddy/tracing.d/agenticwf-tracing.caddy` and restart Caddy; then
  `docker compose -f compose.jaeger.yaml down` (add `-v` to delete the stored traces). If Jaeger
  is down while tracing is on, requests still work; the exporters log failed exports.
- **Local use.** On Docker Desktop, run the same Jaeger on Docker's bridge with published ports
  (`JAEGER_LISTEN_HOST=0.0.0.0` is the container's side):

  ```sh
  docker run -d --name agenticwf-jaeger -e JAEGER_LISTEN_HOST=0.0.0.0 \
    -p 127.0.0.1:4317:4317 -p 127.0.0.1:4318:4318 -p 127.0.0.1:16686:16686 \
    -v "$PWD/deploy/jaeger/jaeger.yaml:/etc/jaeger/jaeger.yaml:ro" -v agenticwf-jaeger-data:/tmp \
    jaegertracing/jaeger:2.21.0 --config /etc/jaeger/jaeger.yaml
  ```

  Then set `OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318` in
  `~/.agenticwf/local.env`; the UI is http://localhost:16686/jaeger/.

## Groups

Groups are how people share knowledge with a team. A group is a Logto **organization**, managed on
the admin page's **Groups** tab (`/app/admin#groups`):

- **Everyone** sees every group, asks to join one (with a note for its admins), sees who is in their
  own groups, and leaves a group.
- **A group's admins** (organization role `admin`) add people by email, remove them, make them
  admins, approve or decline join requests, and rename the group.
- **Administrators** (the `admin` permission) do this for every group, and create and delete groups.
  After creating one, add its first admin.

A knowledge base or a document with **groups** visibility is shared with the groups it names. The
KB stores a group as `org:<id>` and shows it by name; its sidebar lists your groups. authsvc looks
each user's groups up in Logto (cached for `AUTH_GROUP_CACHE_TTL`, 60 s), so joining or leaving
applies within a minute, without signing in again. A group's last admin must appoint another one
before leaving.

`logto-bootstrap` sets this up (the Management API app and the `admin` / `member` organization
roles; `LOGTO_MANAGEMENT_APP=false` turns it off). The same app also enables personal access tokens
on the Tokens tab. Organizations made in the Logto console work too, as long as their members hold
these roles. The API is described in AgenticWF-auth `docs/auth-service.md` (`/auth/groups`).

## My memory

The KB page's sidebar has **🧠 My memory** next to your knowledge bases. It is your own long-term
memory, kept as facts with dates. It is not inside a knowledge base, and only you can read it.

What goes in is stored as an **episode** (a piece of text) with a source: `manual` (added on the
page), `document` (from a document KB whose settings feed processed documents into your memory)
or `conversation` (from the agent, see below). In the background an LLM extracts **entities**
and the **facts** linking them from each episode. Each fact has two times: when it was true in
the world (`valid`) and when the KB learned or retired it (`learned`). A newer fact that
contradicts an older one marks the older one no longer valid instead of deleting it, so you can
still ask what was true, or known, at an earlier date. Deleting an episode removes the facts that
only it supported and reverses the invalidations it caused.

The page has three tabs: **Facts**, **Episodes** (add or delete them) and **Search** (keyword and
meaning, plus the entity's linked facts, optionally as of a past date).

It is off in the image. To switch it on, set this in `/etc/agenticwf/kb.cfg`:

```ini
[features]
memory = true

# optional
[memory]
# model = ...          # extraction and the contradiction judge; default: [models] default_chat
# default_group = default
```

To have the agent keep its long-term memory of your chats there too (group `agent`), set this in
`/etc/agenticwf/agent.cfg`:

```ini
[knowledge]
memory = true
memory_group = agent
```

Then apply both with `docker compose up -d --force-recreate`. See the KB's
`docs/configuration.md` (`[memory]`) and `docs/agent-integration.md` (agent memory on the KB).

## What the build combines

- `container/Dockerfile`: one venv per service under `/opt/{authsvc,kb,agent}/venv`. A `base`
  stage, then the image: base + Node.js + Logto on amd64, base alone on arm64.
- `AGENTICWF_MODE` (`server` or `local`) and `AGENTICWF_SERVICES` decide which
  supervisord programs start, which databases and secrets the entrypoint prepares, and what
  `healthcheck.sh` checks.
- Each repo's own start scripts and supervisord program files are used as they are, except
  `postgres.ini`, `kb.ini` and `agent.ini` (here: one shared cluster, a separate `PORT` per program).
  auth's `rest-example` program (port 8000) is left out.
- `container/scripts/entrypoint.sh` merges the three entrypoints: secrets, one `initdb`, roles,
  databases and the KB's extensions.
- `/etc/agenticwf/policy.yaml` is generated at build time by `container/scripts/merge-policy.py`
  from the KB's, the agent's and authsvc's route policies (in that order; first match wins), and
  checked with authsvc's loader.
- The agent's `agent.cfg` gets `[knowledge] url = unix:/run/agenticwf-kb/kb.sock`, and
  `tools = kb_research`, `research_preset = kb`: knowledge searches go through the KB's agentic
  search with its default preset (`smart`, or `deep` with `KB_WEB=false`). Each user can choose
  otherwise on the agent's admin page (Knowledge, Search). `memory = true`, `memory_group = agent`:
  the agent's long-term memory is the KB's temporal memory; with `KB_MEMORY=false` the entrypoint
  sets `memory = false` and the agent keeps memories in its own database.
- Logto is started by `container/scripts/start-logto-aio.sh`. It seeds Logto's database, adds the
  default email connector (`logto-email-connector.py`), then runs AgenticWF-auth's
  `start-logto.sh`.
- `logto-bootstrap` (`container/scripts/logto-bootstrap.py`) configures Logto once it runs.
  authsvc is started by `start-authsvc-aio.sh`, which waits for it, then runs AgenticWF-auth's
  `start-authsvc.sh`.
- `deploy/caddy/` is AgenticWF-auth's Caddy setup with the KB's `/kb` route added (from
  AgenticWF-KB `deploy/caddy/kb.caddyfile`).
