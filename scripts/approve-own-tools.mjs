// Only the batch runner, invoked as a whole Bash command, and Reads of its own output files may bypass normal approval.
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = realpathSync(join(dirname(fileURLToPath(import.meta.url)), '..'));
const within = (path, roots) => roots.some((r) => path === r || path.startsWith(r + sep));
// Only a command that passes every other check is withheld for want of usable allowed_dirs, so only then does the
// hook say why: a systemMessage with fixed text (never a path) and no hookSpecificOutput. The normal permission flow
// still decides and nothing is denied. Every other rejection stays silent.
const skip = (reason) => {
  process.stdout.write(JSON.stringify({ systemMessage: `local-llm: batch auto-approval skipped: ${reason}` }));
  return false;
};
const resolveRoots = (configured) => execFileSync(process.execPath, [join(root, 'scripts/resolve-roots.mjs')], {
  env: { ...process.env, LOCAL_LLM_ALLOWED_DIRS: configured },
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 1000,
}).trim().split(',').filter(Boolean);
const batchArgsAllowed = (args, cwd) => {
  // Preserve symlink/.. ordering: resolve() before realpath could approve a different file.
  const real = (path) => realpathSync.native(isAbsolute(path) ? path : `${cwd}${sep}${path}`);
  const files = [], options = new Set();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--number' || arg === '--transcripts') {
      if (options.has(arg)) return false;
      options.add(arg);
      continue;
    }
    if (arg === '--job-json') {
      if (options.has(arg) || !args[i + 1] || args[i + 1].startsWith('--')) return false;
      options.add(arg);
      i++;
    } else if (arg.startsWith('-')) return false; // --job and --out too: an approved run writes only to a fresh private tmp dir.
    else files.push(arg);
  }
  if (options.has('--number') && options.has('--transcripts')) return false;
  // --transcripts is never auto-approved: session transcripts under $HOME/.claude/projects hold copies of files from
  // every past session, so reading them goes through the normal permission flow (batch runs are explicit anyway).
  if (options.has('--transcripts')) return false;
  if (!options.has('--job-json') || !files.length) return false;
  const reals = files.map(real); // a missing input throws: silent
  const configured = process.env.CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS;
  if (!configured) return skip('allowed_dirs option is not set'); // the option has no default: unset approves nothing
  let roots;
  try { roots = resolveRoots(configured); } catch (e) { return skip(e.code === 'ETIMEDOUT' ? 'allowed_dirs resolution timed out' : 'allowed_dirs could not be resolved (see "Choose the folders the local model may read" in the README)'); }
  if (!roots.length) return skip('allowed_dirs could not be resolved (see "Choose the folders the local model may read" in the README)'); // exited 0 with nothing to allow
  return reals.every((path) => within(path, roots));
};
// A deliberately small shell lexer. Single quotes are literal; double quotes must not expand anything.
// No evaluation, redirection, pipelines, comments or compound commands. A final & is the only operator.
export const ownBatchCommand = (command, cwd) => {
  if (typeof command !== 'string' || /[\r\n\0]/.test(command)) return false;
  if (typeof cwd !== 'string' || !isAbsolute(cwd)) return false; // relative inputs resolve against it
  let quote = null, word = '', started = false;
  const words = [];
  const push = () => { if (started) words.push(word); word = ''; started = false; };
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (quote === "'") { if (c === "'") quote = null; else word += c; continue; }
    if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === '$' || c === '`' || c === '\\') return false;
      else word += c;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; started = true; }
    else if (/[ \t]/.test(c)) push();
    else if (c === '&' && /^[ \t]*$/.test(command.slice(i + 1))) { push(); break; }
    else if (c === '\\' && command[i + 1] === "'") { word += "'"; started = true; i++; }
    else if (/[A-Za-z0-9._\/,:@%+-]/.test(c)) { word += c; started = true; }
    else return false; // allowlist for unquoted characters: anything else (=cmd, globs, ~, braces, ...) could expand
  }
  if (quote) return false;
  push();
  if (words[0] !== 'node' || words.length < 2) return false;
  const script = words[1];
  if (script !== `${root}/batch/run.mjs`) return false;
  try { return realpathSync(script) === script && batchArgsAllowed(words.slice(2), cwd); } catch { return false; }
};

// The runner's results: a Read of one of its four output files, inside a directory named local-llm-batch-XXXXXX
// directly under the OS tmpdir, mode 0700, owned by this user, with neither the dir nor the file a symlink or hardlink.
// Those are the only checks: a hand-made directory that satisfies them is accepted too.
const OUTPUTS = new Set(['index.md', 'rows.jsonl', 'dropped.jsonl', 'failures.jsonl']);
export const ownBatchOutput = (filePath) => {
  if (typeof filePath !== 'string' || !isAbsolute(filePath)) return false;
  try {
    const dir = dirname(filePath), name = basename(filePath);
    const f = lstatSync(filePath), d = lstatSync(dir);
    if (!OUTPUTS.has(name) || f.isSymbolicLink() || !f.isFile() || f.nlink !== 1 || d.isSymbolicLink() || !d.isDirectory()) return false;
    if ((d.mode & 0o777) !== 0o700) return false; // mkdtemp's mode
    if (d.uid !== process.getuid() || f.uid !== process.getuid()) return false;
    const realDir = realpathSync.native(dir);
    return dirname(realDir) === realpathSync.native(tmpdir()) && /^local-llm-batch-[A-Za-z0-9]{6}$/.test(basename(realDir));
  } catch { return false; }
};

const SKILLS = new Set(['local-llm:delegate-local', 'local-llm:batch-local']);
const TOOLS = new Set([
  'mcp__plugin_local-llm_local-llm__code_task_files',
  'mcp__plugin_local-llm_local-verify__verify_claims',
]);
let input = {};
try {
  input = JSON.parse(readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // unreadable input: stay out of the way
}
const isOwnSkill = input?.tool_name === 'Skill' && SKILLS.has(input?.tool_input?.skill);
if (isOwnSkill || TOOLS.has(input?.tool_name) || (input?.tool_name === 'Bash' && !input?.tool_input?.dangerouslyDisableSandbox
      && ownBatchCommand(input?.tool_input?.command, input.cwd))
    || (input?.tool_name === 'Read' && ownBatchOutput(input?.tool_input?.file_path))) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: 'local-llm plugin skill, read-only tool or batch command',
    },
  }));
}
