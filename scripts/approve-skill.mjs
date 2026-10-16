// PreToolUse hook (matcher: Skill). Pre-approves this plugin's own delegate-local skill so that
// invoking it does not hit a permission prompt (in `claude -p`, an unapproved Skill call is denied).
// Every other Skill call gets no output, so the normal permission flow decides. The skill's
// `allowed-tools` line then covers the MCP tools for that turn.
import { readFileSync } from 'node:fs';

const SKILL = 'local-llm:delegate-local';
let input = {};
try {
  input = JSON.parse(readFileSync(0, 'utf8'));
} catch {
  process.exit(0); // unreadable input: stay out of the way
}
if (input?.tool_name === 'Skill' && input?.tool_input?.skill === SKILL) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: 'local-llm plugin skill',
    },
  }));
}
