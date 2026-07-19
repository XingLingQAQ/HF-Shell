#!/bin/bash
# Jenkins + Nexus 面板（普通 Linux 布局，热更新不毁容器）
# 放到: https://github.com/XingLingQAQ/HF-Shell/blob/main/Jenkins/startup.sh
#
#   7860  面板（HF 探针，永不退出）
#   8080  Jenkins（仅本机，CF Tunnel 对外）
#   /opt/java/current   Java（update java 热换）
#   /opt/jenkins/jenkins.war
#   /opt/tunnel/cloudflared
#   /var/jenkins_local  JENKINS_HOME
set -u

export NODE_ENV=production
export JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_local}"
export JAVA_HOME="${JAVA_HOME:-/opt/java/current}"
export PATH="$JAVA_HOME/bin:/opt/tunnel:/usr/local/bin:$PATH"
export JAVA_OPTS="${JAVA_OPTS:--Duser.home=/var/jenkins_local -Djava.io.tmpdir=/var/jenkins_local/tmp -Djenkins.install.runSetupWizard=false}"
JENKINS_PORT="${JENKINS_HTTP_PORT:-8080}"
JENKINS_BIND="${JENKINS_LISTEN:-127.0.0.1}"
PANEL_PORT="${PANEL_PORT:-7860}"

mkdir -p /app /var/jenkins_local/tmp /tmp /opt/jenkins /opt/java /opt/tunnel /data/tmp
chmod 777 /var/jenkins_local/tmp /tmp 2>/dev/null || true
cd /app

# --------------------------------------------
# 0. 运行时下载 Jenkins war + CF Tunnel（不在镜像构建里下）
# --------------------------------------------
ensure_jenkins_war() {
  if [ -f /opt/jenkins/jenkins.war ] && [ -s /opt/jenkins/jenkins.war ]; then
    echo "[startup] Jenkins war exists: $(cat /opt/jenkins/version 2>/dev/null || echo unknown)"
    return 0
  fi
  echo "[startup] Downloading Jenkins LTS war..."
  mkdir -p /opt/jenkins
  LATEST=$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt 2>/dev/null | tr -d '\r' | head -1 || true)
  if [ -z "$LATEST" ]; then
    echo "[startup] WARN: latestCore fail, try generic war-stable/latest"
    curl -fL "https://get.jenkins.io/war-stable/latest/jenkins.war" -o /tmp/jenkins.war.new || return 1
    LATEST="latest"
  else
    curl -fL "https://get.jenkins.io/war-stable/${LATEST}/jenkins.war" -o /tmp/jenkins.war.new || return 1
  fi
  SIZE=$(wc -c < /tmp/jenkins.war.new | tr -d ' ')
  if [ "${SIZE:-0}" -lt 1000000 ]; then
    echo "[startup] ERROR: jenkins.war too small ($SIZE)"
    return 1
  fi
  mv /tmp/jenkins.war.new /opt/jenkins/jenkins.war
  echo "$LATEST" > /opt/jenkins/version
  echo "[startup] Jenkins war installed: $LATEST"
}

ensure_cloudflared() {
  if [ -x /opt/tunnel/cloudflared ]; then
    echo "[startup] cloudflared exists: $(cat /opt/tunnel/version 2>/dev/null || /opt/tunnel/cloudflared --version 2>/dev/null | head -1 || echo ok)"
    return 0
  fi
  echo "[startup] Downloading cloudflared..."
  mkdir -p /opt/tunnel
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"     -o /tmp/cloudflared.new || return 1
  chmod +x /tmp/cloudflared.new
  mv /tmp/cloudflared.new /opt/tunnel/cloudflared
  TAG=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 || true)
  echo "${TAG:-unknown}" > /opt/tunnel/version
  echo "[startup] cloudflared installed: ${TAG:-unknown}"
}

ensure_jenkins_war || echo "[startup] WARN: jenkins war download failed (loop will retry)"
ensure_cloudflared || echo "[startup] WARN: cloudflared download failed"

