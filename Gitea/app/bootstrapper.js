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
