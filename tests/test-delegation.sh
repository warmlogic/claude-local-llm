#!/usr/bin/env bash
# Delegation acceptance harness for skills/delegate-local. NOT part of the per-commit suite:
# every run is a real `claude -p` session and spends quota. Run from anywhere: bash tests/test-delegation.sh
# The scorers alone run offline against hand-written traces: DELEG_SELFTEST=1 bash tests/test-delegation.sh
# (test-fence.sh does this on every commit).
#
# Each case runs DELEG_RUNS times (default 5) in a headless session with the plugin loaded via --plugin-dir
# and no --allowedTools, then the stream-json trace is checked with jq. A case PASSes at >= 4/5 (scaled
# to DELEG_RUNS). Cases a and b need LM Studio at 127.0.0.1:1234; c, d and e point a temp copy of the
# plugin at a dead port or a fake endpoint and never touch LM Studio.
#   a  20k-char file, "summarize <path>": code_task_files is called on it, unprompted, and Claude does not read it
#      itself (a Read, or a Bash cat/head/tail/sed/awk naming it; Grep spot-checks are fine)
#   b  2k-char file: no code_task_files call, Claude reads the file
#   c  endpoint down: the tool fails with "fetch failed", is not called again, and Claude reads the file itself
#   d  endpoint up but no model loaded (fake endpoint, tests/fake-endpoint.mjs no-model): same as c
#   e  one session, two turns, endpoint down: turn 1 summarizes file A (tool fails, Claude reads it, and the final
#      reply tells the user); turn 2 (claude -p --resume) summarizes file B with zero outage notices and zero
#      code_task_files calls
#   f  no permission prompt for the plugin: no permission_denials entry for the Skill call or the plugin's tools
#      in any inspectable run of a-e (other denials, i.e. Claude's own compound Bash, are printed but do not gate)
# A trace that does not parse or has no result event is "unknown" and fails its case, and so does a run whose
# claude exit code is non-zero. "Claude read the file" means a successful Read with content, or a Grep with
# output_mode "content" that returned matching lines (the Grep default is files_with_matches), on the file after the
# tool failed, joined to its tool_result by tool_use_id. Bash is never credited: wc, ls, stat and cat /dev/null
# prove nothing about the file.
#
# Case e quotes the criterion: "in a two-job session with the server down (two turns of one session), the final
# reply of the turn where the outage happens tells the user (cause and how to retry; a mid-turn note is allowed
# too), and later turns neither mention the outage nor retry the local model". Only the final reply reaches a
# headless or subagent user. So turn 1's result text must carry the notice, and turn 2 must have zero notices in
# any assistant text and zero code_task_files calls. turn1_notices and session_notices (strict counts over all
# assistant text) are printed for information.
#
# Environment: DELEG_RUNS (5)  DELEG_CASES ("a b c d e")  DELEG_MODEL (default model)  DELEG_OUT (trace dir,
# default a new mktemp dir that is kept)  DELEG_ALLOWED_TOOLS (passed to --allowedTools; setting it voids the
# no-prompt result, since it grants the permissions under test)
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
SUBJECT='local[- ]?(model|llm)|lm studio|local-llm'
OUTAGE='unavailab|not (running|available|reachable|responding|connected|loaded)|offline|\bdown\b|fetch failed|no models? loaded|(unable|couldn.t|could not|can.t|cannot) (to )?(reach|connect|delegate|use)'

die() { echo "FAIL: $*" >&2; exit 1; }

