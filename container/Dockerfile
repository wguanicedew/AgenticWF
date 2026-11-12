# syntax=docker/dockerfile:1.7
#
# AgenticWF all-in-one image: agenticwf-auth (authsvc with Logto or Keycloak), agenticwf-kb and
# agenticwf-agent in one container, sharing one PostgreSQL 16 cluster, under supervisord.
#
# One image for both modes, chosen at run time (README.md):
#   AGENTICWF_MODE=server  the shared deployment: identity provider + authsvc + KB + agent behind
#                          host Caddy.
#   AGENTICWF_MODE=local   personal use on a laptop/desktop: the agent and/or the KB with their
#                          own access tokens, no identity provider, authsvc or Caddy.
# AGENTICWF_AUTH_PROVIDER picks the identity provider of server mode: logto (default) or keycloak.
# Both are in the image (build arg AUTH_PROVIDERS); only the chosen one runs.
# AGENTICWF_SERVICES picks the services: "agent", "kb" or "agent kb" (default; in server mode
# the identity provider and authsvc always run besides). Unset AGENTICWF_MODE: server where the
# image has Logto or AGENTICWF_AUTH_PROVIDER is set, else local.
#
# Platforms: linux/amd64 has everything; linux/arm64 has no Logto (its release ships x64 native
# addons): there server mode needs AGENTICWF_AUTH_PROVIDER=keycloak.
#
# The repos come in as BuildKit named contexts (see container/build.sh): the provider-neutral auth
# service (AgenticWF-auth), its two provider repos, the KB and the agent:
#
#   docker buildx build -f container/Dockerfile [--platform linux/arm64] \
#       --build-context auth=../AgenticWF-auth \
#       --build-context auth-logto=../AgenticWF-auth-logto \
#       --build-context auth-keycloak=../AgenticWf-auth-keycloak \
#       --build-context kb=../AgenticWF-KB \
#       --build-context agent=../AgenticWF-agent \
#       -t agenticwf .
#
# A context can also be a git ref, e.g.
#   --build-context auth='https://github.com/InnovateAILab/AgenticWF-auth.git#v0.1.0'

# --- the KB's pg_search version ----------------------------------------------------------------
# The KB pins ParadeDB pg_search in its own container/Dockerfile (ARG PG_SEARCH_VERSION); this image
# installs the same one. Only the version reaches the base stage, so other changes to the KB's
# Dockerfile do not rebuild the PostgreSQL layer.
FROM almalinux:9 AS pg-search-version
COPY --from=kb container/Dockerfile /tmp/kb.Dockerfile
RUN sed -n 's/^ARG PG_SEARCH_VERSION=\([0-9][0-9.]*\)[[:space:]]*$/\1/p' /tmp/kb.Dockerfile > /pg_search_version

# --- base: PostgreSQL, the three Python services, supervisord programs and scripts --------------
FROM almalinux:9 AS base

ARG POSTGRES_MAJOR=16
ARG PYTHON=python3.12
# Empty: the KB's version (stage pg-search-version). Set it to build another one.
ARG PG_SEARCH_VERSION=
# The identity providers installed: "logto keycloak" (default), or one of them for a smaller image.
# Logto only exists on linux/amd64.
ARG AUTH_PROVIDERS="logto keycloak"

# PostgreSQL from PGDG (pgvector, pg_search for the KB; also serves Logto or Keycloak and authsvc),
# Python, supervisord, Java 21 for Keycloak (when AUTH_PROVIDERS has it).
RUN --mount=type=bind,from=pg-search-version,source=/pg_search_version,target=/tmp/pg_search_version \
    set -eux; \
    PG_SEARCH_VERSION="${PG_SEARCH_VERSION:-$(head -n1 /tmp/pg_search_version)}"; \
    [ -n "$PG_SEARCH_VERSION" ] || { echo "no 'ARG PG_SEARCH_VERSION=<version>' in the KB's" \
        "container/Dockerfile: pass --build-arg PG_SEARCH_VERSION=<version>" >&2; exit 1; }; \
    arch="$(uname -m)"; \
    dnf -y install epel-release; \
    dnf -y install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-${arch}/pgdg-redhat-repo-latest.noarch.rpm"; \
    dnf -qy module disable postgresql; \
    dnf -y install --setopt=install_weak_deps=False \
        "postgresql${POSTGRES_MAJOR}-server" "postgresql${POSTGRES_MAJOR}-contrib" "pgvector_${POSTGRES_MAJOR}" \
        "${PYTHON}" "${PYTHON}-pip" supervisor openssl procps-ng tar gzip xz git-core; \
    case " ${AUTH_PROVIDERS} " in *" keycloak "*) \
        dnf -y install --setopt=install_weak_deps=False java-21-openjdk-headless ;; esac; \
    dnf -y install \
        "https://github.com/paradedb/paradedb/releases/download/v${PG_SEARCH_VERSION}/pg_search_${POSTGRES_MAJOR}-${PG_SEARCH_VERSION}-1PARADEDB.el9.${arch}.rpm"; \
    for ext in vector pg_search pg_trgm; do \
        test -f "/usr/pgsql-${POSTGRES_MAJOR}/share/extension/${ext}.control"; \
    done; \
    dnf clean all; rm -rf /var/cache/dnf

