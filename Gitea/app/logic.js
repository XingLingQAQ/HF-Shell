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
          'status | packages | pm2 status | pm2 logs\n' +
          'restart gitea|pages|renovate|tunnel\n' +
          'stop gitea|pages|renovate\n' +
          'update gitea|pages|tunnel|renovate\n' +
          'gitea log | pages log | renovate log | tunnel log\n' +
          'renovate once  (run one scan now)\n' +
          'clear\n\n' +
          'Package = built-in [packages] in app.ini\n' +
          'Pages = deadnews/gitea-pages :8000 (GITEA_PAGES_TOKEN)\n' +
          'Renovate = loop job (RENOVATE_TOKEN)\n'
        );
        socket.emit('system', '[Process completed]');
        return;
      }

      let script = cmd;

      if (cmd === 'status') {
        script = `
echo "=== Gitea / Packages / Pages / Renovate / Tunnel ==="
echo -n "gitea: "; /opt/gitea/gitea --version 2>/dev/null | head -1 || echo missing
echo -n "ver: "; cat /opt/gitea/version 2>/dev/null || echo none
echo -n "WORK_DIR: "; echo "${process.env.GITEA_WORK_DIR || '/data/gitea'}"
echo -n "Gitea :3000: "; curl -fsS -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:3000/ 2>/dev/null || echo down; echo
echo -n "ROOT_URL: "; grep -E '^ROOT_URL' ${process.env.GITEA_CUSTOM || '/data/gitea/custom'}/conf/app.ini 2>/dev/null || echo n/a
echo -n "packages: "; grep -A3 '^\\[packages\\]' ${process.env.GITEA_CUSTOM || '/data/gitea/custom'}/conf/app.ini 2>/dev/null | grep ENABLED || echo 'check app.ini'
echo -n "pages bin: "; [ -x /opt/gitea-pages/gitea-pages ] && echo "ok v$(cat /opt/gitea-pages/version 2>/dev/null)" || echo missing
echo -n "pages :8000: "; curl -fsS -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8000/health 2>/dev/null || echo down; echo
echo -n "GITEA_PAGES_TOKEN: "; [ -n "$GITEA_PAGES_TOKEN" ] && echo set || echo 'NOT SET'
echo -n "renovate: "; [ -x /opt/renovate/node_modules/.bin/renovate ] && echo ok || echo missing
echo -n "RENOVATE_TOKEN: "; [ -n "$RENOVATE_TOKEN" ] && echo set || echo 'NOT SET'
${PM2} status 2>/dev/null || true
`;
      } else if (cmd === 'packages') {
        script = `
echo "=== Gitea Package Registry (built-in, no extra process) ==="
grep -A10 '^\\[packages\\]' /data/gitea/custom/conf/app.ini 2>/dev/null || echo 'no [packages] section'
echo ""
echo "Docs: https://docs.gitea.com/usage/packages/overview"
echo "Need PAT with package read/write. Examples:"
echo "  docker login <gitea-host>"
echo "  npm: //host/api/packages/OWNER/npm/"
`;
      } else if (cmd === 'restart gitea') {
        script = `${PM2} restart gitea --update-env; sleep 2; ${PM2} status gitea; echo done`;
      } else if (cmd === 'restart pages') {
        script = `${PM2} restart pages --update-env 2>/dev/null || true; sleep 1; ${PM2} status pages; curl -fsS -m 3 http://127.0.0.1:8000/health || true; echo`;
      } else if (cmd === 'restart renovate') {
        script = `${PM2} restart renovate --update-env 2>/dev/null || echo 'no renovate (set RENOVATE_TOKEN)'; ${PM2} status renovate 2>/dev/null || true`;
      } else if (cmd === 'restart tunnel') {
        script = `${PM2} restart tunnel --update-env 2>/dev/null || echo no tunnel`;
      } else if (cmd === 'stop gitea') {
        script = `${PM2} stop gitea; echo stopped`;
      } else if (cmd === 'stop pages') {
        script = `${PM2} stop pages; echo stopped`;
      } else if (cmd === 'stop renovate') {
        script = `${PM2} stop renovate; echo stopped`;
      } else if (cmd === 'update gitea') {
        script = `
set -e
LATEST=$(curl -fsSL https://dl.gitea.com/gitea/version.json | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' | head -1 | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+')
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
      } else if (cmd === 'update pages') {
        script = `
set -e
VER=\${GITEA_PAGES_VERSION:-1.0.3}
TAG=$(curl -fsSIL https://github.com/deadnews/gitea-pages/releases/latest 2>/dev/null | tr -d '\\r' | awk -F/ 'tolower(\$1) ~ /location/ {print \$NF; exit}')
[ -n "\$TAG" ] && VER=\${TAG#v}
LOCAL=$(cat /opt/gitea-pages/version 2>/dev/null || echo none)
echo "Local=\$LOCAL Remote=\$VER"
URL="https://github.com/deadnews/gitea-pages/releases/download/v\${VER}/gitea-pages_\${VER}_linux_amd64.tar.gz"
curl -fL --retry 3 "\$URL" -o /tmp/gitea-pages.tgz
rm -rf /tmp/gp-extract; mkdir -p /tmp/gp-extract
tar -xzf /tmp/gitea-pages.tgz -C /tmp/gp-extract
BIN=$(find /tmp/gp-extract -type f -name gitea-pages | head -1)
[ -n "\$BIN" ] || { echo extract fail; exit 1; }
mv "\$BIN" /opt/gitea-pages/gitea-pages
chmod +x /opt/gitea-pages/gitea-pages
echo "\$VER" > /opt/gitea-pages/version
${PM2} restart pages --update-env || true
echo done
`;
      } else if (cmd === 'update renovate') {
        script = `
set -e
npm install --prefix /opt/renovate renovate@latest --omit=dev 2>&1 | tail -20
${PM2} restart renovate --update-env 2>/dev/null || true
echo done
`;
      } else if (cmd === 'update tunnel') {
        script = `
set -e
LOCAL=$(cat /opt/tunnel/version 2>/dev/null || echo none)
NEW=/opt/tunnel/cloudflared.new
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$NEW"
chmod +x "$NEW"
LATEST=$("$NEW" --version 2>&1 | awk '{print $3}' | head -1)
echo "Local=$LOCAL Remote=$LATEST"
[ -z "$LATEST" ] && { echo "cannot determine version"; rm -f "$NEW"; exit 1; }
[ "$LATEST" = "$LOCAL" ] && { echo up-to-date; rm -f "$NEW"; exit 0; }
mv "$NEW" /opt/tunnel/cloudflared
echo "$LATEST" > /opt/tunnel/version
${PM2} restart tunnel || true
echo done
`;
      } else if (cmd === 'gitea log') {
        script = `${PM2} logs gitea --lines 100 --nostream 2>/dev/null || tail -n 100 /tmp/gitea.log 2>/dev/null || echo no log`;
      } else if (cmd === 'pages log') {
        script = `${PM2} logs pages --lines 100 --nostream 2>/dev/null || tail -n 100 /tmp/pages.log 2>/dev/null || echo no log`;
      } else if (cmd === 'renovate log') {
        script = `${PM2} logs renovate --lines 100 --nostream 2>/dev/null || tail -n 100 /tmp/renovate.log 2>/dev/null || echo no log`;
      } else if (cmd === 'tunnel log') {
        script = `${PM2} logs tunnel --lines 80 --nostream 2>/dev/null || tail -n 80 /tmp/tunnel.log 2>/dev/null || echo no log`;
      } else if (cmd === 'renovate once') {
        script = `
export RENOVATE_CONFIG_FILE=/data/renovate/config.js
if [ -z "\$RENOVATE_TOKEN" ]; then echo "RENOVATE_TOKEN empty"; exit 1; fi
if [ ! -x /opt/renovate/node_modules/.bin/renovate ]; then echo "renovate not installed"; exit 1; fi
/opt/renovate/node_modules/.bin/renovate 2>&1 | tail -100
`;
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
