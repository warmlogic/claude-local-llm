#!/usr/bin/env node
// Usage: node run.mjs (--job <job.json> | --job-json <json>) [--number] [--out <dir>] <input files...>
// Runs one extraction prompt over many text files on the local model (LM Studio, loopback only), window by
// window, and writes rows.jsonl, dropped.jsonl, failures.jsonl and a short index.md. See AGENTS.md "Batch runner".
// job.json: {"prompt", "row_schema" (JSON schema of one row), "check": "quote-in-line" | "none", "max_window_chars"?,
// "reasoning_effort"?, "min_rows_per_window"? (positive integer)}. index.md is the one file Claude reads, so it
// never claims more than happened: a stub says RUNNING until the final index replaces it, and its header
// says how many windows were answered.
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, mkdtempSync, renameSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isLoopbackEndpoint, loopbackError, PROXY_VARS } from '../scripts/loopback.mjs';
import { getContextCap, capForContext } from '../scripts/context-cap.mjs';
import { upstreamCode } from '../server/endpoint.mjs';

const REQUEST_TIMEOUT_MS = 180_000;
const MAX_TOKENS = 4000;
const MAX_CONSECUTIVE_FAILED_REQUESTS = 3;
const MAX_FILES_LISTED = 25;
const MIN_QUOTE_CHARS = 12;
const RESERVED_ROW_KEYS = ['file', 'window', 'reason']; // the runner's own keys; a row schema may not declare them
const REQUEST_FAILURES = new Set(['endpoint_unreachable', 'timeout', 'http_error', 'bad_envelope']);
const HINTS = { context_length_exceeded: ' (lower max_window_chars)', no_models_loaded: ' (load a model in LM Studio)' };

class UsageError extends Error {}
const usage = (msg) => { throw new UsageError(msg); };

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
// The text of a numbered line without its id fields: `L<n>\t<text>`, or flattened `L<n>\t<role>\t<kind>\t<text>`.
const textField = (line) => line.replace(/^L\d+\t(?:(?:user|assistant)\t[^\t]*\t)?/, '');