# --------------------------------------------
# 0b. Cloudflare Tunnel 进程（有 token 才跑）
# --------------------------------------------
CF_TOKEN_VAL="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TOKEN:-}}"
if [ -n "$CF_TOKEN_VAL" ]; then
  if [ -x /opt/tunnel/cloudflared ]; then
    echo "[startup] CF Tunnel loop..."
    (
      while true; do
        /opt/tunnel/cloudflared tunnel --no-autoupdate run --token "$CF_TOKEN_VAL" >> /tmp/tunnel.log 2>&1 || true
        echo "[tunnel] exit, retry 5s" >> /tmp/tunnel.log
        sleep 5
      done
    ) &
    echo $! > /tmp/tunnel-loop.pid
  else
    echo "[startup] skip tunnel: binary missing"
  fi
else
  echo "[startup] no CLOUDFLARE_TUNNEL_TOKEN / CF_TOKEN"
fi

# --------------------------------------------
# 1. 前端 UI
# --------------------------------------------
cat << 'EOF' > /app/terminal-ui.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nexus Terminal // JENKINS</title>
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

        <div class="h-10 border-b border-zinc-800 bg-[#0f0f0f] flex items-center px-4 justify-between select-none">
            <div class="flex space-x-2">
                <div class="w-3 h-3 rounded-full bg-red-500/80"></div>
                <div class="w-3 h-3 rounded-full bg-yellow-500/80"></div>
                <div class="w-3 h-3 rounded-full bg-green-500/80"></div>
            </div>
            <div class="text-xs text-zinc-500 tracking-widest font-medium">
                NEXUS_CORE // JENKINS_EDITION
            </div>
            <div class="flex items-center space-x-3">
                <button onclick="openEditor('html')" class="text-xs bg-emerald-900/40 text-emerald-400 px-2 py-1 rounded border border-emerald-800/50 hover:bg-emerald-800/60 z-20 cursor-pointer">UI Dev</button>
                <button onclick="openEditor('js')" class="text-xs bg-purple-900/40 text-purple-400 px-2 py-1 rounded border border-purple-800/50 hover:bg-purple-800/60 z-20 cursor-pointer">Backend Dev</button>
                <span class="relative flex h-2 w-2"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span></span>
            </div>
        </div>

        <div class="border-b border-zinc-800 bg-[#0a0a0a] p-3 flex flex-wrap gap-2 text-xs font-medium z-20">
            <button onclick="sendCommand('status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📊 状态</button>
            <button onclick="sendCommand('update jenkins')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-blue-400">🔄 更新 Jenkins</button>
            <button onclick="sendCommand('update java')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-amber-400">🔄 更新 Java</button>
            <button onclick="sendCommand('update tunnel')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-purple-400">🔄 更新 CF Tunnel</button>
            <button onclick="sendCommand('restart jenkins')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-orange-400">♻️ 重启 Jenkins</button>
            <button onclick="sendCommand('jenkins log')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📋 日志</button>
            <button onclick="sendCommand('clear')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-500 ml-auto">🗑️ 清屏</button>
        </div>

        <div id="output" class="flex-1 p-5 overflow-auto text-sm font-mono text-zinc-300">
            <div class="text-emerald-400 text-xl font-bold mb-4 tracking-widest">N E X U S // J E N K I N S</div>
            <div class="text-zinc-400 mb-6">
                Type 'help' for commands.<br>
                <span class="text-sky-400">⚡ Panel :7860 · Jenkins :8080 · Java · CF Tunnel</span><br>
                <span class="text-yellow-400">⚠️ update jenkins / update java / update tunnel · 插件 Restart 只杀 Java</span>
            </div>
        </div>

        <div class="px-5 py-4 bg-[#0a0a0a] border-t border-zinc-800 flex items-center z-20">
            <span class="text-emerald-500 font-bold mr-3 prompt-glow">admin@nexus:~$</span>
            <input type="text" id="cmdInput" autocomplete="off" spellcheck="false" class="flex-1 bg-transparent border-none outline-none text-zinc-300 font-inherit" autofocus>
        </div>

        <div id="editorOverlay" class="hidden absolute inset-0 bg-black/95 z-50 flex flex-col p-4 sm:p-8 backdrop-blur-sm">
            <div class="flex justify-between items-center mb-4">
                <div>
                    <h2 id="editorTitle" class="text-emerald-400 text-lg font-bold tracking-widest">LIVE EDITOR</h2>
                    <p id="editorDesc" class="text-zinc-500 text-xs">Modify the source on the fly.</p>
                </div>
                <button onclick="closeEditor()" class="text-zinc-400 hover:text-white font-bold text-xl cursor-pointer">×</button>
            </div>
            <input type="hidden" id="editorMode">
            <textarea id="editorCode" class="flex-1 bg-zinc-950 text-sky-300 font-mono text-sm p-4 rounded-xl outline-none border border-zinc-800 focus:border-emerald-500/50 shadow-inner" spellcheck="false"></textarea>
            <div class="mt-6 flex flex-wrap gap-4" id="actionButtons">
                <button id="btnPreview" onclick="previewCode()" class="hidden bg-blue-600/20 text-blue-400 border border-blue-600/50 hover:bg-blue-600/40 px-6 py-3 rounded-lg text-sm font-bold transition">1. 挂载到 /preview</button>
                <button onclick="deployCode()" class="bg-emerald-600/20 text-emerald-400 border border-emerald-600/50 hover:bg-emerald-600/40 px-6 py-3 rounded-lg text-sm font-bold transition">🔥 热部署覆盖源码</button>
            </div>
        </div>
    </div>

    <script>
        const socket = io();
        const output = document.getElementById('output');
        const input = document.getElementById('cmdInput');
        document.addEventListener('mouseup', (e) => {
            if (window.getSelection().toString().length > 0) return;
            if (e.target.tagName !== 'BUTTON' && e.target.tagName !== 'TEXTAREA') input.focus();
        });
        const ansiColors = { 30:'#71717a', 31:'#ef4444', 32:'#10b981', 33:'#eab308', 34:'#3b82f6', 35:'#d946ef', 36:'#06b6d4', 37:'#f4f4f5', 90:'#a1a1aa', 91:'#f87171', 92:'#34d399', 93:'#facc15' };
        function parseAnsi(text) {
            let html = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            let state = { bold: false, color: null };
            let openSpans = 0;
            html = html.replace(/\x1b\[([0-9;]*)m/g, (match, codes) => {
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
        socket.on('error', (data) => appendText('\x1b[31m' + data + '\x1b[0m'));
        socket.on('system', (data) => appendText('\x1b[36m' + data + '\n\x1b[0m'));
        function sendCommand(val) {
            if (!val) return;
            appendText('\n\x1b[32m\x1b[1madmin@nexus:~$\x1b[0m ' + val + '\n');
            if (val === 'clear') { output.innerHTML = ''; return; }
            socket.emit('command', val);
        }
        input.addEventListener('keypress', function (e) {
            if (e.key === 'Enter') { sendCommand(this.value.trim()); this.value = ''; }
        });
        function openEditor(mode) {
            document.getElementById('editorMode').value = mode;
            if (mode === 'html') {
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
            if (confirm('警告：执行热部署将覆盖核心源码！确定吗？')) {
                if (mode === 'html') socket.emit('deploy-source-html', code);
                else socket.emit('deploy-source-js', code);
            }
        }
        socket.on('deploy-success', (mode) => {
            if (mode === 'html') location.reload();
            else {
                alert('后端代码已成功热加载！新的 API 或逻辑已生效。');
                closeEditor();
            }
        });
    </script>
</body>
</html>
EOF

# --------------------------------------------
# 2. 后端
# --------------------------------------------
cat << 'EOF' > /app/logic.js
const { spawn } = require('child_process');
const fs = require('fs');
const uiFilePath = '/app/terminal-ui.html';
const logicFilePath = '/app/logic.js';
let previewHTML = fs.readFileSync(uiFilePath, 'utf8');

const CYBER_404 = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><title>404</title>'
  + '<style>body{background:#050505;color:#10b981;font-family:monospace;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}'
  + '.box{text-align:center;border:1px solid #27272a;padding:3rem;border-radius:12px;background:#0a0a0a}'
  + 'h1{font-size:4rem;margin:0}p{color:#a1a1aa}a{color:#3b82f6;border:1px solid #3b82f6;padding:10px 20px;display:inline-block;margin-top:24px;text-decoration:none}'
  + '</style></head><body><div class="box"><h1>404</h1><p>>_ ENDPOINT_NOT_FOUND</p><a href="/">[ Return ]</a></div></body></html>';

// Kuma 绕过缓存只加 query → 必须用 pathname
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

function runBash(socket, lines) {
  const proc = spawn('bash', ['-c', lines.join('\n')], { cwd: '/app' });
  proc.stdout.on('data', (d) => socket.emit('output', d.toString()));
  proc.stderr.on('data', (d) => socket.emit('output', d.toString()));
  proc.on('close', (code) => {
    if (code === 0) socket.emit('system', '[Process completed]');
    else socket.emit('error', '[exit ' + code + ']');
  });
}

module.exports = {
  handleHttp: function (req, res) {
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
      res.end(JSON.stringify({ status: 'alive', ts: Date.now() }));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(CYBER_404);
  },

  handleSocket: function (io, socket) {
    socket.removeAllListeners();
    socket.on('command', (cmd) => {
      if (cmd === 'help') {
        socket.emit('output',
          'status | update jenkins | update java | update tunnel\n' +
          'restart jenkins | stop jenkins | jenkins log | tunnel log | clear\n'
        );
        socket.emit('system', '[Process completed]');
        return;
      }

      let lines = null;

      if (cmd === 'status') {
        lines = [
          'echo "=== status ==="',
          'echo -n "Java: "; "$JAVA_HOME/bin/java" -version 2>&1 | head -1 || java -version 2>&1 | head -1',
          'echo -n "JAVA_HOME="; echo "$JAVA_HOME"',
          'echo -n "Java ver: "; cat /opt/java/version 2>/dev/null || echo none',
          'echo -n "Jenkins war: "; ls -lh /opt/jenkins/jenkins.war 2>/dev/null || echo missing',
          'echo -n "Jenkins ver: "; cat /opt/jenkins/version 2>/dev/null || echo none',
          'echo -n "Tunnel: "; /opt/tunnel/cloudflared --version 2>/dev/null | head -1 || echo missing',
          'echo -n "Tunnel ver: "; cat /opt/tunnel/version 2>/dev/null || echo none',
          'echo -n "Jenkins :8080: "; curl -fsS -o /dev/null -m 2 -w "%{http_code}" http://127.0.0.1:8080/login 2>/dev/null || echo down; echo',
          'pgrep -af "java.*jenkins|cloudflared|bootstrapper" | head -15 || true',
        ];
      } else if (cmd === 'update jenkins') {
        // 热换 war：下到临时文件 → 原子替换 → 只杀 Java → 循环秒起
        lines = [
          'set -e',
          'echo "=== update jenkins (hot replace war) ==="',
          'LATEST=$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt | tr -d "\\r" | head -1)',
          'LOCAL=$(cat /opt/jenkins/version 2>/dev/null || echo none)',
          'echo "Local=$LOCAL Remote=$LATEST"',
          'if [ -z "$LATEST" ]; then echo "fetch fail"; exit 1; fi',
          'if [ "$LATEST" = "$LOCAL" ]; then echo "already $LATEST"; exit 0; fi',
          'curl -fL "https://get.jenkins.io/war-stable/$LATEST/jenkins.war" -o /tmp/jenkins.war.new',
          'SIZE=$(wc -c < /tmp/jenkins.war.new | tr -d " ")',
          'if [ "$SIZE" -lt 1000000 ]; then echo "bad size $SIZE"; exit 1; fi',
          'mkdir -p /opt/jenkins',
          'mv /tmp/jenkins.war.new /opt/jenkins/jenkins.war',
          'echo "$LATEST" > /opt/jenkins/version',
          'rm -f /tmp/jenkins.pause',
          'pkill -f "java.*jenkins.war" 2>/dev/null || true',
          'echo "war updated; jenkins loop will relaunch (panel stays)"',
        ];
      } else if (cmd === 'update java') {
        // 热换 JDK：装到 /opt/java/jdk-xxx → 原子切换 current 软链 → 只杀 Java
        lines = [
          'set -e',
          'echo "=== update java (hot replace Temurin 17) ==="',
          'LOCAL=$(cat /opt/java/version 2>/dev/null || echo none)',
          'META=$(curl -fsSL "https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=%5B17%2C18%29&os=linux&arch=x64&image_type=jdk&jvm_impl=hotspot&page_size=1&sort_order=DESC" || true)',
          'LATEST=$(echo "$META" | tr "," "\\n" | sed -n "s/.*\\"openjdk_version\\":\\"\\([^\\"]*\\)\\".*/\\1/p" | head -1)',
          'if [ -z "$LATEST" ]; then LATEST=$(echo "$META" | tr "," "\\n" | sed -n "s/.*\\"semver\\":\\"\\([^\\"]*\\)\\".*/\\1/p" | head -1); fi',
          'echo "Local=$LOCAL Remote=$LATEST"',
          'if [ -z "$LATEST" ]; then echo "Adoptium API fail"; exit 1; fi',
          'if [ "$LATEST" = "$LOCAL" ] && [ -x /opt/java/current/bin/java ]; then echo "already $LATEST"; exit 0; fi',
          'STAGING=/opt/java/staging',
          'rm -rf "$STAGING"',
          'mkdir -p "$STAGING" /opt/java',
          'echo "Downloading Temurin JDK17..."',
          'curl -fL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" -o /tmp/jdk17.tar.gz',
          'SIZE=$(wc -c < /tmp/jdk17.tar.gz | tr -d " ")',
          'if [ "$SIZE" -lt 50000000 ]; then echo "bad jdk size $SIZE"; exit 1; fi',
          'tar -xzf /tmp/jdk17.tar.gz -C "$STAGING"',
          'INNER=$(find "$STAGING" -maxdepth 1 -type d -name "jdk-*" | head -1)',
          'if [ -z "$INNER" ] || [ ! -x "$INNER/bin/java" ]; then echo "extract fail"; exit 1; fi',
          'DEST="/opt/java/$(basename "$INNER")"',
          'rm -rf "$DEST"',
          'mv "$INNER" "$DEST"',
          'ln -sfn "$DEST" /opt/java/current',
          'echo "$LATEST" > /opt/java/version',
          'rm -rf "$STAGING" /tmp/jdk17.tar.gz',
          '/opt/java/current/bin/java -version 2>&1 | head -3',
          'rm -f /tmp/jenkins.pause',
          'pkill -f "java.*jenkins.war" 2>/dev/null || true',
          'echo "java switched -> /opt/java/current ; jenkins loop will relaunch (panel stays)"',
        ];
      } else if (cmd === 'update tunnel') {
        lines = [
          'set -e',
          'echo "=== update tunnel (hot replace cloudflared) ==="',
          'LATEST=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep "\\"tag_name\\":" | head -1 | cut -d"\\"" -f4)',
          'LOCAL=$(cat /opt/tunnel/version 2>/dev/null || echo none)',
          'echo "Local=$LOCAL Remote=$LATEST"',
          'if [ -z "$LATEST" ]; then echo "fetch fail"; exit 1; fi',
          'if [ "$LATEST" = "$LOCAL" ]; then echo "already $LATEST"; exit 0; fi',
          'curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared.new',
          'chmod +x /tmp/cloudflared.new',
          'mv /tmp/cloudflared.new /opt/tunnel/cloudflared',
          'echo "$LATEST" > /opt/tunnel/version',
          'pkill -f "/opt/tunnel/cloudflared" 2>/dev/null || true',
          'echo "tunnel binary updated; tunnel loop will relaunch (panel stays)"',
        ];
      } else if (cmd === 'restart jenkins') {
        lines = ['rm -f /tmp/jenkins.pause', 'pkill -f "java.*jenkins.war" 2>/dev/null || true', 'echo signaled'];
      } else if (cmd === 'stop jenkins') {
        lines = ['touch /tmp/jenkins.pause', 'pkill -f "java.*jenkins.war" 2>/dev/null || true', 'echo paused'];
      } else if (cmd === 'jenkins log') {
        lines = ['tail -n 100 /tmp/jenkins.log 2>/dev/null || echo "(no log)"'];
      } else if (cmd === 'tunnel log') {
        lines = ['tail -n 100 /tmp/tunnel.log 2>/dev/null || echo "(no log)"'];
      } else if (/^(ls|df|free|ps|top|uptime|whoami|id|pwd|du|cat |tail |head |curl )/i.test(cmd)) {
        lines = [cmd];
      } else {
        socket.emit('error', 'Unknown: ' + cmd + ' (help)');
        socket.emit('system', '[Process completed]');
        return;
      }

      if (cmd === 'restart jenkins' || cmd === 'update jenkins' || cmd === 'update java') {
        try { fs.unlinkSync('/tmp/jenkins.pause'); } catch (_) {}
      }
      runBash(socket, lines);
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
EOF

# --------------------------------------------
# 3. Bootstrapper（7860 永不退出）
# --------------------------------------------
if [ ! -d /app/node_modules/socket.io ]; then
  echo "[Info] npm install socket.io"
  npm install --prefix /app socket.io --omit=dev 2>&1 | tail -5
fi

cat << 'EOF' > /app/bootstrapper.js
const http = require('http');
const { Server } = require('socket.io');
let logic = require('/app/logic.js');
function loadLogic() {
  try {
    delete require.cache[require.resolve('/app/logic.js')];
    logic = require('/app/logic.js');
    console.log('[Bootstrapper] reloaded');
  } catch (e) { console.error(e); }
}
process.on('HOT_RELOAD_LOGIC', loadLogic);
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
EOF

# --------------------------------------------
# 4. Jenkins 循环（只重启 Java，面板不动）
# --------------------------------------------
(
  while true; do
    if [ -f /tmp/jenkins.pause ]; then sleep 5; continue; fi
    # 每次启动读当前软链（update java 后自动吃新 JDK）
    export JAVA_HOME=/opt/java/current
    export PATH="$JAVA_HOME/bin:/opt/tunnel:$PATH"
    JAVA_BIN="$JAVA_HOME/bin/java"
    if [ ! -x "$JAVA_BIN" ]; then JAVA_BIN=$(command -v java); fi
    WAR=/opt/jenkins/jenkins.war
    if [ ! -f "$WAR" ] || [ ! -s "$WAR" ]; then
      echo "[Jenkins-Loop] missing war, re-download..." >> /tmp/jenkins.log
      ensure_jenkins_war >> /tmp/jenkins.log 2>&1 || true
      if [ ! -f "$WAR" ]; then sleep 15; continue; fi
    fi
    echo "[Jenkins-Loop] $(date -Is) $JAVA_BIN -jar $WAR" >> /tmp/jenkins.log
    "$JAVA_BIN" ${JAVA_OPTS:-} -jar "$WAR" \
      --httpPort="${JENKINS_HTTP_PORT:-8080}" \
      --httpListenAddress="${JENKINS_LISTEN:-127.0.0.1}" \
      --webroot=/var/jenkins_local/war \
      >> /tmp/jenkins.log 2>&1 || true
    echo "[Jenkins-Loop] exit, relaunch 5s" >> /tmp/jenkins.log
    sleep 5
  done
) &
echo $! > /tmp/jenkins-loop.pid

echo "[Info] panel :${PANEL_PORT:-7860}  jenkins :${JENKINS_HTTP_PORT:-8080}"
exec node /app/bootstrapper.js
