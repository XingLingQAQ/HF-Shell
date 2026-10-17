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

function pm2Prefix() {
  return [
    'export PM2_HOME="${PM2_HOME:-/var/jenkins_local/.pm2}"',
    'export PATH="/app/node_modules/.bin:$PATH"',
    'export JAVA_HOME=/opt/java/current',
    'export PATH="$JAVA_HOME/bin:$PATH"',
  ];
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
          'status | pm2 status | pm2 logs\n' +
          'update jenkins | update java | update tunnel\n' +
          'restart jenkins | stop jenkins | jenkins log | tunnel log | clear\n'
        );
        socket.emit('system', '[Process completed]');
        return;
      }

      let lines = null;

      if (cmd === 'status' || cmd === 'pm2 status') {
        lines = pm2Prefix().concat([
          'echo "=== status (PM2 / Java 21 required) ==="',
          'echo -n "Java: "; java -version 2>&1 | head -1',
          'echo -n "JAVA_HOME="; echo "$JAVA_HOME"',
          'echo -n "Java ver: "; cat /opt/java/version 2>/dev/null || echo none',
          'echo -n "Jenkins war: "; ls -lh /opt/jenkins/jenkins.war 2>/dev/null || echo missing',
          'echo -n "Jenkins ver: "; cat /opt/jenkins/version 2>/dev/null || echo none',
          'echo -n "Tunnel: "; /opt/tunnel/cloudflared --version 2>/dev/null | head -1 || echo missing',
          'echo -n "Tunnel ver: "; cat /opt/tunnel/version 2>/dev/null || echo none',
          'echo -n "Jenkins :8080: "; curl -fsS -o /dev/null -m 2 -w "%{http_code}" http://127.0.0.1:8080/login 2>/dev/null || echo down; echo',
          'echo "--- pm2 list ---"',
          'pm2 list',
        ]);
      } else if (cmd === 'update jenkins') {
        lines = pm2Prefix().concat([
          'set -e',
          'echo "=== update jenkins ==="',
          'LATEST=$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt | tr -d "\\r" | head -1)',
          'LOCAL=$(cat /opt/jenkins/version 2>/dev/null || echo none)',
          'echo "Local=$LOCAL Remote=$LATEST"',
          'if [ -z "$LATEST" ]; then echo "fetch fail"; exit 1; fi',
          'if [ "$LATEST" = "$LOCAL" ]; then echo "already $LATEST"; exit 0; fi',
          'curl -fL "https://get.jenkins.io/war-stable/$LATEST/jenkins.war" -o /tmp/jenkins.war.new',
          'SIZE=$(wc -c < /tmp/jenkins.war.new | tr -d " ")',
          'if [ "$SIZE" -lt 1000000 ]; then echo "bad size $SIZE"; exit 1; fi',
          'mv /tmp/jenkins.war.new /opt/jenkins/jenkins.war',
          'echo "$LATEST" > /opt/jenkins/version',
          'pm2 restart jenkins --update-env || pm2 start /opt/jenkins/run-jenkins.sh --name jenkins --interpreter bash --max-restarts 100 --restart-delay 5000 --log /tmp/jenkins.log --time',
          'echo "war updated + pm2 restart jenkins"',
        ]);
      } else if (cmd === 'update java') {
        lines = pm2Prefix().concat([
          'set -e',
          'echo "=== update java (Temurin 21 — Jenkins 最低要求) ==="',
          'LOCAL=$(cat /opt/java/version 2>/dev/null || echo none)',
          'META=$(curl -fsSL "https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=%5B21%2C22%29&os=linux&arch=x64&image_type=jdk&jvm_impl=hotspot&page_size=1&sort_order=DESC" || true)',
          'LATEST=$(echo "$META" | tr "," "\\n" | sed -n "s/.*\\"openjdk_version\\":\\"\\([^\\"]*\\)\\".*/\\1/p" | head -1)',
          'if [ -z "$LATEST" ]; then LATEST=$(echo "$META" | tr "," "\\n" | sed -n "s/.*\\"semver\\":\\"\\([^\\"]*\\)\\".*/\\1/p" | head -1); fi',
          'echo "Local=$LOCAL Remote=$LATEST"',
          'if [ -z "$LATEST" ]; then echo "Adoptium fail"; exit 1; fi',
          'if [ "$LATEST" = "$LOCAL" ] && [ -x /opt/java/current/bin/java ]; then echo "already $LATEST"; exit 0; fi',
          'STAGING=/opt/java/staging',
          'rm -rf "$STAGING"; mkdir -p "$STAGING"',
          'curl -fL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" -o /tmp/jdk21.tar.gz',
          'SIZE=$(wc -c < /tmp/jdk21.tar.gz | tr -d " ")',
          'if [ "$SIZE" -lt 50000000 ]; then echo "bad jdk $SIZE"; exit 1; fi',
          'tar -xzf /tmp/jdk21.tar.gz -C "$STAGING"',
          'INNER=$(find "$STAGING" -maxdepth 1 -type d -name "jdk-*" | head -1)',
          'if [ -z "$INNER" ] || [ ! -x "$INNER/bin/java" ]; then echo "extract fail"; exit 1; fi',
          'DEST="/opt/java/$(basename "$INNER")"',
          'rm -rf "$DEST"; mv "$INNER" "$DEST"',
          'ln -sfn "$DEST" /opt/java/current',
          'echo "$LATEST" > /opt/java/version',
          'rm -rf "$STAGING" /tmp/jdk21.tar.gz',
          '/opt/java/current/bin/java -version 2>&1 | head -3',
          'pm2 restart jenkins --update-env || true',
          'echo "java 21 switched + pm2 restart jenkins"',
        ]);
      } else if (cmd === 'update tunnel') {
        lines = pm2Prefix().concat([
          'set -e',
          'echo "=== update tunnel ==="',
          'LATEST=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep "\\"tag_name\\":" | head -1 | cut -d"\\"" -f4)',
          'LOCAL=$(cat /opt/tunnel/version 2>/dev/null || echo none)',
          'echo "Local=$LOCAL Remote=$LATEST"',
          'if [ -z "$LATEST" ]; then echo "fetch fail"; exit 1; fi',
          'if [ "$LATEST" = "$LOCAL" ]; then echo "already $LATEST"; exit 0; fi',
          'curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared.new',
          'chmod +x /tmp/cloudflared.new',
          'mv /tmp/cloudflared.new /opt/tunnel/cloudflared',
          'echo "$LATEST" > /opt/tunnel/version',
          'if pm2 describe tunnel >/dev/null 2>&1; then pm2 restart tunnel --update-env; fi',
          'echo "tunnel updated"',
        ]);
      } else if (cmd === 'restart jenkins') {
        lines = pm2Prefix().concat(['pm2 restart jenkins --update-env', 'echo done']);
      } else if (cmd === 'stop jenkins') {
        lines = pm2Prefix().concat(['pm2 stop jenkins', 'echo stopped']);
      } else if (cmd === 'jenkins log') {
        lines = pm2Prefix().concat([
          'pm2 logs jenkins --lines 80 --nostream 2>/dev/null || tail -n 80 /tmp/jenkins.log 2>/dev/null || echo "(no log)"',
        ]);
      } else if (cmd === 'tunnel log') {
        lines = pm2Prefix().concat([
          'pm2 logs tunnel --lines 80 --nostream 2>/dev/null || tail -n 80 /tmp/tunnel.log 2>/dev/null || echo "(no log)"',
        ]);
      } else if (cmd === 'pm2 logs') {
        lines = pm2Prefix().concat(['pm2 logs --lines 50 --nostream']);
      } else if (cmd.startsWith('pm2 ')) {
        lines = pm2Prefix().concat([cmd]);
      } else if (/^(ls|df|free|ps|top|uptime|whoami|id|pwd|du|cat |tail |head |curl )/i.test(cmd)) {
        lines = [cmd];
      } else {
        socket.emit('error', 'Unknown: ' + cmd + ' (help)');
        socket.emit('system', '[Process completed]');
        return;
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
