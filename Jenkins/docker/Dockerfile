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

# netcat-openbsd is required by the wrapper's health fallback and was missing
# from the original Space image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg2 unzip xz-utils \
        rsync inotify-tools procps fontconfig netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------- Node 20 ---
ARG NODE_VER=20.18.1
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
    && node -v && npm -v

# ------------------------------------------------------------ Temurin 21 ---
# startup.sh expects the JDK at /opt/java/current and reads /opt/java/version
# to decide whether an update is needed, so both are materialised here.
RUN mkdir -p /opt/java/staging \
    && curl -fL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" \
         -o /tmp/jdk21.tar.gz \
    && test "$(wc -c < /tmp/jdk21.tar.gz)" -gt 50000000 \
    && tar -xzf /tmp/jdk21.tar.gz -C /opt/java/staging \
    && INNER="$(find /opt/java/staging -maxdepth 1 -type d -name 'jdk-*' | head -1)" \
    && test -x "$INNER/bin/java" \
    && mv "$INNER" /opt/java/ \
    && rm -rf /opt/java/staging /tmp/jdk21.tar.gz \
    && ln -sfn "/opt/java/$(basename "$INNER")" /opt/java/current \
    && /opt/java/current/bin/java -version 2>&1 | head -1

# Record the Adoptium release string the panel compares against on "update java".
RUN curl -fsSL "https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=%5B21%2C22%29&os=linux&arch=x64&image_type=jdk&jvm_impl=hotspot&page_size=1&sort_order=DESC" \
      | tr ',' '\n' | sed -n 's/.*"openjdk_version":"\([^"]*\)".*/\1/p' | head -1 > /opt/java/version \
    && test -s /opt/java/version \
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
    && echo "$LATEST" > /opt/jenkins/version \
    && echo "[build] jenkins war: $LATEST"

# ----------------------------------------------------------- cloudflared ---
RUN mkdir -p /opt/tunnel \
    && curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
         -o /opt/tunnel/cloudflared \
    && chmod +x /opt/tunnel/cloudflared \
    && curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
         | grep '"tag_name":' | head -1 | cut -d'"' -f4 > /opt/tunnel/version \
    && echo "[build] cloudflared: $(cat /opt/tunnel/version)"

# ------------------------------------------------------------- PM2 + app ---
WORKDIR /app
COPY app/package.json /app/package.json
RUN npm install --omit=dev --no-audit --no-fund \
    && ./node_modules/.bin/pm2 --version

# Panel sources and the Jenkins launcher, all previously base64-embedded in
# startup.sh. Kept as real files so they stay reviewable and diffable.
COPY app/terminal-ui.html /app/terminal-ui.html
COPY app/logic.js         /app/logic.js
COPY app/bootstrapper.js  /app/bootstrapper.js
COPY app/run-jenkins.sh   /app/run-jenkins.sh

COPY docker/wrapper.sh /wrapper.sh

# Hugging Face runs Docker Spaces as UID 1000, so writable paths stay 777 --
# same approach as the original Space image.
RUN chmod +x /wrapper.sh /app/run-jenkins.sh \
    && mkdir -p /data/jenkins_backup /var/jenkins_local/tmp /opt/core_app \
    && chmod -R 777 /data /var/jenkins_local /app /opt /tmp

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
