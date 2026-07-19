#!/bin/bash
# Jenkins + Nexus — Debian + PM2 保活（对齐原版）
# 覆盖: https://github.com/XingLingQAQ/HF-Shell/blob/main/Jenkins/startup.sh
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

ensure_jenkins_war || echo "[startup] WARN jenkins download failed"
ensure_cloudflared || echo "[startup] WARN tunnel download failed"

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

# logic / bootstrap / run-jenkins via base64（避免多层 heredoc 截断）
echo 'Y29uc3QgeyBzcGF3biB9ID0gcmVxdWlyZSgnY2hpbGRfcHJvY2VzcycpOwpjb25zdCBmcyA9IHJlcXVpcmUoJ2ZzJyk7CmNvbnN0IHVpRmlsZVBhdGggPSAnL2FwcC90ZXJtaW5hbC11aS5odG1sJzsKY29uc3QgbG9naWNGaWxlUGF0aCA9ICcvYXBwL2xvZ2ljLmpzJzsKbGV0IHByZXZpZXdIVE1MID0gZnMucmVhZEZpbGVTeW5jKHVpRmlsZVBhdGgsICd1dGY4Jyk7Cgpjb25zdCBDWUJFUl80MDQgPSAnPCFET0NUWVBFIGh0bWw+PGh0bWwgbGFuZz0iemgtQ04iPjxoZWFkPjxtZXRhIGNoYXJzZXQ9IlVURi04Ij48dGl0bGU+NDA0PC90aXRsZT4nCiAgKyAnPHN0eWxlPmJvZHl7YmFja2dyb3VuZDojMDUwNTA1O2NvbG9yOiMxMGI5ODE7Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2FsaWduLWl0ZW1zOmNlbnRlcjtoZWlnaHQ6MTAwdmg7bWFyZ2luOjB9JwogICsgJy5ib3h7dGV4dC1hbGlnbjpjZW50ZXI7Ym9yZGVyOjFweCBzb2xpZCAjMjcyNzJhO3BhZGRpbmc6M3JlbTtib3JkZXItcmFkaXVzOjEycHg7YmFja2dyb3VuZDojMGEwYTBhfScKICArICdoMXtmb250LXNpemU6NHJlbTttYXJnaW46MH1we2NvbG9yOiNhMWExYWF9YXtjb2xvcjojM2I4MmY2O2JvcmRlcjoxcHggc29saWQgIzNiODJmNjtwYWRkaW5nOjEwcHggMjBweDtkaXNwbGF5OmlubGluZS1ibG9jazttYXJnaW4tdG9wOjI0cHg7dGV4dC1kZWNvcmF0aW9uOm5vbmV9JwogICsgJzwvc3R5bGU+PC9oZWFkPjxib2R5PjxkaXYgY2xhc3M9ImJveCI+PGgxPjQwNDwvaDE+PHA+Pl8gRU5EUE9JTlRfTk9UX0ZPVU5EPC9wPjxhIGhyZWY9Ii8iPlsgUmV0dXJuIF08L2E+PC9kaXY+PC9ib2R5PjwvaHRtbD4nOwoKZnVuY3Rpb24gcGF0aE9ubHkocmVxKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHUgPSBuZXcgVVJMKHJlcS51cmwsICdodHRwOi8vJyArIChyZXEuaGVhZGVycy5ob3N0IHx8ICdsb2NhbGhvc3QnKSk7CiAgICBsZXQgcCA9IHUucGF0aG5hbWUgfHwgJy8nOwogICAgaWYgKHAubGVuZ3RoID4gMSkgcCA9IHAucmVwbGFjZSgvXC8rJC8sICcnKTsKICAgIHJldHVybiBwIHx8ICcvJzsKICB9IGNhdGNoIChlKSB7CiAgICByZXR1cm4gU3RyaW5nKHJlcS51cmwgfHwgJy8nKS5zcGxpdCgnPycpWzBdIHx8ICcvJzsKICB9Cn0KCmZ1bmN0aW9uIHBtMlByZWZpeCgpIHsKICByZXR1cm4gWwogICAgJ2V4cG9ydCBQTTJfSE9NRT0iJHtQTTJfSE9NRTotL3Zhci9qZW5raW5zX2xvY2FsLy5wbTJ9IicsCiAgICAnZXhwb3J0IFBBVEg9Ii9hcHAvbm9kZV9tb2R1bGVzLy5iaW46JFBBVEgiJywKICAgICdleHBvcnQgSkFWQV9IT01FPS9vcHQvamF2YS9jdXJyZW50JywKICAgICdleHBvcnQgUEFUSD0iJEpBVkFfSE9NRS9iaW46JFBBVEgiJywKICBdOwp9CgpmdW5jdGlvbiBydW5CYXNoKHNvY2tldCwgbGluZXMpIHsKICBjb25zdCBwcm9jID0gc3Bhd24oJ2Jhc2gnLCBbJy1jJywgbGluZXMuam9pbignXG4nKV0sIHsgY3dkOiAnL2FwcCcgfSk7CiAgcHJvYy5zdGRvdXQub24oJ2RhdGEnLCAoZCkgPT4gc29ja2V0LmVtaXQoJ291dHB1dCcsIGQudG9TdHJpbmcoKSkpOwogIHByb2Muc3RkZXJyLm9uKCdkYXRhJywgKGQpID0+IHNvY2tldC5lbWl0KCdvdXRwdXQnLCBkLnRvU3RyaW5nKCkpKTsKICBwcm9jLm9uKCdjbG9zZScsIChjb2RlKSA9PiB7CiAgICBpZiAoY29kZSA9PT0gMCkgc29ja2V0LmVtaXQoJ3N5c3RlbScsICdbUHJvY2VzcyBjb21wbGV0ZWRdJyk7CiAgICBlbHNlIHNvY2tldC5lbWl0KCdlcnJvcicsICdbZXhpdCAnICsgY29kZSArICddJyk7CiAgfSk7Cn0KCm1vZHVsZS5leHBvcnRzID0gewogIGhhbmRsZUh0dHA6IGZ1bmN0aW9uIChyZXEsIHJlcykgewogICAgY29uc3QgcGF0aCA9IHBhdGhPbmx5KHJlcSk7CiAgICBpZiAocGF0aCA9PT0gJy8nIHx8IHBhdGggPT09ICcvaW5kZXguaHRtbCcpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgICByZXMuZW5kKGZzLnJlYWRGaWxlU3luYyh1aUZpbGVQYXRoLCAndXRmOCcpKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHBhdGggPT09ICcvcHJldmlldycpIHsKICAgICAgcmVzLndyaXRlSGVhZCgyMDAsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgICByZXMuZW5kKHByZXZpZXdIVE1MKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYgKHBhdGggPT09ICcvYXBpL3BpbmcnIHx8IHBhdGggPT09ICcvaGVhbHRoJyB8fCBwYXRoID09PSAnL2hlYWx0aHonKSB7CiAgICAgIHJlcy53cml0ZUhlYWQoMjAwLCB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSk7CiAgICAgIHJlcy5lbmQoSlNPTi5zdHJpbmdpZnkoeyBzdGF0dXM6ICdhbGl2ZScsIHRzOiBEYXRlLm5vdygpIH0pKTsKICAgICAgcmV0dXJuOwogICAgfQogICAgcmVzLndyaXRlSGVhZCg0MDQsIHsgJ0NvbnRlbnQtVHlwZSc6ICd0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgnIH0pOwogICAgcmVzLmVuZChDWUJFUl80MDQpOwogIH0sCgogIGhhbmRsZVNvY2tldDogZnVuY3Rpb24gKGlvLCBzb2NrZXQpIHsKICAgIHNvY2tldC5yZW1vdmVBbGxMaXN0ZW5lcnMoKTsKICAgIHNvY2tldC5vbignY29tbWFuZCcsIChjbWQpID0+IHsKICAgICAgaWYgKGNtZCA9PT0gJ2hlbHAnKSB7CiAgICAgICAgc29ja2V0LmVtaXQoJ291dHB1dCcsCiAgICAgICAgICAnc3RhdHVzIHwgcG0yIHN0YXR1cyB8IHBtMiBsb2dzXG4nICsKICAgICAgICAgICd1cGRhdGUgamVua2lucyB8IHVwZGF0ZSBqYXZhIHwgdXBkYXRlIHR1bm5lbFxuJyArCiAgICAgICAgICAncmVzdGFydCBqZW5raW5zIHwgc3RvcCBqZW5raW5zIHwgamVua2lucyBsb2cgfCB0dW5uZWwgbG9nIHwgY2xlYXJcbicKICAgICAgICApOwogICAgICAgIHNvY2tldC5lbWl0KCdzeXN0ZW0nLCAnW1Byb2Nlc3MgY29tcGxldGVkXScpOwogICAgICAgIHJldHVybjsKICAgICAgfQoKICAgICAgbGV0IGxpbmVzID0gbnVsbDsKCiAgICAgIGlmIChjbWQgPT09ICdzdGF0dXMnIHx8IGNtZCA9PT0gJ3BtMiBzdGF0dXMnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWwogICAgICAgICAgJ2VjaG8gIj09PSBzdGF0dXMgKFBNMikgPT09IicsCiAgICAgICAgICAnZWNobyAtbiAiSmF2YTogIjsgamF2YSAtdmVyc2lvbiAyPiYxIHwgaGVhZCAtMScsCiAgICAgICAgICAnZWNobyAtbiAiSkFWQV9IT01FPSI7IGVjaG8gIiRKQVZBX0hPTUUiJywKICAgICAgICAgICdlY2hvIC1uICJKYXZhIHZlcjogIjsgY2F0IC9vcHQvamF2YS92ZXJzaW9uIDI+L2Rldi9udWxsIHx8IGVjaG8gbm9uZScsCiAgICAgICAgICAnZWNobyAtbiAiSmVua2lucyB3YXI6ICI7IGxzIC1saCAvb3B0L2plbmtpbnMvamVua2lucy53YXIgMj4vZGV2L251bGwgfHwgZWNobyBtaXNzaW5nJywKICAgICAgICAgICdlY2hvIC1uICJKZW5raW5zIHZlcjogIjsgY2F0IC9vcHQvamVua2lucy92ZXJzaW9uIDI+L2Rldi9udWxsIHx8IGVjaG8gbm9uZScsCiAgICAgICAgICAnZWNobyAtbiAiVHVubmVsOiAiOyAvb3B0L3R1bm5lbC9jbG91ZGZsYXJlZCAtLXZlcnNpb24gMj4vZGV2L251bGwgfCBoZWFkIC0xIHx8IGVjaG8gbWlzc2luZycsCiAgICAgICAgICAnZWNobyAtbiAiVHVubmVsIHZlcjogIjsgY2F0IC9vcHQvdHVubmVsL3ZlcnNpb24gMj4vZGV2L251bGwgfHwgZWNobyBub25lJywKICAgICAgICAgICdlY2hvIC1uICJKZW5raW5zIDo4MDgwOiAiOyBjdXJsIC1mc1MgLW8gL2Rldi9udWxsIC1tIDIgLXcgIiV7aHR0cF9jb2RlfSIgaHR0cDovLzEyNy4wLjAuMTo4MDgwL2xvZ2luIDI+L2Rldi9udWxsIHx8IGVjaG8gZG93bjsgZWNobycsCiAgICAgICAgICAnZWNobyAiLS0tIHBtMiBsaXN0IC0tLSInLAogICAgICAgICAgJ3BtMiBsaXN0JywKICAgICAgICBdKTsKICAgICAgfSBlbHNlIGlmIChjbWQgPT09ICd1cGRhdGUgamVua2lucycpIHsKICAgICAgICBsaW5lcyA9IHBtMlByZWZpeCgpLmNvbmNhdChbCiAgICAgICAgICAnc2V0IC1lJywKICAgICAgICAgICdlY2hvICI9PT0gdXBkYXRlIGplbmtpbnMgPT09IicsCiAgICAgICAgICAnTEFURVNUPSQoY3VybCAtZnNTTCBodHRwczovL3VwZGF0ZXMuamVua2lucy5pby9zdGFibGUvbGF0ZXN0Q29yZS50eHQgfCB0ciAtZCAiXFxyIiB8IGhlYWQgLTEpJywKICAgICAgICAgICdMT0NBTD0kKGNhdCAvb3B0L2plbmtpbnMvdmVyc2lvbiAyPi9kZXYvbnVsbCB8fCBlY2hvIG5vbmUpJywKICAgICAgICAgICdlY2hvICJMb2NhbD0kTE9DQUwgUmVtb3RlPSRMQVRFU1QiJywKICAgICAgICAgICdpZiBbIC16ICIkTEFURVNUIiBdOyB0aGVuIGVjaG8gImZldGNoIGZhaWwiOyBleGl0IDE7IGZpJywKICAgICAgICAgICdpZiBbICIkTEFURVNUIiA9ICIkTE9DQUwiIF07IHRoZW4gZWNobyAiYWxyZWFkeSAkTEFURVNUIjsgZXhpdCAwOyBmaScsCiAgICAgICAgICAnY3VybCAtZkwgImh0dHBzOi8vZ2V0LmplbmtpbnMuaW8vd2FyLXN0YWJsZS8kTEFURVNUL2plbmtpbnMud2FyIiAtbyAvdG1wL2plbmtpbnMud2FyLm5ldycsCiAgICAgICAgICAnU0laRT0kKHdjIC1jIDwgL3RtcC9qZW5raW5zLndhci5uZXcgfCB0ciAtZCAiICIpJywKICAgICAgICAgICdpZiBbICIkU0laRSIgLWx0IDEwMDAwMDAgXTsgdGhlbiBlY2hvICJiYWQgc2l6ZSAkU0laRSI7IGV4aXQgMTsgZmknLAogICAgICAgICAgJ212IC90bXAvamVua2lucy53YXIubmV3IC9vcHQvamVua2lucy9qZW5raW5zLndhcicsCiAgICAgICAgICAnZWNobyAiJExBVEVTVCIgPiAvb3B0L2plbmtpbnMvdmVyc2lvbicsCiAgICAgICAgICAncG0yIHJlc3RhcnQgamVua2lucyAtLXVwZGF0ZS1lbnYnLAogICAgICAgICAgJ2VjaG8gIndhciB1cGRhdGVkICsgcG0yIHJlc3RhcnQgamVua2lucyInLAogICAgICAgIF0pOwogICAgICB9IGVsc2UgaWYgKGNtZCA9PT0gJ3VwZGF0ZSBqYXZhJykgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFsKICAgICAgICAgICdzZXQgLWUnLAogICAgICAgICAgJ2VjaG8gIj09PSB1cGRhdGUgamF2YSAoVGVtdXJpbiAxNykgPT09IicsCiAgICAgICAgICAnTE9DQUw9JChjYXQgL29wdC9qYXZhL3ZlcnNpb24gMj4vZGV2L251bGwgfHwgZWNobyBub25lKScsCiAgICAgICAgICAnTUVUQT0kKGN1cmwgLWZzU0wgImh0dHBzOi8vYXBpLmFkb3B0aXVtLm5ldC92My9pbmZvL3JlbGVhc2VfdmVyc2lvbnM/cmVsZWFzZV90eXBlPWdhJnZlcnNpb249JTVCMTclMkMxOCUyOSZvcz1saW51eCZhcmNoPXg2NCZpbWFnZV90eXBlPWpkayZqdm1faW1wbD1ob3RzcG90JnBhZ2Vfc2l6ZT0xJnNvcnRfb3JkZXI9REVTQyIgfHwgdHJ1ZSknLAogICAgICAgICAgJ0xBVEVTVD0kKGVjaG8gIiRNRVRBIiB8IHRyICIsIiAiXFxuIiB8IHNlZCAtbiAicy8uKlxcIm9wZW5qZGtfdmVyc2lvblxcIjpcXCJcXChbXlxcIl0qXFwpXFwiLiovXFwxL3AiIHwgaGVhZCAtMSknLAogICAgICAgICAgJ2lmIFsgLXogIiRMQVRFU1QiIF07IHRoZW4gTEFURVNUPSQoZWNobyAiJE1FVEEiIHwgdHIgIiwiICJcXG4iIHwgc2VkIC1uICJzLy4qXFwic2VtdmVyXFwiOlxcIlxcKFteXFwiXSpcXClcXCIuKi9cXDEvcCIgfCBoZWFkIC0xKTsgZmknLAogICAgICAgICAgJ2VjaG8gIkxvY2FsPSRMT0NBTCBSZW1vdGU9JExBVEVTVCInLAogICAgICAgICAgJ2lmIFsgLXogIiRMQVRFU1QiIF07IHRoZW4gZWNobyAiQWRvcHRpdW0gZmFpbCI7IGV4aXQgMTsgZmknLAogICAgICAgICAgJ2lmIFsgIiRMQVRFU1QiID0gIiRMT0NBTCIgXSAmJiBbIC14IC9vcHQvamF2YS9jdXJyZW50L2Jpbi9qYXZhIF07IHRoZW4gZWNobyAiYWxyZWFkeSAkTEFURVNUIjsgZXhpdCAwOyBmaScsCiAgICAgICAgICAnU1RBR0lORz0vb3B0L2phdmEvc3RhZ2luZycsCiAgICAgICAgICAncm0gLXJmICIkU1RBR0lORyI7IG1rZGlyIC1wICIkU1RBR0lORyInLAogICAgICAgICAgJ2N1cmwgLWZMICJodHRwczovL2FwaS5hZG9wdGl1bS5uZXQvdjMvYmluYXJ5L2xhdGVzdC8xNy9nYS9saW51eC94NjQvamRrL2hvdHNwb3Qvbm9ybWFsL2VjbGlwc2U/cHJvamVjdD1qZGsiIC1vIC90bXAvamRrMTcudGFyLmd6JywKICAgICAgICAgICdTSVpFPSQod2MgLWMgPCAvdG1wL2pkazE3LnRhci5neiB8IHRyIC1kICIgIiknLAogICAgICAgICAgJ2lmIFsgIiRTSVpFIiAtbHQgNTAwMDAwMDAgXTsgdGhlbiBlY2hvICJiYWQgamRrICRTSVpFIjsgZXhpdCAxOyBmaScsCiAgICAgICAgICAndGFyIC14emYgL3RtcC9qZGsxNy50YXIuZ3ogLUMgIiRTVEFHSU5HIicsCiAgICAgICAgICAnSU5ORVI9JChmaW5kICIkU1RBR0lORyIgLW1heGRlcHRoIDEgLXR5cGUgZCAtbmFtZSAiamRrLSoiIHwgaGVhZCAtMSknLAogICAgICAgICAgJ2lmIFsgLXogIiRJTk5FUiIgXSB8fCBbICEgLXggIiRJTk5FUi9iaW4vamF2YSIgXTsgdGhlbiBlY2hvICJleHRyYWN0IGZhaWwiOyBleGl0IDE7IGZpJywKICAgICAgICAgICdERVNUPSIvb3B0L2phdmEvJChiYXNlbmFtZSAiJElOTkVSIikiJywKICAgICAgICAgICdybSAtcmYgIiRERVNUIjsgbXYgIiRJTk5FUiIgIiRERVNUIicsCiAgICAgICAgICAnbG4gLXNmbiAiJERFU1QiIC9vcHQvamF2YS9jdXJyZW50JywKICAgICAgICAgICdlY2hvICIkTEFURVNUIiA+IC9vcHQvamF2YS92ZXJzaW9uJywKICAgICAgICAgICdybSAtcmYgIiRTVEFHSU5HIiAvdG1wL2pkazE3LnRhci5neicsCiAgICAgICAgICAnL29wdC9qYXZhL2N1cnJlbnQvYmluL2phdmEgLXZlcnNpb24gMj4mMSB8IGhlYWQgLTMnLAogICAgICAgICAgJ3BtMiByZXN0YXJ0IGplbmtpbnMgLS11cGRhdGUtZW52JywKICAgICAgICAgICdlY2hvICJqYXZhIHN3aXRjaGVkICsgcG0yIHJlc3RhcnQgamVua2lucyInLAogICAgICAgIF0pOwogICAgICB9IGVsc2UgaWYgKGNtZCA9PT0gJ3VwZGF0ZSB0dW5uZWwnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWwogICAgICAgICAgJ3NldCAtZScsCiAgICAgICAgICAnZWNobyAiPT09IHVwZGF0ZSB0dW5uZWwgPT09IicsCiAgICAgICAgICAnTEFURVNUPSQoY3VybCAtcyBodHRwczovL2FwaS5naXRodWIuY29tL3JlcG9zL2Nsb3VkZmxhcmUvY2xvdWRmbGFyZWQvcmVsZWFzZXMvbGF0ZXN0IHwgZ3JlcCAiXFwidGFnX25hbWVcXCI6IiB8IGhlYWQgLTEgfCBjdXQgLWQiXFwiIiAtZjQpJywKICAgICAgICAgICdMT0NBTD0kKGNhdCAvb3B0L3R1bm5lbC92ZXJzaW9uIDI+L2Rldi9udWxsIHx8IGVjaG8gbm9uZSknLAogICAgICAgICAgJ2VjaG8gIkxvY2FsPSRMT0NBTCBSZW1vdGU9JExBVEVTVCInLAogICAgICAgICAgJ2lmIFsgLXogIiRMQVRFU1QiIF07IHRoZW4gZWNobyAiZmV0Y2ggZmFpbCI7IGV4aXQgMTsgZmknLAogICAgICAgICAgJ2lmIFsgIiRMQVRFU1QiID0gIiRMT0NBTCIgXTsgdGhlbiBlY2hvICJhbHJlYWR5ICRMQVRFU1QiOyBleGl0IDA7IGZpJywKICAgICAgICAgICdjdXJsIC1mc1NMIGh0dHBzOi8vZ2l0aHViLmNvbS9jbG91ZGZsYXJlL2Nsb3VkZmxhcmVkL3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9jbG91ZGZsYXJlZC1saW51eC1hbWQ2NCAtbyAvdG1wL2Nsb3VkZmxhcmVkLm5ldycsCiAgICAgICAgICAnY2htb2QgK3ggL3RtcC9jbG91ZGZsYXJlZC5uZXcnLAogICAgICAgICAgJ212IC90bXAvY2xvdWRmbGFyZWQubmV3IC9vcHQvdHVubmVsL2Nsb3VkZmxhcmVkJywKICAgICAgICAgICdlY2hvICIkTEFURVNUIiA+IC9vcHQvdHVubmVsL3ZlcnNpb24nLAogICAgICAgICAgJ2lmIHBtMiBkZXNjcmliZSB0dW5uZWwgPi9kZXYvbnVsbCAyPiYxOyB0aGVuIHBtMiByZXN0YXJ0IHR1bm5lbCAtLXVwZGF0ZS1lbnY7IGZpJywKICAgICAgICAgICdlY2hvICJ0dW5uZWwgdXBkYXRlZCArIHBtMiByZXN0YXJ0IicsCiAgICAgICAgXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAncmVzdGFydCBqZW5raW5zJykgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFsncG0yIHJlc3RhcnQgamVua2lucyAtLXVwZGF0ZS1lbnYnLCAnZWNobyBkb25lJ10pOwogICAgICB9IGVsc2UgaWYgKGNtZCA9PT0gJ3N0b3AgamVua2lucycpIHsKICAgICAgICBsaW5lcyA9IHBtMlByZWZpeCgpLmNvbmNhdChbJ3BtMiBzdG9wIGplbmtpbnMnLCAnZWNobyBzdG9wcGVkJ10pOwogICAgICB9IGVsc2UgaWYgKGNtZCA9PT0gJ2plbmtpbnMgbG9nJykgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFsncG0yIGxvZ3MgamVua2lucyAtLWxpbmVzIDgwIC0tbm9zdHJlYW0nXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAndHVubmVsIGxvZycpIHsKICAgICAgICBsaW5lcyA9IHBtMlByZWZpeCgpLmNvbmNhdChbJ3BtMiBsb2dzIHR1bm5lbCAtLWxpbmVzIDgwIC0tbm9zdHJlYW0nXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kID09PSAncG0yIGxvZ3MnKSB7CiAgICAgICAgbGluZXMgPSBwbTJQcmVmaXgoKS5jb25jYXQoWydwbTIgbG9ncyAtLWxpbmVzIDUwIC0tbm9zdHJlYW0nXSk7CiAgICAgIH0gZWxzZSBpZiAoY21kLnN0YXJ0c1dpdGgoJ3BtMiAnKSkgewogICAgICAgIGxpbmVzID0gcG0yUHJlZml4KCkuY29uY2F0KFtjbWRdKTsKICAgICAgfSBlbHNlIGlmICgvXihsc3xkZnxmcmVlfHBzfHRvcHx1cHRpbWV8d2hvYW1pfGlkfHB3ZHxkdXxjYXQgfHRhaWwgfGhlYWQgfGN1cmwgKS9pLnRlc3QoY21kKSkgewogICAgICAgIGxpbmVzID0gW2NtZF07CiAgICAgIH0gZWxzZSB7CiAgICAgICAgc29ja2V0LmVtaXQoJ2Vycm9yJywgJ1Vua25vd246ICcgKyBjbWQgKyAnIChoZWxwKScpOwogICAgICAgIHNvY2tldC5lbWl0KCdzeXN0ZW0nLCAnW1Byb2Nlc3MgY29tcGxldGVkXScpOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBydW5CYXNoKHNvY2tldCwgbGluZXMpOwogICAgfSk7CgogICAgc29ja2V0Lm9uKCdnZXQtc291cmNlLWh0bWwnLCAoKSA9PiBzb2NrZXQuZW1pdCgnc291cmNlLWNvZGUtaHRtbCcsIGZzLnJlYWRGaWxlU3luYyh1aUZpbGVQYXRoLCAndXRmOCcpKSk7CiAgICBzb2NrZXQub24oJ3ByZXZpZXctc291cmNlLWh0bWwnLCAoY29kZSkgPT4geyBwcmV2aWV3SFRNTCA9IGNvZGU7IH0pOwogICAgc29ja2V0Lm9uKCdkZXBsb3ktc291cmNlLWh0bWwnLCAoY29kZSkgPT4gewogICAgICBmcy53cml0ZUZpbGVTeW5jKHVpRmlsZVBhdGgsIGNvZGUpOwogICAgICBzb2NrZXQuZW1pdCgnZGVwbG95LXN1Y2Nlc3MnLCAnaHRtbCcpOwogICAgfSk7CiAgICBzb2NrZXQub24oJ2dldC1zb3VyY2UtanMnLCAoKSA9PiBzb2NrZXQuZW1pdCgnc291cmNlLWNvZGUtanMnLCBmcy5yZWFkRmlsZVN5bmMobG9naWNGaWxlUGF0aCwgJ3V0ZjgnKSkpOwogICAgc29ja2V0Lm9uKCdkZXBsb3ktc291cmNlLWpzJywgKGNvZGUpID0+IHsKICAgICAgZnMud3JpdGVGaWxlU3luYyhsb2dpY0ZpbGVQYXRoLCBjb2RlKTsKICAgICAgcHJvY2Vzcy5lbWl0KCdIT1RfUkVMT0FEX0xPR0lDJyk7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4gc29ja2V0LmVtaXQoJ2RlcGxveS1zdWNjZXNzJywgJ2pzJyksIDUwMCk7CiAgICB9KTsKICB9Cn07Cg==' | base64 -d > /app/logic.js
echo 'Y29uc3QgaHR0cCA9IHJlcXVpcmUoJ2h0dHAnKTsKY29uc3QgeyBTZXJ2ZXIgfSA9IHJlcXVpcmUoJ3NvY2tldC5pbycpOwpsZXQgbG9naWMgPSByZXF1aXJlKCcvYXBwL2xvZ2ljLmpzJyk7CmZ1bmN0aW9uIGxvYWRMb2dpYygpIHsKICB0cnkgewogICAgZGVsZXRlIHJlcXVpcmUuY2FjaGVbcmVxdWlyZS5yZXNvbHZlKCcvYXBwL2xvZ2ljLmpzJyldOwogICAgbG9naWMgPSByZXF1aXJlKCcvYXBwL2xvZ2ljLmpzJyk7CiAgICBjb25zb2xlLmxvZygnW0Jvb3RzdHJhcHBlcl0gcmVsb2FkZWQnKTsKICB9IGNhdGNoIChlKSB7IGNvbnNvbGUuZXJyb3IoZSk7IH0KfQpwcm9jZXNzLm9uKCdIT1RfUkVMT0FEX0xPR0lDJywgbG9hZExvZ2ljKTsKY29uc3Qgc2VydmVyID0gaHR0cC5jcmVhdGVTZXJ2ZXIoKHJlcSwgcmVzKSA9PiB7CiAgdHJ5IHsgbG9naWMuaGFuZGxlSHR0cChyZXEsIHJlcyk7IH0KICBjYXRjaCAoZSkgeyByZXMud3JpdGVIZWFkKDIwMCk7IHJlcy5lbmQoJ0FsaXZlJyk7IH0KfSk7CmNvbnN0IGlvID0gbmV3IFNlcnZlcihzZXJ2ZXIsIHsgY29yczogeyBvcmlnaW46ICcqJyB9IH0pOwppby5vbignY29ubmVjdGlvbicsIChzKSA9PiB7IHRyeSB7IGxvZ2ljLmhhbmRsZVNvY2tldChpbywgcyk7IH0gY2F0Y2ggKGUpIHsgY29uc29sZS5lcnJvcihlKTsgfSB9KTsKY29uc3QgcG9ydCA9IE51bWJlcihwcm9jZXNzLmVudi5QQU5FTF9QT1JUIHx8IDc4NjApOwpzZXJ2ZXIubGlzdGVuKHBvcnQsICcwLjAuMC4wJywgKCkgPT4gY29uc29sZS5sb2coJ1tJbmZvXSBwYW5lbCA6JyArIHBvcnQpKTsKcHJvY2Vzcy5vbigndW5jYXVnaHRFeGNlcHRpb24nLCAoZSkgPT4gY29uc29sZS5lcnJvcihlKSk7CnByb2Nlc3Mub24oJ3VuaGFuZGxlZFJlamVjdGlvbicsIChlKSA9PiBjb25zb2xlLmVycm9yKGUpKTsK' | base64 -d > /app/bootstrapper.js
echo 'IyEvYmluL2Jhc2gKc2V0IC11CmV4cG9ydCBKQVZBX0hPTUU9L29wdC9qYXZhL2N1cnJlbnQKZXhwb3J0IFBBVEg9IiRKQVZBX0hPTUUvYmluOiRQQVRIIgpKQVZBX0JJTj0iJEpBVkFfSE9NRS9iaW4vamF2YSIKWyAteCAiJEpBVkFfQklOIiBdIHx8IEpBVkFfQklOPSQoY29tbWFuZCAtdiBqYXZhKQpXQVI9L29wdC9qZW5raW5zL2plbmtpbnMud2FyCmlmIFsgISAtZiAiJFdBUiIgXSB8fCBbICEgLXMgIiRXQVIiIF07IHRoZW4KICBlY2hvICJbamVua2luc10gbWlzc2luZyB3YXIgJFdBUiIKICBleGl0IDEKZmkKZXhlYyAiJEpBVkFfQklOIiAke0pBVkFfT1BUUzotLUR1c2VyLmhvbWU9L3Zhci9qZW5raW5zX2xvY2FsIC1EamF2YS5pby50bXBkaXI9L3Zhci9qZW5raW5zX2xvY2FsL3RtcH0gXAogIC1qYXIgIiRXQVIiIFwKICAtLWh0dHBQb3J0PSIke0pFTktJTlNfSFRUUF9QT1JUOi04MDgwfSIgXAogIC0taHR0cExpc3RlbkFkZHJlc3M9IiR7SkVOS0lOU19MSVNURU46LTEyNy4wLjAuMX0iIFwKICAtLXdlYnJvb3Q9L3Zhci9qZW5raW5zX2xvY2FsL3dhcgo=' | base64 -d > /opt/jenkins/run-jenkins.sh
chmod +x /opt/jenkins/run-jenkins.sh

# npm
if [ ! -d /app/node_modules/pm2 ] || [ ! -d /app/node_modules/socket.io ]; then
  echo "[Info] npm install pm2 socket.io"
  npm install --prefix /app pm2 socket.io --omit=dev 2>&1 | tail -8
fi
export PATH="/app/node_modules/.bin:$PATH"
PM2=/app/node_modules/.bin/pm2

# PM2 保活
echo "[Info] PM2 bring-up..."
$PM2 delete jenkins 2>/dev/null || true
$PM2 delete tunnel 2>/dev/null || true

if [ -f /opt/jenkins/jenkins.war ]; then
  $PM2 start /opt/jenkins/run-jenkins.sh \
    --name jenkins \
    --interpreter bash \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/jenkins.log \
    --time
else
  echo "[WARN] no jenkins.war"
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

echo "[Info] panel :${PANEL_PORT} jenkins :${JENKINS_HTTP_PORT} (PM2)"
exec node /app/bootstrapper.js
