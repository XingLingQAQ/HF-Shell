# Gitea Space image for Hugging Face Docker Spaces.
#
# Everything the runtime needs -- the Gitea server, gitea-pages, Renovate,
# cloudflared, Node, PM2/socket.io and the panel application -- is baked in here
# so the Space only has to pull layers instead of downloading a server binary, a
# Node runtime and npm packages on every cold start. Startup logic lives in the
# sibling `wrapper.sh`.
#
# Build context: Gitea/ (see .github/workflows/build-gitea-image.yml)

FROM debian:bookworm-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8

# netcat-openbsd backs the entrypoint's health fallback and was missing from the
# original Space image even though its Dockerfile called `nc`. openssh-client
# and gpg/tar/xz support Gitea's SSH, GPG-signing and release-archive paths, and
# sqlite3 lets the panel inspect the database it runs on.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git git-lfs gnupg2 unzip xz-utils \
        rsync inotify-tools procps bash netcat-openbsd openssh-client \
        tzdata gettext sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# The `git` account Gitea refuses to run without. Gitea 1.27+ hard-fails when
# started as root, and the launcher's runtime `useradd` was a silent no-op on
# images without the tooling, so create it here where failure is loud.
RUN groupadd -g 1000 git 2>/dev/null || true \
    && useradd -m -u 1000 -g 1000 -d /home/git -s /bin/bash git \
    && git --version && git lfs version

# Writable skeleton first, while it is still mostly empty: a recursive chmod
# after the Gitea binary and Node land would copy hundreds of MB into a new
# layer. /opt/gitea and /opt/gitea-pages hold the runtime-replaceable binaries,
# so the directories (not just their contents) must stay writable.
RUN mkdir -p /data/gitea/custom/conf /app /tmp /opt/gitea /opt/gitea-pages \
        /opt/renovate /opt/tunnel /home/git \
    && chmod -R 777 /data /app /tmp \
    && chmod 777 /opt /opt/gitea /opt/gitea-pages /opt/renovate /opt/tunnel \
    && chown -R 1000:1000 /data/gitea /home/git

# ------------------------------------------------------------------- Node ---
# Node 24 LTS, not 20: current Renovate declares `engines.node ^24.11.0`, so a
# Node 20 runtime cannot install or run the version the panel's "update
# renovate" action pulls.
ARG NODE_VER=24.22.0
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
    && node -v && npm -v

# ------------------------------------------------------------------ Gitea ---
# Pinned to 1.27.3 to match the schema of the database already living in the
# bucket. Gitea records its schema state in the `version` table, and this DB
# reads 343, which Gitea's own migration ledger documents as "1.27.0 ends at
# migration ID number 342 (database version 343)" -- so the work dir has never
# been touched by a 28.x binary (migration 343's `action_run_job.max_parallel`
# column is absent from it).
#
# Baking 28.x would make the first boot apply migrations 343-357 to a live
# database on a throttled bucket mount. That upgrade is supported but one-way, so
# it stays a deliberate choice: dispatch the workflow with
# gitea_version=28.1.0 once the Space is verified and a backup is in hand.
ARG GITEA_VERSION="1.27.3"
RUN LATEST="${GITEA_VERSION}" \
    && if [ -z "$LATEST" ]; then \
         LATEST="$(curl -fsSL https://dl.gitea.com/gitea/version.json \
                    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' \
                    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
       fi \
    && test -n "$LATEST" \
    && curl -fL "https://dl.gitea.com/gitea/${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.bin \
    && test "$(wc -c < /tmp/gitea.bin)" -gt 50000000 \
    && install -m 755 /tmp/gitea.bin /opt/gitea/gitea \
    && rm -f /tmp/gitea.bin \
    && printf '%s\n' "$LATEST" > /opt/gitea/version \
    && chmod 666 /opt/gitea/version \
    && /opt/gitea/gitea --version

