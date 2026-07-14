#!/bin/bash

export NODE_ENV=production
export PM2_HOME="/app/.pm2"

DATA_DIR="/data"
if [ ! -w "$DATA_DIR" ]; then
    DATA_DIR="/app/data"
    mkdir -p $DATA_DIR
fi

cd /app

# ==========================================
# 1. 生成热插拔的"业务大脑" (核心后端逻辑 + 纯前端代码)
# ==========================================
cat << 'EOF' > /app/logic.js
const { spawn } = require('child_process');
const fs = require('fs');

const uiFilePath = '/app/terminal-ui.html';
const logicFilePath = '/app/logic.js'; // 本文件的路径，用于热编辑后端

// ===================== [ 前端 UI 源码 ] =====================
const DEFAULT_HTML = `
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nexus Terminal</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&display=swap" rel="stylesheet">
    <script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
    <style>
        body { background-color: #050505; color: #a1a1aa; font-family: 'Fira Code', monospace; }
        .crt::before { content: " "; display: block; position: absolute; top: 0; left: 0; bottom: 0; right: 0; background: linear-gradient(rgba(18, 16, 16, 0) 50%, rgba(0, 0, 0, 0.25) 50%), linear-gradient(90deg, rgba(255, 0, 0, 0.06), rgba(0, 255, 0, 0.02), rgba(0, 0, 255, 0.06)); z-index: 2; background-size: 100% 2px, 3px 100%; pointer-events: none; }
        #output { scroll-behavior: smooth; white-space: pre; }
        #output::-webkit-scrollbar { width: 8px; height: 8px; }
        #output::-webkit-scrollbar-thumb { background: #3f3f46; border-radius: 4px; }
        .prompt-glow { text-shadow: 0 0 10px rgba(16, 185, 129, 0.5); }
        .btn-action { transition: all 0.2s; }
        .btn-action:hover { transform: translateY(-1px); background-color: #27272a; color: #fff; }
    </style>
</head>
<body class="h-screen w-screen overflow-hidden crt flex items-center justify-center p-2 sm:p-6">
    <div class="w-full h-full max-w-6xl bg-[#0a0a0a] border border-zinc-800 rounded-xl shadow-2xl flex flex-col relative z-10 overflow-hidden">
        
        <!-- 顶部栏 -->
        <div class="h-10 border-b border-zinc-800 bg-[#0f0f0f] flex items-center px-4 justify-between select-none">
            <div class="flex space-x-2">
                <div class="w-3 h-3 rounded-full bg-red-500/80"></div>
                <div class="w-3 h-3 rounded-full bg-yellow-500/80"></div>
                <div class="w-3 h-3 rounded-full bg-green-500/80"></div>
            </div>
            <div class="text-xs text-zinc-500 tracking-widest font-medium flex items-center gap-4">
                NEXUS_CORE // TERMINAL
            </div>
            <div class="flex items-center space-x-3">
                <button onclick="openEditor('html')" class="text-xs bg-emerald-900/40 text-emerald-400 px-2 py-1 rounded border border-emerald-800/50 hover:bg-emerald-800/60 z-20 cursor-pointer">UI Dev</button>
                <button onclick="openEditor('js')" class="text-xs bg-purple-900/40 text-purple-400 px-2 py-1 rounded border border-purple-800/50 hover:bg-purple-800/60 z-20 cursor-pointer">Backend Dev</button>
                <span class="relative flex h-2 w-2"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span></span>
            </div>
        </div>

        <div class="border-b border-zinc-800 bg-[#0a0a0a] p-3 flex flex-wrap gap-2 text-xs font-medium z-20">
            <button onclick="sendCommand('pm2 status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📊 进程状态</button>
            <button onclick="sendCommand('update kuma')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-blue-400">🔄 更新 Kuma</button>
            <button onclick="sendCommand('update mieru')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-purple-400">🔄 更新 面板</button>
            <button onclick="sendCommand('pm2 logs')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📋 实时日志</button>
            <button onclick="sendCommand('clear')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-500 ml-auto">🗑️ 清屏</button>
        </div>

        <div id="output" class="flex-1 p-5 overflow-auto text-sm font-mono text-zinc-300">
            <div class="text-emerald-400 text-xl font-bold mb-4 tracking-widest">N E X U S // T E R M I N A L</div>
            <div class="text-zinc-400 mb-6">Type 'help' for commands.<br><span class="text-yellow-400">⚠️ System supports Full-Stack Hot Reload.</span></div>
        </div>

        <div class="px-5 py-4 bg-[#0a0a0a] border-t border-zinc-800 flex items-center z-20">
            <span class="text-emerald-500 font-bold mr-3 prompt-glow">admin@nexus:~$</span>
            <input type="text" id="cmdInput" autocomplete="off" spellcheck="false" class="flex-1 bg-transparent border-none outline-none text-zinc-300 font-inherit" autofocus>
        </div>

        <!-- 纯干货全栈热编辑器 -->
        <div id="editorOverlay" class="hidden absolute inset-0 bg-black/95 z-50 flex flex-col p-4 sm:p-8 backdrop-blur-sm">
            <div class="flex justify-between items-center mb-4">
                <div>
                    <h2 id="editorTitle" class="text-emerald-400 text-lg font-bold tracking-widest">LIVE EDITOR</h2>
                    <p id="editorDesc" class="text-zinc-500 text-xs">Modify the source on the fly.</p>
                </div>
                <button onclick="closeEditor()" class="text-zinc-400 hover:text-white font-bold text-xl cursor-pointer">×</button>
            </div>
            <!-- 当前正在编辑的模式标记 -->
            <input type="hidden" id="editorMode">
            <textarea id="editorCode" class="flex-1 bg-zinc-950 text-sky-300 font-mono text-sm p-4 rounded-xl outline-none border border-zinc-800 focus:border-emerald-500/50 shadow-inner" spellcheck="false"></textarea>
            
            <div class="mt-6 flex flex-wrap gap-4" id="actionButtons">
                <!-- HTML 模式才显示预览按钮 -->
                <button id="btnPreview" onclick="previewCode()" class="hidden bg-blue-600/20 text-blue-400 border border-blue-600/50 hover:bg-blue-600/40 px-6 py-3 rounded-lg text-sm font-bold transition">1. 挂载到 /preview</button>
                <button onclick="deployCode()" class="bg-emerald-600/20 text-emerald-400 border border-emerald-600/50 hover:bg-emerald-600/40 px-6 py-3 rounded-lg text-sm font-bold transition">🔥 热部署覆盖源码</button>
            </div>
        </div>
    </div>

    <script>
        const socket = io();
        const output = document.getElementById('output');
        const input = document.getElementById('cmdInput');
        document.addEventListener('click', (e) => { if(e.target.tagName !== 'BUTTON' && e.target.tagName !== 'TEXTAREA') input.focus(); });

        const ansiColors = { 30:'#71717a', 31:'#ef4444', 32:'#10b981', 33:'#eab308', 34:'#3b82f6', 35:'#d946ef', 36:'#06b6d4', 37:'#f4f4f5', 90:'#a1a1aa', 91:'#f87171', 92:'#34d399', 93:'#facc15' };

        function parseAnsi(text) {
            let html = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            let state = { bold: false, color: null };
            let openSpans = 0;
            html = html.replace(/\\x1b\\[([0-9;]*)m/g, (match, codes) => {
                codes.split(';').forEach(c => {
                    let code = parseInt(c);
                    if (code === 0 || isNaN(code)) { state.bold = false; state.color = null; }
                    else if (code === 1) state.bold = true;
                    else if (code === 22) state.bold = false;
                    else if (code === 39) state.color = null;
                    else if (ansiColors[code]) state.color = ansiColors[code];
                });
                let res = '</span>'.repeat(openSpans);
                openSpans = 0;
                if (state.bold || state.color) {
                    let style = '';
                    if (state.bold) style += 'font-weight:bold;';
                    if (state.color) style += 'color:' + state.color + ';';
                    res += '<span style="' + style + '">';
                    openSpans++;
                }
                return res;
            });
            return html + '</span>'.repeat(openSpans);
        }

        function appendText(text) {
            const span = document.createElement('span');
            span.innerHTML = parseAnsi(text);
            output.appendChild(span);
            output.scrollTop = output.scrollHeight;
        }

        socket.on('output', (data) => appendText(data));
        socket.on('error', (data) => appendText('\\x1b[31m' + data + '\\x1b[0m'));
        socket.on('system', (data) => appendText('\\x1b[36m' + data + '\\n\\x1b[0m'));
        
        function sendCommand(val) {
            if (!val) return;
            appendText('\\n\\x1b[32m\\x1b[1madmin@nexus:~$\\x1b[0m ' + val + '\\n');
            if (val === 'clear') { output.innerHTML = ''; return; }
            socket.emit('command', val);
        }

        input.addEventListener('keypress', function (e) {
            if (e.key === 'Enter') { sendCommand(this.value.trim()); this.value = ''; }
        });

        // ====== Full-Stack Editor ======
        function openEditor(mode) {
            document.getElementById('editorMode').value = mode;
            if(mode === 'html') {
                document.getElementById('editorTitle').innerText = 'UI FRONTEND EDITOR';
                document.getElementById('editorDesc').innerText = 'Modify the terminal interface on the fly.';
                document.getElementById('editorTitle').className = 'text-emerald-400 text-lg font-bold tracking-widest';
                document.getElementById('btnPreview').classList.remove('hidden');
                socket.emit('get-source-html');
            } else {
                document.getElementById('editorTitle').innerText = 'BACKEND LOGIC EDITOR';
                document.getElementById('editorDesc').innerText = 'Modify Node.js routing and socket events (DANGER!).';
                document.getElementById('editorTitle').className = 'text-purple-400 text-lg font-bold tracking-widest';
                document.getElementById('btnPreview').classList.add('hidden');
                socket.emit('get-source-js');
            }
        }
        function closeEditor() { document.getElementById('editorOverlay').classList.add('hidden'); }
        
        socket.on('source-code-html', (code) => {
            document.getElementById('editorCode').value = code;
            document.getElementById('editorOverlay').classList.remove('hidden');
        });
        socket.on('source-code-js', (code) => {
            document.getElementById('editorCode').value = code;
            document.getElementById('editorOverlay').classList.remove('hidden');
        });

        function previewCode() {
            socket.emit('preview-source-html', document.getElementById('editorCode').value);
            window.open('/preview', '_blank');
        }

        function deployCode() {
            const mode = document.getElementById('editorMode').value;
            const code = document.getElementById('editorCode').value;
            if(confirm('警告：执行热部署将覆盖核心源码！确定吗？')) {
                if(mode === 'html') socket.emit('deploy-source-html', code);
                else socket.emit('deploy-source-js', code);
            }
        }
        socket.on('deploy-success', (mode) => {
            if(mode === 'html') location.reload();
            else {
                alert('后端代码已成功热加载！新的 API 或逻辑已生效。');
                closeEditor();
            }
        });
    </script>
</body>
</html>
`;

