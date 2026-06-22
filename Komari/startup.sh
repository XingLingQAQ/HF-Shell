#!/bin/sh

if [ ! -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "[startup] Booting core sys-daemon..."
    if [ ! -f "/tmp/sysd" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/sysd
        else
            wget -qO /tmp/sysd https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        fi
        chmod +x /tmp/sysd
    fi
    
   
    /tmp/sysd tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN} > /tmp/sysd.log 2>&1 &
else
    echo "[startup] Warn: CLOUDFLARE_TUNNEL_TOKEN not found, skipping daemon."
fi

echo "[startup] Starting Komari Monitor Server..."


exec /app/komari

