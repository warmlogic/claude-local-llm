// Only these two scripts, invoked as a whole Bash command, may bypass normal approval.
import { readFileSync, realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = realpathSync(join(dirname(fileURLToPath(import.meta.url)), '..'));
// A deliberately small shell lexer. Single quotes are literal; double quotes must not expand anything.
// No evaluation, redirection, pipelines, comments or compound commands. A final & is the only operator.
export const ownBatchCommand = (command) => {
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
    else if (/[;&|<>$`\\#()]/.test(c)) return false;
    else { word += c; started = true; }
  }
  if (quote) return false;
  push();
  if (words[0] !== 'node' || words.length < 2) return false;
  const script = words[1];
  if (!['run.mjs', 'flatten-transcripts.mjs'].some((name) => script === `${root}/batch/${name}`)) return false;
  try { return realpathSync(script) === script; } catch { return false; }
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
if (isOwnSkill || TOOLS.has(input?.tool_name) || (input?.tool_name === 'Bash' && ownBatchCommand(input?.tool_input?.command))) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: 'local-llm plugin skill, read-only tool or batch command',
    },
  }));
}
