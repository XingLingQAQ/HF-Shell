#!/bin/bash
# ============================================================
# Gitea + Nexus 完整面板 on HF
# 覆盖: https://github.com/XingLingQAQ/HF-Shell/blob/main/Gitea/startup.sh
# ============================================================
set -u

export NODE_ENV=production
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PM2_HOME="${PM2_HOME:-/app/.pm2}"
export GITEA_WORK_DIR="${GITEA_WORK_DIR:-/data/gitea}"
export GITEA_CUSTOM="${GITEA_CUSTOM:-/data/gitea/custom}"
export PATH="/usr/local/bin:/app/node_modules/.bin:$PATH"

GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_HTTP_ADDR="${GITEA_HTTP_ADDR:-127.0.0.1}"
PANEL_PORT="${PANEL_PORT:-7860}"
GITEA_ROOT_URL="${GITEA_ROOT_URL:-}"
GITEA_DISABLE_REGISTRATION="${GITEA_DISABLE_REGISTRATION:-true}"

mkdir -p /app /tmp /opt/gitea "$GITEA_WORK_DIR" "$GITEA_CUSTOM/conf" /app/.pm2
chmod 777 /tmp /app 2>/dev/null || true
cd /app

log() { echo "[startup] $*"; }

ensure_gitea() {
  if [ -x /opt/gitea/gitea ]; then
    log "gitea: $(/opt/gitea/gitea --version 2>/dev/null | head -1 || echo ok)"
    return 0
  fi
  log "Downloading Gitea..."
  mkdir -p /opt/gitea
  LATEST=$(curl -fsSL https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 | sed 's/^v//')
  [ -z "$LATEST" ] && LATEST=1.22.6
  URL="https://dl.gitea.com/gitea/${LATEST}/gitea-${LATEST}-linux-amd64"
  curl -fL "$URL" -o /tmp/gitea.bin || curl -fL "https://github.com/go-gitea/gitea/releases/download/v${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.bin || return 1
  chmod +x /tmp/gitea.bin
  mv /tmp/gitea.bin /opt/gitea/gitea
  echo "$LATEST" > /opt/gitea/version
  log "installed gitea $LATEST"
}

ensure_gitea_config() {
  local conf="$GITEA_WORK_DIR/custom/conf/app.ini"
  mkdir -p "$(dirname "$conf")"
  if [ -f "$conf" ]; then
    log "app.ini exists"
    if [ -n "$GITEA_ROOT_URL" ]; then
      if grep -q '^ROOT_URL' "$conf"; then
        sed -i "s|^ROOT_URL.*|ROOT_URL = ${GITEA_ROOT_URL}|" "$conf" || true
      else
        sed -i "/^\[server\]/a ROOT_URL = ${GITEA_ROOT_URL}" "$conf" 2>/dev/null || true
      fi
    fi
    return 0
  fi
  local root_url="${GITEA_ROOT_URL:-http://127.0.0.1:${GITEA_HTTP_PORT}/}"
  log "write app.ini ROOT_URL=$root_url"
  cat > "$conf" << EOF
APP_NAME = Gitea
RUN_MODE = prod
RUN_USER = root

[server]
PROTOCOL = http
DOMAIN = localhost
HTTP_ADDR = ${GITEA_HTTP_ADDR}
HTTP_PORT = ${GITEA_HTTP_PORT}
ROOT_URL = ${root_url}
DISABLE_SSH = true
START_SSH_SERVER = false
OFFLINE_MODE = false
LANDING_PAGE = home

[database]
DB_TYPE = sqlite3
PATH = ${GITEA_WORK_DIR}/gitea.db

[repository]
ROOT = ${GITEA_WORK_DIR}/repositories

[lfs]
PATH = ${GITEA_WORK_DIR}/lfs

[log]
MODE = console
LEVEL = Info
ROOT_PATH = ${GITEA_WORK_DIR}/log

[security]
INSTALL_LOCK = false
MIN_PASSWORD_LENGTH = 8

[service]
DISABLE_REGISTRATION = ${GITEA_DISABLE_REGISTRATION}
REQUIRE_SIGNIN_VIEW = false
ENABLE_NOTIFY_MAIL = false

[session]
PROVIDER = file
PROVIDER_CONFIG = ${GITEA_WORK_DIR}/sessions

[picture]
AVATAR_UPLOAD_PATH = ${GITEA_WORK_DIR}/avatars
REPOSITORY_AVATAR_UPLOAD_PATH = ${GITEA_WORK_DIR}/repo-avatars

[attachment]
PATH = ${GITEA_WORK_DIR}/attachments

[indexer]
ISSUE_INDEXER_PATH = ${GITEA_WORK_DIR}/indexers/issues.bleve
REPO_INDEXER_ENABLED = false
EOF
}

