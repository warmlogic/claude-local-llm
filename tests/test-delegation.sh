#!/usr/bin/env bash
# Delegation acceptance harness for skills/delegate-local. NOT part of the per-commit suite:
# every run is a real `claude -p` session and spends quota. Run from anywhere: bash tests/test-delegation.sh
#
# Each case runs DELEG_RUNS times (default 5) in a headless session with the plugin loaded via --plugin-dir
# and no --allowedTools, then the stream-json trace is checked with jq. A case PASSes at >= 4/5 (scaled
# to DELEG_RUNS). Cases a and b need LM Studio at 127.0.0.1:1234; c, d and e point a temp copy of the
# plugin at a dead port or a fake endpoint and never touch LM Studio.
#   a  20k-char file, "summarize <path>": code_task_files is called on it, unprompted
#   b  2k-char file: no code_task_files call, Claude reads the file
#   c  endpoint down: Claude still answers by reading the file itself
#   d  endpoint up but no model loaded (fake endpoint, tests/fake-endpoint.mjs no-model): same as c
#   e  two jobs, endpoint down: the outage is announced once, not twice
#   f  no permission prompt: permission_denials is empty in every run of a-e
#
# Environment: DELEG_RUNS (5)  DELEG_CASES ("a b c d e")  DELEG_MODEL (default model)  DELEG_OUT (trace dir,
# default a new mktemp dir that is kept)  DELEG_ALLOWED_TOOLS (passed to --allowedTools; empty by default)
# DELEG_SETTING_SOURCES (default "project": the user's settings, allow rules, hooks and plugins are left out,
# so a pass cannot come from the user's own permissions. Hooks are not disabled: the plugin's own
# PreToolUse hook is what pre-approves the skill call).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RUNS="${DELEG_RUNS:-5}"
CASES="${DELEG_CASES:-a b c d e}"
SOURCES="${DELEG_SETTING_SOURCES-project}"
RUN_TIMEOUT_SEC=300
FILE_TOOL="mcp__plugin_local-llm_local-llm__code_task_files"
ENDPOINT="http://127.0.0.1:1234"

for tool in claude node jq curl timeout; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required"; exit 1; }
done
case "$REPO/" in
  "$HOME/github/"*|"$HOME/catalyst/"*) ;;
  *) echo "FAIL: fixtures live under the repo, which must sit inside the default allowed_dirs (\$HOME/github or \$HOME/catalyst)"; exit 1 ;;
esac

OUT="${DELEG_OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
FIX=$(mktemp -d "$REPO/tests/.tmp-deleg-XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
FIX=$(cd "$FIX" && pwd -P)
PLUGINS=$(mktemp -d)
WORK=$(mktemp -d)   # session cwd: outside the repo, so no project memory and no ancestor node_modules
FAKE_PID=""
trap '[ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null; rm -rf "$FIX" "$PLUGINS" "$WORK"' EXIT

# gen_log <chars>: deterministic synthetic app log, a few ERROR lines among INFO/WARN
gen_log() {
  awk -v n="$1" 'BEGIN{
    split("auth billing search sync mailer", svc, " ")
    while (length(s) < n) {
      i++; lvl = (i % 41 == 0) ? "ERROR" : ((i % 7 == 0) ? "WARN " : "INFO ")
      s = s sprintf("2026-03-04T10:%02d:%02dZ %s service=%s req=%05x msg=\"%s\" latency_ms=%d\n", (i/60)%60, i%60, lvl, svc[i%5+1], (i*2654435761)%1048576, (lvl=="ERROR") ? "upstream timeout talking to node " i%13 : "request handled", (i*37)%900)
    }
    printf "%s", substr(s, 1, n)}'
}
gen_log 20000 > "$FIX/app-20k.log"
gen_log 2000 > "$FIX/app-2k.log"
gen_log 22000 | tail -c 20000 > "$FIX/app-20k-b.log"

# copy_plugin <dest> <endpoint-url>: temp plugin copy whose endpoint_url default is <endpoint-url>
copy_plugin() {
  mkdir -p "$1"
  cp -R "$REPO/.claude-plugin" "$REPO/.mcp.json" "$REPO/package.json" "$REPO/scripts" "$REPO/skills" "$REPO/hooks" "$1/"
  jq --arg u "$2" '.userConfig.endpoint_url.default = $u' "$REPO/.claude-plugin/plugin.json" > "$1/.claude-plugin/plugin.json"
}
dead_url() {
  echo "http://127.0.0.1:$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
}

lm_up=0
curl -s -m 3 "$ENDPOINT/v1/models" >/dev/null 2>&1 && lm_up=1

# run_claude <plugin-dir> <prompt> <trace-file>
run_claude() {
  local args=(-p "$2" --plugin-dir "$1" --output-format stream-json --verbose --no-session-persistence)
  [ -z "$SOURCES" ] || args+=(--setting-sources "$SOURCES")
  [ -z "${DELEG_MODEL:-}" ] || args+=(--model "$DELEG_MODEL")
  [ -z "${DELEG_ALLOWED_TOOLS:-}" ] || args+=(--allowedTools "$DELEG_ALLOWED_TOOLS")
  args+=(--add-dir "$FIX")
  (cd "$WORK" && timeout "$RUN_TIMEOUT_SEC" claude "${args[@]}" > "$3" 2> "$3.err" < /dev/null)
}

