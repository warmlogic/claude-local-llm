#!/usr/bin/env bash
# Offline tests for the batch runner (batch/flatten-transcripts.mjs, batch/run.mjs).
# Run from repo root: bash tests/test-batch.sh (test-fence.sh runs it on every commit).
# Every model answer comes from tests/fake-endpoint.mjs in a batch mode; nothing needs LM Studio.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$SCRIPT_DIR/.."
RUN="$REPO/batch/run.mjs"
FLAT="$REPO/batch/flatten-transcripts.mjs"

pass=0; fail=0; tn=0
ok()  { pass=$((pass+1)); tn=$((tn+1)); echo "  Test $tn PASS: $1"; }
bad() { fail=$((fail+1)); tn=$((tn+1)); echo "  Test $tn FAIL: $1"; }
for tool in node jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required to run this suite"; exit 1; }
done

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT

# start_fake <name> <mode>: a fake endpoint on a random loopback port; sets EP and LOG
start_fake() {
  : > "$TMP/$1.log"
  node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/$1.port" "$TMP/$1.log" "$2" &
  PIDS+=($!)
  for _ in $(seq 1 50); do [ -s "$TMP/$1.port" ] && break; sleep 0.1; done
  [ -s "$TMP/$1.port" ] || { echo "FAIL: fake endpoint '$1' ($2) did not start"; exit 1; }
  EP="http://127.0.0.1:$(cat "$TMP/$1.port")"; LOG="$TMP/$1.log"
}
# job <check> <cap>: writes $TMP/job.json
job() {
  jq -n --arg check "$1" --argjson cap "$2" '{prompt:"Find things.", check:$check, max_window_chars:$cap,
    row_schema:{type:"object",additionalProperties:false,required:["line","kind","quote","note"],
      properties:{line:{type:"string"},kind:{type:"string",enum:["correction","stuck"]},quote:{type:"string"},note:{type:"string"}}}}' > "$TMP/job.json"
}
# lines <n> <width> <file>: n flattened-style lines "L<i>\tuser\ttext\t<pad>" of about <width> chars
lines() { node -e 'const [n,w]=process.argv.slice(1).map(Number);for(let i=1;i<=n;i++){const h=`L${i}\tuser\ttext\t`;console.log(h+`line ${i} `.padEnd(w-h.length,"x"))}' "$1" "$2" > "$3"; }
# run_batch <endpoint> <outdir> <files...>: runs the job in $TMP/job.json; stdout+stderr to $TMP/run.out, rc in $RC
run_batch() { local ep="$1" out="$2"; shift 2; LOCAL_LLM_ENDPOINT_URL="$ep" node "$RUN" --job "${JOB:-$TMP/job.json}" --out "$out" "$@" > "$TMP/run.out" 2>&1; RC=$?; }
# request_texts: one window text per logged chat request (between the BEGIN/END markers)
request_texts() { jq -r 'select(.body) | .body.messages[-1].content | split("--- BEGIN TEXT ---\n")[1] | split("\n--- END TEXT ---")[0] | @json' "$1"; }
count() { wc -l < "$1" | tr -d ' '; }

