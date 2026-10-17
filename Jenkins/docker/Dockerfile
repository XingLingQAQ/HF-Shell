# Jenkins Space image for Hugging Face Docker Spaces.
#
# Everything the runtime needs -- Temurin JDK 21, the Jenkins LTS war,
# cloudflared, Node 20, PM2/socket.io and the panel application -- is baked in
# here so the Space only has to pull layers instead of downloading ~400 MB on
# every cold start. Startup logic lives in the sibling `wrapper.sh`.
#
# Build context: Jenkins/ (see .github/workflows/build-jenkins-image.yml)

FROM debian:bookworm-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8

# netcat-openbsd backs the wrapper's health fallback and was missing from the
# original Space image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg2 unzip xz-utils \
        rsync inotify-tools procps fontconfig netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Writable skeleton first, while it is still empty: a recursive chmod after the
# JDK and war land would copy ~400 MB into a new layer.
RUN mkdir -p /data/jenkins_backup /var/jenkins_local/tmp /app /tmp /opt/core_app \
    && chmod -R 777 /data /var/jenkins_local /app /tmp \
    && chmod 777 /opt /opt/core_app

# ---------------------------------------------------------------- Node 20 ---
ARG NODE_VER=20.18.1
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
    && node -v && npm -v

# ------------------------------------------------------------ Temurin 25 ---
# The panel expects the JDK at /opt/java/current and reads /opt/java/version to
# decide whether "update java" is needed, so both are materialised here.
# 25 is a Jenkins-supported LTS (core's SUPPORTED_JAVA_VERSIONS lists 21 and 25);
# 21 stays listed there only until its own EOL, so this tracks the newer branch.
RUN mkdir -p /opt/java/staging \
    && curl -fL "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" \
         -o /tmp/jdk25.tar.gz \
    && test "$(wc -c < /tmp/jdk25.tar.gz)" -gt 50000000 \
    && tar -xzf /tmp/jdk25.tar.gz -C /opt/java/staging \
    && INNER="$(find /opt/java/staging -maxdepth 1 -type d -name 'jdk-*' | head -1)" \
    && test -x "$INNER/bin/java" \
    && mv "$INNER" /opt/java/ \
    && rm -rf /opt/java/staging /tmp/jdk25.tar.gz \
    && ln -sfn "/opt/java/$(basename "$INNER")" /opt/java/current \
    && /opt/java/current/bin/java -version 2>&1 | head -1

# Record the marker the panel compares against on "update java". It must be the
# Adoptium `openjdk_version` string, because that is what the panel fetches at
# runtime -- deriving it from `java -version` would produce a different shape and
# make the panel re-download the JDK on every click. The API now returns
# pretty-printed JSON, so the match tolerates whitespace around the colon
# (the original compact-JSON `tr ',' | sed` pattern silently returned nothing).
RUN VER="$(curl -fsSL 'https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=%5B25%2C26%29&os=linux&arch=x64&image_type=jdk&jvm_impl=hotspot&page_size=1&sort_order=DESC' \
             | grep -oE '"openjdk_version"[[:space:]]*:[[:space:]]*"[^"]*"' \
             | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')" \
    && if [ -z "$VER" ]; then \
         echo "[build] WARN: Adoptium API unavailable, falling back to java -version"; \
         VER="$(/opt/java/current/bin/java -version 2>&1 | head -1)"; \
       fi \
    && test -n "$VER" \
    && printf '%s\n' "$VER" > /opt/java/version \
    && chmod 666 /opt/java/version \
    && echo "[build] java version marker: $(cat /opt/java/version)"

# ------------------------------------------------------- Jenkins LTS war ---
# Leave JENKINS_VERSION empty to track the newest stable core; set it to pin a
# specific LTS release (the workflow exposes this as a dispatch input).
ARG JENKINS_VERSION=""
RUN LATEST="${JENKINS_VERSION:-$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt | tr -d '\r' | head -1)}" \
    && test -n "$LATEST" \
    && mkdir -p /opt/jenkins \
    && curl -fL "https://get.jenkins.io/war-stable/${LATEST}/jenkins.war" -o /opt/jenkins/jenkins.war \
    && test "$(wc -c < /opt/jenkins/jenkins.war)" -gt 1000000 \
    && printf '%s\n' "$LATEST" > /opt/jenkins/version \
    && chmod 666 /opt/jenkins/version \
    && echo "[build] jenkins war: $LATEST"

# ----------------------------------------------------------- cloudflared ---
# The version marker is read from the binary itself. Asking api.github.com for
# the latest release tag is unauthenticated and rate-limited, which failed the
# build with exit 1 as soon as the runner's shared quota was used up.
RUN mkdir -p /opt/tunnel \
    && curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
         -o /opt/tunnel/cloudflared \
    && chmod +x /opt/tunnel/cloudflared \
    && /opt/tunnel/cloudflared --version 2>&1 | awk '{print $3}' | head -1 > /opt/tunnel/version \
    && test -s /opt/tunnel/version \
    && chmod 666 /opt/tunnel/version \
    && echo "[build] cloudflared: $(cat /opt/tunnel/version)"

# The runtime's "update ..." actions replace files inside these directories as
# UID 1000, so the directories themselves (not their contents) must be writable.
RUN chmod 777 /opt/java /opt/jenkins /opt/tunnel

# ------------------------------------------------------------- PM2 + app ---
WORKDIR /app
COPY app/package.json /app/package.json
RUN npm install --omit=dev --no-audit --no-fund \
    && ./node_modules/.bin/pm2 --version

# Panel sources and the Jenkins launcher, previously base64 blobs embedded in
# startup.sh. Kept as real files so they stay reviewable and diffable.
COPY app/terminal-ui.html /app/terminal-ui.html
COPY app/logic.js         /app/logic.js
COPY app/bootstrapper.js  /app/bootstrapper.js
COPY app/run-jenkins.sh   /app/run-jenkins.sh
COPY docker/wrapper.sh    /wrapper.sh

# The panel's live editors overwrite terminal-ui.html and logic.js in place, so
# those two need to stay writable by UID 1000.
RUN chmod +x /wrapper.sh /app/run-jenkins.sh \
    && chmod 666 /app/terminal-ui.html /app/logic.js \
    && chmod 777 /app

ENV JENKINS_HOME=/var/jenkins_local \
    JAVA_HOME=/opt/java/current \
    PM2_HOME=/var/jenkins_local/.pm2 \
    JENKINS_HTTP_PORT=8080 \
    JENKINS_LISTEN=127.0.0.1 \
    PANEL_PORT=7860 \
    CORE_HTTP_PORT=7860 \
    CORE_LISTEN=0.0.0.0 \
    PATH="/app/node_modules/.bin:/opt/java/current/bin:/opt/tunnel:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    JAVA_OPTS="-Duser.home=/var/jenkins_local -Djava.io.tmpdir=/var/jenkins_local/tmp -Djenkins.install.runSetupWizard=false -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8"

EXPOSE 7860

ENTRYPOINT ["/wrapper.sh"]
