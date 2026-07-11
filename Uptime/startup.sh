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
PORT=3001 node server/server.js --data-dir="$DATA_DIR" >/dev/null 2>&1 &
sleep 5

# ==========================================
# 2. 编译并启动 kuma-mieru 面板 (隐藏在 3000 端口)
# ==========================================
cd /app
if [ ! -d "/app/mieru" ]; then
    git clone --depth=1 https://github.com/Alice39s/kuma-mieru.git /app/mieru
fi
cd /app/mieru

# 面板编译需要拉取 API，此时因为在同一域名下，填你自己的域名即可
if [ -n "$KUMA_API_URL" ]; then
    echo "UPTIME_KUMA_URLS=$KUMA_API_URL" > .env
fi

if [ ! -d "node_modules" ]; then
    npm install
fi
if [ ! -d ".next" ]; then
    npm run build
fi
PORT=3000 npm run start >/dev/null 2>&1 &

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
# 4. 生成 Nginx 魔改路由，并作为主进程挂载 (监听 7860 扛检测)
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
        
        # 【规则1】极简首页，留给 Mieru 面板
        location = / {
            proxy_pass http://127.0.0.1:3000;
        }
        location /_next/ {
            proxy_pass http://127.0.0.1:3000;
        }

        # 【规则2】强制 /admin 作为后台入口，剥离路径传给 Kuma
        location ^~ /admin {
            rewrite ^/admin(.*)$ /\$1 break;
            proxy_pass http://127.0.0.1:3001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }
        
        # 【规则3】底层放行，精准拦截 Kuma 必备资源和跳转目录，防止白屏
        location ~ ^/(assets|api|socket\.io|upload|icon\.svg|manifest\.json|apple-touch-icon\.png|dashboard|setup|login|add|edit|settings|status) {
            proxy_pass http://127.0.0.1:3001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }
    }
}
EOF

# 让 Nginx 在前台运行，彻底隐藏后方的服务
exec nginx -c /tmp/nginx.conf -g "daemon off;"