# --- windowing, quote check, request shape, index -------------------------------
start_fake a batch
lines 60 100 "$TMP/a.txt"           # 60 lines of 100 chars = about 6.1k chars
job quote-in-line 2000
run_batch "$EP" "$TMP/out-a" "$TMP/a.txt"
nreq=$(jq -s '[.[] | select(.body)] | length' "$LOG")
maxlen=$(request_texts "$LOG" | jq -s 'map(length) | max')
nlines=$(request_texts "$LOG" | jq -s 'map(split("\n") | length) | add')
if [ "$RC" -eq 0 ] && [ "$nreq" -eq 4 ] && [ "$maxlen" -le 2000 ] && [ "$nlines" -eq 60 ]; then ok "windows hold whole lines within the cap ($nreq windows, longest $maxlen chars, all 60 lines sent once)"
else bad "windowing: rc=$RC requests=$nreq longest=$maxlen lines sent=$nlines"; fi
if grep -q '^a.txt window 1/4: kept 1 dropped 1$' "$TMP/run.out" && grep -q '^a.txt window 4/4: kept 1 dropped 1$' "$TMP/run.out"; then ok "progress: one stderr line per window with kept and dropped counts"
else bad "progress lines: $(head -c 300 "$TMP/run.out")"; fi
if grep -q '^Completed: 4 of 4 windows answered\.$' "$TMP/out-a/index.md" && grep -q 'across 1 of 1 files' "$TMP/out-a/index.md" && grep -qE 'Started [0-9]{4}-' "$TMP/out-a/index.md" && ! grep -q RUNNING "$TMP/out-a/index.md" && [ ! -e "$TMP/out-a/index.md.tmp" ]; then ok "index.md header counts answered windows and files reached; the RUNNING stub is gone"
else bad "index header: $(head -5 "$TMP/out-a/index.md")"; fi
if [ "$(count "$TMP/out-a/rows.jsonl")" -eq "$nreq" ] && jq -e -s 'all(.[]; .note == "true quote" and .file == "a.txt" and (.window | type == "number"))' "$TMP/out-a/rows.jsonl" >/dev/null; then ok "quote-in-line keeps the true quote and tags file and window"
else bad "true quotes: $(head -c 300 "$TMP/out-a/rows.jsonl")"; fi
if [ "$(count "$TMP/out-a/dropped.jsonl")" -eq "$nreq" ] && jq -e -s 'all(.[]; .note == "fabricated" and .reason == "quote_not_in_line")' "$TMP/out-a/dropped.jsonl" >/dev/null; then ok "quote-in-line drops the fabricated quote with a reason"
else bad "fabricated quotes: $(head -c 300 "$TMP/out-a/dropped.jsonl")"; fi
if jq -e -s 'all(.[]; .body.temperature == 0 and .body.reasoning_effort == "none" and .body.response_format.json_schema.strict == true and .body.response_format.json_schema.schema.properties.rows.type == "array" and .body.max_tokens > 0)' <(jq -c 'select(.body)' "$LOG") >/dev/null; then ok "requests use temperature 0, reasoning off and a strict json_schema"
else bad "request shape"; fi
idx="$TMP/out-a/index.md"
if [ "$(count "$idx")" -lt 60 ] && grep -q "Windows: $nreq" "$idx" && grep -q "correction $nreq" "$idx" && grep -q "Tokens: $((nreq*10)) prompt, $((nreq*5)) completion" "$idx"; then ok "index.md is short and reports windows, kinds and token totals"
else bad "index.md: $(head -12 "$idx")"; fi
job none 2000
run_batch "$EP" "$TMP/out-n" "$TMP/a.txt"
if [ "$(count "$TMP/out-n/rows.jsonl")" -eq $((nreq*2)) ] && [ "$(count "$TMP/out-n/dropped.jsonl")" -eq 0 ]; then ok 'check "none" keeps every row'
else bad "check none: kept $(count "$TMP/out-n/rows.jsonl") dropped $(count "$TMP/out-n/dropped.jsonl")"; fi

