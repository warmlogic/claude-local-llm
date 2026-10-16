// Drive a stdio MCP server over JSON-RPC: initialize, then optionally one tools/call.
// Usage: node mcp-call.mjs <server-command> [tool] [json-args]
// Prints one JSON line: {"init":bool,"serverName":str|null,"initError":str|null,"exit":int|null,"timedOut":bool,"stderr":str,"call":{"isError":bool,"text":str}|null}
// Environment is inherited from the caller. Exits 0 whenever it could report.
import { spawn } from 'node:child_process';

const [cmd, tool, argJson] = process.argv.slice(2);
const CALL_TIMEOUT_MS = 240000;
const START_TIMEOUT_MS = 20000;

const child = spawn(cmd, [], { stdio: ['pipe', 'pipe', 'pipe'] });
const out = { init: false, serverName: null, initError: null, exit: null, timedOut: false, stderr: '', call: null };
let buf = '';
let timer;

const send = (msg) => child.stdin.write(JSON.stringify(msg) + '\n');
const finish = () => {
  clearTimeout(timer);
  if (out.exit === null) child.kill();
  console.log(JSON.stringify(out));
  process.exit(0);
};
const arm = (ms) => { clearTimeout(timer); timer = setTimeout(() => { out.timedOut = true; finish(); }, ms); };

child.stderr.on('data', (d) => { out.stderr = (out.stderr + d).slice(-2000); });
child.stdin.on('error', () => {});
child.on('error', (e) => { out.stderr = `spawn failed: ${e.message}`; out.exit = -1; finish(); });
child.on('close', (code) => { out.exit = code ?? -1; setTimeout(finish, 50); });
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id === 1) {
      if (m.error) { out.initError = JSON.stringify(m.error); return finish(); }
      out.init = true;
      out.serverName = m.result?.serverInfo?.name ?? null;
      send({ jsonrpc: '2.0', method: 'notifications/initialized' });
      if (!tool) return finish();
      arm(CALL_TIMEOUT_MS);
      send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: tool, arguments: JSON.parse(argJson || '{}') } });
    } else if (m.id === 2) {
      const r = m.result ?? { isError: true, content: [{ text: JSON.stringify(m.error) }] };
      out.call = { isError: !!r.isError, text: (r.content || []).map((c) => c.text || '').join('\n') };
      finish();
    }
  }
});

arm(START_TIMEOUT_MS);
send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test-fence', version: '0' } } });