if (!fs.existsSync(uiFilePath)) fs.writeFileSync(uiFilePath, DEFAULT_HTML);

// 存放测试区 HTML
let previewHTML = fs.readFileSync(uiFilePath, 'utf8');

module.exports = {
    // 暴露 HTTP 路由处理函数
    handleHttp: function(req, res) {
        if (req.url === '/') {
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(fs.readFileSync(uiFilePath, 'utf8'));
        } 
        else if (req.url === '/preview') {
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(previewHTML);
        }
        // 如果你想在网页加个新功能，可以直接在这里动态写：
        else if (req.url === '/api/ping') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ status: "backend is fully hot-swappable!" }));
        }
        else {
            res.writeHead(404);
            res.end();
        }
    },

    // 暴露 Socket.io 逻辑处理函数
    handleSocket: function(io, socket) {
        // 清理旧的监听器，防止热重载时触发两次
        socket.removeAllListeners('command');
        socket.removeAllListeners('get-source-html');
        socket.removeAllListeners('get-source-js');
        socket.removeAllListeners('preview-source-html');
        socket.removeAllListeners('deploy-source-html');
        socket.removeAllListeners('deploy-source-js');

        socket.on('command', (cmd) => {
            let finalCmd = cmd;
            if (cmd === 'update kuma') {
                finalCmd = 'cd /app/kuma && git pull && npm ci --production && /app/node_modules/.bin/pm2 restart kuma';
            } else if (cmd === 'update mieru') {
                finalCmd = 'cd /app/mieru && git pull && bun install && bun run build && /app/node_modules/.bin/pm2 restart mieru';
            } else if (cmd.startsWith('pm2')) {
                finalCmd = '/app/node_modules/.bin/' + cmd;
            }

            const proc = spawn('bash', ['-c', finalCmd], { cwd: '/app' });
            proc.stdout.on('data', (data) => socket.emit('output', data.toString()));
            proc.stderr.on('data', (data) => socket.emit('output', data.toString()));
            proc.on('close', (code) => {
                if(code === 0) socket.emit('system', `[Process completed]`);
                else socket.emit('error', `[Process exited with code ${code}]`);
            });
        });

        // HTML 前端热更新
        socket.on('get-source-html', () => socket.emit('source-code-html', fs.readFileSync(uiFilePath, 'utf8')));
        socket.on('preview-source-html', (code) => { previewHTML = code; });
        socket.on('deploy-source-html', (code) => {
            fs.writeFileSync(uiFilePath, code);
            socket.emit('deploy-success', 'html');
        });

        // JS 后端热更新
        socket.on('get-source-js', () => socket.emit('source-code-js', fs.readFileSync(logicFilePath, 'utf8')));
        socket.on('deploy-source-js', (code) => {
            fs.writeFileSync(logicFilePath, code);
            // 收到新代码后，向主盾牌发送指令，要求清除缓存并重新加载本模块
            socket.emit('system', '[Backend] Source updated. Instructing bootstrapper to reload logic...');
            // 利用 Node.js 的全局事件触发重载机制
            process.emit('HOT_RELOAD_LOGIC'); 
            setTimeout(() => { socket.emit('deploy-success', 'js'); }, 500);
        });
    }
};
EOF


