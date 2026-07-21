#!/bin/bash
# ============================================================
# Gitea + Nexus 面板 on Hugging Face Space
# 覆盖到: https://github.com/XingLingQAQ/HF-Shell/blob/main/Gitea/startup.sh
# 仓库必须 Public（Dockerfile 用 raw 拉取）
#
#   7860  Nexus 面板（HF 探针）
#   3000  Gitea（仅本机，CF Tunnel 对外）
#   /data/gitea  数据目录
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

# 对外访问域名（CF Tunnel 绑定的域名，用于 ROOT_URL；可 Space Secrets 覆盖）
GITEA_ROOT_URL="${GITEA_ROOT_URL:-}"
# 禁用公开注册（安装后也可在 app.ini 改）
GITEA_DISABLE_REGISTRATION="${GITEA_DISABLE_REGISTRATION:-true}"

mkdir -p /app /tmp /opt/gitea "$GITEA_WORK_DIR" "$GITEA_CUSTOM" /app/.pm2
chmod 777 /tmp /app 2>/dev/null || true
cd /app

log() { echo "[startup] $*"; }

# ---------- 下载 Gitea 二进制 ----------
ensure_gitea() {
  if [ -x /opt/gitea/gitea ]; then
    log "gitea binary ok: $(/opt/gitea/gitea --version 2>/dev/null | head -1 || echo present)"
    return 0
  fi
  log "Downloading Gitea..."
  mkdir -p /opt/gitea
  # 固定拉 linux-amd64 最新稳定版
  LATEST=$(curl -fsSL https://dl.gitea.com/gitea/version.json 2>/dev/null | grep -oE '"latest"[^,]*' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -z "$LATEST" ]; then
    LATEST=$(curl -fsSL https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 | sed 's/^v//')
  fi
  if [ -z "$LATEST" ]; then
    log "WARN: cannot detect version, try 1.22.6"
    LATEST=1.22.6
  fi
  URL="https://dl.gitea.com/gitea/${LATEST}/gitea-${LATEST}-linux-amd64"
  log "fetch $URL"
  curl -fL "$URL" -o /tmp/gitea.bin || curl -fL "https://github.com/go-gitea/gitea/releases/download/v${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.bin || return 1
  chmod +x /tmp/gitea.bin
  mv /tmp/gitea.bin /opt/gitea/gitea
  echo "$LATEST" > /opt/gitea/version
  log "gitea installed: $LATEST"
}

# ---------- 生成 app.ini（首次） ----------
ensure_gitea_config() {
  local conf="$GITEA_WORK_DIR/custom/conf/app.ini"
  mkdir -p "$(dirname "$conf")"

  if [ -f "$conf" ]; then
    log "app.ini exists, skip generate"
    # 若设置了 ROOT_URL 环境变量，热更新 ROOT_URL 行
    if [ -n "$GITEA_ROOT_URL" ]; then
      if grep -q '^ROOT_URL' "$conf"; then
        sed -i "s|^ROOT_URL.*|ROOT_URL = ${GITEA_ROOT_URL}|" "$conf" || true
      else
        # 插入到 [server] 段
        sed -i "/^\[server\]/a ROOT_URL = ${GITEA_ROOT_URL}" "$conf" 2>/dev/null || true
      fi
    fi
    return 0
  fi

  local root_url="${GITEA_ROOT_URL:-http://127.0.0.1:${GITEA_HTTP_PORT}/}"
  log "writing first app.ini ROOT_URL=$root_url"

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
REPO_INDEXER_ENABLED = true
REPO_INDEXER_PATH = ${GITEA_WORK_DIR}/indexers/repos.bleve
EOF
}

ensure_gitea || log "WARN: gitea binary download failed"
ensure_gitea_config

# ---------- Nexus 面板 UI ----------
cat << 'EOFUI' > /app/terminal-ui.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>Nexus Terminal // GITEA</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;600&display=swap" rel="stylesheet"/>
<script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
<style>
body{background:#050505;color:#a1a1aa;font-family:'Fira Code',monospace}
#output{white-space:pre;scroll-behavior:smooth}
#output::-webkit-scrollbar{width:8px}#output::-webkit-scrollbar-thumb{background:#3f3f46;border-radius:4px}
.prompt-glow{text-shadow:0 0 10px rgba(16,185,129,.5)}
.btn-action{transition:.2s}.btn-action:hover{transform:translateY(-1px);background:#27272a;color:#fff}
</style>
</head>
<body class="h-screen w-screen overflow-hidden flex items-center justify-center p-2 sm:p-6">
<div class="w-full h-full max-w-6xl bg-[#0a0a0a] border border-zinc-800 rounded-xl flex flex-col overflow-hidden">
  <div class="h-10 border-b border-zinc-800 bg-[#0f0f0f] flex items-center px-4 justify-between">
    <div class="flex space-x-2"><div class="w-3 h-3 rounded-full bg-red-500/80"></div><div class="w-3 h-3 rounded-full bg-yellow-500/80"></div><div class="w-3 h-3 rounded-full bg-green-500/80"></div></div>
    <div class="text-xs text-zinc-500 tracking-widest">NEXUS_CORE // GITEA</div>
    <span class="relative flex h-2 w-2"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span></span>
  </div>
  <div class="border-b border-zinc-800 p-3 flex flex-wrap gap-2 text-xs">
    <button onclick="sendCommand('status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📊 状态</button>
    <button onclick="sendCommand('pm2 status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📦 PM2</button>
    <button onclick="sendCommand('restart gitea')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-orange-400">♻️ 重启 Gitea</button>
    <button onclick="sendCommand('update gitea')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-blue-400">🔄 更新 Gitea</button>
    <button onclick="sendCommand('update tunnel')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-purple-400">🔄 更新 Tunnel</button>
    <button onclick="sendCommand('gitea log')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📋 日志</button>
    <button onclick="sendCommand('clear')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-500 ml-auto">🗑️ 清屏</button>
  </div>
  <div id="output" class="flex-1 p-5 overflow-auto text-sm text-zinc-300">
    <div class="text-emerald-400 text-xl font-bold mb-4 tracking-widest">N E X U S // G I T E A</div>
    <div class="text-zinc-400 mb-4">Panel :7860 · Gitea :3000 (localhost) · use CF Tunnel for public access<br>
    <span class="text-yellow-400">⚠️ First open Gitea via Tunnel URL to finish install wizard if INSTALL_LOCK=false</span></div>
  </div>
  <div class="px-5 py-4 border-t border-zinc-800 flex items-center">
    <span class="text-emerald-500 font-bold mr-3 prompt-glow">admin@nexus:~$</span>
    <input id="cmdInput" type="text" autocomplete="off" spellcheck="false" class="flex-1 bg-transparent border-none outline-none text-zinc-300" autofocus/>
  </div>
</div>
<script>
const socket=io(),output=document.getElementById('output'),input=document.getElementById('cmdInput');
document.addEventListener('mouseup',e=>{if(window.getSelection().toString())return;if(e.target.tagName!=='BUTTON')input.focus();});
function append(t){const s=document.createElement('span');s.textContent=t;output.appendChild(s);output.scrollTop=output.scrollHeight;}
socket.on('output',d=>append(d));socket.on('error',d=>append(d));socket.on('system',d=>append(d+'\n'));
function sendCommand(v){if(!v)return;append('\nadmin@nexus:~$ '+v+'\n');if(v==='clear'){output.innerHTML='';return;}socket.emit('command',v);}
input.addEventListener('keypress',e=>{if(e.key==='Enter'){sendCommand(input.value.trim());input.value='';}});
</script>
</body>
</html>
EOFUI

# ---------- 后端 ----------
cat << 'EOFLOGIC' > /app/logic.js
const { spawn } = require('child_process');
const fs = require('fs');
const uiFilePath = '/app/terminal-ui.html';

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
    socket.emit(code === 0 ? 'system' : 'error', code === 0 ? '[Process completed]' : '[exit ' + code + ']');
  });
}