ensure_gitea || log "WARN gitea download failed"
ensure_gitea_config

# ---------- 完整 UI（ANSI + 热编辑）----------
cat << 'EOFUI' > /app/terminal-ui.html

<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nexus Terminal // GITEA</title>
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
                NEXUS_CORE // GITEA
            </div>
            <div class="flex items-center space-x-3">
                <button onclick="openEditor('html')" class="text-xs bg-emerald-900/40 text-emerald-400 px-2 py-1 rounded border border-emerald-800/50 hover:bg-emerald-800/60 z-20 cursor-pointer">UI Dev</button>
                <button onclick="openEditor('js')" class="text-xs bg-purple-900/40 text-purple-400 px-2 py-1 rounded border border-purple-800/50 hover:bg-purple-800/60 z-20 cursor-pointer">Backend Dev</button>
                <span class="relative flex h-2 w-2"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span></span>
            </div>
        </div>

        <div class="border-b border-zinc-800 bg-[#0a0a0a] p-3 flex flex-wrap gap-2 text-xs font-medium z-20">
            <button onclick="sendCommand('status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📊 状态</button>
            <button onclick="sendCommand('pm2 status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📦 PM2</button>
            <button onclick="sendCommand('restart gitea')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-orange-400">♻️ 重启 Gitea</button>
            <button onclick="sendCommand('update gitea')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-blue-400">🔄 更新 Gitea</button>
            <button onclick="sendCommand('update tunnel')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-purple-400">🔄 更新 Tunnel</button>
            <button onclick="sendCommand('gitea log')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📋 Gitea 日志</button>
            <button onclick="sendCommand('tunnel log')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📋 Tunnel 日志</button>
            <button onclick="sendCommand('clear')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-500 ml-auto">🗑️ 清屏</button>
        </div>

        <div id="output" class="flex-1 p-5 overflow-auto text-sm font-mono text-zinc-300">
            <div class="text-emerald-400 text-xl font-bold mb-4 tracking-widest">N E X U S // G I T E A</div>
            <div class="text-zinc-400 mb-6">Type 'help' / fix mieru.<br><span class="text-yellow-400">⚠️ Mieru needs TS5.8 + standalone (not TS7).</span></div>
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
        
        // 【修复 2】：使用 mouseup 代替 click，避免复制时强抢焦点导致选中区消失
        document.addEventListener('mouseup', (e) => { 
            if (window.getSelection().toString().length > 0) return;
            if(e.target.tagName !== 'BUTTON' && e.target.tagName !== 'TEXTAREA') {
                input.focus();
            }
        });

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

EOFUI

# ---------- logic.js 完整后端 + ANSI 命令 ----------
cat << 'EOFLOGIC' > /app/logic.js
const { spawn } = require('child_process');
const fs = require('fs');
const uiFilePath = '/app/terminal-ui.html';
const logicFilePath = '/app/logic.js';
let previewHTML = fs.readFileSync(uiFilePath, 'utf8');
const PM2 = '/app/node_modules/.bin/pm2';

function pathOnly(req) {
  try {
    const u = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
    let p = u.pathname || '/';
    if (p.length > 1) p = p.replace(/\/+$/, '');
    return p || '/';
  } catch (e) {
    return String(req.url || '/').split('?')[0] || '/';
  }
}

function runBash(socket, script) {
  const proc = spawn('bash', ['-c', script], { cwd: '/app', env: process.env });
  proc.stdout.on('data', (d) => socket.emit('output', d.toString()));
  proc.stderr.on('data', (d) => socket.emit('output', d.toString()));
  proc.on('close', (code) => {
    if (code === 0) socket.emit('system', '[Process completed]');
    else socket.emit('error', '[Process exited with code ' + code + ']');
  });
}