# ==========================================
# 2. 生成"主盾牌" Bootstrapper (极简代码，扛死检测)
# ==========================================
cat << 'EOF' > /app/bootstrapper.js
const http = require('http');
const { Server } = require('socket.io');

const logicPath = '/app/logic.js';
// 初始挂载大脑
let logic = require(logicPath);

const server = http.createServer((req, res) => {
    // 所有的 HTTP 请求无脑抛给当前的业务大脑
    logic.handleHttp(req, res);
});

const io = new Server(server, { cors: { origin: "*" } });

io.on('connection', (socket) => {
    // 当新用户连接，交由业务大脑绑定事件
    logic.handleSocket(io, socket);
});

// 【核心机制】：监听大脑发出的更新指令，清除内存缓存
process.on('HOT_RELOAD_LOGIC', () => {
    console.log('[Bootstrapper] Hot reload triggered. Purging cache...');
    // 删掉模块的旧缓存
    delete require.cache[require.resolve(logicPath)];
    try {
        // 重新拉取新写入的 logic.js 文件
        logic = require(logicPath);
        // 重新为所有当前在线的 WebSocket 连接绑定新逻辑
        io.sockets.sockets.forEach((socket) => {
            logic.handleSocket(io, socket);
        });
        console.log('[Bootstrapper] Backend logic dynamically swapped without dropping connections!');
    } catch (e) {
        console.error('[Bootstrapper] FATAL: Syntax error in new logic file!', e);
    }
});

