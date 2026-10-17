// Send raw lines to a stdio MCP server and collect what comes back.
// Usage: node mcp-raw.mjs <server-command> <json-array> <expected-responses> [timeout-ms, default 30000]
// Each array element is sent as one line: a string as-is (so malformed JSON can be sent), anything else
// JSON-encoded. An element {"delay_ms": n} waits n ms instead, and {"close_stdin": true} closes the
// server's stdin. Waits for <expected-responses> responses, or for the server to exit.
// Prints one JSON line: {"responses":[{...msg, "at_ms": n}],"exit":int|null,"exit_ms":n|null,"timedOut":bool,"stderr":str}
import { spawn } from 'node:child_process';

const [cmd, linesJson, expected, timeoutArg] = process.argv.slice(2);
const TIMEOUT_MS = Number(timeoutArg ?? 30000);
const t0 = Date.now();
const child = spawn(cmd, [], { stdio: ['pipe', 'pipe', 'pipe'] });
const out = { responses: [], exit: null, exit_ms: null, timedOut: false, stderr: '' };
let buf = '';
const finish = () => {
  if (out.exit === null) child.kill();
  console.log(JSON.stringify(out));
  process.exit(0);
};
const timer = setTimeout(() => { out.timedOut = true; finish(); }, TIMEOUT_MS);
child.stderr.on('data', (d) => { out.stderr = (out.stderr + d).slice(-4000); });
child.stdin.on('error', () => {}); // a server that already exited makes writes fail with EPIPE; the exit is reported instead
child.on('close', (code, signal) => { out.exit = code ?? (signal ? `signal ${signal}` : -1); out.exit_ms = Date.now() - t0; clearTimeout(timer); setTimeout(finish, 50); });
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    try {
      out.responses.push({ ...JSON.parse(line), at_ms: Date.now() - t0 });
    } catch {
      out.responses.push({ unparseable: line.slice(0, 200), at_ms: Date.now() - t0 });
    }
    if (out.responses.length >= Number(expected)) { clearTimeout(timer); finish(); }
  }
});
for (const item of JSON.parse(linesJson)) {
  if (item && typeof item === 'object' && 'delay_ms' in item) await new Promise((r) => setTimeout(r, item.delay_ms));
  else if (item && typeof item === 'object' && item.close_stdin) child.stdin.end();
  else child.stdin.write(`${typeof item === 'string' ? item : JSON.stringify(item)}\n`);
}
