// PreToolUse hook. Pre-approves this plugin's own delegate-local skill and, by EXACT name, its read-only tools, so
// that neither invoking the skill nor asking plainly ("use the local model to ...") hits a permission prompt (in
// `claude -p` an unapproved call is denied; the skill's `allowed-tools` only applies once the skill is loaded).
// Everything else gets no output, so the normal permission flow decides: the other houtini tools (chat,
// custom_prompt, embed, ...) stay unapproved.
// Why this is safe: code_task_files and verify_claims only read files, each server is fenced to the configured
// allowed folders (scripts/launch-server.sh and scripts/launch-verify.sh fail closed, and the verify server
// re-checks the fence, the loopback endpoint and the proxy environment itself), and all inference stays on
// loopback. A deny rule on a tool name still wins over this hook; Read(...) deny rules on folders do
// not apply to MCP tool arguments, so allowed_dirs is the only boundary on what these tools read.
// Names are exact, and the skill name is qualified: a bare `delegate-local` could be another plugin's skill.
import { readFileSync } from 'node:fs';

const SKILL = 'local-llm:delegate-local';
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
const isOwnSkill = input?.tool_name === 'Skill' && input?.tool_input?.skill === SKILL;
if (isOwnSkill || TOOLS.has(input?.tool_name)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: 'local-llm plugin skill or read-only tool',
    },
  }));
}