# the checker itself: whitespace-normalized fallback and a line that is not in the window
cq=$(node --input-type=module -e '
import { checkQuote } from "'"$REPO"'/batch/run.mjs";
const m = new Map([["L1", "L1\tuser\ttext\tno, use  the other ⏎ file here"], ["L2", "L2\tuser\ttext\thello"], ["L3", "L3\tplain numbered line text"]]);
const q = (line, quote) => checkQuote({ line, quote }, m);
console.log(JSON.stringify([
  q("L1", "use the other ⏎ file"), q("L1", "use the files here"), q("L9", "use the other ⏎ file"),
  q("L1", "user"), q("L1", "L1"), q("L1", "text no, use"), q("L1", "user\ttext\tno, use  the"),
  q("L2", "text hello"), q("L1", "x"), q("L2", "hello"), q("L3", "plain numbered"), q("L3", "L3"),
  q("L1", ""), checkQuote({ quote: "other" }, m)]));')
if [ "$cq" = '[null,"quote_not_in_line","line_not_in_window","quote_too_short","quote_too_short","quote_not_in_line","quote_not_in_line","quote_too_short","quote_too_short",null,null,"quote_too_short","missing_line_or_quote","missing_line_or_quote"]' ]; then ok "checkQuote: matches the text field only (not role, kind or id), needs 12 chars unless it is the whole text"
else bad "checkQuote: $cq"; fi

# --- a line over the cap -------------------------------------------------------
lines 5 100 "$TMP/c.txt"
{ head -2 "$TMP/c.txt"; printf 'L90\tuser\ttext\t%s\n' "$(head -c 3000 /dev/zero | tr '\0' y)"; tail -3 "$TMP/c.txt"; } > "$TMP/c2.txt"
: > "$LOG"
job quote-in-line 1000
run_batch "$EP" "$TMP/out-c" "$TMP/c2.txt"
if [ "$RC" -eq 0 ] && jq -e -s 'length == 1 and .[0].type == "line_over_cap"' "$TMP/out-c/failures.jsonl" >/dev/null && ! grep -q 'L90' "$LOG" && grep -q 'line_over_cap 1' "$TMP/out-c/index.md"; then ok "a line over the cap is counted, skipped and never sent"
else bad "line_over_cap: $(cat "$TMP/out-c/failures.jsonl" | head -c 300)"; fi

# --- malformed replies ---------------------------------------------------------
lines 3 100 "$TMP/m.txt"
job quote-in-line 50000
start_fake bad batch-bad
run_batch "$EP" "$TMP/out-bad" "$TMP/m.txt"
if [ "$RC" -eq 1 ] && grep -q '^\*\*FAILED\*\*: no window answered (last failure: malformed_reply' "$TMP/out-bad/index.md" && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 2 ] && jq -e -s 'length == 1 and .[0].type == "malformed_reply"' "$TMP/out-bad/failures.jsonl" >/dev/null && [ "$(count "$TMP/out-bad/rows.jsonl")" -eq 0 ]; then ok "a malformed reply is retried once, then counted"
else bad "malformed: requests=$(jq -s '[.[] | select(.body)] | length' "$LOG") failures=$(head -c 300 "$TMP/out-bad/failures.jsonl")"; fi
start_fake once batch-bad-once
run_batch "$EP" "$TMP/out-once" "$TMP/m.txt"
if [ "$RC" -eq 0 ] && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 2 ] && [ "$(count "$TMP/out-once/failures.jsonl")" -eq 0 ] && [ "$(count "$TMP/out-once/rows.jsonl")" -eq 1 ]; then ok "a malformed first reply followed by a good one costs no failure"
else bad "retry recovery: failures=$(head -c 300 "$TMP/out-once/failures.jsonl")"; fi
start_fake len batch-length
run_batch "$EP" "$TMP/out-len" "$TMP/m.txt"
if [ "$RC" -eq 1 ] && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 1 ] && jq -e -s 'length == 1 and .[0].type == "finish_length"' "$TMP/out-len/failures.jsonl" >/dev/null; then ok "finish_reason length is counted and not retried"
else bad "finish_length: $(head -c 300 "$TMP/out-len/failures.jsonl")"; fi

# --- endpoint down, non-loopback -------------------------------------------------
dead_port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
lines 40 100 "$TMP/d.txt"
job quote-in-line 1000       # 5 windows
run_batch "http://127.0.0.1:$dead_port" "$TMP/out-d" "$TMP/d.txt"
if [ "$RC" -eq 1 ] && jq -e -s 'length == 3 and all(.[]; .type == "endpoint_unreachable")' "$TMP/out-d/failures.jsonl" >/dev/null && grep -q '^\*\*FAILED\*\*: no window answered (last failure: endpoint_unreachable' "$TMP/out-d/index.md" && grep -q 'across 1 of 1 files' "$TMP/out-d/index.md" && grep -q 'endpoint_unreachable 3' "$TMP/out-d/index.md"; then ok "endpoint down: the run aborts after 3 consecutive failures, counted in index.md"
else bad "endpoint down: rc=$RC $(head -c 300 "$TMP/out-d/failures.jsonl")"; fi
run_batch "http://example.com:1234" "$TMP/out-r" "$TMP/m.txt"
if [ "$RC" -eq 2 ] && grep -q 'must be loopback' "$TMP/run.out" && [ ! -e "$TMP/out-r/rows.jsonl" ]; then ok "a non-loopback endpoint is refused before anything runs"
else bad "non-loopback: rc=$RC $(head -c 300 "$TMP/run.out")"; fi