// quote-in-line: the row cites a line of this window and quotes its text (exact, then whitespace-normalized),
// not its id fields, and at least MIN_QUOTE_CHARS long unless it is the whole text.
export const checkQuote = (row, lineMap, rawNumbered = false) => {
  if (typeof row.line !== 'string' || typeof row.quote !== 'string' || !row.quote.trim()) return 'missing_line_or_quote';
  const line = lineMap.get(row.line);
  if (line === undefined) return 'line_not_in_window';
  const text = rawNumbered ? line.replace(/^L\d+\t/, '') : textField(line);
  const [q, t] = [squash(row.quote), squash(text)];
  if (q.length < MIN_QUOTE_CHARS && q !== t) return 'quote_too_short'; // lengths count after whitespace is normalized
  return text.includes(row.quote) || t.includes(q) ? null : 'quote_not_in_line';
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

const tryJson = (s) => { try { return JSON.parse(s); } catch { return undefined; } };

// One chat call. Returns {content, finish, usage} or {failure, detail}. Details are fixed strings built from the
// status and an allowlisted error code (upstreamCode), never body text: it can echo the prompt.
const chat = async (endpoint, body) => {
  let res;
  try {
    res = await fetch(`${endpoint.replace(/\/+$/, '')}/v1/chat/completions`, {
      method: 'POST', redirect: 'manual', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (e) {
    return e.name === 'TimeoutError' ? { failure: 'timeout', detail: `no reply in ${REQUEST_TIMEOUT_MS / 1000} s` }
      : { failure: 'endpoint_unreachable', detail: String(e.cause?.code ?? e.name) };
  }
  let raw = null;
  try { raw = await res.text(); } catch { /* reported below */ }
  if (!res.ok) {
    const code = upstreamCode(tryJson(raw));
    return { failure: 'http_error', detail: `HTTP ${res.status}${code ? ` ${code}${HINTS[code] ?? ''}` : ''}` };
  }
  if (raw === null) return { failure: 'bad_envelope', detail: 'reply body unreadable' };
  const j = tryJson(raw);
  const c = j?.choices?.[0];
  if (!c) return { failure: 'bad_envelope', detail: j === undefined ? 'non-JSON reply' : 'no choices in reply' };
  return { content: typeof c.message?.content === 'string' ? c.message.content : '', finish: c.finish_reason, usage: j.usage ?? {} };
};

const parseArgs = (args) => {
  const opt = {};
  const files = [];
  for (let i = 0; i < args.length; i++) {
    if (['--job', '--job-json', '--out'].includes(args[i])) {
      const key = args[i].slice(2);
      if (opt[key] !== undefined || !args[i + 1] || args[i + 1].startsWith('--')) usage(`missing or repeated --${key}`);
      opt[key] = args[++i];
    }
    else if (args[i] === '--number') opt.number = true;
    else if (args[i].startsWith('--')) usage(`unknown option: ${args[i]}`);
    else files.push(args[i]);
  }
  if ((Boolean(opt.job) === Boolean(opt['job-json'])) || files.length === 0) usage('usage: run.mjs (--job <job.json> | --job-json <json>) [--number] [--out <dir>] <input files...>');
  opt.out = opt.out ? resolve(opt.out) : mkdtempSync(join(tmpdir(), 'local-llm-batch-'));
  return { opt, files };
};

const loadJob = async (opt, endpoint) => {
  let job;
  try { job = JSON.parse(opt['job-json'] ?? readFileSync(opt.job, 'utf8')); } catch (e) { usage(`cannot read job: ${e.message}`); }
  const defaults = job?.max_window_chars === undefined ? await getContextCap({ endpoint }) : null;
  const cap = defaults ? capForContext(defaults.contextTokens, MAX_TOKENS + 1024) : job.max_window_chars;
  const capSource = defaults ? `${defaults.source}${defaults.reason ? ` (assumed 32k context; ${defaults.reason})` : ''}` : 'job';
  if (defaults && cap < 1) usage(`the loaded model's context (${defaults.contextTokens} tokens) leaves no room for a window; load a larger context or set max_window_chars`);
  if (typeof job?.prompt !== 'string' || !Number.isInteger(cap) || cap < 1) usage('job needs a prompt and a positive integer max_window_chars');
  if (job.min_rows_per_window !== undefined && (!Number.isInteger(job.min_rows_per_window) || job.min_rows_per_window < 1)) usage('job min_rows_per_window must be a positive integer');
  if (!job.row_schema || typeof job.row_schema !== 'object' || Array.isArray(job.row_schema)) usage('job row_schema must be a JSON schema object');
  const reserved = RESERVED_ROW_KEYS.filter((k) => Object.hasOwn(job.row_schema.properties ?? {}, k));
  if (reserved.length) usage(`row_schema may not declare ${reserved.join(', ')}: the runner sets them`);
  const check = job.check ?? 'none';
  if (check !== 'none' && check !== 'quote-in-line') usage(`unknown check: ${check}`);
  return { job, cap, check, capSource };
};

let indexPath = null;
const main = async () => {
  const { opt, files } = parseArgs(process.argv.slice(2));
  rmSync(`${opt.out}/index.md`, { force: true }); // a refused re-run must not leave the previous run's index looking current
  const proxied = PROXY_VARS.filter((n) => Object.hasOwn(process.env, n));
  if (proxied.length) usage(`refusing to run: ${proxied.join(', ')} is defined and could route file text through a proxy; start with them unset (env -u ...)`);
  if (new Set(files.map((f) => basename(f))).size !== files.length) usage('input files must have distinct basenames (results are keyed by basename)');
  const endpoint = process.env.LOCAL_LLM_ENDPOINT_URL || 'http://127.0.0.1:1234';
  if (!isLoopbackEndpoint(endpoint)) usage(loopbackError(endpoint));
  const { job, cap, check, capSource } = await loadJob(opt, endpoint);

  if (check === 'quote-in-line' && !opt.number) { // every line must carry an id, or a quote could cite an arbitrary string; one file in memory at a time
    for (const f of files) {
      let t;
      try { t = readFileSync(f, 'utf8'); } catch { continue; } // reported as unreadable_input when its turn comes
      if (t.split('\n').some((l) => l.length && !/^L\d+\t/.test(l))) usage(`${f}: not numbered input; run batch/flatten-transcripts.mjs (or use --number) first`);
    }
  }

  mkdirSync(opt.out, { recursive: true });
  const path = (n) => `${opt.out}/${n}`;
  const started = new Date();
  indexPath = path('index.md');
  writeFileSync(indexPath, `RUNNING since ${started.toISOString()} (pid ${process.pid}) — not complete\n`);
  for (const n of ['rows.jsonl', 'dropped.jsonl', 'failures.jsonl']) writeFileSync(path(n), '');
  const emit = (n, o) => appendFileSync(path(n), JSON.stringify(o) + '\n');

  const schema = { type: 'object', properties: { rows: { type: 'array', items: job.row_schema } }, required: ['rows'] };
  const stats = { windows: 0, answered: 0, noRows: 0, noRowIds: [], kept: 0, dropped: 0, reached: 0, tokens: { prompt: 0, completion: 0 }, failures: {}, kinds: {}, perFile: [] };
  let last = null;
  let windowFailure = null;
  const fail = (type, f, w, detail) => {
    stats.failures[type] = (stats.failures[type] ?? 0) + 1;
    last = `${type} ${detail}`; windowFailure = type;
    emit('failures.jsonl', { type, file: f, window: w, detail });
  };
  let failedRequests = 0; // consecutive; only an answered window resets it
  let aborted = false;

  outer: for (const file of files) {
    const name = basename(file);
    const fs = { name, windows: 0, kept: 0, dropped: 0 };
    stats.perFile.push(fs); stats.reached++;
    let text;
    try { text = readFileSync(file, 'utf8'); } catch (e) { fail('unreadable_input', name, 0, e.code ?? e.name); continue; }
    const { windows, overCap } = makeWindows(text.split(/\r?\n/).map((l, i) => opt.number && l.length ? `L${i + 1}\t${l}` : l).filter((l) => l.length), cap);
    for (const l of overCap) fail('line_over_cap', name, 0, `${l.split('\t')[0].slice(0, 20)} (${l.length} chars)`);
    if (!windows.length && !overCap.length) fail('empty_input', name, 0, 'no lines');
    for (const [i, win] of windows.entries()) {
      const w = i + 1;
      windowFailure = null;
      const ids = win.map((l) => l.split('\t')[0]);
      const lineMap = new Map(win.map((l, j) => [ids[j], l]));
      stats.windows++; fs.windows++;
      const [kept0, dropped0] = [fs.kept, fs.dropped];
      let parsed;
      if (check === 'quote-in-line' && lineMap.size < win.length) fail('duplicate_line_id', name, w, 'a line id repeats in this window');
      else {
        const body = {
          ...(process.env.LOCAL_LLM_MODEL ? { model: process.env.LOCAL_LLM_MODEL } : {}),
          messages: [{ role: 'user', content: `${job.prompt}\n\n--- BEGIN TEXT ---\n${win.join('\n')}\n--- END TEXT ---` }],
          // reasoning off by default: a reasoning model otherwise spends the whole token budget thinking and returns no rows
          temperature: 0, max_tokens: MAX_TOKENS, reasoning_effort: job.reasoning_effort ?? 'none',
          response_format: { type: 'json_schema', json_schema: { name: 'rows', strict: true, schema } },
        };
        for (let attempt = 0; attempt < 2; attempt++) {
          const r = await chat(endpoint, body);
          if (r.failure) {
            fail(r.failure, name, w, r.detail);
            if (REQUEST_FAILURES.has(r.failure) && ++failedRequests >= MAX_CONSECUTIVE_FAILED_REQUESTS) { aborted = true; break outer; }
            break;
          }
          stats.tokens.prompt += r.usage.prompt_tokens ?? 0;
          stats.tokens.completion += r.usage.completion_tokens ?? 0;
          if (r.finish === 'length') { fail('finish_length', name, w, `${MAX_TOKENS} max_tokens`); break; }
          const p = parseReply(r.content, job.row_schema);
          if (p.rows) { parsed = p.rows; failedRequests = 0; stats.answered++; break; }
          if (attempt === 1) fail('malformed_reply', name, w, p.problem);
        }
      }
      if (parsed && parsed.length < job.min_rows_per_window) fail('under_min_rows', name, w, `${parsed.length} rows`);
      for (const row of parsed ?? []) {
        const out = { ...row, file: name, window: w }; // the runner's keys win
        const reason = check === 'quote-in-line' ? checkQuote(row, lineMap, opt.number) : null;
        if (reason) { emit('dropped.jsonl', { ...out, reason }); stats.dropped++; fs.dropped++; continue; }
        emit('rows.jsonl', out); stats.kept++; fs.kept++;
        if (typeof row.kind === 'string') stats.kinds[row.kind] = (stats.kinds[row.kind] ?? 0) + 1;
      }
      if (parsed && fs.kept === kept0) {
        stats.noRows++;
        if (stats.noRowIds.length < 10) stats.noRowIds.push(`(${name}, ${w})`);
      }
      console.error(`${name} window ${w}/${windows.length}: ${windowFailure ?? `kept ${fs.kept - kept0} dropped ${fs.dropped - dropped0}`}`);
    }
  }

  const failed = stats.answered === 0;
  const base = failed ? `**FAILED**: no window answered (last failure: ${last ?? 'none'})${aborted ? `; aborted after ${MAX_CONSECUTIVE_FAILED_REQUESTS} consecutive failed requests` : ''}.`
    : aborted ? `**ABORTED** after ${MAX_CONSECUTIVE_FAILED_REQUESTS} consecutive failed requests (last failure: ${last}): ${stats.answered} of ${stats.windows} windows answered.`
    : `Completed: ${stats.answered} of ${stats.windows} windows answered${stats.noRows ? `; ${stats.noRows} returned no rows` : ''}${stats.failures.under_min_rows ? `; ${stats.failures.under_min_rows} under minimum rows` : ''}.`;
  const skipped = ['unreadable_input', 'line_over_cap', 'empty_input', 'duplicate_line_id'].reduce((n, t) => n + (stats.failures[t] ?? 0), 0);
  const header = skipped ? base.replace(/\.$/, `; ${skipped} input problem${skipped > 1 ? 's' : ''} skipped.`) : base;
  const total = stats.kept + stats.dropped;
  const list = (o) => Object.entries(o).map(([k, v]) => `${k} ${v}`).join(', ') || 'none';
  const shown = stats.perFile.slice(0, MAX_FILES_LISTED);
  const summary = [
    header,
    `Windows: ${stats.windows} across ${stats.reached} of ${files.length} files (max ${cap} chars each; source: ${capSource}). Started ${started.toISOString()}, wall time ${Math.round((Date.now() - started) / 1000)} s.`,
    `Rows: ${stats.kept} kept, ${stats.dropped} dropped by check "${check}"${total ? ` (${Math.round((100 * stats.kept) / total)}% passing)` : ''}.`,
    `Kept per kind: ${list(stats.kinds)}.`,
    `Failures: ${list(stats.failures)}.`,
    ...(stats.noRows ? [`Returned no rows: ${stats.noRows} (includes all rows dropped by check); ${stats.noRowIds.join(', ')}.`] : []),
    `Tokens: ${stats.tokens.prompt} prompt, ${stats.tokens.completion} completion.`,
  ];
  const index = [
    `# Batch index: ${opt.job ? basename(opt.job) : 'inline job'}`, '', ...summary, '',
    '| file | windows | kept | dropped |', '| --- | ---: | ---: | ---: |',
    ...shown.map((f) => `| ${f.name} | ${f.windows} | ${f.kept} | ${f.dropped} |`),
    ...(stats.perFile.length > shown.length ? [`| (${stats.perFile.length - shown.length} more files) | | | |`] : []),
    '', 'Detail: rows.jsonl, dropped.jsonl (with reason), failures.jsonl in this directory.',
  ];
  writeFileSync(`${indexPath}.tmp`, index.join('\n') + '\n');
  renameSync(`${indexPath}.tmp`, indexPath);
  console.log(summary.join('\n'));
  console.log(indexPath); // stable last stdout line, including failed/aborted runs with an index
  process.exit(failed || aborted ? 1 : 0);
};

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch((e) => {
    console.error(`run.mjs: ${e instanceof UsageError ? e.message : `crashed: ${e.stack ?? e}`}`);
    if (!(e instanceof UsageError) && indexPath) { try { writeFileSync(indexPath, `**FAILED**: run.mjs crashed (${e.name}); results are incomplete.\n`); } catch { /* the stderr message stands */ } }
    process.exit(2);
  });
}