# Service users. Group agenticwf may read authsvc's AuthContext secret; the agent is in group kb
# to reach the KB's service socket in /run/agenticwf-kb (2770 kb:kb). Users for both identity
# providers, whichever is installed.
RUN groupadd --system agenticwf \
 && groupadd --gid 1000 kb \
 && useradd --uid 1000 --gid kb -G agenticwf --create-home --home-dir /home/kb --shell /sbin/nologin kb \
 && useradd --uid 1001 --user-group -G kb,agenticwf --create-home --home-dir /home/agent --shell /sbin/nologin agent \
 && useradd --system --create-home --home-dir /home/logto --shell /sbin/nologin logto \
 && useradd --system --create-home --home-dir /home/keycloak --shell /sbin/nologin keycloak \
 && useradd --system --create-home --home-dir /home/authsvc --shell /sbin/nologin -G agenticwf authsvc

# One venv per service, as in the per-service images (their start scripts use these paths).
# authsvc's venv has the provider-neutral service and both provider packages (small; the start
# script picks one: agenticwf_auth_logto or agenticwf_auth_keycloak). KB and agent import
# agenticwf.auth's AuthContext verifier, so each venv gets it too.
COPY --from=auth authsvc /opt/authsvc/src
COPY --from=auth-logto provider /opt/authsvc/provider-logto
COPY --from=auth-keycloak provider /opt/authsvc/provider-keycloak
RUN "${PYTHON}" -m venv /opt/authsvc/venv \
 && /opt/authsvc/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/authsvc/venv/bin/pip install --no-cache-dir "/opt/authsvc/src[otel]" \
        /opt/authsvc/provider-logto /opt/authsvc/provider-keycloak

COPY --from=kb pyproject.toml /opt/kb/src/pyproject.toml
COPY --from=kb src /opt/kb/src/src
RUN "${PYTHON}" -m venv /opt/kb/venv \
 && /opt/kb/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/kb/venv/bin/pip install --no-cache-dir /opt/authsvc/src \
 && /opt/kb/venv/bin/pip install --no-cache-dir "/opt/kb/src[parsers,otel]"

COPY --from=agent pyproject.toml /opt/agent/src/pyproject.toml
COPY --from=agent src /opt/agent/src/src
RUN "${PYTHON}" -m venv /opt/agent/venv \
 && /opt/agent/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/agent/venv/bin/pip install --no-cache-dir /opt/authsvc/src \
 && /opt/agent/venv/bin/pip install --no-cache-dir "/opt/agent/src[llm,otel]"

# supervisord: the repos' own program files where they fit unchanged. Replaced here: postgres, kb
# and agent (one shared cluster; per-program PORT; started per AGENTICWF_SERVICES), logto (the
# default email connector first), keycloak (started per AGENTICWF_AUTH_PROVIDER) and authsvc (the
# chosen provider; waits for logto-bootstrap). The provider repos' rest-example (:8000) is left out.
# groups.ini here replaces the repos' (supervisorctl names auth:*, kbsvc:*, agentsvc:*).
COPY --from=auth-logto container/supervisord.conf /etc/supervisord.conf
COPY --from=kb container/supervisord.d/kb-service.ini container/supervisord.d/kb-worker.ini \
     container/supervisord.d/fatal.ini /etc/supervisord.d/
COPY --from=agent container/supervisord.d/agent-worker.ini /etc/supervisord.d/
COPY container/supervisord.d/ /etc/supervisord.d/

# Program scripts from the repos; entrypoint, healthcheck and helpers for the combined container.
# Both provider repos name their authsvc script start-authsvc.sh: here -logto.sh / -keycloak.sh,
# started by start-authsvc-aio.sh.
COPY --from=auth-logto container/scripts/start-logto.sh container/scripts/listen-host.cjs /usr/local/bin/
COPY --from=auth-logto container/scripts/start-authsvc.sh /usr/local/bin/start-authsvc-logto.sh
COPY --from=auth-keycloak container/scripts/start-keycloak.sh container/scripts/render-realm.py /usr/local/bin/
COPY --from=auth-keycloak container/scripts/start-authsvc.sh /usr/local/bin/start-authsvc-keycloak.sh
COPY --from=auth-keycloak container/config/realm-agenticwf.json /etc/agenticwf/keycloak/realm-agenticwf.json
COPY --from=kb container/scripts/start-kb.sh container/scripts/start-kb-service.sh \
     container/scripts/start-kb-worker.sh container/scripts/supervisor-fatal.sh \
     container/scripts/log-prefix.sh /usr/local/bin/
