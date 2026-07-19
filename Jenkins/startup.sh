#!/bin/bash
# Jenkins + Nexus — Java 21 + PM2 保活
# 覆盖: https://github.com/XingLingQAQ/HF-Shell/blob/main/Jenkins/startup.sh
# 新版 Jenkins 要求 Java 21+（17 会直接拒绝启动）
set -u

export NODE_ENV=production
export JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_local}"
export JAVA_HOME="${JAVA_HOME:-/opt/java/current}"
export PATH="$JAVA_HOME/bin:/opt/tunnel:/usr/local/bin:$PATH"
export JAVA_OPTS="${JAVA_OPTS:--Duser.home=/var/jenkins_local -Djava.io.tmpdir=/var/jenkins_local/tmp -Djenkins.install.runSetupWizard=false}"
export PM2_HOME="${PM2_HOME:-/var/jenkins_local/.pm2}"
export JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
export JENKINS_LISTEN="${JENKINS_LISTEN:-127.0.0.1}"
export PANEL_PORT="${PANEL_PORT:-7860}"

mkdir -p /app /var/jenkins_local/tmp /tmp /opt/jenkins /opt/java /opt/tunnel /data/tmp "$PM2_HOME"
chmod 777 /var/jenkins_local/tmp /tmp 2>/dev/null || true
cd /app

# ---------- 运行时下载：Java 21 / Jenkins war / cloudflared ----------
ensure_java21() {
  NEED=1
  if [ -x /opt/java/current/bin/java ]; then
    MAJ=$(/opt/java/current/bin/java -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
    if [ -n "$MAJ" ] && [ "$MAJ" -ge 21 ]; then
      echo "[startup] Java ok: $(/opt/java/current/bin/java -version 2>&1 | head -1)"
      NEED=0
    else
      echo "[startup] Java ${MAJ:-?} < 21, will install Temurin 21"
    fi
  else
    echo "[startup] No Java at /opt/java/current, install Temurin 21"
  fi
  [ "$NEED" = "0" ] && return 0

  STAGING=/opt/java/staging
  rm -rf "$STAGING"
  mkdir -p "$STAGING" /opt/java
  echo "[startup] Downloading Temurin JDK 21..."
  curl -fL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" \
    -o /tmp/jdk21.tar.gz || return 1
  SIZE=$(wc -c < /tmp/jdk21.tar.gz | tr -d ' ')
  if [ "${SIZE:-0}" -lt 50000000 ]; then
    echo "[startup] ERROR: jdk archive too small ($SIZE)"
    return 1
  fi
  tar -xzf /tmp/jdk21.tar.gz -C "$STAGING"
  INNER=$(find "$STAGING" -maxdepth 1 -type d -name 'jdk-*' | head -1)
  if [ -z "$INNER" ] || [ ! -x "$INNER/bin/java" ]; then
    echo "[startup] ERROR: extract jdk fail"
    return 1
  fi
  DEST="/opt/java/$(basename "$INNER")"
  rm -rf "$DEST"
  mv "$INNER" "$DEST"
  ln -sfn "$DEST" /opt/java/current
  VER=$("$DEST/bin/java" -version 2>&1 | head -1)
  echo "$VER" > /opt/java/version
  rm -rf "$STAGING" /tmp/jdk21.tar.gz
  export JAVA_HOME=/opt/java/current
  export PATH="$JAVA_HOME/bin:$PATH"
  echo "[startup] Java installed: $VER"
}

ensure_jenkins_war() {
  if [ -f /opt/jenkins/jenkins.war ] && [ -s /opt/jenkins/jenkins.war ]; then
    echo "[startup] Jenkins war ok: $(cat /opt/jenkins/version 2>/dev/null || echo unknown)"
    return 0
  fi
  echo "[startup] Downloading Jenkins LTS war..."
  mkdir -p /opt/jenkins
  LATEST=$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt 2>/dev/null | tr -d '\r' | head -1 || true)
  if [ -z "$LATEST" ]; then
    curl -fL "https://get.jenkins.io/war-stable/latest/jenkins.war" -o /tmp/jenkins.war.new || return 1
    LATEST="latest"
  else
    curl -fL "https://get.jenkins.io/war-stable/${LATEST}/jenkins.war" -o /tmp/jenkins.war.new || return 1
  fi
  SIZE=$(wc -c < /tmp/jenkins.war.new | tr -d ' ')
  [ "${SIZE:-0}" -lt 1000000 ] && { echo "[startup] war too small $SIZE"; return 1; }
  mv /tmp/jenkins.war.new /opt/jenkins/jenkins.war
  echo "$LATEST" > /opt/jenkins/version
  echo "[startup] Jenkins war: $LATEST"
}

ensure_cloudflared() {
  if [ -x /opt/tunnel/cloudflared ]; then
    echo "[startup] cloudflared ok: $(cat /opt/tunnel/version 2>/dev/null || echo ok)"
    return 0
  fi
  echo "[startup] Downloading cloudflared..."
  mkdir -p /opt/tunnel
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    -o /tmp/cloudflared.new || return 1
  chmod +x /tmp/cloudflared.new
  mv /tmp/cloudflared.new /opt/tunnel/cloudflared
  TAG=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | head -1 | cut -d'"' -f4 || true)
  echo "${TAG:-unknown}" > /opt/tunnel/version
  echo "[startup] cloudflared: ${TAG:-unknown}"
}