const PM2 = '/app/node_modules/.bin/pm2';

module.exports = {
  handleHttp(req, res) {
    const path = pathOnly(req);
    if (path === '/' || path === '/index.html') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(fs.readFileSync(uiFilePath, 'utf8'));
      return;
    }
    if (path === '/api/ping' || path === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'alive', app: 'gitea-nexus', ts: Date.now() }));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  },
  handleSocket(io, socket) {
    socket.removeAllListeners();
    socket.on('command', (cmd) => {
      if (cmd === 'help') {
        socket.emit('output', 'status | pm2 status | restart gitea | update gitea | update tunnel | gitea log | clear\n');
        socket.emit('system', '[Process completed]');
        return;
      }
      let script = cmd;
      if (cmd === 'status') {
        script = `
echo "=== Gitea / Tunnel ==="
echo -n "gitea bin: "; /opt/gitea/gitea --version 2>/dev/null || echo missing
echo -n "version file: "; cat /opt/gitea/version 2>/dev/null || echo none
echo -n "GITEA_WORK_DIR: "; echo "${process.env.GITEA_WORK_DIR || '/data/gitea'}"
echo -n "Gitea :3000: "; curl -fsS -o /dev/null -m 2 -w "%{http_code}" http://127.0.0.1:3000/ 2>/dev/null || echo down; echo
echo -n "ROOT_URL: "; grep -E '^ROOT_URL' /data/gitea/custom/conf/app.ini 2>/dev/null || echo n/a
${PM2} status 2>/dev/null || true
`;
      } else if (cmd === 'restart gitea') {
        script = `${PM2} restart gitea --update-env; echo done`;
      } else if (cmd === 'update gitea') {
        script = `
set -e
echo "=== update gitea binary ==="
LATEST=$(curl -fsSL https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 | sed 's/^v//')
LOCAL=$(cat /opt/gitea/version 2>/dev/null || echo none)
echo "Local=$LOCAL Remote=$LATEST"
[ -z "$LATEST" ] && { echo fetch fail; exit 1; }
if [ "$LATEST" = "$LOCAL" ]; then echo already; exit 0; fi
curl -fL "https://dl.gitea.com/gitea/${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.new \
  || curl -fL "https://github.com/go-gitea/gitea/releases/download/v${LATEST}/gitea-${LATEST}-linux-amd64" -o /tmp/gitea.new
chmod +x /tmp/gitea.new
mv /tmp/gitea.new /opt/gitea/gitea
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
        script = `${PM2} logs gitea --lines 80 --nostream 2>/dev/null || tail -n 80 /tmp/gitea.log 2>/dev/null || echo no log`;
      } else if (cmd.startsWith('pm2 ')) {
        script = PM2 + ' ' + cmd.slice(4);
      } else if (cmd === 'pm2 status' || cmd === 'pm2 list') {
        script = PM2 + ' status';
      } else if (cmd === 'clear') {
        socket.emit('system', '[Process completed]');
        return;
      }
      runBash(socket, script);
    });
  }
};
EOFLOGIC

# ---------- deps + bootstrapper ----------
if [ ! -d /app/node_modules/pm2 ] || [ ! -d /app/node_modules/socket.io ]; then
  log "npm install pm2 socket.io"
  npm install --prefix /app pm2 socket.io --omit=dev 2>&1 | tail -8
fi

cat << 'EOFBOOT' > /app/bootstrapper.js
const http = require('http');
const { Server } = require('socket.io');
let logic = require('/app/logic.js');
const server = http.createServer((req, res) => {
  try { logic.handleHttp(req, res); }
  catch (e) { res.writeHead(200); res.end('Alive'); }
});
const io = new Server(server, { cors: { origin: '*' } });
io.on('connection', (s) => { try { logic.handleSocket(io, s); } catch (e) { console.error(e); } });
const port = Number(process.env.PANEL_PORT || 7860);
server.listen(port, '0.0.0.0', () => console.log('[Info] panel :' + port));
process.on('uncaughtException', (e) => console.error(e));
process.on('unhandledRejection', (e) => console.error(e));
EOFBOOT

PM2=/app/node_modules/.bin/pm2
export PATH="/app/node_modules/.bin:$PATH"
export GITEA_WORK_DIR
export GITEA_CUSTOM

# ---------- 后台：Gitea + Tunnel ----------
(
  log "starting gitea + tunnel..."

  $PM2 delete gitea 2>/dev/null || true
  $PM2 delete tunnel 2>/dev/null || true

  if [ -x /opt/gitea/gitea ]; then
    # 使用 web 子命令；配置从 GITEA_WORK_DIR/custom/conf/app.ini 读
    $PM2 start /opt/gitea/gitea \
      --name gitea \
      --max-restarts 50 \
      --restart-delay 5000 \
      --log /tmp/gitea.log \
      --time \
      -- web \
      --config "${GITEA_WORK_DIR}/custom/conf/app.ini" \
      --work-path "${GITEA_WORK_DIR}" || true
  else
    log "ERROR: gitea binary missing"
  fi

  CF="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TOKEN:-}}"
  if [ -n "$CF" ]; then
    if [ ! -x /tmp/sysd ]; then
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /tmp/sysd && chmod +x /tmp/sysd || true
      TAG=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 || true)
      echo "${TAG:-unknown}" > /app/.tunnel_version
    fi
    if [ -x /tmp/sysd ]; then
      $PM2 start /tmp/sysd --name tunnel \
        --max-restarts 50 --restart-delay 5000 --log /tmp/tunnel.log --time \
        -- tunnel --no-autoupdate run --token "$CF" || true
    fi
  else
    log "no CLOUDFLARE_TUNNEL_TOKEN / CF_TOKEN — set it in HF Secrets"
  fi

  $PM2 save 2>/dev/null || true
  $PM2 list || true
) >/tmp/startup-bg.log 2>&1 &

log "panel :${PANEL_PORT}  gitea :${GITEA_HTTP_PORT} (127.0.0.1)"
exec node /app/bootstrapper.js
