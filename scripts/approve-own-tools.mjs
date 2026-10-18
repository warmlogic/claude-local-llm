// Only the batch runner, invoked as a whole Bash command, may bypass normal approval.
import { readFileSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = realpathSync(join(dirname(fileURLToPath(import.meta.url)), '..'));
const within = (path, roots) => roots.some((r) => path === r || path.startsWith(r + sep));
const batchArgsAllowed = (args, cwd) => {
  const configured = process.env.CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS
    ?? JSON.parse(readFileSync(join(root, '.claude-plugin/plugin.json'), 'utf8')).userConfig.allowed_dirs.default.join(',');
  const roots = execFileSync(process.execPath, [join(root, 'scripts/resolve-roots.mjs')], {
    env: { ...process.env, LOCAL_LLM_ALLOWED_DIRS: configured },
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 1000,
  }).trim().split(',').filter(Boolean);
  if (!roots.length) return false;
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
  if (options.has('--transcripts')) {
    // Claude Code session transcripts also live outside allowed_dirs, under $HOME/.claude/projects.
    try { roots.push(realpathSync.native(join(homedir(), '.claude/projects'))); } catch { /* no transcripts */ }
  }
  return options.has('--job-json') && files.length > 0 && files.every((path) => within(real(path), roots));
};
// A deliberately small shell lexer. Single quotes are literal; double quotes must not expand anything.
// No evaluation, redirection, pipelines, comments or compound commands. A final & is the only operator.
export const ownBatchCommand = (command, cwd = process.cwd()) => {
  if (typeof command !== 'string' || /[\r\n\0]/.test(command)) return false;
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
    else if (/[;&|<>$`\\#()*?\[\]{}~!]/.test(c)) return false;
    else { word += c; started = true; }
  }
  if (quote) return false;
  push();
  if (words[0] !== 'node' || words.length < 2) return false;
  const script = words[1];
  if (script !== `${root}/batch/run.mjs`) return false;
  try { return realpathSync(script) === script && batchArgsAllowed(words.slice(2), cwd); } catch { return false; }
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
if (isOwnSkill || TOOLS.has(input?.tool_name) || (input?.tool_name === 'Bash' && ownBatchCommand(input?.tool_input?.command, input.cwd))) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: 'local-llm plugin skill, read-only tool or batch command',
    },
  }));
}