# --- flatten-transcripts -----------------------------------------------------------
long=$(head -c 2500 /dev/zero | tr '\0' z)
jq -nc --arg long "$long" '
  {type:"user",message:{role:"user",content:"first\nsecond\tthird"}},
  {type:"assistant",message:{role:"assistant",content:[{type:"thinking",thinking:"secret"},{type:"text",text:"hello"},{type:"tool_use",name:"Bash",input:{command:"ls"}}]}},
  {type:"user",message:{role:"user",content:[{type:"tool_result",content:[{type:"text",text:"out"}],is_error:true}]}},
  {type:"user",message:{role:"user",content:[{type:"tool_result",content:$long}]}},
  {type:"assistant",message:{role:"assistant",content:[]}},
  {type:"attachment"},
  {type:"system",message:{content:"ignored"}}' > "$TMP/s.jsonl"
echo 'not json' >> "$TMP/s.jsonl"
node "$FLAT" "$TMP/flat" "$TMP/s.jsonl" > /dev/null
f="$TMP/flat/s.txt"
if [ "$(count "$f")" -eq 5 ] && [ "$(sed -n 1p "$f")" = "$(printf 'L1\tuser\ttext\tfirst ⏎ second third')" ] && ! grep -q secret "$f" \
   && [ "$(sed -n 4p "$f")" = "$(printf 'L4\tuser\ttool_error\tout')" ] && [ "$(sed -n 3p "$f" | cut -f1-3)" = "$(printf 'L3\tassistant\ttool_use')" ] \
   && [ "$(sed -n 5p "$f" | cut -f4)" = "${long:0:2000}…" ]; then ok "flatten: ids, roles and kinds; thinking, empty and non-message entries skipped; newlines folded; blocks cut at 2000 chars"
else bad "flatten output: $(cut -c1-80 "$f")"; fi

# --- direct-run guards: proxy, distinct basenames, paths with spaces -------------------
: > "$LOG"
start_fake px batch
HTTP_PROXY=http://127.0.0.1:9 run_batch "$EP" "$TMP/out-px" "$TMP/m.txt"
rc1=$RC; grep -q 'HTTP_PROXY' "$TMP/run.out"; g1=$?
NODE_USE_ENV_PROXY=1 run_batch "$EP" "$TMP/out-px" "$TMP/m.txt"
if [ "$rc1" -eq 2 ] && [ "$g1" -eq 0 ] && [ "$RC" -eq 2 ] && [ ! -e "$TMP/out-px/rows.jsonl" ] && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 0 ]; then ok "a proxy variable defined refuses the run before any request"
else bad "proxy guard: rc=$rc1/$RC $(head -c 200 "$TMP/run.out")"; fi
mkdir -p "$TMP/d1" "$TMP/d2"; cp "$TMP/m.txt" "$TMP/d1/same.txt"; cp "$TMP/m.txt" "$TMP/d2/same.txt"
run_batch "$EP" "$TMP/out-dup" "$TMP/d1/same.txt" "$TMP/d2/same.txt"
if [ "$RC" -eq 2 ] && grep -q 'distinct basenames' "$TMP/run.out" && [ ! -e "$TMP/out-dup/rows.jsonl" ]; then ok "run.mjs refuses inputs with the same basename"
else bad "duplicate basenames: rc=$RC $(head -c 200 "$TMP/run.out")"; fi
mkdir -p "$TMP/d1/x" "$TMP/d2/x"; cp "$TMP/s.jsonl" "$TMP/d1/x/s.jsonl"; cp "$TMP/s.jsonl" "$TMP/d2/x/s.jsonl"
node "$FLAT" "$TMP/flat-dup" "$TMP/d1/x/s.jsonl" "$TMP/d2/x/s.jsonl" > "$TMP/flat.out" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$TMP/flat-dup/s.txt" ]; then ok "flatten refuses two inputs that map to one output file"
else bad "flatten duplicates: rc=$rc"; fi
mkdir -p "$TMP/sp ace #1/scripts" "$TMP/sp ace #1/server"; cp -R "$REPO/batch" "$TMP/sp ace #1/batch"
cp "$REPO/scripts/loopback.mjs" "$TMP/sp ace #1/scripts/"; cp "$REPO/server/endpoint.mjs" "$REPO/server/errors.mjs" "$TMP/sp ace #1/server/"
LOCAL_LLM_ENDPOINT_URL="$EP" node "$TMP/sp ace #1/batch/run.mjs" --job "$TMP/job.json" --out "$TMP/out-sp" "$TMP/m.txt" > "$TMP/run.out" 2>&1
node "$TMP/sp ace #1/batch/flatten-transcripts.mjs" "$TMP/flat-sp" "$TMP/s.jsonl" > /dev/null 2>&1
if [ -s "$TMP/out-sp/index.md" ] && [ -s "$TMP/flat-sp/s.txt" ]; then ok "both scripts run from a directory with spaces and a # in its path"
else bad "path with spaces: index=$(ls "$TMP/out-sp" 2>&1 | head -3) $(head -c 200 "$TMP/run.out")"; fi