# summarize <trace> <base>...: one JSON object of facts about a trace (bases = fixture file names)
summarize() {
  local trace="$1"; shift
  jq -s --arg ft "$FILE_TOOL" --argjson bases "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" '
    def tools: [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")];
    def texts: [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text];
    tools as $T
    | ([.[] | select(.type == "result")] | last // {}) as $r
    | ([$T[] | select(.name == $ft)]) as $D
    | ([$T[] | select(.name == "Read" or .name == "Grep" or (.name == "Bash" and ((.input.command // "") | test("^\\s*wc ") | not)))]) as $R
    | {
        ok: ($r | has("result")),
        answer_chars: (($r.result // "") | length),
        is_error: (if ($r | has("is_error")) then $r.is_error else true end),
        denied: [($r.permission_denials // [])[] | .tool_name],
        mcp_tool_listed: ([.[] | select(.type == "system" and .subtype == "init") | .tools[]?] | index($ft) != null),
        skill_used: ([$T[] | select(.name == "Skill")] | length > 0),
        delegate_calls: ($D | length),
        delegated: [$bases[] | . as $b | select([$D[] | select((.input | tostring) | contains($b))] | length > 0)],
        read_by_claude: [$bases[] | . as $b | select([$R[] | select((.input | tostring) | contains($b))] | length > 0)],
        notices: ([texts[] | select(test("local[- ]?(model|llm)|lm studio|local-llm|delegat|\\bserver\\b"; "i") and test("unavailab|not (running|available|reachable|responding|connected|loaded)|offline|\\bdown\\b|fetch failed|no models? loaded|(unable|couldn.t|could not|can.t|cannot) (to )?(reach|connect|delegate|use)"; "i"))] | length)
      }' "$trace" 2>/dev/null || echo '{"ok":false}'
}

# check_<case> <summary-json> -> exit 0 when the run passes
check_a() { jq -e '.ok and .answer_chars > 0 and (.delegated | index("app-20k.log") != null) and (.denied | index("'"$FILE_TOOL"'") == null)' >/dev/null <<<"$1"; }
check_b() { jq -e '.ok and .answer_chars > 0 and .delegate_calls == 0 and (.read_by_claude | index("app-2k.log") != null)' >/dev/null <<<"$1"; }
check_c() { jq -e '.ok and (.is_error | not) and .answer_chars > 0 and (.read_by_claude | index("app-20k.log") != null)' >/dev/null <<<"$1"; }
check_d() { check_c "$1"; }
check_e() { jq -e '.ok and (.is_error | not) and .answer_chars > 0 and (.read_by_claude | length == 2) and .notices == 1' >/dev/null <<<"$1"; }

# --- plugins for each case ---------------------------------------------------------------------------
copy_plugin "$PLUGINS/real" "$ENDPOINT"
copy_plugin "$PLUGINS/down" "$(dead_url)"
case " $CASES " in *" d "*)
  node "$SCRIPT_DIR/fake-endpoint.mjs" "$PLUGINS/port" "$PLUGINS/requests.log" no-model &
  FAKE_PID=$!
  for _ in $(seq 1 50); do [ -s "$PLUGINS/port" ] && break; sleep 0.1; done
  [ -s "$PLUGINS/port" ] || { echo "FAIL: fake endpoint did not start"; exit 1; }
  copy_plugin "$PLUGINS/nomodel" "http://127.0.0.1:$(cat "$PLUGINS/port")" ;;
esac

plugin_for() { case "$1" in a|b) echo real ;; c|e) echo down ;; d) echo nomodel ;; esac; }
bases_for() { case "$1" in e) echo "app-20k.log app-20k-b.log" ;; b) echo "app-2k.log" ;; *) echo "app-20k.log" ;; esac; }
prompt_for() {
  case "$1" in
    b) echo "Summarize $FIX/app-2k.log in five bullet points." ;;
    e) echo "Do two jobs. First, summarize $FIX/app-20k.log in three bullet points. Second, summarize $FIX/app-20k-b.log in three bullet points." ;;
    *) echo "Summarize $FIX/app-20k.log in five bullet points." ;;
  esac
}
THRESHOLD=$(( (RUNS * 4 + 4) / 5 ))

echo "delegation acceptance: $RUNS runs per case (pass at >= $THRESHOLD), traces in $OUT"
echo "LM Studio reachable: $lm_up; model: ${DELEG_MODEL:-default}; setting sources: ${SOURCES:-none}"

overall=0; total_runs=0; denied_runs=0
for c in $CASES; do
  if [ -z "$(plugin_for "$c")" ]; then echo "unknown case: $c"; overall=1; continue; fi
  if [ "$lm_up" = 0 ] && { [ "$c" = a ] || [ "$c" = b ]; }; then echo "case $c: SKIP (LM Studio is not reachable)"; continue; fi
  passes=0
  for n in $(seq 1 "$RUNS"); do
    trace="$OUT/$c-$n.jsonl"
    run_claude "$PLUGINS/$(plugin_for "$c")" "$(prompt_for "$c")" "$trace"
    # shellcheck disable=SC2086
    s=$(summarize "$trace" $(bases_for "$c"))
    total_runs=$((total_runs+1))
    jq -e '.denied | length > 0' >/dev/null <<<"$s" && denied_runs=$((denied_runs+1))
    if "check_$c" "$s"; then passes=$((passes+1)); verdict=pass; else verdict=FAIL; fi
    echo "  $c-$n $verdict $(jq -c '{mcp_tool_listed, skill_used, delegate_calls, delegated, read_by_claude, notices, denied, answer_chars}' <<<"$s")"
  done
  if [ "$passes" -ge "$THRESHOLD" ]; then echo "case $c: $passes/$RUNS PASS"; else echo "case $c: $passes/$RUNS FAIL"; overall=1; fi
done
if [ "$denied_runs" -eq 0 ]; then echo "case f: 0/$total_runs runs with permission_denials PASS"
else echo "case f: $denied_runs/$total_runs runs with permission_denials FAIL"; overall=1; fi
exit "$overall"
