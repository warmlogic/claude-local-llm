// UserPromptSubmit hook. When the prompt names an existing regular file of at least 30,000 bytes (absolute, ~/, or
// relative to the hook input's cwd), adds a one-line instruction per file (at most 3) to invoke the
// delegate-local skill before reading a big file itself. It only stats paths: file contents are never
// read. Bytes are a char proxy. One bounded metadata lookup supplies the loaded context cap.
// Candidates are scanned lazily (no spreads, so a huge prompt cannot overflow the stack) and only path-like ones are
// stat'ed: they contain a "/", start with "~", or end in an extension. The cap is on stat calls, not on tokens scanned.
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, resolve } from 'node:path';
import { getContextCap, MIN_DELEGATE_CHARS } from './context-cap.mjs';
import { isLoopbackEndpoint } from './loopback.mjs';

const MAX_FILES = 3;
const MAX_STATS = 100;

let input = {};
try {
  input = JSON.parse(readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // unreadable or non-JSON input: say nothing
}
const prompt = typeof input.prompt === 'string' ? input.prompt : '';
const cwd = typeof input.cwd === 'string' && isAbsolute(input.cwd) ? input.cwd : process.cwd();

// A quoted span (so a path may contain spaces) or a whitespace-delimited token that holds no wrapping quote, so
// ("/a dir/x.txt") yields the quoted span while customer's-notes.md stays one token (an apostrophe between word
// characters is part of the token). The tokens inside a quoted span are candidates too, which keeps a stray
// apostrophe in prose from hiding a path.
const CANDIDATE = /"([^"\n]+)"|(?<!\w)'([^'\n]+)'|`([^`\n]+)`|((?:[^\s"'`]|(?<=\w)'(?=\w))+)/g;
const clean = (t) => t.replace(/^[\s"'`(<[{@]+/, '').replace(/[\s"'`)>\]},.;:!?]+$/, '');
const isPathLike = (t) => t.includes('/') || t.startsWith('~') || /\.[A-Za-z0-9]{1,10}$/.test(t);

const statted = new Set();
const hinted = new Set();
const files = [];
const done = () => files.length >= MAX_FILES || statted.size >= MAX_STATS;
function consider(token) {
  const t = clean(token);
  if (!t || t.length > 4096 || !isPathLike(t)) return;
  const expanded = t === '~' ? homedir() : t.startsWith('~/') ? resolve(homedir(), t.slice(2)) : t;
  const path = isAbsolute(expanded) ? expanded : resolve(cwd, expanded);
  if (statted.has(path)) return; // the same file named twice (quoted and bare) uses one slot
  statted.add(path);
  try {
    const st = statSync(path);
    if (!st.isFile() || st.size < MIN_DELEGATE_CHARS || hinted.has(path)) return;
    hinted.add(path);
    files.push({ path, size: st.size });
  } catch {
    // stat failed (missing path, no permission, name too long, ...): not a file to hint about
  }
}
for (const m of prompt.matchAll(CANDIDATE)) {
  if (done()) break;
  const span = m[1] ?? m[2] ?? m[3];
  if (span === undefined) { consider(m[4]); continue; }
  consider(span);
  for (const inner of span.matchAll(/\S+/g)) { if (done()) break; consider(inner[0]); }
}
if (files.length > 0) {
  // The plugin's endpoint_url and model options reach hooks as CLAUDE_PLUGIN_OPTION_* (once set), not via .mcp.json's env.
  const env = process.env;
  const configured = env.CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS
    ?? JSON.parse(readFileSync(new URL('../.claude-plugin/plugin.json', import.meta.url), 'utf8')).userConfig.delegate_tasks.default;
  const kinds = [...new Set(configured.split(',').map((kind) => kind.trim()).filter(Boolean))];
  const known = new Set(['classify', 'extract', 'summarize', 'draft']);
  const unknown = kinds.filter((kind) => !known.has(kind));
  if (unknown.length) console.error(`local-llm: ignoring unknown delegate_tasks kinds: ${JSON.stringify(unknown)}`);
  const tasks = kinds.filter((kind) => known.has(kind));
  const taskList = tasks.length < 2 ? tasks[0] : `${tasks.slice(0, -1).join(', ')} or ${tasks.at(-1)}`;
  const endpoint = env.CLAUDE_PLUGIN_OPTION_ENDPOINT_URL || env.LOCAL_LLM_ENDPOINT_URL || undefined;
  const optionEndpoint = env.CLAUDE_PLUGIN_OPTION_ENDPOINT_URL; // the value .mcp.json hands the launchers; a shell variable never reaches them
  if (tasks.length && optionEndpoint && !isLoopbackEndpoint(optionEndpoint)) {
    // Both launchers refuse this endpoint, so no local tool is running: do not tell Claude to delegate.
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext:
      'local-llm: endpoint_url is not a loopback server root (http://127.0.0.1:1234 form), so the local model tools are unavailable; read big files yourself.' } }));
    process.exit(0);
  }
  const { contextTokens, capChars, source, reason } = await getContextCap({
    endpoint,
    model: env.CLAUDE_PLUGIN_OPTION_MODEL ?? env.LOCAL_LLM_MODEL ?? undefined,
  });
  const number = (n) => n.toLocaleString('en-US');
  const context = source === 'loaded'
    ? `${number(contextTokens)} tokens, about ${number(capChars)} chars; loaded`
    : `assumed 32k context (model metadata unavailable: ${reason}); about ${number(capChars)} chars; ${source}`;
  const lines = files.map(({ path, size }) => {
    const prefix = `local-llm: ${path} is about ${number(size)} bytes (a char proxy).`;
    if (size > capChars) return `${prefix} It is too big for the loaded model's context (${context}); Grep or Read the relevant slices. Only when the user explicitly requests a local batch over multiple files, use batch/run.mjs.`;
    if (!tasks.length) return null;
    return `${prefix} Context cap: ${context}. If this turn's job on it is a read-only ${taskList} task, invoke the local-llm:delegate-local skill with the Skill tool before reading the file, instead of reading it yourself; this holds for the user's own project files too. Send the Skill call and ToolSearch query "select:mcp__plugin_local-llm_local-llm__code_task_files" in the same assistant message (they are independent), and use the stated size instead of running \`wc -c\` again.`;
  }).filter(Boolean);
  const fitting = files.filter((f) => f.size <= capChars);
  if (tasks.length && fitting.length > 1 && fitting.reduce((sum, f) => sum + f.size, 0) > capChars) {
    lines.push('local-llm: The files that fit exceed the loaded context together; if the job is delegated, make one call per file.');
  }
  if (!lines.length) process.exit(0);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: lines.join('\n') },
  }));
}
