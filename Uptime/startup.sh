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
# 1. 动态生成 Web Terminal 控制台 (修复了反引号语法冲突)
# ==========================================
cat << 'EOF' > /app/terminal-server.js
const http = require('http');
const { spawn } = require('child_process');
const { Server } = require('socket.io');

const HTML = `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nexus Terminal</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&display=swap" rel="stylesheet">
    <script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
    <style>
        body { background-color: #050505; color: #a1a1aa; font-family: 'Fira Code', monospace; }
        .crt::before {
            content: " "; display: block; position: absolute; top: 0; left: 0; bottom: 0; right: 0;
            background: linear-gradient(rgba(18, 16, 16, 0) 50%, rgba(0, 0, 0, 0.25) 50%), linear-gradient(90deg, rgba(255, 0, 0, 0.06), rgba(0, 255, 0, 0.02), rgba(0, 0, 255, 0.06));
            z-index: 2; background-size: 100% 2px, 3px 100%; pointer-events: none;
        }
        #output { scroll-behavior: smooth; overflow-x: hidden;}
        #output::-webkit-scrollbar { width: 6px; }
        #output::-webkit-scrollbar-thumb { background: #3f3f46; border-radius: 3px; }
        .prompt-glow { text-shadow: 0 0 10px rgba(16, 185, 129, 0.5); }
    </style>
</head>
<body class="h-screen w-screen overflow-hidden crt flex items-center justify-center p-4 sm:p-8">
    <div class="w-full h-full max-w-5xl bg-[#0a0a0a] border border-zinc-800 rounded-xl shadow-2xl flex flex-col relative z-10 overflow-hidden">
        <div class="h-10 border-b border-zinc-800 bg-[#0f0f0f] flex items-center px-4 justify-between select-none">
            <div class="flex space-x-2">
                <div class="w-3 h-3 rounded-full bg-red-500/80"></div>
                <div class="w-3 h-3 rounded-full bg-yellow-500/80"></div>
                <div class="w-3 h-3 rounded-full bg-green-500/80"></div>
            </div>
            <div class="text-xs text-zinc-500 tracking-widest font-medium">NEXUS_CORE // TERMINAL</div>
            <div class="flex items-center space-x-2">
                <span class="relative flex h-2 w-2"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span></span>
            </div>
        </div>

        <div id="output" class="flex-1 p-5 overflow-y-auto text-sm md:text-base whitespace-pre-wrap leading-relaxed">
            <div class="text-emerald-400 text-xl md:text-2xl font-bold mb-4 tracking-[0.2em]">
                N E X U S // T E R M I N A L
            </div>
            <div class="text-zinc-400 mb-6">Welcome to Nexus Container Terminal.<br>Type <span class="text-sky-400">'help'</span> for available commands.<br><br><span class="text-yellow-400">⚠️ System Note: Core services are compiling in the background. Open a new tab or type 'pm2 logs' to view their startup progress.</span></div>
        </div>

        <div class="px-5 py-4 bg-[#0a0a0a] border-t border-zinc-800 flex items-center">
            <span class="text-emerald-500 font-bold mr-3 prompt-glow">admin@nexus:~$</span>
            <input type="text" id="cmdInput" autocomplete="off" spellcheck="false" class="flex-1 bg-transparent border-none outline-none text-zinc-300 font-inherit" autofocus>
        </div>
    </div>

    <script>
        const socket = io();
        const output = document.getElementById('output');
        const input = document.getElementById('cmdInput');
        
        document.addEventListener('click', () => input.focus());

        function appendText(text, color = 'text-zinc-300') {
            const span = document.createElement('span');
            span.className = color;
            span.innerHTML = text.replace(/\\n/g, '<br>');
            output.appendChild(span);
            output.scrollTop = output.scrollHeight;
        }

        socket.on('output', (data) => appendText(data, 'text-zinc-300'));
        socket.on('error', (data) => appendText(data, 'text-red-400'));
        socket.on('system', (data) => appendText(data + '\\n', 'text-sky-400 font-medium'));
        
        input.addEventListener('keypress', function (e) {
            if (e.key === 'Enter') {
                const val = this.value.trim();
                this.value = '';
                if (!val) return;
                
                // 【核心修复】：完全去掉了反引号，改用单引号 + 字符串拼接
                appendText('\\n<span class="text-emerald-500 font-bold">admin@nexus:~$</span> ' + val + '\\n');
                
                if (val === 'clear') { output.innerHTML = ''; return; }
                if (val === 'help') {
                    const helpText = '\\nAvailable Commands:\\n' +
                        '  <span class="text-sky-400">update kuma</span>   - Fetch and hot-reload backend engine\\n' +
                        '  <span class="text-sky-400">update mieru</span>  - Fetch and rebuild frontend dashboard\\n' +
                        '  <span class="text-sky-400">pm2 status</span>    - Show all background processes\\n' +
                        '  <span class="text-sky-400">pm2 logs</span>      - Show logs for all services\\n' +
                        '  <span class="text-sky-400">clear</span>         - Clear terminal screen\\n' +
                        '  * Standard bash commands (ls, pwd, etc.) are also supported in /app\\n\\n';
                    appendText(helpText);
                    return;
                }
                socket.emit('command', val);
            }
        });
    </script>
</body>
</html>
`;

