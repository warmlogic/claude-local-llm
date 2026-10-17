// UserPromptSubmit hook. When the prompt names an existing regular file of at least 10,000 bytes (absolute, ~/, or
// relative to the hook input's cwd), adds a one-line instruction per file (at most 3) to invoke the
// delegate-local skill before reading a big file itself. It only stats paths: file contents are never
// read, and nothing is printed otherwise.
// The instruction is forceful, so it is withheld where delegating would be wrong: a file outside the plugin's
// allowed_dirs (the local model could not read it), and a file whose basename looks secret-like (the skill says
// never to delegate secrets). The name check is a best-effort heuristic, not a boundary: it withholds every dotfile
// (.env*, .netrc, .npmrc, ...), any name with a key or keystore extension anywhere in it (server.pem.bak), id_*, and
// names containing credential, secret, token or passw; a secret under a neutral name still gets the instruction. The allowed folders are the
// option's value when Claude Code exports it (CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS, comma-joined; a hook cannot take
// ${user_config.*} in a shell-form command), else the manifest default, which is what the MCP launchers fall back
// to; they are resolved by scripts/resolve-roots.mjs, so the fence is the launchers' own. If they cannot be
// resolved, no hint is printed, and the reason goes to stderr (Claude Code's debug log), never stdout.
// Candidates are scanned lazily (no spreads, so a huge prompt cannot overflow the stack) and only path-like ones are
// stat'ed: they contain a "/", start with "~", or end in an extension. The cap is on stat calls, not on tokens scanned.
import { execFileSync } from 'node:child_process';
import { readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, isAbsolute, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const MIN_BYTES = 10_000;
const MAX_FILES = 3;
const MAX_STATS = 100;
const SECRET_NAME = /^\.|^id_|credential|secret|token|passw|\.(?:pem|key|p12|pfx|jks|keystore|kdbx|ppk|gpg|asc|tfstate)(?:\.|$)/i;
const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url));

let input = {};
try {
  input = JSON.parse(readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // unreadable or non-JSON input: say nothing
}

// The allowed folders, resolved exactly as the launchers resolve them; null when they cannot be.
function allowedRoots() {
  let dirs = process.env.CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS;
  try {
    if (dirs === undefined) {
      const manifest = JSON.parse(readFileSync(resolve(PLUGIN_DIR, '.claude-plugin/plugin.json'), 'utf8'));
      dirs = manifest.userConfig.allowed_dirs.default.join(',');
    }
    const out = execFileSync(process.execPath, [resolve(PLUGIN_DIR, 'scripts/resolve-roots.mjs')], {
      env: { ...process.env, LOCAL_LLM_ALLOWED_DIRS: dirs }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], timeout: 3000,
    });
    return out.trim().split(',').filter(Boolean);
  } catch (e) {
    process.stderr.write(`local-llm size hint: allowed folders unresolved (${e.code ?? e.status ?? e.name}); no hints this prompt\n`);
    return null;
  }
}
let roots; // resolved on the first big file, so a prompt that names none spawns nothing
const isAllowed = (file) => {
  if (roots === undefined) roots = allowedRoots(); // null (unresolvable) is kept, so a failure is not retried per file
  return roots !== null && roots.some((r) => file === r || file.startsWith(r + sep));
};

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
const lines = [];
const done = () => lines.length >= MAX_FILES || statted.size >= MAX_STATS;
function consider(token) {
  const t = clean(token);
  if (!t || t.length > 4096 || !isPathLike(t)) return;
  const expanded = t === '~' ? homedir() : t.startsWith('~/') ? resolve(homedir(), t.slice(2)) : t;
  const path = isAbsolute(expanded) ? expanded : resolve(cwd, expanded);
  if (statted.has(path)) return; // the same file named twice (quoted and bare) uses one slot
  statted.add(path);
  try {
    const st = statSync(path);
    if (!st.isFile() || st.size < MIN_BYTES || hinted.has(path)) return;
    const real = realpathSync.native(path);
    if (SECRET_NAME.test(basename(path)) || SECRET_NAME.test(basename(real)) || !isAllowed(real)) return;
    hinted.add(path);
    lines.push(`local-llm: ${path} is about ${st.size.toLocaleString('en-US')} bytes. If this turn's job on it is a read-only text task (summarize, classify, extract), invoke the local-llm:delegate-local skill with the Skill tool before reading the file, instead of reading it yourself; this holds for the user's own project files too.`);
  } catch {
    // stat or realpath failed (missing path, no permission, a symlink loop, ...): not a file to hint about
  }
}
for (const m of prompt.matchAll(CANDIDATE)) {
  if (done()) break;
  const span = m[1] ?? m[2] ?? m[3];
  if (span === undefined) { consider(m[4]); continue; }
  consider(span);
  for (const inner of span.matchAll(/\S+/g)) { if (done()) break; consider(inner[0]); }
}
if (lines.length > 0) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: lines.join('\n') },
  }));
}
