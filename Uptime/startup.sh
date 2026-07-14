#!/bin/bash

export NODE_ENV=production
export PM2_HOME="/app/.pm2"

# 确保持久化存储存在
DATA_DIR="/data"
if [ ! -w "$DATA_DIR" ]; then
    DATA_DIR="/app/data"
    mkdir -p $DATA_DIR
fi

cd /app

# ==========================================
# 0. 局部安装并初始化 PM2
# ==========================================
if [ ! -d "/app/node_modules/pm2" ]; then
    npm install pm2
fi
PM2="/app/node_modules/.bin/pm2"

# ==========================================
# 1. 后台启动 Uptime Kuma (端口 3001)
# ==========================================
if [ ! -d "/app/kuma" ]; then
    git clone --depth=1 https://github.com/louislam/uptime-kuma.git /app/kuma
fi
cd /app/kuma
if [ ! -d "node_modules" ]; then
    npm ci --production
    npm run download-dist
fi
PORT=3001 $PM2 start server/server.js --name "kuma" -- --data-dir="$DATA_DIR"

# ==========================================
# 2. 编译并后台启动 kuma-mieru (端口 3000)
# ==========================================
cd /app
if [ ! -d "/app/mieru" ]; then
    git clone --depth=1 https://github.com/Alice39s/kuma-mieru.git /app/mieru
fi
cd /app/mieru
# 注意：这里请确保你的 HF Secrets 里配置了 KUMA_API_URL 
# 因为现在是双域名，你应该配置为你的 Kuma 后台公网域名，例如：https://kuma.你的域名.com/status/default
if [ -n "$KUMA_API_URL" ]; then
    export UPTIME_KUMA_URLS="$KUMA_API_URL"
fi
if [ ! -d "node_modules" ]; then
    bun install
fi
if [ ! -d ".next" ]; then
    bun run build
fi
PORT=3000 HOSTNAME=127.0.0.1 $PM2 start "bun run start" --name "mieru"

# ==========================================
# 3. 启动 Cloudflare Tunnel
# ==========================================
if [ ! -f "/tmp/network_daemon" ]; then
    curl -sL 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64' -o /tmp/network_daemon
    chmod +x /tmp/network_daemon
fi
if [ -n "$CF_TOKEN" ]; then
    $PM2 start /tmp/network_daemon --name "tunnel" -- tunnel --no-autoupdate run --token "$CF_TOKEN"
fi

# ==========================================
# 4. 动态生成并启动 "热更新控制台" (监听 7860)
# ==========================================
cat << 'EOF' > /app/control-panel.js
const http = require('http');
const { spawn, execSync } = require('child_process');