const server = http.createServer((req, res) => {
    if (req.url === '/') {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(HTML);
    } else {
        res.writeHead(404);
        res.end();
    }
});

const io = new Server(server, { cors: { origin: "*" } });

io.on('connection', (socket) => {
    socket.on('command', (cmd) => {
        let finalCmd = cmd;
        if (cmd === 'update kuma') {
            finalCmd = 'cd /app/kuma && echo "Fetching latest code..." && git pull && echo "Installing dependencies..." && npm ci --production && echo "Restarting PM2 process..." && pm2 restart kuma';
        } else if (cmd === 'update mieru') {
            finalCmd = 'cd /app/mieru && echo "Fetching latest code..." && git pull && echo "Installing packages..." && bun install && echo "Rebuilding Next.js (This may take a minute)..." && bun run build && echo "Restarting PM2 process..." && pm2 restart mieru';
        }

        const proc = spawn('bash', ['-c', finalCmd], { cwd: '/app' });
        proc.stdout.on('data', (data) => socket.emit('output', data.toString()));
        proc.stderr.on('data', (data) => socket.emit('output', `<span class="text-yellow-400/80">${data.toString()}</span>`));
        proc.on('close', (code) => {
            if(code === 0) socket.emit('system', `[Process completed successfully]`);
            else socket.emit('error', `[Process exited with code ${code}]\\n`);
        });
    });
});

server.listen(7860, '0.0.0.0', () => console.log('[Info] Terminal online on 7860'));
EOF

# ==========================================
# 2. 耗时操作全部扔进后台执行 (&) 坚决不阻塞前台
# ==========================================
(
    echo "[Info] Starting background initialization..."
    
    # --- 启动 Kuma ---
    if [ ! -d "/app/kuma" ]; then
        git clone --depth=1 https://github.com/louislam/uptime-kuma.git /app/kuma
    fi
    cd /app/kuma
    if [ ! -d "node_modules" ]; then
        npm ci --production
        npm run download-dist
    fi
    PORT=3001 pm2 start server/server.js --name "kuma" -- --data-dir="$DATA_DIR"

    # --- 编译启动 Mieru ---
    cd /app
    if [ ! -d "/app/mieru" ]; then
        git clone --depth=1 https://github.com/Alice39s/kuma-mieru.git /app/mieru
    fi
    cd /app/mieru
    if [ -n "$KUMA_API_URL" ]; then
        export UPTIME_KUMA_URLS="$KUMA_API_URL"
    fi
    if [ ! -d "node_modules" ]; then
        bun install
    fi
    if [ ! -d ".next" ]; then
        bun run build
    fi
    PORT=3000 HOSTNAME=127.0.0.1 pm2 start "bun run start" --name "mieru"

    # --- 启动隧道 ---
    if [ ! -f "/tmp/network_daemon" ]; then
        curl -sL 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64' -o /tmp/network_daemon
        chmod +x /tmp/network_daemon
    fi
    if [ -n "$CF_TOKEN" ]; then
        pm2 start /tmp/network_daemon --name "tunnel" -- tunnel --no-autoupdate run --token "$CF_TOKEN"
    fi
    
    echo "[Info] Background initialization complete."
) >/tmp/startup.log 2>&1 &

# ==========================================
# 3. 立即启动 Terminal 响应 7860 端口
# ==========================================
exec node /app/terminal-server.js