module.exports = {
  handleHttp(req, res) {
    const path = pathOnly(req);
    if (path === '/' || path === '/index.html') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(fs.readFileSync(uiFilePath, 'utf8'));
      return;
    }
    if (path === '/preview') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(previewHTML);
      return;
    }
    if (path === '/api/ping' || path === '/health' || path === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'Gitea nexus terminal is alive!', ts: Date.now() }));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end('<!DOCTYPE html><html><head><meta charset="UTF-8"><title>404</title></head><body style="background:#050505;color:#10b981;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0"><div style="text-align:center"><h1>404</h1><p>>_ ENDPOINT_NOT_FOUND</p><a href="/" style="color:#3b82f6">[ Return ]</a></div></body></html>');
  },

  handleSocket(io, socket) {
    socket.removeAllListeners();
    socket.on('command', (cmd) => {
      if (cmd === 'help') {
        socket.emit('output',
          'status | pm2 status | pm2 logs\n' +
          'restart gitea | stop gitea | update gitea | update tunnel\n' +
          'gitea log | tunnel log | clear\n'
        );
        socket.emit('system', '[Process completed]');
        return;
      }

      let script = cmd;

      if (cmd === 'status') {
        script = `
echo "=== Gitea / Tunnel ==="
echo -n "gitea: "; /opt/gitea/gitea --version 2>/dev/null | head -1 || echo missing
echo -n "ver: "; cat /opt/gitea/version 2>/dev/null || echo none
echo -n "WORK_DIR: "; echo "${process.env.GITEA_WORK_DIR || '/data/gitea'}"
echo -n "Gitea :3000: "; curl -fsS -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:3000/ 2>/dev/null || echo down; echo
echo -n "ROOT_URL: "; grep -E '^ROOT_URL' /data/gitea/custom/conf/app.ini 2>/dev/null || echo n/a
echo "--- last gitea log ---"
tail -n 15 /tmp/gitea.log 2>/dev/null || ${PM2} logs gitea --lines 15 --nostream 2>/dev/null || true
${PM2} status 2>/dev/null || true
`;
      } else if (cmd === 'restart gitea') {
        script = `${PM2} restart gitea --update-env; sleep 2; ${PM2} status gitea; echo done`;
      } else if (cmd === 'stop gitea') {
        script = `${PM2} stop gitea; echo stopped`;
      } else if (cmd === 'update gitea') {
        script = `
set -e
LATEST=$(curl -fsSL https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 | sed 's/^v//')
LOCAL=$(cat /opt/gitea/version 2>/dev/null || echo none)
echo "Local=$LOCAL Remote=$LATEST"
[ -z "$LATEST" ] && exit 1
[ "$LATEST" = "$LOCAL" ] && { echo already; exit 0; }
curl -fL "https://dl.gitea.com/gitea/${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.new \
  || curl -fL "https://github.com/go-gitea/gitea/releases/download/v${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.new
chmod +x /tmp/gitea.new; mv /tmp/gitea.new /opt/gitea/gitea
echo "$LATEST" > /opt/gitea/version
${PM2} restart gitea --update-env
echo done
`;
      } else if (cmd === 'update tunnel') {
        script = `
set -e
LATEST=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4)
LOCAL=$(cat /app/.tunnel_version 2>/dev/null || echo none)
echo "Local=$LOCAL Remote=$LATEST"
[ -z "$LATEST" ] && exit 1
[ "$LATEST" = "$LOCAL" ] && [ -x /tmp/sysd ] && { echo up-to-date; exit 0; }
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/sysd.new
chmod +x /tmp/sysd.new; mv /tmp/sysd.new /tmp/sysd
echo "$LATEST" > /app/.tunnel_version
${PM2} restart tunnel || true
echo done
`;
      } else if (cmd === 'gitea log') {
        script = `${PM2} logs gitea --lines 100 --nostream 2>/dev/null || tail -n 100 /tmp/gitea.log 2>/dev/null || echo no log`;
      } else if (cmd === 'tunnel log') {
        script = `${PM2} logs tunnel --lines 80 --nostream 2>/dev/null || tail -n 80 /tmp/tunnel.log 2>/dev/null || echo no log`;
      } else if (cmd.startsWith('pm2 ')) {
        script = PM2 + ' ' + cmd.slice(4);
      } else if (cmd === 'pm2 status' || cmd === 'pm2 list') {
        script = PM2 + ' status';
      } else if (cmd === 'pm2 logs') {
        script = PM2 + ' logs --lines 50 --nostream';
      } else if (cmd === 'clear') {
        socket.emit('system', '[Process completed]');
        return;
      }

      runBash(socket, script);
    });

    socket.on('get-source-html', () => socket.emit('source-code-html', fs.readFileSync(uiFilePath, 'utf8')));
    socket.on('preview-source-html', (code) => { previewHTML = code; });
    socket.on('deploy-source-html', (code) => {
      fs.writeFileSync(uiFilePath, code);
      socket.emit('deploy-success', 'html');
    });
    socket.on('get-source-js', () => socket.emit('source-code-js', fs.readFileSync(logicFilePath, 'utf8')));
    socket.on('deploy-source-js', (code) => {
      fs.writeFileSync(logicFilePath, code);
      process.emit('HOT_RELOAD_LOGIC');
      setTimeout(() => socket.emit('deploy-success', 'js'), 500);
    });
  }
};
EOFLOGIC