ensure_java21 || echo "[startup] WARN java21 install failed"
ensure_jenkins_war || echo "[startup] WARN jenkins download failed"
ensure_cloudflared || echo "[startup] WARN tunnel download failed"

export JAVA_HOME=/opt/java/current
export PATH="$JAVA_HOME/bin:/opt/tunnel:/usr/local/bin:$PATH"

# UI
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
            <button onclick="sendCommand('pm2 status')" class="btn-action bg-zinc-900 border border-zinc-700 px-4 py-2 rounded-lg text-zinc-300">📦 PM2</button>
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
                <span class="text-yellow-400">⚠️ PM2 保活 jenkins/tunnel · update 热换后 pm2 restart · 面板不挂</span>
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

# decode app files
echo 'Y29uc3QgeyBzcGF3biB9ID0gcmVxdWlyZSgnY2hpbGRfcHJvY2VzcycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ2ZzJyk7CmNvbnN0IHVpRmlsZVBhdGggPSAnL2FwcC90ZXJtaW5hbC11aS5odG1sJzsKY29uc3QgbG9naWNGaWxlUGF0aCA9ICcvYXBwL2xvZ2ljLmpzJzsKbGV0IHByZXZpZXdIVE1MID0gZnMucmVhZEZpbGVTeW5jKHVpRmlsZVBhdGgsICd1dGY4Jyk7Cgpjb25zdCBDWUJFUl80MDQgPSAnPCFET0NUWVBFIGh0bWw+PGh0bWwgbGFuZz0iemgtQ04iPjxoZWFkPjxtZXRhIGNoYXJzZXQ9IlVURi04Ij48dGl0bGU+NDA0PC90aXRsZT4nCiAgKyAnPHN0eWxlPmJvZHl7YmFja2dyb3VuZDojMDUwNTA1O2NvbG9yOiMxMGI5ODE7Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2FsaWduLWl0ZW1zOmNlbnRlcjtoZWlnaHQ6MTAwdmg7bWFyZ2luOjB9JwogICsgJy5ib3h7dGV4dC1hbGlnbjpjZW50ZXI7Ym9yZGVyOjFweCBzb2xpZCAjMjcyNzJhO3BhZGRpbmc6M3JlbTtib3JkZXItcmFkaXVzOjEycHg7YmFja2dyb3VuZDojMGEwYTBhfScKICArICdoMXtmb250LXNpemU6NHJlbTttYXJnaW46MH1we2NvbG9yOiNhMWExYWF9YXtjb2xvcjojM2I4MmY2O2JvcmRlcjoxcHggc29saWQgIzNiODJmNjtwYWRkaW5nOjEwcHggMjBweDtkaXNwbGF5OmlubGluZS1ibG9jazttYXJnaW4tdG9wOjI0cHg7dGV4dC1kZWNvcmF0aW9uOm5vbmV9JwogICsgJzwvc3R5bGU+PC9oZWFkPjxib2R5PjxkaXYgY2xhc3M9ImJveCI+PGgxPjQwNDwvaDE+PHA+Pl8gRU5EUE9JTlRfTk9UX0ZPVU5EPC9wPjxhIGhyZWY9Ii8iPlsgUmV0dXJuIF08L2E+PC9kaXY+PC9ib2R5PjwvaHRtbD4nOwoKZnVuY3Rpb24gcGF0aE9ubHkocmVxKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHUgPSBuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vJyArIChyZXEuaGVhZGVycy5ob3N0IHx8ICdsb2NhbGhvc3QnKSk7CiAgICBsZXQgcCA9IHUucGF0aG5hbWUgfHwgJy8nOwogICAgaWYgKHAubGVuZ3RoID4gMSkgcCA9IHAucmVwbGFjZSgvXC8rJC8sICcnKTsKICAgIHJldHVybiBwIHx8ICcvJzsKICB9IGNhdGNoIChlKSB7CiAgICByZXR1cm4gU3RyaW5nKHJlcS51cmwgfHwgJy8nKS5zcGxpdCgnPycpWzBdIHx8ICcvJzsKICB9Cn0KCmZ1bmN0aW9uIHBtMlByZWZpeCgpIHsKICByZXR1cm4gWwogICAgJ2V4cG9ydCBQTTJfSE9NRT0iJHtQTTJfSE9NRTotL3Zhci9qZW5raW5zX2xvY2FsLy5wbTJ9IicsCiAgICAnZXhwb3J0IFBBVEg9Ii9hcHAvbm9kZV9tb2R1bGVzLy5iaW46JFBBVEgiJywKICAgICdleHBvcnQgSkFWQV9IT01FPS9vcHQvamF2YS9jdXJyZW50JywKICAgICdleHBvcnQgUEFUSD0iJEpBVkFfSE9NRS9iaW46JFBBVEgiJywKICBdOwp9CgpmdW5jdGlvbiBydW5CYXNoKHNvY2tldCwgbGluZXMpIHsKICBjb25zdCBwcm9jID0gc3Bhd24oJ2Jhc2gnLCBbJy1jJywgbGluZXMuam9pbignXG4nKV0sIHsgY3dkOiAnL2FwcCcgfSk7CiAgcHJvYy5zdGRvdXQub24oJ2RhdGEnLCAoZCkgPT4gc29ja2V0LmVtaXQoJ291dHB1dCcsIGQudG9TdHJpbmcoKSkpOwogIHByb2Muc3RkZXJyLm9uKCdkYXRhJywgKGQpID0+IHNvY2tldC5lbWl0KCdvdXRwdXQnLCBkLnRvU3RyaW5nKCkpKTsKICBwcm9jLm9uKCdjbG9zZScsIChjb2RlKSA9PiB7CiAgICBpZiAoY29kZSA9PT0gMCkgc29ja2V0LmVtaXQoJ3N5c3RlbScsICdbUHJvY2VzcyBjb21wbGV0ZWRdJyk7CiAgICBlbHNlIHNvY2tldC5lbWl0KCdlcnJvcicsICdbZXhpdCAnICsgY29kZSArICddJyk7CiAgfSk7Cn0KCm1vZHVsZS5leHBvcnRzID0gewogIGhhbmRsZUh0dHA6IGZ1bmN0aW9uIChyZXEsIHJlcykgewogICAgY29uc3QgcGF0aCA9IHBhdGhPbmx5KHJlcSk7CiAgICBpZiAocGF0aCA9PT0gJy8nIHx8IHBhdGggPT09ICcvaW5kZXguaHRtbCcpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgICByZXMuZW5kKGZzLnJlYWRGaWxlU3luYyh1aUZpbGVQYXRoLCAndXRmOCcpKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHBhdGggPT09ICcvcHJldmlldycpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgICByZXMuZW5kKHByZXZpZXdIVE1MKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHBhdGggPT09ICcvYXBpL3BpbmcnIHx8IHBhdGggPT09ICcvaGVhbHRoJyB8fCBwYXRoID09PSAnL2hlYWx0aHonKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSk7CiAgICAgIHJlcy5lbmQoSlNPTi5zdHJpbmdpZnkoeyBzdGF0dXM6ICdhbGl2ZScsIHRzOiBEYXRlLm5vdygpIH0pKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgcmVzLndyaXRlSGVhZCg0MDQsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgcmVzLmVuZChDWUJFUl80MDQpOwogIH0sCgogIGhhbmRsZVNvY2tldDogZnVuY3Rpb24gKGlvLCBzb2NrZXQpIHsKICAgIHNvY2tldC5yZW1vdmVBbGxMaXN0ZW5lcnMoKTsKICAgIHNvY2tldC5vbignY29tbWFuZCcsIChjbWQpID0+IHsKICAgICAgaWYgKGNtZCA9PT0gJ2hlbHAnKSB7CiAgICAgICAgc29ja2V0LmVtaXQoJ291dHB1dCcsCiAgICAgICAgICAnc3RhdHVzIHwgcG0yIHN0YXR1cyB8IHBtMiBsb2dzXG4nICsKICAgICAgICAgICd1cGRhdGUgamVua2lucyB8IHVwZGF0ZSBqYXZhIHwgdXBkYXRlIHR1bm5lbFxuJyArCiAgICAgICAgICAncmVzdGFydCBqZW5raW5zIHwgc3RvcCBqZW5raW5zIHwgamVua2lucyBsb2cgfCB0dW5uZWwgbG9nIHwgY2xlYXJcbicKICAgICAgICApOwogICAgICAgIHNvY2tldC5lbWl0KCdzeXN0ZW0nLCAnW1Byb2Nlc3MgY29tcGxldGVkXScpOwogICAgICAgIHJldHVybjsKICAgICAgfQoKICAgICAgbGV0IGxpbmVzID0gbnVsbDsKCiAgICAgIGlmIChjbWQgPT09ICdzdGF0dXMnIHx8IGNtZCA9PT0gJ3BtMiBzdGF0dXMnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWwogICAgICAgICAgJ2VjaG8gIj09PSBzdGF0dXMgKFBNMiAvIEphdmEgMjEgcmVxdWlyZWQpID09PSInLAogICAgICAgICAgJ2VjaG8gLW4gIkphdmE6ICI7IGphdmEgLXZlcnNpb24gMj4mMSB8IGhlYWQgLTEnLAogICAgICAgICAgJ2VjaG8gLW4gIkpBVkFfSE9NRT0iOyBlY2hvICIkSkFWQV9IT01FIicsCiAgICAgICAgICAnZWNobyAtbiAiSmF2YSB2ZXI6ICI7IGNhdCAvb3B0L2phdmEvdmVyc2lvbiAyPi9kZXYvbnVsbCB8fCBlY2hvIG5vbmUnLAogICAgICAgICAgJ2VjaG8gLW4gIkplbmtpbnMgd2FyOiAiOyBscyAtbGggL29wdC9qZW5raW5zL2plbmtpbnMud2FyIDI+L2Rldi9udWxsIHx8IGVjaG8gbWlzc2luZycsCiAgICAgICAgICAnZWNobyAtbiAiSmVua2lucyB2ZXI6ICI7IGNhdCAvb3B0L2plbmtpbnMvdmVyc2lvbiAyPi9kZXYvbnVsbCB8fCBlY2hvIG5vbmUnLAogICAgICAgICAgJ2VjaG8gLW4gIlR1bm5lbDogIjsgL29wdC90dW5uZWwvY2xvdWRmbGFyZWQgLS12ZXJzaW9uIDI+L2Rldi9udWxsIHwgaGVhZCAtMSB8fCBlY2hvIG1pc3NpbmcnLAogICAgICAgICAgJ2VjaG8gLW4gIlR1bm5lbCB2ZXI6ICI7IGNhdCAvb3B0L3R1bm5lbC92ZXJzaW9uIDI+L2Rldi9udWxsIHx8IGVjaG8gbm9uZScsCiAgICAgICAgICAnZWNobyAtbiAiSmVua2lucyA6ODA4MDogIjsgY3VybCAtZnNTIC1vIC9kZXYvbnVsbCAtbSAyIC13ICIle2h0dHBfY29kZX0iIGh0dHA6Ly8xMjcuMC4wLjE6ODA4MC9sb2dpbiAyPi9kZXYvbnVsbCB8fCBlY2hvIGRvd247IGVjaG8nLAogICAgICAgICAgJ2VjaG8gIi0tLSBwbTIgbGlzdCAtLS0iJywKICAgICAgICAgICdwbTIgbGlzdCcsCiAgICAgICAgXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAndXBkYXRlIGplbmtpbnMnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWwogICAgICAgICAgJ3NldCAtZScsCiAgICAgICAgICAnZWNobyAiPT09IHVwZGF0ZSBqZW5raW5zID09PSInLAogICAgICAgICAgJ0xBVEVTVD0kKGN1cmwgLWZzU0wgaHR0cHM6Ly91cGRhdGVzLmplbmtpbnMuaW8vc3RhYmxlL2xhdGVzdENvcmUudHh0IHwgdHIgLWQgIlxcciIgfCBoZWFkIC0xKScsCiAgICAgICAgICAnTE9DQUw9JChjYXQgL29wdC9qZW5raW5zL3ZlcnNpb24gMj4vZGV2L251bGwgfHwgZWNobyBub25lKScsCiAgICAgICAgICAnZWNobyAiTG9jYWw9JExPQ0FMIFJlbW90ZT0kTEFURVNUIicsCiAgICAgICAgICAnaWYgWyAteiAiJExBVEVTVCIgXTsgdGhlbiBlY2hvICJmZXRjaCBmYWlsIjsgZXhpdCAxOyBmaScsCiAgICAgICAgICAnaWYgWyAiJExBVEVTVCIgPSAiJExPQ0FMIiBdOyB0aGVuIGVjaG8gImFscmVhZHkgJExBVEVTVCI7IGV4aXQgMDsgZmknLAogICAgICAgICAgJ2N1cmwgLWZMICJodHRwczovL2dldC5qZW5raW5zLmlvL3dhci1zdGFibGUvJExBVEVTVC9qZW5raW5zLndhciIgLW8gL3RtcC9qZW5raW5zLndhci5uZXcnLAogICAgICAgICAgJ1NJWkU9JCh3YyAtYyA8IC90bXAvamVua2lucy53YXIubmV3IHwgdHIgLWQgIiAiKScsCiAgICAgICAgICAnaWYgWyAiJFNJWkUiIC1sdCAxMDAwMDAwIF07IHRoZW4gZWNobyAiYmFkIHNpemUgJFNJWkUiOyBleGl0IDE7IGZpJywKICAgICAgICAgICdtdiAvdG1wL2plbmtpbnMud2FyLm5ldyAvb3B0L2plbmtpbnMvamVua2lucy53YXInLAogICAgICAgICAgJ2VjaG8gIiRMQVRFU1QiID4gL29wdC9qZW5raW5zL3ZlcnNpb24nLAogICAgICAgICAgJ3BtMiByZXN0YXJ0IGplbmtpbnMgLS11cGRhdGUtZW52IHx8IHBtMiBzdGFydCAvb3B0L2plbmtpbnMvcnVuLWplbmtpbnMuc2ggLS1uYW1lIGplbmtpbnMgLS1pbnRlcnByZXRlciBiYXNoIC0tbWF4LXJlc3RhcnRzIDEwMCAtLXJlc3RhcnQtZGVsYXkgNTAwMCAtLWxvZyAvdG1wL2plbmtpbnMubG9nIC0tdGltZScsCiAgICAgICAgICAnZWNobyAid2FyIHVwZGF0ZWQgKyBwbTIgcmVzdGFydCBqZW5raW5zIicsCiAgICAgICAgXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAndXBkYXRlIGphdmEnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWwogICAgICAgICAgJ3NldCAtZScsCiAgICAgICAgICAnZWNobyAiPT09IHVwZGF0ZSBqYXZhIChUZW11cmluIDIxIOKAlCBKZW5raW5zIOacgOS9juimgeaxgikgPT09IicsCiAgICAgICAgICAnTE9DQUw9JChjYXQgL29wdC9qYXZhL3ZlcnNpb24gMj4vZGV2L251bGwgfHwgZWNobyBub25lKScsCiAgICAgICAgICAnTUVUQT0kKGN1cmwgLWZzU0wgImh0dHBzOi8vYXBpLmFkb3B0aXVtLm5ldC92My9pbmZvL3JlbGVhc2VfdmVyc2lvbnM/cmVsZWFzZV90eXBlPWdhJnZlcnNpb249JTVCMjElMkMyMiUyOSZvcz1saW51eCZhcmNoPXg2NCZpbWFnZV90eXBlPWpkayZqdm1faW1wbD1ob3RzcG90JnBhZ2Vfc2l6ZT0xJnNvcnRfb3JkZXI9REVTQyIgfHwgdHJ1ZSknLAogICAgICAgICAgJ0xBVEVTVD0kKGVjaG8gIiRNRVRBIiB8IHRyICIsIiAiXFxuIiB8IHNlZCAtbiAicy8uKlxcIm9wZW5qZGtfdmVyc2lvblxcIjpcXCJcXChbXlxcIl0qXFwpXFwiLiovXFwxL3AiIHwgaGVhZCAtMSknLAogICAgICAgICAgJ2lmIFsgLXogIiRMQVRFU1QiIF07IHRoZW4gTEFURVNUPSQoZWNobyAiJE1FVEEiIHwgdHIgIiwiICJcXG4iIHwgc2VkIC1uICJzLy4qXFwic2VtdmVyXFwiOlxcIlxcKFteXFwiXSpcXClcXCIuKi9cXDEvcCIgfCBoZWFkIC0xKTsgZmknLAogICAgICAgICAgJ2VjaG8gIkxvY2FsPSRMT0NBTCBSZW1vdGU9JExBVEVTVCInLAogICAgICAgICAgJ2lmIFsgLXogIiRMQVRFU1QiIF07IHRoZW4gZWNobyAiQWRvcHRpdW0gZmFpbCI7IGV4aXQgMTsgZmknLAogICAgICAgICAgJ2lmIFsgIiRMQVRFU1QiID0gIiRMT0NBTCIgXSAmJiBbIC14IC9vcHQvamF2YS9jdXJyZW50L2Jpbi9qYXZhIF07IHRoZW4gZWNobyAiYWxyZWFkeSAkTEFURVNUIjsgZXhpdCAwOyBmaScsCiAgICAgICAgICAnU1RBR0lORz0vb3B0L2phdmEvc3RhZ2luZycsCiAgICAgICAgICAncm0gLXJmICIkU1RBR0lORyI7IG1rZGlyIC1wICIkU1RBR0lORyInLAogICAgICAgICAgJ2N1cmwgLWZMICJodHRwczovL2FwaS5hZG9wdGl1bS5uZXQvdjMvYmluYXJ5L2xhdGVzdC8yMS9nYS9saW51eC94NjQvamRrL2hvdHNwb3Qvbm9ybWFsL2VjbGlwc2U/cHJvamVjdD1qZGsiIC1vIC90bXAvamRrMjEudGFyLmd6JywKICAgICAgICAgICdTSVpFPSQod2MgLWMgPCAvdG1wL2pkazIxLnRhci5neiB8IHRyIC1kICIgIiknLAogICAgICAgICAgJ2lmIFsgIiRTSVpFIiAtbHQgNTAwMDAwMDAgXTsgdGhlbiBlY2hvICJiYWQgamRrICRTSVpFIjsgZXhpdCAxOyBmaScsCiAgICAgICAgICAndGFyIC14emYgL3RtcC9qZGsyMS50YXIuZ3ogLUMgIiRTVEFHSU5HIicsCiAgICAgICAgICAnSU5ORVI9JChmaW5kICIkU1RBR0lORyIgLW1heGRlcHRoIDEgLXR5cGUgZCAtbmFtZSAiamRrLSoiIHwgaGVhZCAtMSknLAogICAgICAgICAgJ2lmIFsgLXogIiRJTk5FUiIgXSB8fCBbICEgLXggIiRJTk5FUi9iaW4vamF2YSIgXTsgdGhlbiBlY2hvICJleHRyYWN0IGZhaWwiOyBleGl0IDE7IGZpJywKICAgICAgICAgICdERVNUPSIvb3B0L2phdmEvJChiYXNlbmFtZSAiJElOTkVSIikiJywKICAgICAgICAgICdybSAtcmYgIiRERVNUIjsgbXYgIiRJTk5FUiIgIiRERVNUIicsCiAgICAgICAgICAnbG4gLXNmbiAiJERFU1QiIC9vcHQvamF2YS9jdXJyZW50JywKICAgICAgICAgICdlY2hvICIkTEFURVNUIiA+IC9vcHQvamF2YS92ZXJzaW9uJywKICAgICAgICAgICdybSAtcmYgIiRTVEFHSU5HIiAvdG1wL2pkazIxLnRhci5neicsCiAgICAgICAgICAnL29wdC9qYXZhL2N1cnJlbnQvYmluL2phdmEgLXZlcnNpb24gMj4mMSB8IGhlYWQgLTMnLAogICAgICAgICAgJ3BtMiByZXN0YXJ0IGplbmtpbnMgLS11cGRhdGUtZW52IHx8IHRydWUnLAogICAgICAgICAgJ2VjaG8gImphdmEgMjEgc3dpdGNoZWQgKyBwbTIgcmVzdGFydCBqZW5raW5zIicsCiAgICAgICAgXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAndXBkYXRlIHR1bm5lbCcpIHsKICAgICAgICBsaW5lcyA9IHBtMlByZWZpeCgpLmNvbmNhdChbCiAgICAgICAgICAnc2V0IC1lJywKICAgICAgICAgICdlY2hvICI9PT0gdXBkYXRlIHR1bm5lbCA9PT0iJywKICAgICAgICAgICdMQVRFU1Q9JChjdXJsIC1zIGh0dHBzOi8vYXBpLmdpdGh1Yi5jb20vcmVwb3MvY2xvdWRmbGFyZS9jbG91ZGZsYXJlZC9yZWxlYXNlcy9sYXRlc3QgfCBncmVwICJcXCJ0YWdfbmFtZVxcIjoiIHwgaGVhZCAtMSB8IGN1dCAtZCJcXCIiIC1mNCknLAogICAgICAgICAgJ0xPQ0FMPSQoY2F0IC9vcHQvdHVubmVsL3ZlcnNpb24gMj4vZGV2L251bGwgfHwgZWNobyBub25lKScsCiAgICAgICAgICAnZWNobyAiTG9jYWw9JExPQ0FMIFJlbW90ZT0kTEFURVNUIicsCiAgICAgICAgICAnaWYgWyAteiAiJExBVEVTVCIgXTsgdGhlbiBlY2hvICJmZXRjaCBmYWlsIjsgZXhpdCAxOyBmaScsCiAgICAgICAgICAnaWYgWyAiJExBVEVTVCIgPSAiJExPQ0FMIiBdOyB0aGVuIGVjaG8gImFscmVhZHkgJExBVEVTVCI7IGV4aXQgMDsgZmknLAogICAgICAgICAgJ2N1cmwgLWZzU0wgaHR0cHM6Ly9naXRodWIuY29tL2Nsb3VkZmxhcmUvY2xvdWRmbGFyZWQvcmVsZWFzZXMvbGF0ZXN0L2Rvd25sb2FkL2Nsb3VkZmxhcmVkLWxpbnV4LWFtZDY0IC1vIC90bXAvY2xvdWRmbGFyZWQubmV3JywKICAgICAgICAgICdjaG1vZCAreCAvdG1wL2Nsb3VkZmxhcmVkLm5ldycsCiAgICAgICAgICAnbXYgL3RtcC9jbG91ZGZsYXJlZC5uZXcgL29wdC90dW5uZWwvY2xvdWRmbGFyZWQnLAogICAgICAgICAgJ2VjaG8gIiRMQVRFU1QiID4gL29wdC90dW5uZWwvdmVyc2lvbicsCiAgICAgICAgICAnaWYgcG0yIGRlc2NyaWJlIHR1bm5lbCA+L2Rldi9udWxsIDI+JjE7IHRoZW4gcG0yIHJlc3RhcnQgdHVubmVsIC0tdXBkYXRlLWVudjsgZmknLAogICAgICAgICAgJ2VjaG8gInR1bm5lbCB1cGRhdGVkIicsCiAgICAgICAgXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAncmVzdGFydCBqZW5raW5zJykgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFsncG0yIHJlc3RhcnQgamVua2lucyAtLXVwZGF0ZS1lbnYnLCAnZWNobyBkb25lJ10pOwogICAgICB9IGVsc2UgaWYgKGNtZCA9PT0gJ3N0b3AgamVua2lucycpIHsKICAgICAgICBsaW5lcyA9IHBtMlByZWZpeCgpLmNvbmNhdChbJ3BtMiBzdG9wIGplbmtpbnMnLCAnZWNobyBzdG9wcGVkJ10pOwogICAgICB9IGVsc2UgaWYgKGNtZCA9PT0gJ2plbmtpbnMgbG9nJykgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFsKICAgICAgICAgICdwbTIgbG9ncyBqZW5raW5zIC0tbGluZXMgODAgLS1ub3N0cmVhbSAyPi9kZXYvbnVsbCB8fCB0YWlsIC1uIDgwIC90bXAvamVua2lucy5sb2cgMj4vZGV2L251bGwgfHwgZWNobyAiKG5vIGxvZykiJywKICAgICAgICBdKTsKICAgICAgfSBlbHNlIGlmIChjbWQgPT09ICd0dW5uZWwgbG9nJykgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFsKICAgICAgICAgICdwbTIgbG9ncyB0dW5uZWwgLS1saW5lcyA4MCAtLW5vc3RyZWFtIDI+L2Rldi9udWxsIHx8IHRhaWwgLW4gODAgL3RtcC90dW5uZWwubG9nIDI+L2Rldi9udWxsIHx8IGVjaG8gIihubyBsb2cpIicsCiAgICAgICAgXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAncG0yIGxvZ3MnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWydwbTIgbG9ncyAtLWxpbmVzIDUwIC0tbm9zdHJlYW0nXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kLnN0YXJ0c1dpdGgoJ3BtMiAnKSkgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFtjbWRdKTsKICAgICAgfSBlbHNlIGlmICgvXihsc3xkZnxmcmVlfHBzfHRvcHx1cHRpbWV8d2hvYW1pfGlkfHB3ZHxkdXxjYXQgfHRhaWwgfGhlYWQgfGN1cmwgKS9pLnRlc3QoY21kKSkgewogICAgICAgIGxpbmVzID0gW2NtZF07CiAgICAgIH0gZWxzZSB7CiAgICAgICAgc29ja2V0LmVtaXQoJ2Vycm9yJywgJ1Vua25vd246ICcgKyBjbWQgKyAnIChoZWxwKScpOwogICAgICAgIHNvY2tldC5lbWl0KCdzeXN0ZW0nLCAnW1Byb2Nlc3MgY29tcGxldGVkXScpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBydW5CYXNoKHNvY2tldCwgbGluZXMpOwogICAgfSk7CgogICAgc29ja2V0Lm9uKCdnZXQtc291cmNlLWh0bWwnLCAoKSA9PiBzb2NrZXQuZW1pdCgnc291cmNlLWNvZGUtaHRtbCcsIGZzLnJlYWRGaWxlU3luYyh1aUZpbGVQYXRoLCAndXRmOCcpKSk7CiAgICBzb2NrZXQub24oJ3ByZXZpZXctc291cmNlLWh0bWwnLCAoY29kZSkgPT4geyBwcmV2aWV3SFRNTCA9IGNvZGU7IH0pOwogICAgc29ja2V0Lm9uKCdkZXBsb3ktc291cmNlLWh0bWwnLCAoY29kZSkgPT4gewogICAgICBmcy53cml0ZUZpbGVTeW5jKHVpRmlsZVBhdGgsIGNvZGUpOwogICAgICBzb2NrZXQuZW1pdCgnZGVwbG95LXN1Y2Nlc3MnLCAnaHRtbCcpOwogICAgfSk7CiAgICBzb2NrZXQub24oJ2dldC1zb3VyY2UtanMnLCAoKSA9PiBzb2NrZXQuZW1pdCgnc291cmNlLWNvZGUtanMnLCBmcy5yZWFkRmlsZVN5bmMobG9naWNGaWxlUGF0aCwgJ3V0ZjgnKSkpOwogICAgc29ja2V0Lm9uKCdkZXBsb3ktc291cmNlLWpzJywgKGNvZGUpID0+IHsKICAgICAgZnMud3JpdGVGaWxlU3luYyhsb2dpY0ZpbGVQYXRoLCBjb2RlKTsKICAgICAgcHJvY2Vzcy5lbWl0KCdIT1RfUkVMT0FEX0xPR0lDJyk7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4gc29ja2V0LmVtaXQoJ2RlcGxveS1zdWNjZXNzJywgJ2pzJyksIDUwMCk7CiAgICB9KTsKICB9Cn07Cg==' | base64 -d > /app/logic.js
echo 'Y29uc3QgaHR0cCA9IHJlcXVpcmUoJ2h0dHAnKTsKY29uc3QgeyBTZXJ2ZXIgfSA9IHJlcXVpcmUoJ3NvY2tldC5pbycpOwpsZXQgbG9naWMgPSByZXF1aXJlKCcvYXBwL2xvZ2ljLmpzJyk7CmZ1bmN0aW9uIGxvYWRMb2dpYygpIHsKICB0cnkgewogICAgZGVsZXRlIHJlcXVpcmUuY2FjaGVbcmVxdWlyZS5yZXNvbHZlKCcvYXBwL2xvZ2ljLmpzJyldOwogICAgbG9naWMgPSByZXF1aXJlKCcvYXBwL2xvZ2ljLmpzJyk7CiAgICBjb25zb2xlLmxvZygnW0Jvb3RzdHJhcHBlcl0gcmVsb2FkZWQnKTsKICB9IGNhdGNoIChlKSB7IGNvbnNvbGUuZXJyb3IoZSk7IH0KfQpwcm9jZXNzLm9uKCdIT1RfUkVMT0FEX0xPR0lDJywgbG9hZExvZ2ljKTsKY29uc3Qgc2VydmVyID0gaHR0cC5jcmVhdGVTZXJ2ZXIoKHJlcSwgcmVzKSA9PiB7CiAgdHJ5IHsgbG9naWMuaGFuZGxlSHR0cChyZXEsIHJlcyk7IH0KICBjYXRjaCAoZSkgeyByZXMud3JpdGVIZWFkKDIwMCk7IHJlcy5lbmQoJ0FsaXZlJyk7IH0KfSk7CmNvbnN0IGlvID0gbmV3IFNlcnZlcihzZXJ2ZXIsIHsgY29yczogeyBvcmlnaW46ICcqJyB9IH0pOwppby5vbignY29ubmVjdGlvbicsIChzKSA9PiB7IHRyeSB7IGxvZ2ljLmhhbmRsZVNvY2tldChpbywgcyk7IH0gY2F0Y2ggKGUpIHsgY29uc29sZS5lcnJvcihlKTsgfSB9KTsKY29uc3QgcG9ydCA9IE51bWJlcihwcm9jZXNzLmVudi5QQU5FTF9QT1JUIHx8IDc4NjApOwpzZXJ2ZXIubGlzdGVuKHBvcnQsICcwLjAuMC4wJywgKCkgPT4gY29uc29sZS5sb2coJ1tJbmZvXSBwYW5lbCA6JyArIHBvcnQpKTsKcHJvY2Vzcy5vbigndW5jYXVnaHRFeGNlcHRpb24nLCAoZSkgPT4gY29uc29sZS5lcnJvcihlKSk7CnByb2Nlc3Mub24oJ3VuaGFuZGxlZFJlamVjdGlvbicsIChlKSA9PiBjb25zb2xlLmVycm9yKGUpKTsK' | base64 -d > /app/bootstrapper.js
echo 'IyEvYmluL2Jhc2gKc2V0IC11CmV4cG9ydCBKQVZBX0hPTUU9L29wdC9qYXZhL2N1cnJlbnQKZXhwb3J0IFBBVEg9IiRKQVZBX0hPTUUvYmluOiRQQVRIIgpKQVZBX0JJTj0iJEpBVkFfSE9NRS9iaW4vamF2YSIKWyAteCAiJEpBVkFfQklOIiBdIHx8IEpBVkFfQklOPSQoY29tbWFuZCAtdiBqYXZhKQpXQVI9L29wdC9qZW5raW5zL2plbmtpbnMud2FyCmlmIFsgISAtZiAiJFdBUiIgXSB8fCBbICEgLXMgIiRXQVIiIF07IHRoZW4KICBlY2hvICJbamVua2luc10gbWlzc2luZyB3YXIgJFdBUiIKICBleGl0IDEKZmkKIyDkuozmrKHmoKHpqowgbWFqb3IgdmVyc2lvbgpNQUo9JCgiJEpBVkFfQklOIiAtdmVyc2lvbiAyPiYxIHwgaGVhZCAtMSB8IHNlZCAtbiAncy8uKnZlcnNpb24gIlwoWzAtOV0qXCkuKi9cMS9wJykKaWYgWyAtbiAiJE1BSiIgXSAmJiBbICIkTUFKIiAtbHQgMjEgXTsgdGhlbgogIGVjaG8gIltqZW5raW5zXSBKYXZhICRNQUogPCAyMSwgcmVmdXNlLiBSdW46IHVwZGF0ZSBqYXZhIgogIGV4aXQgMQpmaQpleGVjICIkSkFWQV9CSU4iICR7SkFWQV9PUFRTOi0tRHVzZXIuaG9tZT0vdmFyL2plbmtpbnNfbG9jYWwgLURqYXZhLmlvLnRtcGRpcj0vdmFyL2plbmtpbnNfbG9jYWwvdG1wfSBcCiAgLWphciAiJFdBUiIgXAogIC0taHR0cFBvcnQ9IiR7SkVOS0lOU19IVFRQX1BPUlQ6LTgwODB9IiBcCiAgLS1odHRwTGlzdGVuQWRkcmVzcz0iJHtKRU5LSU5TX0xJU1RFTjotMTI3LjAuMC4xfSIgXAogIC0td2Vicm9vdD0vdmFyL2plbmtpbnNfbG9jYWwvd2FyCg==' | base64 -d > /opt/jenkins/run-jenkins.sh
chmod +x /opt/jenkins/run-jenkins.sh