COPY --from=agent container/scripts/start-agent.sh container/scripts/start-agent-worker.sh /usr/local/bin/
COPY container/scripts/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/*.sh /usr/local/bin/*.py /usr/local/bin/agenticwf-links \
 && ln -s /opt/kb/venv/bin/agenticwf-kb /usr/local/bin/agenticwf-kb \
 && ln -s /opt/agent/venv/bin/agenticwf-agent /usr/local/bin/agenticwf-agent

# Route policy: KB, agent and Jaeger UI (deploy/policy.jaeger.yaml) rules merged into authsvc's,
# checked with authsvc's own loader.
COPY --from=kb deploy/policy.kb.yaml /tmp/policy/kb.yaml
COPY --from=agent deploy/policy.agent.yaml /tmp/policy/agent.yaml
COPY --from=auth config/policy.yaml /tmp/policy/auth.yaml
COPY deploy/policy.jaeger.yaml /tmp/policy/jaeger.yaml
RUN install -d /etc/agenticwf \
 && /opt/authsvc/venv/bin/python /usr/local/bin/merge-policy.py \
        /tmp/policy/kb.yaml /tmp/policy/agent.yaml /tmp/policy/jaeger.yaml /tmp/policy/auth.yaml > /etc/agenticwf/policy.yaml \
 && /opt/authsvc/venv/bin/python -c \
        'from pathlib import Path; from agenticwf.auth.authz import Policy; Policy.load(Path("/etc/agenticwf/policy.yaml"))' \
 && rm -rf /tmp/policy

# Service configuration. The agent's [knowledge] section is switched on: the KB's service
# listener on the in-container socket (the entrypoint turns it off when the KB does not run).
# Knowledge searches go through the KB's agentic search (kb_research) with the KB's default preset
# (kb.cfg: deep, the knowledge bases only; the agent's own web search fills gaps); each user may
# choose otherwise on the agent's admin page. The
# agent's long-term memory is the KB's temporal memory (group `agent`; off again with KB_MEMORY=false).
COPY --from=kb container/config/kb.cfg /etc/agenticwf/kb.cfg
COPY --from=agent container/config/agent.cfg /etc/agenticwf/agent.cfg
COPY --from=agent src/agenticwf/agent/runtime/defaults/ /etc/agenticwf/agent/
RUN mkdir -p /etc/agenticwf/agent/tools \
 && sed -i \
        -e 's|^# \[knowledge\]$|[knowledge]|' \
        -e 's|^# url = unix:/run/agenticwf-kb/kb.sock .*$|url = unix:/run/agenticwf-kb/kb.sock|' \
        -e 's|^# base_path = /kb$|base_path = /kb|' \
        -e 's|^# mode = service .*$|mode = service|' \
        -e 's|^# tools = auto .*$|tools = kb_research|' \
        -e 's|^# research_preset = model .*$|research_preset = kb|' \
        -e 's|^# memory = false .*$|memory = true|' \
        -e 's|^# memory_group = agent$|memory_group = agent|' \
        /etc/agenticwf/agent.cfg \
 && /opt/agent/venv/bin/python -c 'import configparser, sys; c = configparser.ConfigParser(inline_comment_prefixes=("#",)); c.read(sys.argv[1]); k = c["knowledge"]; assert k["url"] == "unix:/run/agenticwf-kb/kb.sock" and k["base_path"] == "/kb" and k["mode"] == "service" and k["tools"] == "kb_research" and k["research_preset"] == "kb" and k["memory"] == "true" and k["memory_group"] == "agent", dict(k)' \
        /etc/agenticwf/agent.cfg

# One data volume. kb.cfg and agent.cfg name /var/lib/agenticwf-kb and /var/lib/agenticwf-agent;
# those point into it.
RUN ln -s /var/lib/agenticwf/kb /var/lib/agenticwf-kb \
 && ln -s /var/lib/agenticwf/agent /var/lib/agenticwf-agent

ENV DATA_ROOT=/var/lib/agenticwf \
    PGDATA=/var/lib/agenticwf/pgdata \
    PGBIN=/usr/pgsql-${POSTGRES_MAJOR}/bin \
    KB_DATA_ROOT=/var/lib/agenticwf/kb \
    AGENT_DATA_ROOT=/var/lib/agenticwf/agent \
    AGENTICWF_KB_CONFIG=/etc/agenticwf/kb.cfg \
    AGENTICWF_CONFIG=/etc/agenticwf/agent.cfg \
    AGENTICWF_AGENT_HOME=/var/lib/agenticwf/agent/local \
    KB_CONTAINER=1 \
    AGENT_CONTAINER=1 \
    PATH=/usr/pgsql-${POSTGRES_MAJOR}/bin:$PATH \
    PYTHONUNBUFFERED=1

VOLUME ["/var/lib/agenticwf"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 CMD /usr/local/bin/healthcheck.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord.conf"]

# --- the image: base + the identity providers (AUTH_PROVIDERS) ----------------------------------
FROM base AS agenticwf

ARG TARGETARCH
ARG AUTH_PROVIDERS="logto keycloak"
ARG LOGTO_VERSION=1.44.0
ARG NODE_VERSION=22.23.3
ARG KEYCLOAK_VERSION=26.4.0
# Keycloak's path prefix, a build-time option of Keycloak (kc.sh build). Caddy routes it to Keycloak,
# so Keycloak and the application can share one hostname.
ARG KEYCLOAK_PATH=/idp

# Logto: Node.js (the official build; the EL9 nodejs module segfaults with Logto), then the Logto
# OSS release, whose native addons are linux-x64-gnu: on arm64 neither is installed, and server
# mode there needs Keycloak.
RUN set -eux; \
    case " ${AUTH_PROVIDERS} " in *" logto "*) ;; *) echo "Logto not in AUTH_PROVIDERS"; exit 0 ;; esac; \
    arch="$(uname -m)"; \
    if [ "$arch" != x86_64 ]; then \
        echo "no Logto on $arch (${TARGETARCH:-}): server mode needs AGENTICWF_AUTH_PROVIDER=keycloak"; exit 0; \
    fi; \
    cd /tmp; \
    tarball="node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${tarball}\$" | sha256sum -c -; \
    tar -xJf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner \
        --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'; \
    rm -f "${tarball}"; \
    node --version; \
    curl -fsSL "https://github.com/logto-io/logto/releases/download/v${LOGTO_VERSION}/logto.tar.gz" | tar -xz -C /opt; \
    install -d -o logto -g logto /opt/logto/packages/cli/alteration-scripts; \
    echo "${LOGTO_VERSION}" > /opt/logto/.agenticwf-version

# Keycloak (Java, every platform): the release, checked against its published SHA-1, built for
# PostgreSQL with health checks under KEYCLOAK_PATH (`kc.sh build`), so it starts with --optimized.
# Code stays root-owned; the keycloak user may only write data/. data/import is where
# --import-realm reads the realm the entrypoint renders into the volume.
RUN set -eux; \
    case " ${AUTH_PROVIDERS} " in *" keycloak "*) ;; *) echo "Keycloak not in AUTH_PROVIDERS"; exit 0 ;; esac; \
    cd /tmp; \
    tarball="keycloak-${KEYCLOAK_VERSION}.tar.gz"; \
    curl -fsSLO "https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/${tarball}"; \
    echo "$(curl -fsSL "https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/${tarball}.sha1")  ${tarball}" | sha1sum -c -; \
    tar -xzf "${tarball}" -C /opt; \
    mv "/opt/keycloak-${KEYCLOAK_VERSION}" /opt/keycloak; \
    rm -f "${tarball}"; \
    /opt/keycloak/bin/kc.sh build --db=postgres --health-enabled=true --http-relative-path="${KEYCLOAK_PATH}"; \
    install -d -o keycloak -g keycloak /opt/keycloak/data; \
    ln -s /var/lib/agenticwf/keycloak/import /opt/keycloak/data/import; \
    echo "${KEYCLOAK_VERSION}" > /opt/keycloak/.agenticwf-version

ENV LOGTO_VERSION=${LOGTO_VERSION} \
    KEYCLOAK_VERSION=${KEYCLOAK_VERSION} \
    KEYCLOAK_PATH=${KEYCLOAK_PATH}
# Server mode: run with `--network host` (services on 127.0.0.1; Logto mails through the host's MTA
# on :25). Local mode: publish the agent and KB ports, e.g. -p 127.0.0.1:8765:8000 -p 127.0.0.1:8766:8020.
# 3001 Logto OIDC, 3002 Logto admin, 8080 Keycloak (9000 its health), 8010 authsvc, 8000 agent, 8020 KB
EXPOSE 3001 3002 8080 8010 8000 8020
