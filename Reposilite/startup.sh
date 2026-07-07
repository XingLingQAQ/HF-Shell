#!/bin/bash


mkdir -p /data/tmp
chmod 777 /data/tmp


if [ ! -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    echo "[Tunnel] Booting core sys-daemon..."
    if [ ! -f "/tmp/sysd" ]; then
        curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/sysd
        chmod +x /tmp/sysd
    fi
    /tmp/sysd tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN} > /tmp/sysd.log 2>&1 &
else
    echo "[Tunnel] Warn: CLOUDFLARE_TUNNEL_TOKEN not found."
fi

echo "[Reposilite] Starting Maven Repository Server on port 7860..."

# 将控制权交给 Reposilite 核心，监听 7860 应对探针
# --token 参数会在第一次启动时自动为你生成一个具备最高权限的管理员账号 (格式为 用户名:密码)
# 部署完成后，你可以登录网页后台把密码修改得更复杂些
exec java -Djava.io.tmpdir=/data/tmp -jar /app/reposilite.jar \
    --port=7860 \
    --working-directory=/data \
    --token=XingLingQAQ:admin123
