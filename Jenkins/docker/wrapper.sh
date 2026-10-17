#!/bin/bash
# Jenkins Space entrypoint.
#
# Replaces the original flow where the Space image downloaded Jenkins/startup.sh
# from GitHub at boot and that script then re-downloaded Java 21, the Jenkins
# war, cloudflared and npm packages. All of those are baked into this image, so
# the boot path is now: restore state from the B-storage bucket, start PM2,
# serve the control panel on :7860, and let PM2 supervise Jenkins on :8080.
set -u
umask 000

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8
export NODE_ENV=production

export JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_local}"
export JAVA_HOME="${JAVA_HOME:-/opt/java/current}"
export PM2_HOME="${PM2_HOME:-/var/jenkins_local/.pm2}"
export JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
export JENKINS_LISTEN="${JENKINS_LISTEN:-127.0.0.1}"
export PANEL_PORT="${PANEL_PORT:-7860}"
export PATH="/app/node_modules/.bin:$JAVA_HOME/bin:/opt/tunnel:/usr/local/bin:$PATH"

# UTF-8 must reach the JVM or non-ASCII Jenkins job names degrade to U+FFFD.
case " ${JAVA_OPTS:-} " in
  *"file.encoding"*) ;;
  *) export JAVA_OPTS="${JAVA_OPTS:--Duser.home=/var/jenkins_local -Djava.io.tmpdir=/var/jenkins_local/tmp -Djenkins.install.runSetupWizard=false} -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8" ;;
esac

mkdir -p /data/jenkins_backup /var/jenkins_local/tmp /app /tmp /opt/core_app "$PM2_HOME" 2>/dev/null || true
chmod 777 /var/jenkins_local /var/jenkins_local/tmp /tmp /app 2>/dev/null || true
cd /app

# ---------------- 1. Restore from the bucket (paced, to protect the mount) ----
# The bucket mount throttles under burst I/O, so children of the two
# file-count-heavy directories are copied one at a time with a short pause.
if [ -d /data/jenkins_backup ] && [ -n "$(ls -A /data/jenkins_backup 2>/dev/null)" ]; then
  echo "[Sync] Restoring from /data/jenkins_backup ..."
  for item in /data/jenkins_backup/*; do
    [ ! -e "$item" ] && continue
    name=$(basename "$item")
    echo "[Sync] Restoring: $name"
    if [ "$name" = "jobs" ] || [ "$name" = "plugins" ]; then
      mkdir -p "/var/jenkins_local/$name"
      for sub in "$item"/*; do
        [ ! -e "$sub" ] && continue
        cp -a "$sub" "/var/jenkins_local/$name/" || true
        sleep 0.5
      done
    else
      cp -a "$item" /var/jenkins_local/ || true
      sleep 1
    fi
  done
  cp -a /data/jenkins_backup/.[!.]* /var/jenkins_local/ 2>/dev/null || true
  echo "[Sync] Restore complete."
else
  echo "[Sync] No backup found, starting fresh."
fi

# ---------------- 2. Background incremental backup ---------------------------
(
  sleep 7200
  while true; do
    echo "[Sync] Incremental backup -> /data/jenkins_backup"
    rsync -a --delete /var/jenkins_local/ /data/jenkins_backup/ >/dev/null 2>&1 || true
    sleep 86400
  done
) &

# ---------------- 3. PM2: Jenkins + optional Cloudflare tunnel ---------------
PM2=/app/node_modules/.bin/pm2
echo "[Info] PM2 bring-up..."
"$PM2" delete all >/dev/null 2>&1 || true

if [ -x "$JAVA_HOME/bin/java" ] && [ -s /opt/jenkins/jenkins.war ]; then
  echo "[Info] Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
  echo "[Info] Jenkins war: $(cat /opt/jenkins/version 2>/dev/null || echo unknown)"
  "$PM2" start /app/run-jenkins.sh \
    --name jenkins \
    --interpreter bash \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/jenkins.log \
    --time
else
  echo "[FATAL] Jenkins runtime missing (java=$JAVA_HOME/bin/java war=/opt/jenkins/jenkins.war)"
fi

# Accept either secret name so existing deployments keep working.
CF_TOKEN_VAL="${CLOUDFLARE_TUNNEL_TOKEN:-${SYS_AUTH_KEY:-${CF_TOKEN:-}}}"
if [ -n "$CF_TOKEN_VAL" ] && [ -x /opt/tunnel/cloudflared ]; then
  "$PM2" start /opt/tunnel/cloudflared \
    --name tunnel \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/tunnel.log \
    --time \
    -- tunnel --no-autoupdate run --token "$CF_TOKEN_VAL"
else
  echo "[Info] Tunnel skipped (no token or cloudflared missing)."
fi

"$PM2" save >/dev/null 2>&1 || true
"$PM2" list || true

echo "[Info] Panel :${PANEL_PORT}  Jenkins 127.0.0.1:${JENKINS_HTTP_PORT}"

# The panel is PID 1's foreground process; PM2 keeps Jenkins and the tunnel up.
exec node /app/bootstrapper.js
