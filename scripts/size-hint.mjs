// UserPromptSubmit hook. When the prompt names an existing regular file of at least 10,000 bytes (absolute, ~/, or
// relative to the hook input's cwd), adds a one-line hint per file (at most 3) so Claude considers the
// delegate-local skill on a big file instead of reading part of it. It only stats paths: file contents are never
// read, and nothing is printed otherwise.
// Candidates are scanned lazily (no spreads, so a huge prompt cannot overflow the stack) and only path-like ones are
// stat'ed: they contain a "/", start with "~", or end in an extension. The cap is on stat calls, not on tokens scanned.
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, resolve } from 'node:path';

const MIN_BYTES = 10_000;
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

// A quoted span (so a path may contain spaces) or a whitespace-delimited token, trimmed of wrapping punctuation.
const CANDIDATE = /"([^"\n]+)"|'([^'\n]+)'|`([^`\n]+)`|(\S+)/g;
const clean = (t) => t.replace(/^[\s"'`(<[{@]+/, '').replace(/[\s"'`)>\]},.;:!?]+$/, '');
const isPathLike = (t) => t.includes('/') || t.startsWith('~') || /\.[A-Za-z0-9]{1,10}$/.test(t);

const statted = new Set();
const hinted = new Set();
const lines = [];
for (const m of prompt.matchAll(CANDIDATE)) {
  if (lines.length >= MAX_FILES || statted.size >= MAX_STATS) break;
  const t = clean(m[1] ?? m[2] ?? m[3] ?? m[4] ?? '');
  if (!t || t.length > 4096 || !isPathLike(t)) continue;
  const expanded = t === '~' ? homedir() : t.startsWith('~/') ? resolve(homedir(), t.slice(2)) : t;
  const path = isAbsolute(expanded) ? expanded : resolve(cwd, expanded);
  if (statted.has(path)) continue; // the same file named twice (quoted and bare) uses one slot
  statted.add(path);
  try {
    const st = statSync(path);
    if (!st.isFile() || st.size < MIN_BYTES || hinted.has(path)) continue;
    hinted.add(path);
    lines.push(`local-llm: ${path} is about ${st.size.toLocaleString('en-US')} bytes; if the job is a bounded read-only text task (summarize, classify, extract), the delegate-local skill applies.`);
  } catch {
    // stat failed (missing path, no permission, name too long, ...): not a file to hint about
  }
}
if (lines.length > 0) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: lines.join('\n') },
  }));
}