if [ ! -d /app/node_modules/pm2 ] || [ ! -d /app/node_modules/socket.io ]; then
  echo "[Info] npm install pm2 socket.io"
  npm install --prefix /app pm2 socket.io --omit=dev 2>&1 | tail -8
fi
export PATH="/app/node_modules/.bin:$PATH"
PM2=/app/node_modules/.bin/pm2

echo "[Info] PM2 bring-up..."
$PM2 delete jenkins 2>/dev/null || true
$PM2 delete tunnel 2>/dev/null || true

if [ -x /opt/java/current/bin/java ] && [ -f /opt/jenkins/jenkins.war ]; then
  $PM2 start /opt/jenkins/run-jenkins.sh \
    --name jenkins \
    --interpreter bash \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/jenkins.log \
    --time
else
  echo "[WARN] skip jenkins (need java21 + war)"
  /opt/java/current/bin/java -version 2>&1 | head -1 || true
fi

CF_TOKEN_VAL="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TOKEN:-}}"
if [ -n "$CF_TOKEN_VAL" ] && [ -x /opt/tunnel/cloudflared ]; then
  $PM2 start /opt/tunnel/cloudflared \
    --name tunnel \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/tunnel.log \
    --time \
    -- tunnel --no-autoupdate run --token "$CF_TOKEN_VAL"
else
  echo "[Info] skip tunnel"
fi

$PM2 save 2>/dev/null || true
$PM2 list || true

echo "[Info] panel :${PANEL_PORT} jenkins :${JENKINS_HTTP_PORT} java21+pm2"
exec node /app/bootstrapper.js