# ------------------------------------------------------------ gitea-pages ---
# deadnews/gitea-pages serves a repository's branch as a static site. The
# launcher treated the tarball as if the binary sat at the archive root; it
# actually ships under a versioned directory, so extract then locate it. The
# explicit `test -x` matters: the original chain ended in `|| echo`, which let
# the build succeed with no binary installed at all.
ARG GITEA_PAGES_VERSION=1.0.3
RUN VER="${GITEA_PAGES_VERSION}" \
    && curl -fL --retry 3 "https://github.com/deadnews/gitea-pages/releases/download/v${VER}/gitea-pages_${VER}_linux_amd64.tar.gz" \
         -o /tmp/gitea-pages.tgz \
    && mkdir -p /tmp/gp-extract \
    && tar -xzf /tmp/gitea-pages.tgz -C /tmp/gp-extract \
    && BIN="$(find /tmp/gp-extract -type f -name 'gitea-pages' | head -1)" \
    && test -n "$BIN" \
    && install -m 755 "$BIN" /opt/gitea-pages/gitea-pages \
    && test -x /opt/gitea-pages/gitea-pages \
    && rm -rf /tmp/gp-extract /tmp/gitea-pages.tgz \
    && printf '%s\n' "$VER" > /opt/gitea-pages/version \
    && chmod 666 /opt/gitea-pages/version \
    && echo "[build] gitea-pages $VER installed"

# --------------------------------------------------------------- Renovate ---
# Installed here rather than at boot: `npm install renovate` takes minutes and
# needs the network, which is exactly the cold-start cost this image removes.
RUN npm install --prefix /opt/renovate renovate --omit=dev --no-audit --no-fund \
    && test -x /opt/renovate/node_modules/.bin/renovate \
    && /opt/renovate/node_modules/.bin/renovate --version

# ------------------------------------------------------------ cloudflared ---
# The version marker is read from the binary itself. The original queried
# api.github.com unauthenticated, which is rate-limited and made the build (and
# the panel's "update tunnel") fail non-deterministically.
RUN curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
         -o /opt/tunnel/cloudflared \
    && chmod +x /opt/tunnel/cloudflared \
    && /opt/tunnel/cloudflared --version 2>&1 | awk '{print $3}' | head -1 > /opt/tunnel/version \
    && test -s /opt/tunnel/version \
    && chmod 666 /opt/tunnel/version \
    && echo "[build] cloudflared: $(cat /opt/tunnel/version)"

# ------------------------------------------------------------- PM2 + app ---
WORKDIR /app
COPY app/package.json /app/package.json
RUN npm install --omit=dev --no-audit --no-fund \
    && ./node_modules/.bin/pm2 --version

# Panel sources and the process launchers, previously heredoc blobs embedded in
# startup.sh. Kept as real files so they stay reviewable and diffable.
COPY app/terminal-ui.html /app/terminal-ui.html
COPY app/logic.js         /app/logic.js
COPY app/bootstrapper.js  /app/bootstrapper.js
COPY app/run-gitea.sh     /app/run-gitea.sh
COPY app/run-pages.sh     /app/run-pages.sh
COPY app/run-renovate.sh  /app/run-renovate.sh
COPY docker/wrapper.sh    /wrapper.sh

# The panel's live editors overwrite terminal-ui.html and logic.js in place, so
# those two must stay writable, and Renovate runs against /opt/renovate.
RUN chmod +x /wrapper.sh /app/run-gitea.sh /app/run-pages.sh /app/run-renovate.sh \
    && chmod 666 /app/terminal-ui.html /app/logic.js \
    && chmod 777 /app /opt/renovate

ENV GITEA_WORK_DIR=/data/gitea \
    GITEA_CUSTOM=/data/gitea/custom \
    PANEL_PORT=7860 \
    GITEA_HTTP_PORT=3000 \
    GITEA_HTTP_ADDR=127.0.0.1 \
    GITEA_PAGES_PORT=8000 \
    GITEA_PAGES_ADDR=127.0.0.1:8000 \
    GITEA_PAGES_BRANCH=gh-pages \
    GITEA_PAGES_SERVER=http://127.0.0.1:3000 \
    GITEA_DISABLE_REGISTRATION=true \
    RENOVATE_INTERVAL=3600 \
    PM2_HOME=/app/.pm2 \
    PATH="/app/node_modules/.bin:/opt/gitea:/opt/gitea-pages:/opt/renovate/node_modules/.bin:/opt/tunnel:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

EXPOSE 7860

ENTRYPOINT ["/wrapper.sh"]
