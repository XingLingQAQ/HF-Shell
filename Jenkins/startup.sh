#!/bin/bash

if [ ! -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "[startup] Booting core sys-daemon..."
    if [ ! -f "/tmp/sysd" ]; then
        curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/sysd
        chmod +x /tmp/sysd
    fi
    
    /tmp/sysd tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN} > /tmp/sysd.log 2>&1 &
else
    echo "[startup] Warn: CLOUDFLARE_TUNNEL_TOKEN not found, skipping tunnel."
fi

echo "[startup] Starting Jenkins CI Server on port 7860..."

exec java -jar /usr/share/jenkins/jenkins.war $JENKINS_OPTS
