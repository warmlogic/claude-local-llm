#!/usr/bin/env node
// Usage: node run.mjs --job <job.json> --out <dir> <input files...>
// Runs one extraction prompt over many text files on the local model (LM Studio, loopback only), window by
// window, and writes rows.jsonl, dropped.jsonl, failures.jsonl and a short index.md. See AGENTS.md "Batch runner".
// job.json: {"prompt", "row_schema" (JSON schema of one row), "check": "quote-in-line" | "none", "max_window_chars"}
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, realpathSync } from 'node:fs';
import { basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isLoopbackEndpoint, loopbackError } from '../scripts/loopback.mjs';

const REQUEST_TIMEOUT_MS = 180_000;
const MAX_TOKENS = 4000;
const MAX_CONSECUTIVE_UNREACHABLE = 3;
const MAX_FILES_LISTED = 25;

// With any of these defined, Node's env proxy could send the window text through a proxy: refuse to start
// (scripts/no-proxy.sh unsets the same set for the launchers). NO_PROXY is never consulted.
const PROXY_VARS = ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NODE_USE_ENV_PROXY'];

const die = (msg) => { console.error(`run.mjs: ${msg}`); process.exit(2); };

// Whole lines, each window at most `cap` chars (lines joined by "\n"). Returns {windows, overCap}.
export const makeWindows = (lines, cap) => {
  const windows = [];
  const overCap = [];
  let cur = [];
  let size = 0;
  for (const line of lines) {
    if (line.length > cap) { overCap.push(line); continue; }
    if (cur.length && size + 1 + line.length > cap) { windows.push(cur); cur = []; size = 0; }
    size += (cur.length ? 1 : 0) + line.length;
    cur.push(line);
  }
  if (cur.length) windows.push(cur);
  return { windows, overCap };
};

const squash = (s) => s.replace(/\s+/g, ' ').trim();

// quote-in-line: the row cites a line of this window and quotes it (exact, then whitespace-normalized).
export const checkQuote = (row, lineMap) => {
  if (typeof row.line !== 'string' || typeof row.quote !== 'string' || !row.quote.trim()) return 'missing_line_or_quote';
  const text = lineMap.get(row.line);
  if (text === undefined) return 'line_not_in_window';
  if (text.includes(row.quote) || squash(text).includes(squash(row.quote))) return null;
  return 'quote_not_in_line';
};

// A light check of the reply against the row schema: required keys, string and enum properties.
const rowProblem = (row, schema) => {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return 'row is not an object';
  for (const k of schema.required ?? []) if (!(k in row)) return `missing ${k}`;
  for (const [k, p] of Object.entries(schema.properties ?? {})) {
    if (!(k in row)) continue;
    if (p.type === 'string' && typeof row[k] !== 'string') return `${k} is not a string`;
    if (p.enum && !p.enum.includes(row[k])) return `${k} not in enum`;
  }
  return null;
};

export const parseReply = (content, schema) => {
  let obj;
  try { obj = JSON.parse(content); } catch { return { problem: 'not JSON' }; }
  if (!Array.isArray(obj?.rows)) return { problem: 'no rows array' };
  for (const r of obj.rows) { const p = rowProblem(r, schema); if (p) return { problem: p }; }
  return { rows: obj.rows };
};

