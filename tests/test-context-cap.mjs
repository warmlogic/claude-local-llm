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
import { getContextCap, capForContext, MIN_DELEGATE_CHARS } from '../scripts/context-cap.mjs';
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
  writeFileSync(port, ''); // A published port file may still be empty while the server starts.
  const p = spawn(process.execPath, [join(repo, 'tests/fake-endpoint.mjs'), port, log, 'context', String(tokens)], { env });
  children.push(p);
  for (let i = 0; i < 100; i++) {
    try {
      const value = readFileSync(port, 'utf8').trim();
      if (value) return { endpoint: `http://127.0.0.1:${value}`, log };
    } catch { /* not created yet */ }
    await new Promise((r) => setTimeout(r, 20));
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
const fallback = { contextTokens: 32768, capChars: 45875, source: 'fallback' };
const assumed = (reason, source = 'fallback') => ({ ...fallback, source, reason });
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
  assert.deepEqual(await getContextCap({ endpoint: a.endpoint }), { contextTokens: 32768, capChars: 45875, source: 'loaded' });
  assert.deepEqual(await getContextCap({ endpoint: b.endpoint }), { contextTokens: 65536, capChars: 98304, source: 'loaded' });
});
test('model selection uses the smallest loaded chat context unless pinned', async () => {
  let models = [model('embed', 999999, 'loaded', 'embeddings'), model('idle', 999999, 'not-loaded'), model('a', 65536)];
  const endpoint = await serve((q, r) => r.end(JSON.stringify({ data: models })));
  assert.equal((await getContextCap({ endpoint })).capChars, 98304);
  models.push(model('b', 16384));
  assert.deepEqual(await getContextCap({ endpoint }), { contextTokens: 16384, capChars: 19660, source: 'loaded' });
  assert.deepEqual(await getContextCap({ endpoint, model: 'b' }), { contextTokens: 16384, capChars: 19660, source: 'loaded' });
  writeFileSync(join(tmp, 'pin.txt'), 'x'.repeat(35000));
  for (const pin of ['missing', 'idle']) {
    assert.deepEqual(await getContextCap({ endpoint, model: pin }), assumed('pinned model not loaded', 'pinned model not loaded'));
    const h = await run('scripts/size-hint.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint, LOCAL_LLM_MODEL: pin }, JSON.stringify({ prompt: join(tmp, 'pin.txt') }));
    assert.match(h.stdout, /assumed 32k context \(model metadata unavailable: pinned model not loaded\)/);
  }
  // Exercise the helper's env defaults in a separate process.
  const result = await run('scripts/context-cap.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint, LOCAL_LLM_MODEL: 'b' });
  assert.deepEqual(JSON.parse(result.stdout), { contextTokens: 16384, capChars: 19660, source: 'loaded' });
});
test('unavailable or malformed metadata falls back; tiny context has no usable room', async () => {
  let payload = {};
  const endpoint = await serve((q, r) => r.end(JSON.stringify(payload)));
  for (const data of [undefined, [], [model('a', 0)], [model('a', '65536')], [model('a', 12.5)], [model('a', 65536, 'not-loaded')]]) {
    payload = { data };
    const reason = data === undefined ? 'no metadata' : data.some((m) => m.state === 'loaded') ? 'invalid context' : 'no chat model loaded';
    assert.deepEqual(await getContextCap({ endpoint }), assumed(reason));
  }
  payload = { data: [model('a', 2048)] };
  assert.deepEqual(await getContextCap({ endpoint }), { contextTokens: 2048, capChars: 0, source: 'loaded' });
  const dead = await serve(() => {});
  await new Promise((r) => servers.at(-1).close(r));
  assert.deepEqual(await getContextCap({ endpoint: dead }), assumed('no metadata'));
  assert.match(await hint(dead, [35000]), /assumed 32k context \(model metadata unavailable: no metadata\).*45,875 chars.*fallback/);
});
test('loopback validation, redirect refusal and proxy bypass keep metadata local', async () => {
  let hits = 0;
  const target = await serve((q, r) => { hits++; r.end(JSON.stringify({ data: [model('a', 65536)] })); });
  const redirect = await serve((q, r) => { r.writeHead(307, { location: target }); r.end(); });
  assert.deepEqual(await getContextCap({ endpoint: redirect }), assumed('http 307'));
  assert.deepEqual(await getContextCap({ endpoint: target.replace('127.0.0.1', '127.1') }), assumed('not loopback'));
  assert.equal(hits, 0);
  let proxyHits = 0;
  const proxy = await serve((q, r) => { proxyHits++; r.end('{}'); });
  const result = await run('scripts/context-cap.mjs', [], {
    LOCAL_LLM_ENDPOINT_URL: target, HTTP_PROXY: proxy, NODE_USE_ENV_PROXY: '1', NO_PROXY: '', no_proxy: '',
  });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { contextTokens: 65536, capChars: 98304, source: 'loaded' });
  assert.equal(proxyHits, 0);
});
test('stalled metadata times out and hook returns within its five-second budget', async () => {
  for (const bodyStall of [false, true]) {
    const endpoint = await serve((q, r) => { if (bodyStall) { r.writeHead(200); r.flushHeaders(); } });
    const start = Date.now();
    assert.match(await hint(endpoint, [35000]), /assumed 32k context \(model metadata unavailable: timeout\).*45,875 chars.*fallback/);
    assert.ok(Date.now() - start < 2500, 'headers and body must both time out in about 1 s');
  }
});
test('hook is silent below 30k and makes no API request', async () => {
  const f = await fake(32768);
  assert.equal(await hint(f.endpoint, [29999]), '');
  assert.throws(() => readFileSync(f.log, 'utf8')); // fake log is created on its first request
});
test('hook delegates inclusive bounds, warns above cap, and looks up once per prompt', async () => {
  const f = await fake(32768);
  const h = await hint(f.endpoint, [30000, 45875, 45876]);
  const lines = h.split('\n');
  assert.equal(lines.length, 4);
  for (const line of lines.slice(0, 2)) {
    assert.match(line, /invoke the local-llm:delegate-local skill/);
    assert.match(line, /invoke the local-llm:delegate-local skill with the Skill tool before reading the file, instead of reading it yourself/);
    assert.match(line, /Send the Skill call and ToolSearch query "select:mcp__plugin_local-llm_local-llm__code_task_files" in the same assistant message \(they are independent\)/);
    assert.match(line, /use the stated size instead of running `wc -c` again/);
    assert.match(line, /bytes \(a char proxy\)/);
    assert.match(line, /32,768 tokens, about 45,875 chars; loaded/);
  }
  assert.match(lines[2], /too big for the loaded model's context.*32,768 tokens, about 45,875 chars.*Grep or Read the relevant slices, or use batch\/run.mjs for many-window jobs/);
  assert.doesNotMatch(lines[2], /invoke/);
  assert.equal(lines[3], 'local-llm: The files that fit exceed the loaded context together; if the job is delegated, make one call per file.');
  const requests = readFileSync(f.log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(requests.map((r) => r.url), ['/api/v0/models']);
  assert.doesNotMatch(await hint(f.endpoint, [30000]), /together/);
  assert.doesNotMatch(await hint(f.endpoint, [50000, 50000]), /together/); // oversized files never get a delegate-per-file line
  const large = await fake(65536);
  assert.doesNotMatch(await hint(large.endpoint, [30000, 30000]), /files together/);
});
test('skill reuses hinted sizes and pairs independent skill and schema loads', () => {
  const skill = readFileSync(join(repo, 'skills/delegate-local/SKILL.md'), 'utf8');
  assert.match(skill, /With a size hint, use its stated size; do not run `wc -c`/);
  assert.match(skill, /Without a hint, get the size without reading the file: `wc -c <file>`/);
  assert.match(skill, /\| Schema lookup \| ToolSearch query `select:mcp__plugin_local-llm_local-llm__code_task_files` \|/);
  assert.match(skill, /Skill call and the schema lookup in the same assistant message: they are independent/);
  assert.match(skill, /Wait for both results before calling the file tool/);
});
test('skill scales spot-checks to stakes while retaining verification safeguards', () => {
  const skill = readFileSync(join(repo, 'skills/delegate-local/SKILL.md'), 'utf8');
  const verify = skill.split('## How to verify\n')[1].split('\n## ')[0];
  assert.match(verify, /footer is present and says `N file\(s\) read` for all the paths/);
  assert.match(verify, /Reject an empty answer, any flag in the table, or an `Error:` result/);
  assert.match(verify, /For extraction ask for JSON and parse it; reject malformed output/);
  assert.match(verify, /No spot-check when no single fact in the answer is load-bearing/);
  assert.match(verify, /When a value, number, name or quoted line matters to the user's question \(extractions, drafts that quote the file\), use one targeted Grep for it \(a few lines\)/);
  assert.match(verify, /never read a successfully delegated file in full by any means/);
  assert.match(verify, /Flags and partial reads: see When it fails/);
  const fails = skill.split('## When it fails\n')[1];
  assert.match(fails, /Input-specific\*\* \(too big, path not allowed, a quality flag, a partial `x\/y file\(s\) read`\): do that one job yourself/);
  assert.match(verify, /When the local model produced the answer, say so in a few words/);
});
test('hook follows a larger loaded context', async () => {
  const f = await fake(65536);
  assert.match(await hint(f.endpoint, [90000]), /98,304 chars; loaded.*invoke/);
});
test('batch defaults follow context and index reports the source; explicit cap wins', async () => {
  const input = join(tmp, 'batch.txt');
  writeFileSync(input, Array.from({ length: 100 }, (_, i) => `L${i}\tuser\ttext\t` + 'x'.repeat(990)).join('\n'));
  const job = join(tmp, 'job.json');
  for (const [tokens, expected, windows] of [[32768, 44390, 3], [65536, 96819, 2]]) {
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
  assert.match(readFileSync(join(out, 'index.md'), 'utf8'), /max 44390 chars each; source: fallback \(assumed 32k context; http 404\)/);
});

test('caps clamp at the 1 MB file limit and share configurable reserves', () => {
  assert.equal(capForContext(1000000), 1000000);
  assert.equal(capForContext(32768, 5024), 44390);
  assert.equal(capForContext(2048), 0);
});
test('invalid JSON and oversized metadata have bounded fallback reasons', async () => {
  for (const [body, reason] of [['{', 'no metadata'], ['x'.repeat(1000001), 'metadata too large']]) {
    const endpoint = await serve((q, r) => r.end(body));
    assert.deepEqual(await getContextCap({ endpoint }), assumed(reason));
  }
});
test('batch refuses contexts with no window room, while an explicit cap wins', async () => {
  const f = await fake(5024);
  const job = join(tmp, 'tiny-job.json'), input = join(tmp, 'tiny.txt'), out = join(tmp, 'tiny-out');
  writeFileSync(input, 'hello');
  for (const explicit of [false, true]) {
    writeFileSync(job, JSON.stringify({ prompt: 'Find things', row_schema: { type: 'object' }, ...(explicit ? { max_window_chars: 100 } : {}) }));
    const r = await run('batch/run.mjs', ['--job', job, '--out', out, input], { LOCAL_LLM_ENDPOINT_URL: f.endpoint });
    assert.equal(r.code, explicit ? 0 : 2, r.stderr);
    if (!explicit) assert.match(r.stderr, /the loaded model's context \(5024 tokens\) leaves no room for a window; load a larger context or set max_window_chars/);
  }
});
