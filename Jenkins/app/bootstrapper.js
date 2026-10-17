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