// One chat call. Returns {content, finish, usage} or {failure: 'endpoint_unreachable'|'http_error'|..., detail}.
const chat = async (endpoint, body) => {
  let res;
  try {
    res = await fetch(`${endpoint.replace(/\/+$/, '')}/v1/chat/completions`, {
      method: 'POST', redirect: 'manual', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (e) {
    return { failure: 'endpoint_unreachable', detail: e.name === 'TimeoutError' ? 'timeout' : String(e.cause?.code ?? e.message) };
  }
  const raw = await res.text().catch(() => '');
  if (!res.ok) return { failure: 'http_error', detail: `HTTP ${res.status}` };
  try {
    const j = JSON.parse(raw);
    const c = j.choices?.[0];
    return { content: c?.message?.content ?? '', finish: c?.finish_reason, usage: j.usage ?? {} };
  } catch { return { content: '', finish: 'stop', usage: {} }; } // unparseable envelope reads as a malformed reply
};

const main = async () => {
  const args = process.argv.slice(2);
  const opt = {};
  const files = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--job' || args[i] === '--out') opt[args[i].slice(2)] = args[++i];
    else files.push(args[i]);
  }
  if (!opt.job || !opt.out || files.length === 0) die('usage: run.mjs --job <job.json> --out <dir> <input files...>');
  const proxied = PROXY_VARS.filter((n) => Object.hasOwn(process.env, n));
  if (proxied.length) die(`refusing to run: ${proxied.join(', ')} is defined and could route file text through a proxy; start with them unset (env -u ...)`);
  if (new Set(files.map((f) => basename(f))).size !== files.length) die('input files must have distinct basenames (results are keyed by basename)');
  const endpoint = process.env.LOCAL_LLM_ENDPOINT_URL || 'http://127.0.0.1:1234';
  if (!isLoopbackEndpoint(endpoint)) die(loopbackError(endpoint));
  let job;
  try { job = JSON.parse(readFileSync(opt.job, 'utf8')); } catch (e) { die(`cannot read job: ${e.message}`); }
  const cap = job.max_window_chars ?? 50000;
  if (typeof job.prompt !== 'string' || typeof job.row_schema !== 'object' || !Number.isInteger(cap) || cap < 1) die('job needs prompt, row_schema, and a positive integer max_window_chars');
  const check = job.check ?? 'none';
  if (check !== 'none' && check !== 'quote-in-line') die(`unknown check: ${check}`);

  mkdirSync(opt.out, { recursive: true });
  const path = (n) => `${opt.out}/${n}`;
  for (const n of ['rows.jsonl', 'dropped.jsonl', 'failures.jsonl']) writeFileSync(path(n), '');
  const emit = (n, o) => appendFileSync(path(n), JSON.stringify(o) + '\n');

  const schema = { type: 'object', properties: { rows: { type: 'array', items: job.row_schema } }, required: ['rows'] };
  const stats = { windows: 0, kept: 0, dropped: 0, tokens: { prompt: 0, completion: 0 }, failures: {}, kinds: {}, perFile: [] };
  const fail = (type, f, w, detail) => { stats.failures[type] = (stats.failures[type] ?? 0) + 1; emit('failures.jsonl', { type, file: f, window: w, detail }); };
  const started = Date.now();
  let unreachable = 0;
  let aborted = false;

  outer: for (const file of files) {
    const name = basename(file);
    const fs = { name, windows: 0, kept: 0, dropped: 0 };
    stats.perFile.push(fs);
    let text;
    try { text = readFileSync(file, 'utf8'); } catch (e) { fail('unreadable_input', name, 0, e.code ?? e.message); continue; }
    const { windows, overCap } = makeWindows(text.split('\n').filter((l) => l.length), cap);
    for (const l of overCap) fail('line_over_cap', name, 0, `${l.split('\t')[0].slice(0, 20)} (${l.length} chars)`);
    for (const [i, win] of windows.entries()) {
      const w = i + 1;
      const lineMap = new Map(win.map((l) => [l.split('\t')[0], l]));
      const body = {
        messages: [{ role: 'user', content: `${job.prompt}\n\n--- BEGIN TEXT ---\n${win.join('\n')}\n--- END TEXT ---` }],
        temperature: 0, max_tokens: MAX_TOKENS,
        response_format: { type: 'json_schema', json_schema: { name: 'rows', strict: true, schema } },
      };
      stats.windows++; fs.windows++;
      let parsed;
      for (let attempt = 0; attempt < 2; attempt++) {
        const r = await chat(endpoint, body);
        if (r.failure) {
          fail(r.failure, name, w, r.detail);
          if (r.failure === 'endpoint_unreachable' && ++unreachable >= MAX_CONSECUTIVE_UNREACHABLE) { aborted = true; break outer; }
          break;
        }
        unreachable = 0;
        stats.tokens.prompt += r.usage.prompt_tokens ?? 0;
        stats.tokens.completion += r.usage.completion_tokens ?? 0;
        if (r.finish === 'length') { fail('finish_length', name, w, `${MAX_TOKENS} max_tokens`); break; }
        const p = parseReply(r.content, job.row_schema);
        if (p.rows) { parsed = p.rows; break; }
        if (attempt === 1) fail('malformed_reply', name, w, p.problem);
      }
      for (const row of parsed ?? []) {
        const out = { file: name, window: w, ...row };
        const reason = check === 'quote-in-line' ? checkQuote(row, lineMap) : null;
        if (reason) { emit('dropped.jsonl', { reason, ...out }); stats.dropped++; fs.dropped++; continue; }
        emit('rows.jsonl', out); stats.kept++; fs.kept++;
        if (typeof row.kind === 'string') stats.kinds[row.kind] = (stats.kinds[row.kind] ?? 0) + 1;
      }
    }
  }

  const total = stats.kept + stats.dropped;
  const list = (o) => Object.entries(o).map(([k, v]) => `${k} ${v}`).join(', ') || 'none';
  const shown = stats.perFile.slice(0, MAX_FILES_LISTED);
  const index = [
    `# Batch index: ${basename(opt.job)}`,
    '',
    aborted ? `**ABORTED** after ${MAX_CONSECUTIVE_UNREACHABLE} consecutive unreachable-endpoint failures (${endpoint}); counts below are partial.` : 'Completed.',
    `Windows: ${stats.windows} across ${files.length} files (max ${cap} chars each). Wall time: ${Math.round((Date.now() - started) / 1000)} s.`,
    `Rows: ${stats.kept} kept, ${stats.dropped} dropped by check "${check}"${total ? ` (${Math.round((100 * stats.kept) / total)}% passing)` : ''}.`,
    `Kept per kind: ${list(stats.kinds)}.`,
    `Failures: ${list(stats.failures)}.`,
    `Tokens: ${stats.tokens.prompt} prompt, ${stats.tokens.completion} completion.`,
    '',
    '| file | windows | kept | dropped |',
    '| --- | ---: | ---: | ---: |',
    ...shown.map((f) => `| ${f.name} | ${f.windows} | ${f.kept} | ${f.dropped} |`),
    ...(stats.perFile.length > shown.length ? [`| (${stats.perFile.length - shown.length} more files) | | | |`] : []),
    '',
    'Detail: rows.jsonl, dropped.jsonl (with reason), failures.jsonl in this directory.',
  ];
  writeFileSync(path('index.md'), index.join('\n') + '\n');
  console.log(index.slice(2, 8).join('\n'));
  process.exit(aborted ? 1 : 0);
};

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) main();