# deps
if [ ! -d /app/node_modules/pm2 ] || [ ! -d /app/node_modules/socket.io ]; then
  log "npm install pm2 socket.io"
  npm install --prefix /app pm2 socket.io --omit=dev 2>&1 | tail -8
fi

cat << 'EOFBOOT' > /app/bootstrapper.js
const http = require('http');
const { Server } = require('socket.io');
const logicPath = '/app/logic.js';
let logic = require(logicPath);
process.on('HOT_RELOAD_LOGIC', () => {
  delete require.cache[require.resolve(logicPath)];
  try {
    logic = require(logicPath);
    io.sockets.sockets.forEach((socket) => logic.handleSocket(io, socket));
  } catch (e) { console.error(e); }
});
const server = http.createServer((req, res) => {
  try { logic.handleHttp(req, res); }
  catch (e) { res.writeHead(200); res.end('Alive'); }
});
const io = new Server(server, { cors: { origin: '*' } });
io.on('connection', (s) => { try { logic.handleSocket(io, s); } catch (e) { console.error(e); } });
server.listen(Number(process.env.PANEL_PORT || 7860), '0.0.0.0', () => console.log('[Info] panel online'));
process.on('uncaughtException', (e) => console.error(e));
process.on('unhandledRejection', (e) => console.error(e));
EOFBOOT

PM2=/app/node_modules/.bin/pm2
export PATH="/app/node_modules/.bin:$PATH"
export GITEA_WORK_DIR GITEA_CUSTOM

(
  log "start gitea + tunnel..."
  $PM2 delete gitea 2>/dev/null || true
  $PM2 delete tunnel 2>/dev/null || true

  if [ -x /opt/gitea/gitea ]; then
    # 用 shell 包一层，保证环境变量与工作目录正确；RUN_USER=root 已在 app.ini
    cat > /opt/gitea/run.sh << 'RUNSH'
#!/bin/bash
set -u
export GITEA_WORK_DIR="${GITEA_WORK_DIR:-/data/gitea}"
export GITEA_CUSTOM="${GITEA_CUSTOM:-/data/gitea/custom}"
export USER=root
export HOME=/root
cd "$GITEA_WORK_DIR"
exec /opt/gitea/gitea web \
  --config "${GITEA_WORK_DIR}/custom/conf/app.ini" \
  --work-path "${GITEA_WORK_DIR}" \
  --custom-path "${GITEA_CUSTOM}"
RUNSH
    chmod +x /opt/gitea/run.sh
    $PM2 start /opt/gitea/run.sh \
      --name gitea \
      --interpreter bash \
      --max-restarts 50 \
      --restart-delay 5000 \
      --log /tmp/gitea.log \
      --time || true
  else
    log "ERROR: no gitea binary"
  fi

  CF="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TOKEN:-}}"
  if [ -n "$CF" ]; then
    if [ ! -x /tmp/sysd ]; then
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/sysd
      chmod +x /tmp/sysd
      TAG=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 || true)
      echo "${TAG:-unknown}" > /app/.tunnel_version
    fi
    [ -x /tmp/sysd ] && $PM2 start /tmp/sysd --name tunnel \
      --max-restarts 50 --restart-delay 5000 --log /tmp/tunnel.log --time \
      -- tunnel --no-autoupdate run --token "$CF" || true
  else
    log "no CF_TOKEN / CLOUDFLARE_TUNNEL_TOKEN"
  fi

  $PM2 save 2>/dev/null || true
  sleep 3
  $PM2 list || true
  # 探测 gitea
  curl -fsS -o /dev/null -m 3 -w "[startup] gitea http=%{http_code}\n" http://127.0.0.1:3000/ 2>/dev/null || echo "[startup] gitea not up yet, see: pm2 logs gitea"
) >/tmp/startup-bg.log 2>&1 &

log "panel :${PANEL_PORT}"
exec node /app/bootstrapper.js