const HTML = `
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Control Center</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        body { font-family: 'Inter', sans-serif; background-color: #0f172a; color: #f8fafc; }
        .terminal::-webkit-scrollbar { width: 8px; }
        .terminal::-webkit-scrollbar-thumb { background: #334155; border-radius: 4px; }
    </style>
</head>
<body class="min-h-screen flex items-center justify-center p-4">
    <div class="max-w-3xl w-full bg-slate-800 rounded-2xl shadow-2xl p-8 border border-slate-700">
        <div class="flex items-center justify-between mb-8">
            <h1 class="text-2xl font-bold text-white tracking-tight">System Control Center</h1>
            <div class="flex items-center space-x-2">
                <span class="relative flex h-3 w-3"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-3 w-3 bg-emerald-500"></span></span>
                <span class="text-emerald-400 text-sm font-medium">Container Active</span>
            </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
            <!-- App 1 -->
            <div class="bg-slate-900 rounded-xl p-6 border border-slate-700 transition hover:border-blue-500">
                <div class="flex justify-between items-start mb-4">
                    <div><h2 class="text-lg font-semibold text-white">Uptime Kuma</h2><p class="text-xs text-slate-400 mt-1">Core Backend Engine</p></div>
                    <span class="px-2.5 py-1 rounded-full bg-blue-500/10 text-blue-400 text-xs font-semibold">Port 3001</span>
                </div>
                <button onclick="triggerUpdate('kuma')" class="w-full mt-4 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium py-2.5 rounded-lg transition-colors focus:ring-4 focus:ring-blue-500/20">Check & Hot Update</button>
            </div>
            
            <!-- App 2 -->
            <div class="bg-slate-900 rounded-xl p-6 border border-slate-700 transition hover:border-purple-500">
                <div class="flex justify-between items-start mb-4">
                    <div><h2 class="text-lg font-semibold text-white">Kuma Mieru</h2><p class="text-xs text-slate-400 mt-1">Frontend Dashboard</p></div>
                    <span class="px-2.5 py-1 rounded-full bg-purple-500/10 text-purple-400 text-xs font-semibold">Port 3000</span>
                </div>
                <button onclick="triggerUpdate('mieru')" class="w-full mt-4 bg-purple-600 hover:bg-purple-500 text-white text-sm font-medium py-2.5 rounded-lg transition-colors focus:ring-4 focus:ring-purple-500/20">Check & Hot Update</button>
            </div>
        </div>

        <div class="bg-black/50 rounded-xl border border-slate-700 overflow-hidden">
            <div class="bg-slate-800/80 px-4 py-2 border-b border-slate-700 flex items-center space-x-2">
                <div class="flex space-x-1.5"><div class="w-3 h-3 rounded-full bg-red-500/80"></div><div class="w-3 h-3 rounded-full bg-yellow-500/80"></div><div class="w-3 h-3 rounded-full bg-green-500/80"></div></div>
                <span class="text-xs text-slate-400 ml-2 font-mono">Terminal Output</span>
            </div>
            <div id="terminal" class="terminal p-4 h-64 overflow-y-auto font-mono text-sm text-slate-300 leading-relaxed whitespace-pre-wrap">Awaiting commands...</div>
        </div>
    </div>

    <script>
        const terminal = document.getElementById('terminal');
        function triggerUpdate(app) {
            terminal.innerHTML = `<span class="text-blue-400">➜</span> Initializing hot update sequence for <span class="text-white font-bold">${app}</span>...\n`;
            
            const source = new EventSource(`/api/update/${app}`);
            source.onmessage = function(event) {
                const data = JSON.parse(event.data);
                if(data.text === "===UPDATE_COMPLETE===") {
                    terminal.innerHTML += `\n<span class="text-emerald-400 font-bold">✔ Hot Update Successful! The service has been gracefully restarted.</span>\n`;
                    terminal.scrollTop = terminal.scrollHeight;
                    source.close();
                    return;
                }
                terminal.innerHTML += data.text;
                terminal.scrollTop = terminal.scrollHeight;
            };
            source.onerror = function() {
                terminal.innerHTML += `\n<span class="text-red-400 font-bold">✖ Stream disconnected or finished.</span>\n`;
                source.close();
            };
        }
    </script>
</body>
</html>
`;

const server = http.createServer((req, res) => {
    if (req.url === '/') {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(HTML);
    } 
    else if (req.url.startsWith('/api/update/')) {
        const appName = req.url.split('/').pop();
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive'
        });

        let cmd = '';
        if (appName === 'kuma') {
            cmd = 'cd /app/kuma && echo "Fetching latest code..." && git pull && echo "Installing dependencies..." && npm ci --production && echo "Restarting PM2 process..." && /app/node_modules/.bin/pm2 restart kuma';
        } else if (appName === 'mieru') {
            cmd = 'cd /app/mieru && echo "Fetching latest code..." && git pull && echo "Installing packages..." && bun install && echo "Rebuilding Next.js (This may take a minute)..." && bun run build && echo "Restarting PM2 process..." && /app/node_modules/.bin/pm2 restart mieru';
        } else {
            res.end(); return;
        }

        const child = spawn('bash', ['-c', cmd]);

        child.stdout.on('data', data => {
            res.write(`data: ${JSON.stringify({ text: data.toString() })}\n\n`);
        });

        child.stderr.on('data', data => {
            res.write(`data: ${JSON.stringify({ text: `<span class="text-yellow-400">${data.toString()}</span>` })}\n\n`);
        });

        child.on('close', code => {
            res.write(`data: ${JSON.stringify({ text: '===UPDATE_COMPLETE===' })}\n\n`);
            res.end();
        });
    } else {
        res.writeHead(404);
        res.end();
    }
});

server.listen(7860, () => console.log('Control Center running on 7860'));
EOF

# 将原生的 Node.js 控制台顶在前台，扛住 HF 的健康检测，并守护容器不灭
exec node /app/control-panel.js
