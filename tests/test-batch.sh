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
run_batch() { local ep="$1" out="$2"; shift 2; LOCAL_LLM_ENDPOINT_URL="$ep" node "$RUN" --job "$TMP/job.json" --out "$out" "$@" > "$TMP/run.out" 2>&1; RC=$?; }
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
if [ "$RC" -eq 0 ] && [ "$nreq" -ge 4 ] && [ "$maxlen" -le 2000 ] && [ "$nlines" -eq 60 ]; then ok "windows hold whole lines within the cap ($nreq windows, longest $maxlen chars, all 60 lines sent once)"
else bad "windowing: rc=$RC requests=$nreq longest=$maxlen lines sent=$nlines"; fi
if [ "$(count "$TMP/out-a/rows.jsonl")" -eq "$nreq" ] && jq -e -s 'all(.[]; .note == "true quote" and .file == "a.txt" and (.window | type == "number"))' "$TMP/out-a/rows.jsonl" >/dev/null; then ok "quote-in-line keeps the true quote and tags file and window"
else bad "true quotes: $(head -c 300 "$TMP/out-a/rows.jsonl")"; fi
if [ "$(count "$TMP/out-a/dropped.jsonl")" -eq "$nreq" ] && jq -e -s 'all(.[]; .note == "fabricated" and .reason == "quote_not_in_line")' "$TMP/out-a/dropped.jsonl" >/dev/null; then ok "quote-in-line drops the fabricated quote with a reason"
else bad "fabricated quotes: $(head -c 300 "$TMP/out-a/dropped.jsonl")"; fi
if jq -e -s 'all(.[]; .body.temperature == 0 and .body.response_format.json_schema.strict == true and .body.response_format.json_schema.schema.properties.rows.type == "array" and .body.max_tokens > 0)' <(jq -c 'select(.body)' "$LOG") >/dev/null; then ok "requests use temperature 0 and a strict json_schema"
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
const m = new Map([["L1", "L1\tuser\ttext\tno, use  the\t other ⏎ file"], ["L2", "L2\tuser\ttext\tother"]]);
console.log(JSON.stringify([
  checkQuote({ line: "L1", quote: "use the other ⏎ file" }, m),
  checkQuote({ line: "L1", quote: "use the files" }, m),
  checkQuote({ line: "L9", quote: "other" }, m),
  checkQuote({ line: "L2", quote: "no, use" }, m),
  checkQuote({ line: "L2", quote: "" }, m),
  checkQuote({ quote: "other" }, m)]));')
if [ "$cq" = '[null,"quote_not_in_line","line_not_in_window","quote_not_in_line","missing_line_or_quote","missing_line_or_quote"]' ]; then ok "checkQuote: whitespace-normalized match passes; wrong line, other line's text, empty and missing fields fail"
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
if [ "$RC" -eq 0 ] && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 2 ] && jq -e -s 'length == 1 and .[0].type == "malformed_reply"' "$TMP/out-bad/failures.jsonl" >/dev/null && [ "$(count "$TMP/out-bad/rows.jsonl")" -eq 0 ]; then ok "a malformed reply is retried once, then counted"
else bad "malformed: requests=$(jq -s '[.[] | select(.body)] | length' "$LOG") failures=$(head -c 300 "$TMP/out-bad/failures.jsonl")"; fi
start_fake once batch-bad-once
run_batch "$EP" "$TMP/out-once" "$TMP/m.txt"
if [ "$RC" -eq 0 ] && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 2 ] && [ "$(count "$TMP/out-once/failures.jsonl")" -eq 0 ] && [ "$(count "$TMP/out-once/rows.jsonl")" -eq 1 ]; then ok "a malformed first reply followed by a good one costs no failure"
else bad "retry recovery: failures=$(head -c 300 "$TMP/out-once/failures.jsonl")"; fi
start_fake len batch-length
run_batch "$EP" "$TMP/out-len" "$TMP/m.txt"
if [ "$RC" -eq 0 ] && [ "$(jq -s '[.[] | select(.body)] | length' "$LOG")" -eq 1 ] && jq -e -s 'length == 1 and .[0].type == "finish_length"' "$TMP/out-len/failures.jsonl" >/dev/null; then ok "finish_reason length is counted and not retried"
else bad "finish_length: $(head -c 300 "$TMP/out-len/failures.jsonl")"; fi

# --- endpoint down, non-loopback -------------------------------------------------
dead_port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
lines 40 100 "$TMP/d.txt"
job quote-in-line 1000       # 5 windows
run_batch "http://127.0.0.1:$dead_port" "$TMP/out-d" "$TMP/d.txt"
if [ "$RC" -eq 1 ] && jq -e -s 'length == 3 and all(.[]; .type == "endpoint_unreachable")' "$TMP/out-d/failures.jsonl" >/dev/null && grep -q 'ABORTED' "$TMP/out-d/index.md" && grep -q 'endpoint_unreachable 3' "$TMP/out-d/index.md"; then ok "endpoint down: the run aborts after 3 consecutive failures, counted in index.md"
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

echo "batch pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
