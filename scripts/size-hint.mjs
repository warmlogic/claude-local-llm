// UserPromptSubmit hook. When the prompt names an existing regular file of at least 10,000 bytes (absolute, ~/, or
// relative to the hook input's cwd), adds a one-line hint per file (at most 3) so Claude considers the
// delegate-local skill on a big file instead of reading part of it. It only stats paths: file contents are never
// read, and nothing is printed otherwise.
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, resolve } from 'node:path';

const MIN_BYTES = 10_000;
const MAX_FILES = 3;
const MAX_CANDIDATES = 200;

let input = {};
try {
  input = JSON.parse(readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}
const prompt = typeof input.prompt === 'string' ? input.prompt : '';
const cwd = typeof input.cwd === 'string' && isAbsolute(input.cwd) ? input.cwd : process.cwd();

// Candidates: quoted spans (paths may contain spaces) and whitespace-separated tokens, trimmed of wrapping punctuation.
const raw = [];
for (const m of prompt.matchAll(/"([^"\n]+)"|'([^'\n]+)'|`([^`\n]+)`/g)) raw.push(m[1] ?? m[2] ?? m[3]);
raw.push(...prompt.split(/\s+/));
const clean = (t) => t.replace(/^[\s"'`(<[{@]+/, '').replace(/[\s"'`)>\]},.;:!?]+$/, '');

const seen = new Set();
const hints = [];
for (const token of raw.slice(0, MAX_CANDIDATES * 2)) {
  if (hints.length >= MAX_FILES || seen.size >= MAX_CANDIDATES) break;
  const t = clean(token);
  if (!t || t.length > 4096 || seen.has(t)) continue;
  seen.add(t);
  const expanded = t === '~' ? homedir() : t.startsWith('~/') ? resolve(homedir(), t.slice(2)) : t;
  const path = isAbsolute(expanded) ? expanded : resolve(cwd, expanded);
  try {
    const st = statSync(path);
    if (!st.isFile() || st.size < MIN_BYTES) continue;
    const line = `local-llm: ${path} is about ${st.size.toLocaleString('en-US')} characters; the delegate-local skill applies to bounded text jobs on files this size.`;
    if (!hints.includes(line)) hints.push(line);
  } catch {
    // not a path that exists
  }
}
if (hints.length > 0) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: hints.join('\n') },
  }));
}
