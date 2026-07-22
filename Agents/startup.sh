#!/bin/bash
# ============================================================
# Jenkins agent + Gitea act_runner + Nexus 完整面板
# 覆盖: HF-Shell/Jenkins-Gitea-Agent/startup.sh
# ============================================================
set -u

export NODE_ENV=production
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PM2_HOME="${PM2_HOME:-/app/.pm2}"
export PATH="/opt/act_runner:/usr/local/bin:/app/node_modules/.bin:$PATH"
export PANEL_PORT="${PANEL_PORT:-7860}"
export ACT_RUNNER_DATA="${ACT_RUNNER_DATA:-/data/act_runner}"
export JENKINS_AGENT_WORKDIR="${JENKINS_AGENT_WORKDIR:-/home/jenkins/agent}"

mkdir -p /app /tmp "$ACT_RUNNER_DATA" "$JENKINS_AGENT_WORKDIR" /app/.pm2 /opt/act_runner
chmod 777 /tmp /app 2>/dev/null || true
cd /app

log() { echo "[startup] $*"; }

ensure_act_runner() {
  if [ -x /opt/act_runner/act_runner ]; then
    log "act_runner: $(/opt/act_runner/act_runner --version 2>/dev/null | head -1 || echo ok)"
    return 0
  fi
  log "Downloading act_runner..."
  LATEST=$(curl -fsSL https://dl.gitea.com/act_runner/ 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 || true)
  [ -z "$LATEST" ] && LATEST=0.2.11
  curl -fL "https://dl.gitea.com/act_runner/${LATEST}/act_runner-${LATEST}-linux-amd64" \
    -o /opt/act_runner/act_runner && chmod +x /opt/act_runner/act_runner || return 1
  log "installed act_runner $LATEST"
}

ensure_act_runner || log "WARN act_runner missing"

# ---------- UI ----------
cat << 'EOFUI' > /app/terminal-ui.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>Nexus Terminal // DUAL-AGENT</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&display=swap" rel="stylesheet"/>
<script src="https://cdn.socket.io/4.7.2/socket.io.min.js"></script>
<style>
body{background:#050505;color:#a1a1aa;font-family:'Fira Code',monospace}
.crt::before{content:" ";display:block;position:absolute;top:0;left:0;bottom:0;right:0;background:linear-gradient(rgba(18,16,16,0) 50%,rgba(0,0,0,.25) 50%),linear-gradient(90deg,rgba(255,0,0,.06),rgba(0,255,0,.02),rgba(0,0,255,.06));z-index:1;background-size:100% 2px,3px 100%;pointer-events:none!important}
#output{scroll-behavior:smooth;white-space:pre}
#output::-webkit-scrollbar{width:8px;height:8px}
#output::-webkit-scrollbar-thumb{background:#3f3f46;border-radius:4px}
.prompt-glow{text-shadow:0 0 10px rgba(16,185,129,.5)}
.btn-action{transition:.2s;position:relative;z-index:30;cursor:pointer}
.btn-action:hover{transform:translateY(-1px);background:#27272a;color:#fff}
#editorOverlay[style*="display: none"],#editorOverlay.hidden{display:none!important;pointer-events:none!important}
#editorOverlay{pointer-events:auto}
button,.btn-action,input,textarea{pointer-events:auto!important;position:relative;z-index:40}
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
    <div class="text-xs text-zinc-500 tracking-widest font-medium">NEXUS_CORE // JENKINS + GITEA_ACTIONS</div>
    <div class="flex items-center space-x-3">
      <button type="button" onclick="openEditor('html')" class="text-xs bg-emerald-900/40 text-emerald-400 px-2 py-1 rounded border border-emerald-800/50 hover:bg-emerald-800/60 cursor-pointer">UI Dev</button>
      <button type="button" onclick="openEditor('js')" class="text-xs bg-purple-900/40 text-purple-400 px-2 py-1 rounded border border-purple-800/50 hover:bg-purple-800/60 cursor-pointer">Backend Dev</button>
      <span class="relative flex h-2 w-2"><span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span><span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span></span>
    </div>
  </div>
  <div class="border-b border-zinc-800 bg-[#0a0a0a] p-3 flex flex-wrap gap-2 text-xs font-medium z-20">
    <button type="button" onclick="sendCommand('status')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-emerald-400">📊 status</button>
    <button type="button" onclick="sendCommand('pm2 status')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-zinc-300">进程</button>
    <button type="button" onclick="sendCommand('restart jenkins')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-blue-400">🔄 Jenkins</button>
    <button type="button" onclick="sendCommand('restart runner')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-orange-400">🔄 Runner</button>
    <button type="button" onclick="sendCommand('jenkins log')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-zinc-400">J 日志</button>
    <button type="button" onclick="sendCommand('runner log')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-zinc-400">R 日志</button>
    <button type="button" onclick="sendCommand('update runner')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-purple-400">⬆ act_runner</button>
    <button type="button" onclick="sendCommand('clear')" class="btn-action bg-zinc-900 border border-zinc-700 px-3 py-2 rounded-lg text-zinc-500 ml-auto">清屏</button>
  </div>
  <div id="output" class="flex-1 p-5 overflow-auto text-sm text-zinc-300">
    <div class="text-emerald-400 text-xl font-bold mb-4 tracking-widest">N E X U S // D U A L - A G E N T</div>
    <div class="text-zinc-400 mb-2">Jenkins inbound-agent · Gitea act_runner (host) · Panel :7860</div>
    <div class="text-zinc-500 text-xs mb-4">Type help · status · restart jenkins · restart runner</div>
  </div>
  <div class="px-5 py-4 border-t border-zinc-800 flex items-center">
    <span class="text-emerald-500 font-bold mr-3 prompt-glow">admin@nexus:~$</span>
    <input id="cmdInput" type="text" autocomplete="off" spellcheck="false" class="flex-1 bg-transparent border-none outline-none text-zinc-300" autofocus/>
  </div>
</div>

<div id="editorOverlay" style="display:none" class="fixed inset-0 bg-black/80 z-50 flex items-center justify-center p-4">
  <div class="w-full max-w-4xl h-[80vh] bg-[#0a0a0a] border border-zinc-700 rounded-xl flex flex-col overflow-hidden">
    <div class="h-10 border-b border-zinc-800 flex items-center px-4 justify-between">
      <span id="editorTitle" class="text-xs text-zinc-400">editor</span>
      <div class="flex gap-2">
        <button type="button" onclick="deployEditor()" class="text-xs bg-emerald-900/50 text-emerald-400 px-3 py-1 rounded border border-emerald-800">Deploy</button>
        <button type="button" onclick="closeEditor()" class="text-xs bg-zinc-800 text-zinc-300 px-3 py-1 rounded border border-zinc-700">Close</button>
      </div>
    </div>
    <textarea id="editorArea" class="flex-1 bg-[#050505] text-zinc-300 p-4 font-mono text-xs outline-none resize-none"></textarea>
  </div>
</div>

<script>
const socket=io(),output=document.getElementById('output'),input=document.getElementById('cmdInput');
let editorMode='html';
document.addEventListener('mouseup',e=>{
  if(window.getSelection().toString())return;
  const t=e.target.tagName;
  if(t!=='BUTTON'&&t!=='TEXTAREA'&&t!=='INPUT')input.focus();
});
const ac={30:'#71717a',31:'#ef4444',32:'#10b981',33:'#eab308',34:'#3b82f6',35:'#d946ef',36:'#06b6d4',37:'#f4f4f5',90:'#a1a1aa'};
function parseAnsi(t){
  let h=t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  let s={b:false,c:null},o=0;
  h=h.replace(/\x1b\[([0-9;]*)m/g,(m,codes)=>{
    codes.split(';').forEach(x=>{const n=parseInt(x);if(!n){s.b=false;s.c=null;}else if(n===1)s.b=true;else if(ac[n])s.c=ac[n];});
    let r='</span>'.repeat(o);o=0;
    if(s.b||s.c){r+='<span style="'+(s.b?'font-weight:bold;':'')+(s.c?'color:'+s.c+';':'')+'">';o++;}
    return r;
  });
  return h+'</span>'.repeat(o);
}
function append(t){const s=document.createElement('span');s.innerHTML=parseAnsi(t);output.appendChild(s);output.scrollTop=output.scrollHeight;}
socket.on('output',d=>append(d));
socket.on('error',d=>append('\x1b[31m'+d+'\x1b[0m'));
socket.on('system',d=>append('\x1b[36m'+d+'\n\x1b[0m'));
function sendCommand(v){
  if(!v)return;
  append('\n\x1b[32m\x1b[1madmin@nexus:~$\x1b[0m '+v+'\n');
  if(v==='clear'){output.innerHTML='';return;}
  socket.emit('command',v);
}
input.addEventListener('keypress',e=>{if(e.key==='Enter'){sendCommand(input.value.trim());input.value='';}});
function openEditor(mode){
  editorMode=mode;
  document.getElementById('editorTitle').textContent=mode==='html'?'terminal-ui.html':'logic.js';
  document.getElementById('editorOverlay').style.display='flex';
  if(mode==='html')socket.emit('get-source-html');else socket.emit('get-source-js');
}
function closeEditor(){document.getElementById('editorOverlay').style.display='none';}
socket.on('source-code-html',c=>{document.getElementById('editorArea').value=c;});
socket.on('source-code-js',c=>{document.getElementById('editorArea').value=c;});
function deployEditor(){
  const code=document.getElementById('editorArea').value;
  if(editorMode==='html')socket.emit('deploy-source-html',code);else socket.emit('deploy-source-js',code);
}
socket.on('deploy-success',t=>{append('\x1b[32m[deployed '+t+']\x1b[0m\n');closeEditor();});
</script>
</body>
</html>
EOFUI

# ---------- logic.js ----------
cat << 'EOFLOGIC' > /app/logic.js
const { spawn } = require('child_process');
const fs = require('fs');
const uiFilePath = '/app/terminal-ui.html';
const logicFilePath = '/app/logic.js';
let previewHTML = fs.readFileSync(uiFilePath, 'utf8');

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
    else socket.emit('error', '[exit ' + code + ']');
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
    if (path === '/preview') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(previewHTML);
      return;
    }
    if (path === '/api/ping' || path === '/health' || path === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'alive', ts: Date.now(), role: 'jenkins+gitea-agent' }));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  },

  handleSocket(io, socket) {
    socket.removeAllListeners();
    socket.on('command', (cmd) => {
      if (cmd === 'help') {
        socket.emit('output',
          'status | pm2 status | restart jenkins | restart runner | stop jenkins | stop runner\n' +
          'jenkins log | runner log | update runner | re-register runner | clear\n'
        );
        socket.emit('system', '[Process completed]');
        return;
      }
      let script = cmd;
      if (cmd === 'status') {
        script = `
echo "=== Dual Agent (Jenkins + Gitea Actions) ==="
echo -n "jenkins-agent: "; command -v jenkins-agent >/dev/null && echo ok || echo missing
echo -n "act_runner: "; /opt/act_runner/act_runner --version 2>/dev/null | head -1 || echo missing
echo -n "MASTER_URL: "; echo "\${MASTER_URL:-(empty)}"
echo -n "NODE_AGENT_NAME: "; echo "\${NODE_AGENT_NAME:-(empty)}"
echo -n "GITEA_INSTANCE_URL: "; echo "\${GITEA_INSTANCE_URL:-(empty)}"
echo -n "runner data: "; ls -la /data/act_runner/.runner 2>/dev/null || echo "not registered"
echo -n "workDir: "; echo "\${JENKINS_AGENT_WORKDIR:-/home/jenkins/agent}"
echo "--- logs (tail) ---"
echo "[jenkins last 5]"; tail -n 5 /tmp/jenkins-agent.log 2>/dev/null || echo n/a
echo "[runner last 5]"; tail -n 5 /tmp/act_runner.log 2>/dev/null || echo n/a
${PM2} status 2>/dev/null || true
`;
      } else if (cmd === 'restart jenkins') {
        script = `${PM2} restart jenkins-agent --update-env; sleep 1; ${PM2} status jenkins-agent; echo done`;
      } else if (cmd === 'restart runner' || cmd === 'restart act_runner') {
        script = `${PM2} restart act-runner --update-env; sleep 1; ${PM2} status act-runner; echo done`;
      } else if (cmd === 'stop jenkins') {
        script = `${PM2} stop jenkins-agent; echo stopped`;
      } else if (cmd === 'stop runner') {
        script = `${PM2} stop act-runner; echo stopped`;
      } else if (cmd === 'jenkins log') {
        script = `${PM2} logs jenkins-agent --lines 80 --nostream 2>/dev/null; echo '---'; tail -n 40 /tmp/jenkins-agent.log 2>/dev/null || true`;
      } else if (cmd === 'runner log' || cmd === 'act_runner log') {
        script = `${PM2} logs act-runner --lines 80 --nostream 2>/dev/null; echo '---'; tail -n 40 /tmp/act_runner.log 2>/dev/null || true`;
      } else if (cmd === 'update runner') {
        script = `
set -e
LATEST=\$(curl -fsSL https://dl.gitea.com/act_runner/ 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | sort -V | tail -1 || true)
[ -z "\$LATEST" ] && LATEST=0.2.11
echo "download act_runner \$LATEST"
curl -fL "https://dl.gitea.com/act_runner/\${LATEST}/act_runner-\${LATEST}-linux-amd64" -o /tmp/ar.new
chmod +x /tmp/ar.new
mv /tmp/ar.new /opt/act_runner/act_runner
/opt/act_runner/act_runner --version
${PM2} restart act-runner --update-env || true
echo done
`;
      } else if (cmd === 're-register runner') {
        script = `
set -e
if [ -z "\${GITEA_INSTANCE_URL:-}" ] || [ -z "\${GITEA_RUNNER_TOKEN:-}" ]; then
  echo "need GITEA_INSTANCE_URL + GITEA_RUNNER_TOKEN"; exit 1
fi
${PM2} stop act-runner 2>/dev/null || true
DATA=\${ACT_RUNNER_DATA:-/data/act_runner}
mkdir -p "\$DATA"
# 备份旧注册
[ -f "\$DATA/.runner" ] && mv "\$DATA/.runner" "\$DATA/.runner.bak.\$(date +%s)" || true
cd "\$DATA"
NAME=\${GITEA_RUNNER_NAME:-HF-Jenkins-Agent}
LABELS=\${GITEA_RUNNER_LABELS:-linux_amd64:host,self-hosted:host,hf-agent:host}
/opt/act_runner/act_runner register --no-interactive \\
  --instance "\$GITEA_INSTANCE_URL" \\
  --token "\$GITEA_RUNNER_TOKEN" \\
  --name "\$NAME" \\
  --labels "\$LABELS"
${PM2} restart act-runner --update-env || ${PM2} start bash --name act-runner --cwd "\$DATA" -- -c "cd '\$DATA' && exec /opt/act_runner/act_runner daemon"
echo done
`;
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
    socket.on('get-source-html', () => socket.emit('source-code-html', fs.readFileSync(uiFilePath, 'utf8')));
    socket.on('preview-source-html', (code) => { previewHTML = code; });
    socket.on('deploy-source-html', (code) => { fs.writeFileSync(uiFilePath, code); socket.emit('deploy-success', 'html'); });
    socket.on('get-source-js', () => socket.emit('source-code-js', fs.readFileSync(logicFilePath, 'utf8')));
    socket.on('deploy-source-js', (code) => {
      fs.writeFileSync(logicFilePath, code);
      process.emit('HOT_RELOAD_LOGIC');
      setTimeout(() => socket.emit('deploy-success', 'js'), 500);
    });
  }
};
EOFLOGIC

if [ ! -d /app/node_modules/pm2 ] || [ ! -d /app/node_modules/socket.io ]; then
  log "npm install pm2 socket.io"
  npm install --prefix /app pm2 socket.io --omit=dev 2>&1 | tail -10
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
const port = Number(process.env.PANEL_PORT || 7860);
server.listen(port, '0.0.0.0', () => console.log('[Info] panel :' + port));
process.on('uncaughtException', (e) => console.error(e));
process.on('unhandledRejection', (e) => console.error(e));
EOFBOOT

PM2=/app/node_modules/.bin/pm2
export PATH="/app/node_modules/.bin:$PATH"

# 写启动包装脚本（PM2 用）
cat > /opt/act_runner/run-jenkins-agent.sh << 'JSH'
#!/bin/bash
set -u
export PATH="/usr/local/bin:$PATH"
WORKDIR="${JENKINS_AGENT_WORKDIR:-/home/jenkins/agent}"
mkdir -p "$WORKDIR"
if [ -z "${MASTER_URL:-}" ] || [ -z "${NODE_SECRET:-}" ]; then
  echo "[jenkins-agent] MASTER_URL/NODE_SECRET empty, sleep"
  while true; do sleep 3600; done
fi
NAME="${NODE_AGENT_NAME:-HF-agent}"
echo "[jenkins-agent] connect $MASTER_URL as $NAME"
if command -v jenkins-agent >/dev/null 2>&1; then
  exec jenkins-agent \
    -url "$MASTER_URL" \
    -secret "$NODE_SECRET" \
    -name "$NAME" \
    -workDir "$WORKDIR" \
    -webSocket
else
  exec java -jar /usr/share/jenkins/agent.jar \
    -url "$MASTER_URL" \
    -secret "$NODE_SECRET" \
    -name "$NAME" \
    -workDir "$WORKDIR" \
    -webSocket
fi
JSH
chmod +x /opt/act_runner/run-jenkins-agent.sh

cat > /opt/act_runner/run-act-runner.sh << 'RSH'
#!/bin/bash
set -u
DATA="${ACT_RUNNER_DATA:-/data/act_runner}"
BIN=/opt/act_runner/act_runner
mkdir -p "$DATA"
cd "$DATA" || exit 1

if [ ! -x "$BIN" ]; then
  echo "[act_runner] binary missing"; sleep 60; exit 1
fi

if [ ! -f "$DATA/.runner" ]; then
  if [ -z "${GITEA_INSTANCE_URL:-}" ] || [ -z "${GITEA_RUNNER_TOKEN:-}" ]; then
    echo "[act_runner] no .runner and no token, idle"
    while true; do sleep 3600; done
  fi
  NAME="${GITEA_RUNNER_NAME:-HF-Jenkins-Agent}"
  LABELS="${GITEA_RUNNER_LABELS:-linux_amd64:host,self-hosted:host,hf-agent:host}"
  echo "[act_runner] register $GITEA_INSTANCE_URL name=$NAME"
  "$BIN" register --no-interactive \
    --instance "$GITEA_INSTANCE_URL" \
    --token "$GITEA_RUNNER_TOKEN" \
    --name "$NAME" \
    --labels "$LABELS" || {
    echo "[act_runner] register failed"; sleep 30; exit 1
  }
fi

echo "[act_runner] daemon"
exec "$BIN" daemon
RSH
chmod +x /opt/act_runner/run-act-runner.sh

(
  log "start pm2 services..."
  $PM2 delete jenkins-agent 2>/dev/null || true
  $PM2 delete act-runner 2>/dev/null || true

  $PM2 start /opt/act_runner/run-jenkins-agent.sh \
    --name jenkins-agent \
    --interpreter bash \
    --max-restarts 50 \
    --restart-delay 8000 \
    --log /tmp/jenkins-agent.log \
    --time || true

  $PM2 start /opt/act_runner/run-act-runner.sh \
    --name act-runner \
    --interpreter bash \
    --max-restarts 50 \
    --restart-delay 8000 \
    --log /tmp/act_runner.log \
    --time || true

  $PM2 save 2>/dev/null || true
  sleep 2
  $PM2 list || true
) >/tmp/startup-bg.log 2>&1 &

log "panel :${PANEL_PORT}"
exec node /app/bootstrapper.js
