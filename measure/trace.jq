# Usage and status facts from one `claude -p --output-format stream-json` trace.
# Input: the trace's lines as one array, each parsed event or, for a line that is not JSON, the string "__bad__"
# (lib.sh's trace_facts). Only the last line may be bad (a run cut off mid-write); a bad line anywhere else, or a
# result whose usage lacks any of its four numeric counters, is facts-error, never a run with T = 0.
# Args: $path (the job's file, "" for a control), $cfg ("off"|"on"), $kind ("job", or "ctl"/"warm"), $rc (claude's exit
# code; 124 is a timeout), $ft (the server's file tool name). Tool uses are joined to their results by
# tool_use_id, as in tests/test-delegation.sh.
include "footer";

def txt: if type == "array" then map(.text // "") | join(" ") else (. // "" | tostring) end;
def n0: . // 0;
def num: type == "number";
def four: [.inputTokens, .cacheCreationInputTokens, .cacheReadInputTokens, .outputTokens];
def four_usage: [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens, .output_tokens];

([to_entries[] | select(.value | type != "object") | .key]) as $bad
| (length) as $nlines
| ([$bad[] | select(. != $nlines - 1)] | length) as $parse_errors
| [.[] | select(type == "object")] as $all
| [$all | to_entries[] | select(.value.type == "assistant") | .key as $k
    | .value.message.content[]? | select(.type == "tool_use") | {id, name, input, pos: $k}] as $uses
| [$all[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
    | {id: .tool_use_id, is_error: (.is_error // false), text: (.content | txt)}] as $res
| [$uses[] | . as $u | . + {res: (first($res[] | select(.id == $u.id)) // null)}] as $J
| ([$all[] | select(.type == "result")] | last // null) as $r
| ($r.modelUsage // {}) as $mu
| (if ($mu | length) > 0 then
     (if all($mu[]; four | all(num)) then
        {input: ([$mu[] | .inputTokens] | add), cache_creation: ([$mu[] | .cacheCreationInputTokens] | add),
         cache_read: ([$mu[] | .cacheReadInputTokens] | add), output: ([$mu[] | .outputTokens] | add)}
      else null end)
   elif ($r.usage // null) != null and ($r.usage | four_usage | all(num)) then
     {input: $r.usage.input_tokens, cache_creation: $r.usage.cache_creation_input_tokens,
      cache_read: $r.usage.cache_read_input_tokens, output: $r.usage.output_tokens}
   else null end) as $u
# Per-call input side: each main-thread API call (assistant message id) carries its own input, cache_read and
# cache_creation; output counts in these snapshots under-report, so only the input side is read here.
| ([$all[] | select(.type == "assistant" and (.parent_tool_use_id // null) == null and .message.usage != null)
    | {id: .message.id, v: (.message.usage | (.input_tokens | n0) + (.cache_read_input_tokens | n0) + (.cache_creation_input_tokens | n0))}]
   | group_by(.id) | map(.[0].v) | max) as $ctx
| ([$all[] | select(.type == "system" and .subtype == "init") | .tools[]?] | index($ft) != null) as $listed
| [$J[] | select(.name == $ft and ((.input | tostring) | contains($path)) and $path != "")
    | . + {footer: (.res.text // null | houtini_footer)}
    | . + {good: (.res != null and (.res.is_error | not) and (.res.text | startswith("Error:") | not)
                  and .footer != null and .footer.files_total != null and .footer.files_read == .footer.files_total
                  and (.footer.flags | length) == 0)}] as $D
| ([$D[] | select(.good)] | first // null) as $good
| def bash_read: .name == "Bash" and ((.input.command // "") | contains($path))
    and ([(.input.command // "") | splits("[;&|\n]+") | select(test("^\\s*([^\\s]*/)?(cat|head|tail|sed|awk)\\s"))] | length > 0);
  def credited: .res != null and (.res.is_error | not) and (.res.text | length) > 0
    and ((.input | tostring) | contains($path))
    and (.name == "Read" or (.name == "Grep" and .input.output_mode == "content" and (.res.text | test("^No matches found") | not)) or bash_read);
  ([$J[] | select(credited)] | length > 0) as $read
| ([$J[] | select(.name == "Read" or bash_read) | select((.input | tostring) | contains($path))] | length > 0) as $read_attempt
| (if $parse_errors > 0 then "facts-error"
   elif $rc == 124 then "timeout"
   elif $r != null and $r.is_error == true then "is-error"
   elif $r == null or ($r | has("result") | not) then "unknown"
   elif $u == null then "facts-error"
   elif $rc != 0 then "exit-\($rc)"
   elif $cfg == "off" and $listed then "plugin-leak"
   elif $cfg == "on" and ($listed | not) then "no-server"
   elif $kind != "job" then "ok"
   elif $cfg == "on" and ($D | length) == 0 then "no-call"
   elif $cfg == "on" and $good == null then "call-error"
   elif $cfg == "off" and ($read | not) then "base-no-read"
   else "ok" end) as $status
| {
    status: $status,
    stage: (if $status != "facts-error" then null elif $parse_errors > 0 then "parse" else "usage" end),
    parse_errors: $parse_errors,
    subtype: ($r.subtype // null),
    T: (if $u == null or $status == "facts-error" then null else $u.input + $u.cache_creation + $u.cache_read + $u.output end),
    input: (if $status == "facts-error" then null else $u.input end), cache_creation: (if $status == "facts-error" then null else $u.cache_creation end),
    cache_read: (if $status == "facts-error" then null else $u.cache_read end), output: (if $status == "facts-error" then null else $u.output end),
    usage_match: (if ($mu | length) == 1 and $r.usage != null then
        ($r.usage | [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens, .output_tokens] | map(n0))
          == [$u.input, $u.cache_creation, $u.cache_read, $u.output]
      else null end),
    models: ($mu | keys),
    usd: ($r.total_cost_usd // null),
    turns: ($r.num_turns // null),
    duration_ms: ($r.duration_ms // null),
    ctx_max: $ctx,
    tool_listed: $listed,
    calls: ($D | length),
    footer: ($good.footer // null),
    # every call's footer, valid answer or not: a call that hit max tokens after 75 s still took 75 s
    call_footers: [$D[] | .footer | select(. != null) | {model, ttft_ms, total_s, flags}],
    also_read: ($cfg == "on" and $read_attempt),
    denials: [($r.permission_denials // [])[] | .tool_name | select(. != "Skill" and (startswith("mcp__plugin_local-llm_") | not))],
    plugin_denials: [($r.permission_denials // [])[] | .tool_name | select(. == "Skill" or startswith("mcp__plugin_local-llm_"))],
    answer: ($r.result // null)
  }
