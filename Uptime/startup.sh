#!/bin/bash

export NODE_ENV=production

# 确保持久化存储存在
DATA_DIR="/data"
if [ ! -w "$DATA_DIR" ]; then
    DATA_DIR="/app/data"
    mkdir -p $DATA_DIR
fi

cd /app

# ==========================================
# 1. 启动 Uptime Kuma (隐藏在 3001 端口)
# ==========================================
if [ ! -d "/app/kuma" ]; then
    git clone --depth=1 https://github.com/louislam/uptime-kuma.git /app/kuma
fi
cd /app/kuma
if [ ! -d "node_modules" ]; then
    npm ci --production
    npm run download-dist
fi
PORT=3001 node server/server.js --data-dir="$DATA_DIR" >/tmp/kuma.log 2>&1 &
sleep 5

# ==========================================
# 2. 编译并启动 kuma-mieru 面板
# ==========================================
cd /app
if [ ! -d "/app/mieru" ]; then
    git clone --depth=1 https://github.com/Alice39s/kuma-mieru.git /app/mieru
fi
cd /app/mieru

if [ -n "$KUMA_API_URL" ]; then
    export UPTIME_KUMA_URLS="$KUMA_API_URL"
else
    export UPTIME_KUMA_URLS="http://127.0.0.1:3001/status/default"
fi

if [ ! -d "node_modules" ]; then
    bun install
fi
if [ ! -d ".next" ]; then
    bun run build
fi

# 【核心修复】：统一使用 bun，强制绑定 IPv4，并将日志输出到控制台
(
  while true; do
    echo "========= Starting Mieru Frontend ========="
    PORT=3000 HOSTNAME=127.0.0.1 bun run start
    echo "========= Mieru Frontend Crashed, restarting in 5s ========="
    sleep 5
  done
) &

# ==========================================
# 3. 静默启动 Cloudflare Tunnel
# ==========================================
if [ ! -f "/tmp/network_daemon" ]; then
    curl -sL 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64' -o /tmp/network_daemon
    chmod +x /tmp/network_daemon
fi
if [ -n "$CF_TOKEN" ]; then
    /tmp/network_daemon tunnel --no-autoupdate run --token "$CF_TOKEN" >/dev/null 2>&1 &
fi

# ==========================================
# 4. 生成 Nginx 配置，修复路由
# ==========================================
cat <<EOF > /tmp/nginx.conf
worker_processes 1;
pid /tmp/nginx.pid;
events { worker_connections 1024; }
http {
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp_path;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;
    
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 7860;
        
        # 补全 Host 头，防止 Next.js 拒绝请求
        location / {
            proxy_pass http://127.0.0.1:3000;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }

        location ^~ /admin {
            rewrite ^/admin(.*)$ /\$1 break;
            proxy_pass http://127.0.0.1:3001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
        }
        
        location ~ ^/(assets|api|socket\.io|upload|icon\.svg|manifest\.json|apple-touch-icon\.png|dashboard|setup|login|add|edit|settings|status) {
            proxy_pass http://127.0.0.1:3001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
        }
    }
}
EOF

exec nginx -c /tmp/nginx.conf -g "daemon off;"