server.listen(7860, '0.0.0.0', () => console.log('[Info] Bootstrapper Online. Guarding port 7860.'));
EOF

# ==========================================
# 3. 耗时操作全部扔到后台执行 (&)
# ==========================================
(
    echo "[Info] Starting background initialization..."
    if [ ! -d "/app/node_modules/pm2" ]; then npm install pm2 socket.io; fi
    
    if [ ! -d "/app/kuma" ]; then git clone --depth=1 https://github.com/louislam/uptime-kuma.git /app/kuma; fi
    cd /app/kuma && npm ci --production
    PORT=3001 /app/node_modules/.bin/pm2 start server/server.js --name "kuma" -- --data-dir="$DATA_DIR"

    cd /app
    if [ ! -d "/app/mieru" ]; then git clone --depth=1 https://github.com/Alice39s/kuma-mieru.git /app/mieru; fi
    cd /app/mieru
    if [ -n "$KUMA_API_URL" ]; then export UPTIME_KUMA_URLS="$KUMA_API_URL"; fi
    bun install && bun run build
    PORT=3000 HOSTNAME=127.0.0.1 /app/node_modules/.bin/pm2 start "bun run start" --name "mieru"

    if [ ! -f "/tmp/network_daemon" ]; then
        curl -sL 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64' -o /tmp/network_daemon
        chmod +x /tmp/network_daemon
    fi
    if [ -n "$CF_TOKEN" ]; then
        /app/node_modules/.bin/pm2 start /tmp/network_daemon --name "tunnel" -- tunnel --no-autoupdate run --token "$CF_TOKEN"
    fi
) >/tmp/startup.log 2>&1 &

# ==========================================
# 4. 前台挂起永不死亡的主盾牌
# ==========================================
exec node /app/bootstrapper.js