# --- flatten: queued_command attachments and unparseable lines -----------------------------
{ jq -nc '{type:"user",message:{role:"user",content:"hi"}},
  {type:"attachment",attachment:{type:"queued_command",prompt:"no, stop doing that"}},
  {type:"attachment",attachment:{type:"queued_command",prompt:[{type:"text",text:"array prompt"}]}},
  {type:"attachment",attachment:{type:"hook_success"}}'; echo null; echo '{broken'; echo '[1]'; } > "$TMP/q.jsonl"
node "$FLAT" "$TMP/flat-q" "$TMP/q.jsonl" 2> "$TMP/flat-q.err"
if [ "$(cat "$TMP/flat-q/q.txt")" = "$(printf 'L1\tuser\ttext\thi\nL2\tuser\ttext\tno, stop doing that\nL3\tuser\ttext\tarray prompt')" ] && grep -q 'q.txt: 3 lines, 2 unparseable skipped$' "$TMP/flat-q.err"; then ok "flatten: queued_command attachments become user text lines; null and broken lines are counted on stderr"
else bad "flatten queued_command: $(tr '\n' '|' < "$TMP/flat-q/q.txt" | cut -c1-120) / $(cat "$TMP/flat-q.err")"; fi

# --- run outcome, abort rule, failure details ---------------------------------------------
lines 95 100 "$TMP/w.txt"       # 5 windows at cap 2000
lines 114 100 "$TMP/w6.txt"     # 6 windows
job quote-in-line 2000
start_fake nm no-model
run_batch "$EP" "$TMP/out-nm" "$TMP/w.txt" "$TMP/w6.txt"
if [ "$RC" -eq 1 ] && grep -q 'across 1 of 2 files' "$TMP/out-nm/index.md" && jq -e -s 'length == 3 and all(.[]; .type == "http_error" and .detail == "HTTP 404 no_models_loaded (load a model in LM Studio)")' "$TMP/out-nm/failures.jsonl" >/dev/null \
   && grep -q '^\*\*FAILED\*\*: no window answered (last failure: http_error HTTP 404 no_models_loaded' "$TMP/out-nm/index.md"; then ok "every window an HTTP error: FAILED header names the allowlisted code, exit 1, abort after 3"
else bad "no-model: rc=$RC $(head -c 300 "$TMP/out-nm/failures.jsonl") $(sed -n 3p "$TMP/out-nm/index.md")"; fi
start_fake fl batch-flaky
run_batch "$EP" "$TMP/out-fl" "$TMP/w6.txt"
if [ "$RC" -eq 0 ] && grep -q '^Completed: 3 of 6 windows answered\.$' "$TMP/out-fl/index.md" && jq -e -s 'length == 3 and all(.[]; .type == "http_error")' "$TMP/out-fl/failures.jsonl" >/dev/null; then ok "alternating failures and answers do not abort; the header says 3 of 6 answered"
else bad "flaky: rc=$RC $(sed -n 3,4p "$TMP/out-fl/index.md")"; fi
start_fake tgt batch; TGT_EP=$EP; TGT_LOG=$LOG
start_fake rd verify-redirect "$TGT_EP"
run_batch "$EP" "$TMP/out-rd" "$TMP/m.txt"
tgt_n=$(jq -s '[.[] | select(.url == "/v1/chat/completions")] | length' "$TGT_LOG")
if [ "$RC" -eq 1 ] && [ "$tgt_n" -eq 0 ] && jq -e -s 'length >= 1 and all(.[]; .type == "http_error" and .detail == "HTTP 307")' "$TMP/out-rd/failures.jsonl" >/dev/null; then ok "a redirect is a recorded http_error and the target sees no request"
else bad "redirect: rc=$RC target requests=$tgt_n $(head -c 200 "$TMP/out-rd/failures.jsonl")"; fi

# --- several files, a missing one, empty and duplicate-id inputs -----------------------------
start_fake mf batch
printf '\n\n' > "$TMP/empty.txt"
{ printf 'L1\tuser\ttext\tfirst line of text\n'; printf 'L1\tuser\ttext\tsame id again here\n'; } > "$TMP/dup.txt"
run_batch "$EP" "$TMP/out-mf" "$TMP/a.txt" "$TMP/missing.txt" "$TMP/m.txt" "$TMP/empty.txt" "$TMP/dup.txt"
nm=$(jq -s '[.[] | select(.body)] | length' "$LOG")
if [ "$RC" -eq 0 ] && [ "$nm" -eq 5 ] \
   && jq -e -s '([.[] | select(.file == "a.txt") | .window] | unique) == [1,2,3,4] and ([.[] | select(.file == "m.txt") | .window] | unique) == [1]' "$TMP/out-mf/rows.jsonl" >/dev/null \
   && jq -e -s 'map(.type) | sort == ["duplicate_line_id","empty_input","unreadable_input"]' "$TMP/out-mf/failures.jsonl" >/dev/null \
   && jq -e -s '.[] | select(.type == "unreadable_input") | .file == "missing.txt" and .detail == "ENOENT"' "$TMP/out-mf/failures.jsonl" >/dev/null \
   && grep -q 'across 5 of 5 files' "$TMP/out-mf/index.md" && grep -q '^Completed: 5 of 6 windows answered\.$' "$TMP/out-mf/index.md" \
   && grep -q '^| missing.txt | 0 | 0 | 0 |$' "$TMP/out-mf/index.md"; then ok "several files: windows number per file; missing, empty and duplicate-id inputs are counted failures, the duplicate window is never sent"
else bad "multi-file: rc=$RC requests=$nm $(sed -n 3,4p "$TMP/out-mf/index.md") $(jq -c '.type' "$TMP/out-mf/failures.jsonl" | tr '\n' ' ')"; fi

# --- job validation and unnumbered input (exit 2, nothing written) --------------------------
validate() { # <name> <jq filter over the job> : the run must exit 2 and leave --out untouched
  jq "$2" "$TMP/job.json" > "$TMP/job-$1.json"
  JOB="$TMP/job-$1.json" run_batch "$EP" "$TMP/out-v-$1" "$TMP/m.txt"
  if [ "$RC" -eq 2 ] && [ ! -e "$TMP/out-v-$1" ]; then ok "job validation: $1 exits 2 before anything is written"
  else bad "job validation $1: rc=$RC $(head -c 200 "$TMP/run.out")"; fi
}
validate unknown-check '.check = "nope"'
validate zero-window-cap '.max_window_chars = 0'
validate text-window-cap '.max_window_chars = "big"'
validate null-row-schema '.row_schema = null'
validate array-row-schema '.row_schema = []'
validate schema-declares-file '.row_schema.properties.file = {type:"string"}'
validate schema-declares-reason '.row_schema.properties.reason = {type:"string"}'
printf 'just a plain line\nanother plain line\n' > "$TMP/plain.txt"
run_batch "$EP" "$TMP/out-plain" "$TMP/plain.txt"
if [ "$RC" -eq 2 ] && grep -q 'not numbered input; run batch/flatten-transcripts.mjs' "$TMP/run.out" && [ ! -e "$TMP/out-plain" ]; then ok "quote-in-line on unnumbered input exits 2 and says to flatten first"
else bad "unnumbered input: rc=$RC $(head -c 200 "$TMP/run.out")"; fi

# --- a killed run leaves a stub that says RUNNING ----------------------------------------------
start_fake st batch-stall
LOCAL_LLM_ENDPOINT_URL="$EP" node "$RUN" --job "$TMP/job.json" --out "$TMP/out-st" "$TMP/m.txt" > /dev/null 2>&1 &
st_pid=$!
for _ in $(seq 1 100); do grep -q '"body"' "$LOG" && break; sleep 0.1; done
cat "$TMP/out-st/index.md" > "$TMP/st-while.md"
kill "$st_pid" 2>/dev/null; wait "$st_pid" 2>/dev/null
if grep -qE "^RUNNING since [0-9]{4}-.* \(pid $st_pid\) — not complete$" "$TMP/out-st/index.md" && grep -q RUNNING "$TMP/st-while.md"; then ok "index.md says RUNNING while the run is in flight and after it is killed"
else bad "RUNNING stub: $(head -c 200 "$TMP/out-st/index.md")"; fi

echo "batch pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
