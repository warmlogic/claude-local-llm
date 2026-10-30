// Offline context bounds, hook and batch integration. Also run by test-fence.sh.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, cpSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
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
delete env.CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS; // default tests must use the manifest
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
const hintResult = async (endpoint, sizes, options = {}) => {
  const paths = sizes.map((size, i) => {
    const p = join(tmp, `hint-${i}.txt`); writeFileSync(p, 'x'.repeat(size)); return p;
  });
  const r = await run('scripts/size-hint.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint, ...options }, JSON.stringify({ prompt: paths.join(' ') }));
  assert.equal(r.code, 0, r.stderr);
  return r;
};
const hintText = (r) => r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.additionalContext : '';
const optedHint = async (endpoint, sizes, options = { CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS: 'classify,extract' }) => hintText(await hintResult(endpoint, sizes, options));

test('context formula follows 32k and 64k loaded contexts', async () => {
  const a = await fake(32768), b = await fake(65536);
  assert.equal(MIN_DELEGATE_CHARS, 30000);
  assert.deepEqual(await getContextCap({ endpoint: a.endpoint }), { contextTokens: 32768, capChars: 45875, source: 'loaded', model: 'fake-context' });
  assert.deepEqual(await getContextCap({ endpoint: b.endpoint }), { contextTokens: 65536, capChars: 98304, source: 'loaded', model: 'fake-context' });
});
test('model selection uses the smallest loaded chat context unless pinned', async () => {
  let models = [model('embed', 999999, 'loaded', 'embeddings'), model('idle', 999999, 'not-loaded'), model('a', 65536)];
  const endpoint = await serve((q, r) => r.end(JSON.stringify({ data: models })));
  assert.deepEqual(await getContextCap({ endpoint }), { contextTokens: 65536, capChars: 98304, source: 'loaded', model: 'a' });
  models.push(model('b', 16384));
  assert.deepEqual(await getContextCap({ endpoint }), { contextTokens: 16384, capChars: 19660, source: 'loaded' });
  assert.deepEqual(await getContextCap({ endpoint, model: 'b' }), { contextTokens: 16384, capChars: 19660, source: 'loaded', model: 'b' });
  writeFileSync(join(tmp, 'pin.txt'), 'x'.repeat(35000));
  for (const pin of ['missing', 'idle']) {
    assert.deepEqual(await getContextCap({ endpoint, model: pin }), assumed('pinned model not loaded', 'pinned model not loaded'));
    const h = await run('scripts/size-hint.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint, LOCAL_LLM_MODEL: pin, CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS: 'classify,extract' }, JSON.stringify({ prompt: join(tmp, 'pin.txt') }));
    assert.match(h.stdout, /assumed 32k context \(model metadata unavailable: pinned model not loaded\)/);
  }
  // Exercise the helper's env defaults in a separate process.
  const result = await run('scripts/context-cap.mjs', [], { LOCAL_LLM_ENDPOINT_URL: endpoint, LOCAL_LLM_MODEL: 'b' });
  assert.deepEqual(JSON.parse(result.stdout), { contextTokens: 16384, capChars: 19660, source: 'loaded', model: 'b' });
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
  assert.deepEqual(await getContextCap({ endpoint }), { contextTokens: 2048, capChars: 0, source: 'loaded', model: 'a' });
  const dead = await serve(() => {});
  await new Promise((r) => servers.at(-1).close(r));
  assert.deepEqual(await getContextCap({ endpoint: dead }), assumed('no metadata'));
  assert.match(await optedHint(dead, [35000]), /assumed 32k context \(model metadata unavailable: no metadata\).*45,875 chars.*fallback/);
});
test('loopback validation, redirect refusal and proxy bypass keep metadata local', async () => {
  let hits = 0;
  const target = await serve((q, r) => { hits++; r.end(JSON.stringify({ data: [model('a', 65536)] })); });
  const redirect = await serve((q, r) => { r.writeHead(307, { location: target }); r.end(); });
  assert.deepEqual(await getContextCap({ endpoint: redirect }), assumed('http 307'));
  assert.deepEqual(await getContextCap({ endpoint: target.replace('127.0.0.1', '127.1') }), assumed('not a loopback server root'));
  assert.deepEqual(await getContextCap({ endpoint: `${target}/v1` }), assumed('not a loopback server root'));
  assert.equal(hits, 0);
  assert.deepEqual(await getContextCap({ endpoint: `${target}/` }), { contextTokens: 65536, capChars: 98304, source: 'loaded', model: 'a' });
  let proxyHits = 0;
  const proxy = await serve((q, r) => { proxyHits++; r.end('{}'); });
  const result = await run('scripts/context-cap.mjs', [], {
    LOCAL_LLM_ENDPOINT_URL: target, HTTP_PROXY: proxy, NODE_USE_ENV_PROXY: '1', NO_PROXY: '', no_proxy: '',
  });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { contextTokens: 65536, capChars: 98304, source: 'loaded', model: 'a' });
  assert.equal(proxyHits, 0);
});
test('stalled metadata times out and hook returns within its five-second budget', async () => {
  for (const bodyStall of [false, true]) {
    const endpoint = await serve((q, r) => { if (bodyStall) { r.writeHead(200); r.flushHeaders(); } });
    const start = Date.now();
    assert.match(await optedHint(endpoint, [35000]), /assumed 32k context \(model metadata unavailable: timeout\).*45,875 chars.*fallback/);
    assert.ok(Date.now() - start < 2500, 'headers and body must both time out in about 1 s');
  }
});
test('hook is silent below 30k and makes no API request', async () => {
  const f = await fake(32768);
  assert.equal(await optedHint(f.endpoint, [29999]), '');
  assert.throws(() => readFileSync(f.log, 'utf8')); // fake log is created on its first request
});
test('default is silent for 35k files and retains only the above-cap note', async () => {
  const f = await fake(32768);
  assert.equal((await hintResult(f.endpoint, [35000])).stdout, '');
  const r = await hintResult(f.endpoint, [35000, 35000, 45876]);
  assert.equal(r.stderr, '');
  const text = hintText(r);
  assert.equal(text.split('\n').length, 1);
  assert.match(text, /hint-2.txt.*too big for the loaded model's context.*45,875 chars.*Grep or Read the relevant slices.*Only when the user explicitly requests a local batch over multiple files, use batch\/run.mjs/);
  assert.doesNotMatch(text, /invoke|delegat|together/);
});
test('hook delegates inclusive bounds, warns above cap, and looks up once per prompt', async () => {
  const f = await fake(32768);
  const h = await optedHint(f.endpoint, [30000, 45875, 45876]);
  const lines = h.split('\n');
  assert.equal(lines.length, 4);
  for (const line of lines.slice(0, 2)) {
    assert.match(line, /read-only classify or extract task, invoke/);
    assert.doesNotMatch(line, /summarize|draft/);
    assert.match(line, /invoke the local-llm:delegate-local skill with the Skill tool before reading the file, instead of reading it yourself/);
    assert.match(line, /Send the Skill call and ToolSearch query "select:mcp__plugin_local-llm_local-llm__code_task_files" in the same assistant message \(they are independent\)/);
    assert.match(line, /use the stated size instead of running `wc -c` again/);
    assert.match(line, /bytes \(a char proxy\)/);
    assert.match(line, /32,768 tokens, about 45,875 chars; loaded/);
  }
  assert.match(lines[2], /too big for the loaded model's context.*32,768 tokens, about 45,875 chars.*Grep or Read the relevant slices.*Only when the user explicitly requests a local batch over multiple files, use batch\/run.mjs/);
  assert.doesNotMatch(lines[2], /invoke/);
  assert.equal(lines[3], 'local-llm: The files that fit exceed the loaded context together; if the job is delegated, make one call per file.');
  const requests = readFileSync(f.log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(requests.map((r) => r.url), ['/api/v0/models']);
  assert.doesNotMatch(await optedHint(f.endpoint, [30000]), /together/);
  assert.doesNotMatch(await optedHint(f.endpoint, [50000, 50000]), /together/); // oversized files never get a delegate-per-file line
  const large = await fake(65536);
  assert.doesNotMatch(await optedHint(large.endpoint, [30000, 30000]), /files together/);
});
test('unsaved task kinds come from the manifest default', async () => {
  const f = await fake(32768);
  const copy = join(tmp, 'plugin-copy');
  cpSync(join(repo, 'scripts'), join(copy, 'scripts'), { recursive: true });
  mkdirSync(join(copy, '.claude-plugin'));
  const manifest = JSON.parse(readFileSync(join(repo, '.claude-plugin/plugin.json'), 'utf8'));
  assert.equal(manifest.userConfig.delegate_tasks.type, 'string');
  assert.equal(manifest.userConfig.delegate_tasks.default, '');
  manifest.userConfig.delegate_tasks.default = 'extract,draft';
  writeFileSync(join(copy, '.claude-plugin/plugin.json'), JSON.stringify(manifest));
  const file = join(tmp, 'manifest-default.txt');
  writeFileSync(file, 'x'.repeat(35000));
  const r = await run(relative(repo, join(copy, 'scripts/size-hint.mjs')), [], { LOCAL_LLM_ENDPOINT_URL: f.endpoint }, JSON.stringify({ prompt: file }));
  assert.equal(r.code, 0, r.stderr);
  assert.match(hintText(r), /read-only extract or draft task, invoke/);
  assert.doesNotMatch(hintText(r), /classify|summarize/);
});
test('hook delegates only configured known kinds, preserving their order', async () => {
  const f = await fake(32768);
  const option = (value) => ({ CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS: value });
  assert.match(await optedHint(f.endpoint, [35000], option('classify,extract,summarize')), /read-only classify, extract or summarize task, invoke/);
  assert.match(await optedHint(f.endpoint, [35000], option('draft')), /read-only draft task, invoke/);
  const mixed = await hintResult(f.endpoint, [35000], option(' extract,unknown,classify,extract '));
  assert.match(hintText(mixed), /read-only extract or classify task, invoke/);
  assert.doesNotMatch(hintText(mixed), /unknown|summarize|draft/);
  assert.match(mixed.stderr, /ignoring unknown delegate_tasks kinds:.*unknown/);
});
test('empty or unknown-only tasks disable instructions but keep oversized warnings', async () => {
  const f = await fake(32768);
  for (const value of ['', 'unknown,other']) {
    const options = { CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS: value };
    assert.equal(await optedHint(f.endpoint, [35000, 35000], options), '');
    const r = await hintResult(f.endpoint, [35000, 35000, 45876], options);
    assert.match(hintText(r), /too big for the loaded model's context/);
    assert.equal(hintText(r).split('\n').length, 1);
    assert.doesNotMatch(hintText(r), /invoke|delegat|together/);
    if (value) assert.match(r.stderr, /ignoring unknown delegate_tasks kinds:.*unknown.*other/);
    else assert.equal(r.stderr, '');
  }
});
test('skill requires hinted kinds or an explicit local-model request', () => {
  const skill = readFileSync(join(repo, 'skills/delegate-local/SKILL.md'), 'utf8');
  assert.match(skill, /Delegate unprompted only for the task kinds named by the size hint/);
  assert.match(skill, /With no hint naming kinds, delegate only when the user explicitly asks for the local model/);
  assert.match(skill.split('\n')[2], /with no hint naming kinds, use it only when the user explicitly asks for the local model/);
  assert.match(skill, /bulk checkable.*invoke `local-llm:batch-local` only when the user explicitly asks/);
});
test('delegation harness prompts exercise classify and extract with opt-in', () => {
  const harness = readFileSync(join(repo, 'tests/test-delegation.sh'), 'utf8');
  const prompts = harness.split('prompt_for() {')[1].split('THRESHOLD=')[0];
  for (const expected of [
    'b) echo "Classify $FIX/app-2k.log in five bullet points."',
    'e) echo "Classify $FIX/app-35k.log in three bullet points."',
    'h) echo "Classify $DOC in 5 bullets."',
    'a2) echo "Classify this document: $FIX/notes-0412.md"',
    'g) echo "Use the local model to classify $FIX/notes-0412.md"',
    '*) echo "Classify $FIX/app-35k.log in five bullet points."',
  ]) assert.ok(prompts.includes(expected), expected);
  assert.ok(harness.includes('"Now classify $FIX/app-35k-b.log in three bullet points."'));
  assert.doesNotMatch(prompts, /summarize/i);
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
  assert.match(await optedHint(f.endpoint, [90000]), /98,304 chars; loaded.*invoke/);
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
