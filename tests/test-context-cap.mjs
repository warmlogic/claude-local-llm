// Offline context bounds, hook and batch integration. Also run by test-fence.sh.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getContextCap, MIN_DELEGATE_CHARS } from '../scripts/context-cap.mjs';
import { PROXY_VARS } from '../scripts/loopback.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const tmp = mkdtempSync(join(tmpdir(), 'context-cap-'));
const children = [];
const servers = [];
after(() => { children.forEach((p) => p.kill()); servers.forEach((s) => s.closeAllConnections()); servers.forEach((s) => s.close()); rmSync(tmp, { recursive: true, force: true }); });
delete process.env.LOCAL_LLM_MODEL; // helper calls are independent of the operator's model pin
const env = { ...process.env, LOCAL_LLM_MODEL: '' };
for (const k of PROXY_VARS) delete env[k];
const run = (script, args = [], extraEnv = {}, input = '') => new Promise((resolve, reject) => {
  const p = spawn(process.execPath, [join(repo, script), ...args], { env: { ...env, ...extraEnv } });
  children.push(p);
  let stdout = '', stderr = '';
  const timer = setTimeout(() => { p.kill(); reject(new Error(`${script} exceeded 4 s`)); }, 4000);
  p.stdout.on('data', (s) => { stdout += s; });
  p.stderr.on('data', (s) => { stderr += s; });
  p.on('error', reject);
  p.on('close', (code) => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  p.stdin.end(input);
});
async function fake(tokens) {
  const name = `fake-${tokens}-${children.length}`;
  const log = join(tmp, name + '.log');
  const port = join(tmp, name + '.port');
  const p = spawn(process.execPath, [join(repo, 'tests/fake-endpoint.mjs'), port, log, 'context', String(tokens)], { env });
  children.push(p);
  for (let i = 0; i < 100; i++) {
    try { return { endpoint: `http://127.0.0.1:${readFileSync(port, 'utf8')}`, log }; } catch { await new Promise((r) => setTimeout(r, 20)); }
  }
  throw new Error('fake endpoint did not start');
}
async function serve(handler) {
  const s = createServer(handler);
  servers.push(s);
  s.listen(0, '127.0.0.1');
  await once(s, 'listening');
  return `http://127.0.0.1:${s.address().port}`;
}
const model = (id, tokens, state = 'loaded', type = 'llm') => ({ id, loaded_context_length: tokens, state, type });
const fallback = { contextTokens: 32768, capChars: 71680, source: 'fallback' };
const hint = async (endpoint, sizes) => {
  const paths = sizes.map((size, i) => {
    const p = join(tmp, `hint-${i}.txt`); writeFileSync(p, 'x'.repeat(size)); return p;
  });
  const r = await run('scripts/size-hint.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint }, JSON.stringify({ prompt: paths.join(' ') }));
  assert.equal(r.code, 0, r.stderr);
  return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.additionalContext : '';
};

test('context formula follows 32k and 64k loaded contexts', async () => {
  const a = await fake(32768), b = await fake(65536);
  assert.equal(MIN_DELEGATE_CHARS, 30000);
  assert.deepEqual(await getContextCap({ endpoint: a.endpoint }), { contextTokens: 32768, capChars: 71680, source: 'loaded' });
  assert.deepEqual(await getContextCap({ endpoint: b.endpoint }), { contextTokens: 65536, capChars: 153600, source: 'loaded' });
});
test('model selection ignores embeddings and unloaded models; pin resolves ambiguity', async () => {
  let models = [model('embed', 999999, 'loaded', 'embeddings'), model('idle', 999999, 'not-loaded'), model('a', 65536)];
  const endpoint = await serve((q, r) => r.end(JSON.stringify({ data: models })));
  assert.equal((await getContextCap({ endpoint })).capChars, 153600);
  models.push(model('b', 16384));
  assert.deepEqual(await getContextCap({ endpoint }), fallback);
  assert.deepEqual(await getContextCap({ endpoint, model: 'b' }), { contextTokens: 16384, capChars: 30720, source: 'loaded' });
  assert.deepEqual(await getContextCap({ endpoint, model: 'missing' }), fallback);
  // Exercise the helper's env defaults in a separate process.
  const result = await run('scripts/context-cap.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint, LOCAL_LLM_MODEL: 'b' });
  assert.deepEqual(JSON.parse(result.stdout), { contextTokens: 16384, capChars: 30720, source: 'loaded' });
});
test('unavailable or malformed metadata falls back; tiny context has no usable room', async () => {
  let payload = {};
  const endpoint = await serve((q, r) => r.end(JSON.stringify(payload)));
  for (const data of [undefined, [], [model('a', 0)], [model('a', '65536')], [model('a', 12.5)], [model('a', 65536, 'not-loaded')]]) {
    payload = { data };
    assert.deepEqual(await getContextCap({ endpoint }), fallback);
  }
  payload = { data: [model('a', 2048)] };
  assert.deepEqual(await getContextCap({ endpoint }), { contextTokens: 2048, capChars: 0, source: 'loaded' });
  const dead = await serve(() => {});
  await new Promise((r) => servers.at(-1).close(r));
  assert.deepEqual(await getContextCap({ endpoint: dead }), fallback);
  assert.match(await hint(dead, [35000]), /71,680 chars.*fallback/);
});
test('loopback validation, redirect refusal and proxy bypass keep metadata local', async () => {
  let hits = 0;
  const target = await serve((q, r) => { hits++; r.end(JSON.stringify({ data: [model('a', 65536)] })); });
  const redirect = await serve((q, r) => { r.writeHead(307, { location: target }); r.end(); });
  assert.deepEqual(await getContextCap({ endpoint: redirect }), fallback);
  assert.deepEqual(await getContextCap({ endpoint: target.replace('127.0.0.1', '127.1') }), fallback);
  assert.equal(hits, 0);
  let proxyHits = 0;
  const proxy = await serve((q, r) => { proxyHits++; r.end('{}'); });
  const result = await run('scripts/context-cap.mjs', [], {
    LOCAL_LLM_ENDPOINT_URL: target, HTTP_PROXY: proxy, NODE_USE_ENV_PROXY: '1', NO_PROXY: '', no_proxy: '',
  });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { contextTokens: 65536, capChars: 153600, source: 'loaded' });
  assert.equal(proxyHits, 0);
});
test('stalled metadata times out and hook returns within its five-second budget', async () => {
  const endpoint = await serve(() => {});
  const start = Date.now();
  assert.match(await hint(endpoint, [35000]), /71,680 chars.*fallback/);
  assert.ok(Date.now() - start < 2500, 'hook must fall back in about 1 s');
});
test('hook is silent below 30k and makes no API request', async () => {
  const f = await fake(32768);
  assert.equal(await hint(f.endpoint, [29999]), '');
  assert.throws(() => readFileSync(f.log, 'utf8')); // fake log is created on its first request
});
test('hook delegates inclusive bounds, warns above cap, and looks up once per prompt', async () => {
  const f = await fake(32768);
  const h = await hint(f.endpoint, [30000, 71680, 71681]);
  const lines = h.split('\n');
  assert.equal(lines.length, 3);
  for (const line of lines.slice(0, 2)) {
    assert.match(line, /invoke the local-llm:delegate-local skill/);
    assert.match(line, /bytes \(a char proxy\)/);
    assert.match(line, /32,768 tokens, about 71,680 chars; loaded/);
  }
  assert.match(lines[2], /too big for the loaded model's context.*32,768 tokens, about 71,680 chars.*read it directly or split it/);
  assert.doesNotMatch(lines[2], /invoke/);
  const requests = readFileSync(f.log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(requests.map((r) => r.url), ['/api/v0/models']);
});
test('hook follows a larger loaded context', async () => {
  const f = await fake(65536);
  assert.match(await hint(f.endpoint, [100000]), /153,600 chars; loaded.*invoke/);
});
test('batch defaults follow context and index reports the source; explicit cap wins', async () => {
  const input = join(tmp, 'batch.txt');
  writeFileSync(input, Array.from({ length: 100 }, (_, i) => `L${i}\tuser\ttext\t` + 'x'.repeat(990)).join('\n'));
  const job = join(tmp, 'job.json');
  for (const [tokens, expected, windows] of [[32768, 71680, 2], [65536, 153600, 1]]) {
    const f = await fake(tokens);
    for (const explicit of [false, true]) {
      writeFileSync(job, JSON.stringify({ prompt: 'Find things', row_schema: { type: 'object' }, ...(explicit ? { max_window_chars: 20000 } : {}) }));
      const out = join(tmp, `out-${tokens}-${explicit}`);
      const r = await run('batch/run.mjs', ['--job', job, '--out', out, input], { LOCAL_LLM_ENDPOINT_URL: f.endpoint, LOCAL_LLM_MODEL: 'fake-context' });
      assert.equal(r.code, 0, r.stderr);
      const idx = readFileSync(join(out, 'index.md'), 'utf8');
      assert.match(idx, new RegExp(`max ${explicit ? 20000 : expected} chars each; source: ${explicit ? 'job' : 'loaded'}`));
      assert.match(idx, new RegExp(`Windows: ${explicit ? 6 : windows} across`));
    }
    const chats = readFileSync(f.log, 'utf8').trim().split('\n').map(JSON.parse).filter((r) => r.body);
    assert.ok(chats.length > 0);
    assert.ok(chats.every((r) => r.body.model === 'fake-context'), 'inference must use the model whose context was selected');
  }
});
test('batch fallback default is reported when model metadata is unavailable', async () => {
  const endpoint = await serve((q, r) => {
    if (q.url === '/api/v0/models') { r.writeHead(404); r.end(); }
    else r.end(JSON.stringify({ choices: [{ message: { content: '{"rows":[]}' }, finish_reason: 'stop' }] }));
  });
  const job = join(tmp, 'fallback-job.json'), input = join(tmp, 'fallback.txt'), out = join(tmp, 'fallback-out');
  writeFileSync(job, JSON.stringify({ prompt: 'Find things', row_schema: { type: 'object' } }));
  writeFileSync(input, 'hello');
  const r = await run('batch/run.mjs', ['--job', job, '--out', out, input], { LOCAL_LLM_ENDPOINT_URL: endpoint });
  assert.equal(r.code, 0, r.stderr);
  assert.match(readFileSync(join(out, 'index.md'), 'utf8'), /max 71680 chars each; source: fallback/);
});