# summarize <trace> <base>...: one JSON object of facts about a trace (bases = fixture file names).
# Tool uses are joined to their results by tool_use_id; positions are event indexes in the stream. Parallel calls
# from one assistant message arrive as separate events with results interleaved, so a "wave" is the message id.
summarize() {
  local trace="$1" bases; shift
  bases=$(printf '%s\n' "$@" | jq -R . | jq -sc .) || return 1
  jq -s --arg ft "$FILE_TOOL" --arg subj "$SUBJECT" --arg outage "$OUTAGE" --argjson bases "$bases" '
    def txt: if type == "array" then map(.text // "") | join(" ") else (. // "" | tostring) end;
    . as $all
    | [$all | to_entries[] | select(.value.type == "assistant") | .key as $k
        | .value.message.content[]? | select(.type == "tool_use") | {id, name, input, pos: $k, mid: $all[$k].message.id}] as $uses
    | [$all | to_entries[] | select(.value.type == "user") | .key as $k
        | .value.message.content[]? | select(.type == "tool_result")
        | {id: .tool_use_id, is_error: (.is_error // false), text: (.content | txt), pos: $k}] as $res
    | [$uses[] | . as $u | . + {res: (first($res[] | select(.id == $u.id)) // null)}] as $J
    | [$J[] | select(.name == $ft)] as $D
    | ([$D[] | select(.res != null and (.res.is_error or (.res.text | startswith("Error:"))))] | min_by(.res.pos)) as $first
    | ($first.res.pos // -1) as $ff
    | [$J[] | select(.res != null and (.res.is_error | not) and (.res.text | length) > 0 and .pos > $ff
        and (.name == "Read"
          or (.name == "Grep" and .input.output_mode == "content" and (.res.text | test("^No matches found") | not))))] as $RD
    | ([.[] | select(.type == "result")] | last // {}) as $r
    | {
        ok: ($r | has("result")),
        answer_chars: (($r.result // "") | length),
        is_error: (if ($r | has("is_error")) then $r.is_error else true end),
        denied: [($r.permission_denials // [])[] | .tool_name],
        plugin_denied: [($r.permission_denials // [])[] | .tool_name | select(. == "Skill" or startswith("mcp__plugin_local-llm_local-llm__"))],
        mcp_tool_listed: ([$all[] | select(.type == "system" and .subtype == "init") | .tools[]?] | index($ft) != null),
        skill_used: ([$J[] | select(.name == "Skill")] | length > 0),
        delegate_calls: ($D | length),
        late_delegate_calls: (if $ff < 0 then 0 else [$D[] | select(.pos > $ff and .mid != $first.mid)] | length end),
        saw_fetch_failed: ([$D[] | select(.res != null and (.res.text | contains("fetch failed")))] | length > 0),
        saw_no_model: ([$D[] | select(.res != null and (.res.text | contains("No models loaded")))] | length > 0),
        delegated: [$bases[] | . as $b | select([$D[] | select((.input | tostring) | contains($b))] | length > 0)],
        read_by_claude: [$bases[] | . as $b | select([$RD[] | select((.input | tostring) | contains($b))] | length > 0)],
        content_read_attempt: [$bases[] | . as $b | select([$J[] | select((.name == "Read" and ((.input | tostring) | contains($b)))
          or (.name == "Bash" and ((.input.command // "") | contains($b))
            and ([(.input.command // "") | splits("[;&|]+") | select(test("^\\s*(cat|head|tail|sed|awk)\\s") and (contains($b) or contains("$")))] | length > 0)))] | length > 0)],
        notices_all: ([$all[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text
          | split("\n")[] | splits("(?<=[.!?]) +") | select(test($subj; "i") and test($outage; "i"))] | length),
        result_notices: ([($r.result // "") | split("\n")[] | splits("(?<=[.!?]) +") | select(test($subj; "i") and test($outage; "i"))] | length)
      }' "$trace" || echo '{"ok":false,"unknown":true}'
}

# check_<case> <summary-json> -> exit 0 when the run passes
check_a() { jq -e '.ok and (.is_error | not) and .answer_chars > 0 and (.delegated | index("app-20k.log") != null)
  and (.denied | index("'"$FILE_TOOL"'") == null) and (.content_read_attempt | index("app-20k.log") == null)' >/dev/null <<<"$1"; }
check_b() { jq -e '.ok and (.is_error | not) and .answer_chars > 0 and .delegate_calls == 0 and (.read_by_claude | index("app-2k.log") != null)' >/dev/null <<<"$1"; }
# c and d: the tool was tried, failed the expected way, was not called again, and Claude then read the file itself
check_c() { jq -e '.ok and (.is_error | not) and .answer_chars > 0 and .delegate_calls >= 1 and .saw_fetch_failed
  and .late_delegate_calls == 0 and (.read_by_claude | index("app-20k.log") != null)' >/dev/null <<<"$1"; }
check_d() { jq -e '.ok and (.is_error | not) and .answer_chars > 0 and .delegate_calls >= 1 and .saw_no_model
  and .late_delegate_calls == 0 and (.read_by_claude | index("app-20k.log") != null)' >/dev/null <<<"$1"; }
# check_e <turn-1 summary> <turn-2 summary>: turn 1 read file A itself after the tool failed with "fetch failed" and
# its final reply told the user; turn 2 read file B itself with no outage notice anywhere and no code_task_files call
check_e() {
  jq -e '.ok and (.is_error | not) and .answer_chars > 0 and .delegate_calls >= 1 and .saw_fetch_failed and .late_delegate_calls == 0
    and (.read_by_claude | index("app-20k.log") != null) and .result_notices >= 1' >/dev/null <<<"$1" \
  && jq -e '.ok and (.is_error | not) and .answer_chars > 0 and .delegate_calls == 0 and .notices_all == 0
    and (.read_by_claude | index("app-20k-b.log") != null)' >/dev/null <<<"$2"
}

# --- offline scorer self-test ------------------------------------------------------------------------
# Every assertion is one expect, expect_e or expect_f call; test-fence.sh checks that the printed total equals the
# number of such calls in this file and that none failed.
selftest() {
  local fx="$SCRIPT_DIR/fixtures/deleg" fails=0 total=0 s
  verdict() { # <label> <want> <got>
    total=$((total+1))
    if [ "$2" = "$3" ]; then echo "  selftest PASS: $1"; else echo "  selftest FAIL: $1 (got $3)"; fails=$((fails+1)); fi
  }
  # expect <label> <pass|fail> <case> <fixture> <base>...
  expect() {
    local label=$1 want=$2 c=$3 f=$4 got=fail; shift 4
    s=$(summarize "$fx/$f.jsonl" "$@" 2>/dev/null)
    "check_$c" "$s" && got=pass
    verdict "$label" "$want" "$got"
  }
  # expect_e <label> <pass|fail> <turn-1 fixture> <turn-2 fixture>
  expect_e() {
    local got=fail s1 s2
    s1=$(summarize "$fx/$3.jsonl" app-20k.log 2>/dev/null); s2=$(summarize "$fx/$4.jsonl" app-20k-b.log 2>/dev/null)
    check_e "$s1" "$s2" && got=pass
    verdict "$1" "$2" "$got"
  }
  # expect_f <label> <pass|fail> <fixture>: pass means no plugin-tool or skill denial
  expect_f() {
    local got=fail
    s=$(summarize "$fx/$3.jsonl" app-20k.log 2>/dev/null)
    jq -e '.ok and (.plugin_denied | length == 0)' >/dev/null <<<"$s" && got=pass
    verdict "$1" "$2" "$got"
  }
  expect "a: delegated, Grep spot-check" pass a a-ok app-20k.log
  expect "a: Claude also Read the delegated file" fail a a-read app-20k.log
  expect "a: Claude also cat the delegated file" fail a a-cat app-20k.log
  expect "b: read directly, no delegation" pass b b-ok app-2k.log
  expect "b: the 2k file was delegated" fail b b-delegates app-2k.log
  expect "c: fetch failed, then a successful Read" pass c c-ok app-20k.log
  expect "c: fetch failed, then a Grep in content mode" pass c c-grep-content app-20k.log
  expect "c: tool results given as content arrays" pass c c-array-content app-20k.log
  expect "c: parallel first wave of two calls is allowed" pass c c-parallel app-20k.log
  expect "c: fetch failed, then a denied Read and a refusal" fail c c-denied-read app-20k.log
  expect "c: second code_task_files call after the failure" fail c c-second-call app-20k.log
  expect "c: Grep in files_with_matches mode proves nothing" fail c c-grep-files-only app-20k.log
  expect "c: Grep in content mode with no match proves nothing" fail c c-grep-no-match app-20k.log
  expect "c: wc -c; cat /dev/null proves nothing" fail c c-wc-cat-devnull app-20k.log
  expect "d: No models loaded, then a Read" pass d d-ok app-20k.log
  expect "d: fetch failed instead of No models loaded" fail d c-ok app-20k.log
  expect_e "e: turn 1 final reply tells the user, turn 2 is silent and reads" pass c-ok e2-ok
  expect_e "e: a mid-turn note plus a final notice in turn 1" pass e1-two-notices e2-ok
  expect_e "e: a mid-turn note but a silent final reply in turn 1" fail e1-midnote-only e2-ok
  expect_e "e: turn 1 never tells the user" fail e1-silent e2-ok
  expect_e "e: turn 1 failure is not an outage" fail e1-other-failure e2-ok
  expect_e "e: turn 2 re-announces the outage" fail c-ok e2-renotice
  expect_e "e: turn 2 calls code_task_files again" fail c-ok e2-delegates
  expect_e "e: turn 2 summary says a log server is down" pass c-ok e2-server-summary
  expect "unparseable trace is unknown and fails" fail c garbage app-20k.log
  expect_f "f: a plugin-tool denial is flagged" fail f-plugin-denied
  expect_f "f: a non-plugin denial does not gate" pass c-denied-read
  echo "selftest total: $total, failed: $fails"
  [ "$fails" -eq 0 ]
}
if [ "${DELEG_SELFTEST:-}" = 1 ] || [ "${1:-}" = "--self-test" ]; then
  command -v jq >/dev/null 2>&1 || die "jq is required"
  selftest; exit $?
fi

# --- setup -------------------------------------------------------------------------------------------
for tool in claude node jq curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
TIMEOUT=$(command -v timeout || command -v gtimeout) || die "timeout (or gtimeout) is required; on macOS: brew install coreutils"
case "$REPO/" in
  "$HOME/github/"*|"$HOME/catalyst/"*) ;;
  *) die "fixtures live under the repo, which must sit inside the default allowed_dirs (\$HOME/github or \$HOME/catalyst)" ;;
esac

OUT="${DELEG_OUT:-$(mktemp -d)}"
mkdir -p "$OUT" && [ -d "$OUT" ] && [ -w "$OUT" ] || die "trace dir $OUT is not a writable directory"
OUT=$(cd "$OUT" && pwd -P)
FIX=$(mktemp -d "$REPO/tests/.tmp-deleg-XXXXXX") || die "mktemp for fixtures"
FIX=$(cd "$FIX" && pwd -P)
PLUGINS=$(mktemp -d) || die "mktemp for plugin copies"
WORK=$(mktemp -d) || die "mktemp for the session cwd"   # outside the repo: no project memory, no ancestor node_modules
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
for f_n in app-20k.log:20000 app-2k.log:2000 app-20k-b.log:20000; do
  [ "$(wc -c < "$FIX/${f_n%%:*}")" -eq "${f_n##*:}" ] || die "fixture ${f_n%%:*} is not ${f_n##*:} bytes"
done

# copy_plugin <dest> <endpoint-url>: temp plugin copy whose endpoint_url default is <endpoint-url>
copy_plugin() {
  mkdir -p "$1" || die "mkdir $1"
  cp -R "$REPO/.claude-plugin" "$REPO/.mcp.json" "$REPO/package.json" "$REPO/scripts" "$REPO/skills" "$REPO/hooks" "$1/" \
    || die "copying the plugin to $1"
  jq --arg u "$2" '.userConfig.endpoint_url.default = $u' "$REPO/.claude-plugin/plugin.json" > "$1/.claude-plugin/plugin.json" \
    || die "rewriting plugin.json in $1"
  [ "$(jq -r '.userConfig.endpoint_url.default' "$1/.claude-plugin/plugin.json")" = "$2" ] || die "plugin copy $1 does not carry endpoint $2"
}
dead_url() {
  local port
  port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})') \
    && [ -n "$port" ] || die "could not reserve an unused loopback port"
  echo "http://127.0.0.1:$port"
}

# LM Studio counts as up only when it lists at least one model
lm_up=0; lm_models=0
lm_models=$(curl -s -m 3 "$ENDPOINT/v1/models" 2>/dev/null | jq '.data | length' 2>/dev/null) || lm_models=0
[ "${lm_models:-0}" -gt 0 ] 2>/dev/null && lm_up=1 || lm_models=0

# run_claude <plugin-dir> <prompt> <trace-file> [resume-session-id]: returns claude's (timeout's) exit code.
# Case e needs a resumable session, so it passes an id (turn 2) or sets KEEP_SESSION=1 (turn 1); the other
# cases do not persist theirs.
run_claude() {
  local args=(-p "$2" --plugin-dir "$1" --output-format stream-json --verbose)
  if [ -n "${4:-}" ]; then args+=(--resume "$4"); elif [ "${KEEP_SESSION:-}" != 1 ]; then args+=(--no-session-persistence); fi
  [ -z "$SOURCES" ] || args+=(--setting-sources "$SOURCES")
  [ -z "${DELEG_MODEL:-}" ] || args+=(--model "$DELEG_MODEL")
  [ -z "${DELEG_ALLOWED_TOOLS:-}" ] || args+=(--allowedTools "$DELEG_ALLOWED_TOOLS")
  args+=(--add-dir "$FIX")
  (cd "$WORK" && "$TIMEOUT" "$RUN_TIMEOUT_SEC" claude "${args[@]}" > "$3" 2> "$3.err" < /dev/null)
}

# --- plugins for each case ---------------------------------------------------------------------------
copy_plugin "$PLUGINS/real" "$ENDPOINT"
DEAD=$(dead_url) || die "no dead endpoint url"
copy_plugin "$PLUGINS/down" "$DEAD"
case " $CASES " in *" d "*)
  node "$SCRIPT_DIR/fake-endpoint.mjs" "$PLUGINS/port" "$PLUGINS/requests.log" no-model &
  FAKE_PID=$!
  for _ in $(seq 1 50); do [ -s "$PLUGINS/port" ] && break; sleep 0.1; done
  [ -s "$PLUGINS/port" ] || die "fake endpoint did not start"
  copy_plugin "$PLUGINS/nomodel" "http://127.0.0.1:$(cat "$PLUGINS/port")" ;;
esac

plugin_for() { case "$1" in a|b) echo real ;; c|e) echo down ;; d) echo nomodel ;; esac; }
bases_for() { case "$1" in b) echo "app-2k.log" ;; *) echo "app-20k.log" ;; esac; }
prompt_for() {
  case "$1" in
    b) echo "Summarize $FIX/app-2k.log in five bullet points." ;;
    e) echo "Summarize $FIX/app-20k.log in three bullet points." ;;
    *) echo "Summarize $FIX/app-20k.log in five bullet points." ;;
  esac
}
THRESHOLD=$(( (RUNS * 4 + 4) / 5 ))

echo "delegation acceptance: $RUNS runs per case (pass at >= $THRESHOLD), traces in $OUT"
echo "LM Studio models listed: $lm_models; model: ${DELEG_MODEL:-default}; setting sources: ${SOURCES:-none}"

overall=0; total_runs=0; inspectable=0; plugin_denials=0; other_denials=0; skipped=0
# tally <summary>: add one trace to the case f totals
tally() {
  total_runs=$((total_runs+1))
  jq -e '.ok' >/dev/null <<<"$1" || return 0
  inspectable=$((inspectable+1))
  plugin_denials=$((plugin_denials + $(jq '.plugin_denied | length' <<<"$1")))
  other_denials=$((other_denials + $(jq '(.denied | length) - (.plugin_denied | length)' <<<"$1")))
}
# report_run <exit-code> <trace> <verdict>: name a timeout, and show the first stderr line of a failed run
report_run() {
  if [ "$1" -ne 0 ]; then
    if [ "$1" -eq 124 ]; then echo "    claude timed out after ${RUN_TIMEOUT_SEC}s (exit 124): $(basename "$2")"; else echo "    claude exited $1: $(basename "$2")"; fi
  fi
  case "$3" in pass) ;; *) [ ! -s "$2.err" ] || echo "    stderr: $(head -n 1 "$2.err" | cut -c1-200)" ;; esac
}
for c in $CASES; do
  if [ -z "$(plugin_for "$c")" ]; then echo "unknown case: $c"; overall=1; continue; fi
  if [ "$lm_up" = 0 ] && { [ "$c" = a ] || [ "$c" = b ]; }; then echo "case $c: SKIP (LM Studio lists no model)"; skipped=$((skipped+1)); continue; fi
  passes=0
  for n in $(seq 1 "$RUNS"); do
    trace="$OUT/$c-$n.jsonl"
    if [ "$c" = e ]; then
      KEEP_SESSION=1 run_claude "$PLUGINS/$(plugin_for e)" "$(prompt_for e)" "$trace"; rc=$?
      s=$(summarize "$trace" app-20k.log)
      sid=$(jq -rs '[.[] | .session_id? // empty] | first // empty' "$trace" 2>/dev/null)
      trace2="$OUT/e-$n-turn2.jsonl"; rc2=0
      if [ -n "$sid" ]; then
        run_claude "$PLUGINS/$(plugin_for e)" "Now summarize $FIX/app-20k-b.log in three bullet points." "$trace2" "$sid"; rc2=$?
        s2=$(summarize "$trace2" app-20k-b.log)
      else
        s2='{"ok":false,"unknown":true}'; echo "no session id in $(basename "$trace"); turn 2 not run" > "$trace2.err"
      fi
      tally "$s"; tally "$s2"
      if ! jq -e '.ok' >/dev/null <<<"$s" || ! jq -e '.ok' >/dev/null <<<"$s2"; then verdict="FAIL (unknown: no parsable result event or session id)"
      elif [ "$rc" -ne 0 ] || [ "$rc2" -ne 0 ]; then verdict="FAIL (claude exited $rc/$rc2)"
      elif check_e "$s" "$s2"; then passes=$((passes+1)); verdict=pass
      else verdict=FAIL; fi
      echo "  e-$n $verdict turn1_notices=$(jq '.notices_all' <<<"$s" 2>/dev/null) session_notices=$(jq -n --argjson a "$s" --argjson b "$s2" '($a.notices_all // 0) + ($b.notices_all // 0)') turn1 $(jq -c '{delegate_calls, late_delegate_calls, result_notices, read_by_claude}' <<<"$s" 2>/dev/null) turn2 $(jq -c '{delegate_calls, notices_all, read_by_claude, denied}' <<<"$s2" 2>/dev/null)"
      report_run "$rc" "$trace" "$verdict"; [ ! -e "$trace2" ] || report_run "$rc2" "$trace2" "$verdict"
      continue
    fi
    run_claude "$PLUGINS/$(plugin_for "$c")" "$(prompt_for "$c")" "$trace"; rc=$?
    # shellcheck disable=SC2046
    s=$(summarize "$trace" $(bases_for "$c"))
    tally "$s"
    if ! jq -e '.ok' >/dev/null <<<"$s"; then verdict="FAIL (unknown: no parsable result event)"
    elif [ "$rc" -ne 0 ]; then verdict="FAIL (claude exited $rc)"
    elif "check_$c" "$s"; then passes=$((passes+1)); verdict=pass
    else verdict=FAIL; fi
    echo "  $c-$n $verdict $(jq -c '{mcp_tool_listed, skill_used, delegate_calls, late_delegate_calls, saw_fetch_failed, saw_no_model, delegated, read_by_claude, content_read_attempt, notices_all, denied, answer_chars}' <<<"$s" 2>/dev/null)"
    report_run "$rc" "$trace" "$verdict"
  done
  if [ "$passes" -ge "$THRESHOLD" ]; then echo "case $c: $passes/$RUNS PASS"; else echo "case $c: $passes/$RUNS FAIL"; overall=1; fi
done
if [ "$inspectable" -eq 0 ]; then
  echo "case f: nothing was inspectable"
elif [ "$inspectable" -eq "$total_runs" ] && [ "$plugin_denials" -eq 0 ]; then
  echo "case f: $plugin_denials plugin denials in $inspectable/$total_runs inspectable runs PASS"
else
  echo "case f: $plugin_denials plugin denials in $inspectable/$total_runs inspectable runs FAIL"; overall=1
fi
echo "other denials (not plugin): $other_denials"
if [ "$skipped" -gt 0 ]; then echo "$skipped case(s) SKIPPED: acceptance incomplete"; overall=1; fi
exit "$overall"
