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
export HOME="$TMP/home"; mkdir -p "$HOME" # lane files must never reach the real ~/catalyst
unset CATALYST_TASK LOCAL_LLM_MODEL # the suite must not depend on the caller's env
LANES="$HOME/catalyst/band/lanes"
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

# Inline job, automatic output directory and raw line numbering (including blank/CRLF lines).
printf 'first raw evidence here\r\n\r\nthird raw evidence here\r\n' > "$TMP/raw.txt"
job quote-in-line 2000
before=$(shasum "$TMP/raw.txt")
LOCAL_LLM_ENDPOINT_URL="$EP" TMPDIR="$TMP" node "$RUN" --number --job-json "$(cat "$TMP/job.json")" "$TMP/raw.txt" > "$TMP/inline.stdout" 2> "$TMP/inline.stderr"; RC=$?
inline_index=$(tail -n 1 "$TMP/inline.stdout")
if [ "$RC" -eq 0 ] && [ -f "$inline_index" ] && [ "$(dirname "$inline_index")" != "$TMP" ] \
   && [ "$before" = "$(shasum "$TMP/raw.txt")" ] \
   && jq -e -s 'map(select(.body)) | last | .body.messages[-1].content | contains("L1\tfirst raw evidence here\nL3\tthird raw evidence here")' "$LOG" >/dev/null \
   && [ "$(count "$(dirname "$inline_index")/rows.jsonl")" -eq 1 ] \
   && grep -q 'inline job' "$inline_index"; then ok "inline job: fresh tmp output, last stdout index path, physical raw line numbers and quote checking without changing input"
else bad "inline job/numbering: rc=$RC index=$inline_index $(cat "$TMP/inline.stderr")"; fi
LOCAL_LLM_ENDPOINT_URL="$EP" TMPDIR="$TMP" node "$RUN" --number --job-json "$(cat "$TMP/job.json")" "$TMP/raw.txt" > "$TMP/inline2.stdout" 2>/dev/null; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$(tail -n 1 "$TMP/inline2.stdout")" ] && [ "$(tail -n 1 "$TMP/inline2.stdout")" != "$inline_index" ]; then ok "omitted --out creates a fresh directory per run"; else bad "fresh output directory"; fi
for args in both malformed reserved missing; do
  case "$args" in
    both) opts=(--job "$TMP/job.json" --job-json "$(cat "$TMP/job.json")") ;;
    malformed) opts=(--job-json '{') ;;
    reserved) opts=(--job-json "$(jq '.row_schema.properties.file={type:"string"}' "$TMP/job.json")") ;;
    missing) opts=(--job-json) ;;
  esac
  LOCAL_LLM_ENDPOINT_URL="$EP" TMPDIR="$TMP" node "$RUN" --out "$TMP/invalid" "$TMP/raw.txt" "${opts[@]}" > "$TMP/invalid.out" 2>&1; RC=$?
  if [ "$RC" -eq 2 ] && [ ! -f "$TMP/invalid/index.md" ]; then ok "inline validation rejects $args"; else bad "inline validation $args rc=$RC"; fi
done

# --- empty replies, all-dropped windows and optional minimum row count ----------
start_fake zs batch-empty-some
lines 24 100 "$TMP/zero.txt"      # one line per window; even windows return []
job quote-in-line 100
run_batch "$EP" "$TMP/out-zero" "$TMP/zero.txt"
if [ "$RC" -eq 0 ] && grep -q '^Completed: 24 of 24 windows answered; 12 returned no rows\.$' "$TMP/out-zero/index.md" \
   && grep -q '^Returned no rows: 12 (includes all rows dropped by check);' "$TMP/out-zero/index.md" \
   && [ "$(grep -oE '\(zero.txt, [0-9]+\)' "$TMP/out-zero/index.md" | tr '\n' '|')" = '(zero.txt, 2)|(zero.txt, 4)|(zero.txt, 6)|(zero.txt, 8)|(zero.txt, 10)|(zero.txt, 12)|(zero.txt, 14)|(zero.txt, 16)|(zero.txt, 18)|(zero.txt, 20)|' ]; then ok "empty replies: count in header and index, first ten file/window ids only"
else bad "empty replies: rc=$RC $(head -10 "$TMP/out-zero/index.md")"; fi
: > "$TMP/empty-zero.txt"
run_batch "$EP" "$TMP/out-zero-skipped" "$TMP/zero.txt" "$TMP/empty-zero.txt"
if grep -q '^Completed: 24 of 24 windows answered; 12 returned no rows; 1 input problem skipped\.$' "$TMP/out-zero-skipped/index.md"; then ok "empty replies preserve the input-problem suffix"
else bad "empty reply input suffix: $(sed -n 3p "$TMP/out-zero-skipped/index.md")"; fi
start_fake zd batch-all-dropped
run_batch "$EP" "$TMP/out-dropped" "$TMP/zero.txt"
if [ "$RC" -eq 0 ] && grep -q '^Completed: 24 of 24 windows answered; 24 returned no rows\.$' "$TMP/out-dropped/index.md" \
   && grep -q '^Returned no rows: 24 (includes all rows dropped by check); (zero.txt, 1), (zero.txt, 2),' "$TMP/out-dropped/index.md" \
   && [ "$(count "$TMP/out-dropped/rows.jsonl")" -eq 0 ] && [ "$(count "$TMP/out-dropped/dropped.jsonl")" -eq 24 ]; then ok "all rows dropped by check are included in the no-row count and ids"
else bad "all-dropped windows: rc=$RC $(head -10 "$TMP/out-dropped/index.md")"; fi
start_fake mn batch
job quote-in-line 2000
jq '.min_rows_per_window = 3' "$TMP/job.json" > "$TMP/job-min.json"
JOB="$TMP/job-min.json" run_batch "$EP" "$TMP/out-min" "$TMP/a.txt"
if [ "$RC" -eq 0 ] && jq -e -s 'length == 4 and all(.[]; .type == "under_min_rows" and .detail == "2 rows" and .file == "a.txt") and (map(.window) == [1,2,3,4])' "$TMP/out-min/failures.jsonl" >/dev/null \
   && grep -q '^Completed: 4 of 4 windows answered; 4 under minimum rows\.$' "$TMP/out-min/index.md" \
   && grep -q '^Failures: under_min_rows 4\.$' "$TMP/out-min/index.md" \
   && [ "$(count "$TMP/out-min/rows.jsonl")" -eq 4 ] && [ "$(count "$TMP/out-min/dropped.jsonl")" -eq 4 ]; then ok "minimum rows: short replies are counted failures and flagged in header, keeping their rows"
else bad "minimum rows: rc=$RC $(head -10 "$TMP/out-min/index.md") $(head -c 300 "$TMP/out-min/failures.jsonl")"; fi
jq '.min_rows_per_window = 2' "$TMP/job.json" > "$TMP/job-min.json"
JOB="$TMP/job-min.json" run_batch "$EP" "$TMP/out-min-boundary" "$TMP/a.txt"
if [ "$RC" -eq 0 ] && [ "$(count "$TMP/out-min-boundary/failures.jsonl")" -eq 0 ] \
   && [ "$(sed -n 3p "$TMP/out-min-boundary/index.md")" = 'Completed: 4 of 4 windows answered.' ]; then ok "minimum is inclusive and counts returned rows before the check; clean header stays byte-identical"
else bad "minimum boundary: rc=$RC $(head -10 "$TMP/out-min-boundary/index.md")"; fi
start_fake mz batch-empty-some
jq '.min_rows_per_window = 1' "$TMP/job.json" > "$TMP/job-min.json"
JOB="$TMP/job-min.json" run_batch "$EP" "$TMP/out-min-zero" "$TMP/a.txt"
if [ "$RC" -eq 0 ] && jq -e -s 'length == 2 and all(.[]; .type == "under_min_rows" and .detail == "0 rows") and (map(.window) == [2,4])' "$TMP/out-min-zero/failures.jsonl" >/dev/null \
   && grep -q '^Completed: 4 of 4 windows answered; 2 returned no rows; 2 under minimum rows\.$' "$TMP/out-min-zero/index.md" \
   && [ "$(count "$TMP/out-min-zero/rows.jsonl")" -eq 2 ]; then ok "empty replies below the minimum count once each as both no-row windows and failures"
else bad "empty replies below minimum: rc=$RC $(head -10 "$TMP/out-min-zero/index.md")"; fi

# the checker itself: whitespace-normalized fallback and a line that is not in the window
cq=$(node --input-type=module -e '
import { checkQuote } from "'"$REPO"'/batch/run.mjs";
const m = new Map([["L1", "L1\tuser\ttext\tno, use  the other ⏎ file here"], ["L2", "L2\tuser\ttext\thello"], ["L3", "L3\tplain numbered line text"]]);
const q = (line, quote) => checkQuote({ line, quote }, m);
console.log(JSON.stringify([
  q("L1", "use the other ⏎ file"), q("L1", "use the files here"), q("L9", "use the other ⏎ file"),
  q("L1", "user"), q("L1", "L1"), q("L1", "text no, use"), q("L1", "user\ttext\tno, use  the"),
  q("L2", "text hello"), q("L1", "x"), q("L2", "hello"), q("L3", "plain numbered"), q("L3", "L3"),
  q("L1", ""), checkQuote({ quote: "other" }, m), q("L1", "           x"), q("L1", "no,    use")]));')
if [ "$cq" = '[null,"quote_not_in_line","line_not_in_window","quote_too_short","quote_too_short","quote_not_in_line","quote_not_in_line","quote_too_short","quote_too_short",null,null,"quote_too_short","missing_line_or_quote","missing_line_or_quote","quote_too_short","quote_too_short"]' ]; then ok "checkQuote: matches the text field only (not role, kind or id), needs 12 chars unless it is the whole text"
else bad "checkQuote: $cq"; fi

raw_quote=$(node --input-type=module -e '
import { checkQuote } from "'"$REPO"'/batch/run.mjs";
const m = new Map([["L1", "L1\tuser\tpermission_denial\tthe raw content"]]);
console.log(checkQuote({line:"L1",quote:"user\tpermission_denial"}, m, true));')
if [ "$raw_quote" = null ]; then ok "raw numbering treats role-like prefixes as source evidence"; else bad "raw numbering stripped source fields: $raw_quote"; fi

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

# Integrated transcripts must produce exactly the same windows and rows as the manual CLI pipeline.
start_fake transcripts batch
job quote-in-line 2200
run_batch "$EP" "$TMP/out-flat" "$TMP/flat/s.txt"
flat_rc=$RC
request_texts "$LOG" > "$TMP/flat-requests"
: > "$LOG"
LOCAL_LLM_ENDPOINT_URL="$EP" node "$RUN" --job "$TMP/job.json" --out "$TMP/out-transcripts" --transcripts "$TMP/s.jsonl" > "$TMP/transcript.stdout" 2> "$TMP/transcript.stderr"; RC=$?
request_texts "$LOG" > "$TMP/transcript-requests"
if [ "$flat_rc" -eq 0 ] && [ "$RC" -eq 0 ] && [ -s "$TMP/out-flat/rows.jsonl" ] \
   && cmp -s "$TMP/flat-requests" "$TMP/transcript-requests" \
   && diff -u <(jq -c 'del(.file)' "$TMP/out-flat/rows.jsonl") <(jq -c 'del(.file)' "$TMP/out-transcripts/rows.jsonl") \
   && jq -e -s 'all(.[]; .file == "s.jsonl")' "$TMP/out-transcripts/rows.jsonl" >/dev/null; then ok "--transcripts matches flatten-then-run windows and rows, retaining the session filename"
else bad "integrated transcripts: rc=$flat_rc/$RC $(head -c 300 "$TMP/transcript.stderr")"; fi
if grep -q '^s.jsonl: 5 flattened lines, 1 unparseable skipped$' "$TMP/transcript.stderr" \
   && grep -q '^Transcript flattening: 5 lines, 1 unparseable skipped (blocks cut at 2000 chars).$' "$TMP/out-transcripts/index.md"; then ok "--transcripts reports flattened and unparseable skipped counts on stderr and in index.md"
else bad "transcript counts: $(head -12 "$TMP/out-transcripts/index.md")"; fi
run_batch "$EP" "$TMP/out-mode-conflict" --number --transcripts "$TMP/s.jsonl"
if [ "$RC" -eq 2 ] && grep -q 'mutually exclusive' "$TMP/run.out" && [ ! -e "$TMP/out-mode-conflict" ]; then ok "--number and --transcripts cannot be combined"
else bad "conflicting input modes: rc=$RC $(head -c 200 "$TMP/run.out")"; fi

# Exclusive output creation refuses an existing file or symlink instead of following it.
for name in index.md rows.jsonl dropped.jsonl failures.jsonl index.md.tmp; do
  dest="$TMP/exclusive-$name"
  mkdir -p "$dest"
  printf 'sentinel\n' > "$TMP/sentinel"
  ln -s "$TMP/sentinel" "$dest/$name"
  run_batch "$EP" "$dest" --transcripts "$TMP/s.jsonl"
  # The running index is replaced deliberately; all other output names must be exclusively created.
  if [ "$name" = index.md ]; then
    if [ "$RC" -eq 0 ] && [ ! -L "$dest/$name" ] && [ "$(cat "$TMP/sentinel")" = sentinel ]; then ok "output index replaces a stale symlink without following it"; else bad "stale index followed"; fi
  elif [ "$RC" -eq 2 ] && [ "$(cat "$TMP/sentinel")" = sentinel ]; then ok "exclusive output creation: $name refuses an existing symlink"
  else bad "exclusive output creation: $name rc=$RC sentinel=$(head -c 80 "$TMP/sentinel")"; fi
done

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
cp "$REPO/scripts/loopback.mjs" "$REPO/scripts/context-cap.mjs" "$TMP/sp ace #1/scripts/"; cp "$REPO/server/endpoint.mjs" "$REPO/server/errors.mjs" "$TMP/sp ace #1/server/"
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
   && grep -q 'across 5 of 5 files' "$TMP/out-mf/index.md" && grep -q '^Completed: 5 of 6 windows answered; 3 input problems skipped\.$' "$TMP/out-mf/index.md" \
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
validate zero-min-rows '.min_rows_per_window = 0'
validate negative-min-rows '.min_rows_per_window = -1'
validate fractional-min-rows '.min_rows_per_window = 1.5'
validate text-min-rows '.min_rows_per_window = "2"'
validate null-min-rows '.min_rows_per_window = null'
validate boolean-min-rows '.min_rows_per_window = true'
validate null-row-schema '.row_schema = null'
validate array-row-schema '.row_schema = []'
validate schema-declares-file '.row_schema.properties.file = {type:"string"}'
validate schema-declares-reason '.row_schema.properties.reason = {type:"string"}'
printf 'just a plain line\nanother plain line\n' > "$TMP/plain.txt"
run_batch "$EP" "$TMP/out-plain" "$TMP/plain.txt"
if [ "$RC" -eq 2 ] && grep -q 'not numbered input; use --number for raw text or --transcripts for sessions' "$TMP/run.out" && [ ! -e "$TMP/out-plain" ]; then ok "quote-in-line on unnumbered input exits 2 and explains the input modes"
else bad "unnumbered input: rc=$RC $(head -c 200 "$TMP/run.out")"; fi
{ head -2 "$TMP/m.txt"; echo 'an unnumbered line after numbered ones'; } > "$TMP/mixed.txt"
run_batch "$EP" "$TMP/out-mixed" "$TMP/mixed.txt"
if [ "$RC" -eq 2 ] && grep -q 'not numbered input' "$TMP/run.out" && [ ! -e "$TMP/out-mixed" ]; then ok "one unnumbered line after numbered ones is refused too"
else bad "mixed numbering: rc=$RC $(head -c 200 "$TMP/run.out")"; fi

# --- a killed run leaves a stub that says RUNNING ----------------------------------------------
start_fake st batch-stall
LOCAL_LLM_ENDPOINT_URL="$EP" node "$RUN" --job "$TMP/job.json" --out "$TMP/out-st" "$TMP/m.txt" > /dev/null 2>&1 &
st_pid=$!
for _ in $(seq 1 100); do grep -q '"body"' "$LOG" && break; sleep 0.1; done
cat "$TMP/out-st/index.md" > "$TMP/st-while.md"
kill "$st_pid" 2>/dev/null; wait "$st_pid" 2>/dev/null
if grep -qE "^RUNNING since [0-9]{4}-.* \(pid $st_pid\) — not complete$" "$TMP/out-st/index.md" && grep -q RUNNING "$TMP/st-while.md"; then ok "index.md says RUNNING while the run is in flight and after it is killed"
else bad "RUNNING stub: $(head -c 200 "$TMP/out-st/index.md")"; fi

# --- an abort after some windows were answered ------------------------------------------------
start_fake tf batch-then-fail
run_batch "$EP" "$TMP/out-tf" "$TMP/w.txt" "$TMP/w6.txt"
if [ "$RC" -eq 1 ] && grep -q '^\*\*ABORTED\*\* after 3 consecutive failed requests (last failure: http_error HTTP 500 server_error): 1 of 4 windows answered\.$' "$TMP/out-tf/index.md" && grep -q 'across 1 of 2 files' "$TMP/out-tf/index.md"; then ok "abort after one answered window: ABORTED header with 1 of 4 answered, exit 1, one of two files reached"
else bad "abort header: rc=$RC $(sed -n 3,4p "$TMP/out-tf/index.md")"; fi

# --- the header owns up to input problems; a refused re-run leaves no stale index ------------------
if grep -q '^Completed: 5 of 6 windows answered; 3 input problems skipped\.$' "$TMP/out-mf/index.md"; then ok "header counts unreadable, empty and over-cap inputs next to the answered windows"
else bad "input-problem header: $(sed -n 3p "$TMP/out-mf/index.md")"; fi
printf 'Completed: 9 of 9 windows answered.\n' > "$TMP/out-a/index.md"
HTTP_PROXY=http://127.0.0.1:9 run_batch "$EP" "$TMP/out-a" "$TMP/m.txt"
rc1=$RC; stale1=$(grep -c Completed "$TMP/out-a/index.md" 2>/dev/null)
printf 'Completed: 9 of 9 windows answered.\n' > "$TMP/out-a/index.md"
JOB="$TMP/job-unknown-check.json" run_batch "$EP" "$TMP/out-a" "$TMP/m.txt"
if [ "$rc1" -eq 2 ] && [ "$RC" -eq 2 ] && [ "${stale1:-0}" -eq 0 ] && ! grep -q Completed "$TMP/out-a/index.md" 2>/dev/null; then ok "a refused re-run (proxy, bad job) removes the previous index.md"
else bad "stale index after refusal: rc=$rc1/$RC"; fi

# --- the run shows as a lane in Catalyst's band while it runs ------------------------------------
lane_wait() { for _ in $(seq 1 100); do ls "$LANES"/local-*.json >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
start_stalled() { # [env...]: starts a stalled run in the background; sets st_pid, waits for its first request
  : > "$LOG"
  env LOCAL_LLM_ENDPOINT_URL="$EP" "$@" node "$RUN" --job "${JOB:-$TMP/job.json}" --out "$TMP/out-ln$RANDOM" "$TMP/m.txt" > /dev/null 2>&1 &
  st_pid=$!
  for _ in $(seq 1 100); do grep -q '"body"' "$LOG" && break; sleep 0.1; done
}
rm -rf "$HOME/catalyst"; mkdir -p "$HOME/catalyst" # Catalyst is installed: the dir exists
job quote-in-line 2000
start_fake ls batch-stall
start_stalled CATALYST_TASK=x46 LOCAL_LLM_MODEL=acme/qwen3-7b@q4_k_m.gguf
lane_wait; lf="$LANES/local-$st_pid.json"
if jq -e --argjson p "$st_pid" '.v == 1 and .kind == "local" and .pid == $p and .task == "x46" and .label == "qwen3-7b" and (.started | test("^[0-9]{4}-.*Z$")) and (.repo == null or (.repo | startswith("/")))' "$lf" >/dev/null 2>&1; then ok "a running batch writes local-<pid>.json (v 1, kind local, own pid, task, shortened LOCAL_LLM_MODEL label)"
else bad "lane file: $(head -c 300 "$lf" 2>&1)"; fi
[ -e "$lf" ]; was_int=$? # present mid-run, or "gone" proves nothing
kill -INT "$st_pid" 2>/dev/null; wait "$st_pid" 2>/dev/null; rc_int=$?
if [ "$was_int" -eq 0 ] && [ "$rc_int" -eq 130 ] && [ ! -e "$lf" ]; then ok "SIGINT removes the lane file and exits 130"
else bad "SIGINT: rc=$rc_int file=$([ -e "$lf" ] && echo present || echo gone)"; fi
start_stalled LOCAL_LLM_MODEL=m
lane_wait; lf="$LANES/local-$st_pid.json"
[ -e "$lf" ]; was_term=$?
task_null=$(jq -r '.task == null' "$lf" 2>/dev/null)
kill -TERM "$st_pid" 2>/dev/null; wait "$st_pid" 2>/dev/null; rc_term=$?
if [ "$task_null" = true ] && [ "$was_term" -eq 0 ] && [ "$rc_term" -eq 143 ] && [ ! -e "$lf" ]; then ok "SIGTERM removes the lane file and exits 143; task is null without CATALYST_TASK"
else bad "SIGTERM: rc=$rc_term file=$([ -e "$lf" ] && echo present || echo gone)"; fi
start_fake ln batch
# The probe registers its exit hook before the runner does, so it sees the file just before remove() runs.
cat > "$TMP/probe.mjs" <<'PROBE'
import { readdirSync } from 'node:fs';
import { homedir } from 'node:os';
process.on('exit', () => { try { console.error(`PROBE ${readdirSync(`${homedir()}/catalyst/band/lanes`).join(',')}`); } catch { console.error('PROBE none'); } });
PROBE
LOCAL_LLM_ENDPOINT_URL="$EP" node --import "$TMP/probe.mjs" "$RUN" --job "$TMP/job.json" --out "$TMP/out-ln1" "$TMP/a.txt" > "$TMP/run.out" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -qE '^PROBE local-[0-9]+\.json$' "$TMP/run.out" && ! ls "$LANES"/local-*.json >/dev/null 2>&1; then ok "a normal end removes the lane file that was present until exit"
else bad "normal end: rc=$RC $(grep PROBE "$TMP/run.out") $(ls "$LANES" 2>&1)"; fi
rm -rf "$HOME/catalyst"; mkdir -p "$HOME/catalyst"
HTTP_PROXY=http://127.0.0.1:9 run_batch "$EP" "$TMP/out-ln2" "$TMP/a.txt"; rc_p=$RC
LOCAL_LLM_ENDPOINT_URL=http://example.com:1234 node "$RUN" --job "$TMP/job.json" --out "$TMP/out-ln3" "$TMP/a.txt" > /dev/null 2>&1; rc_nl=$?
JOB="$TMP/job-unknown-check.json" run_batch "$EP" "$TMP/out-ln4" "$TMP/a.txt"
if [ "$rc_p" -eq 2 ] && [ "$rc_nl" -eq 2 ] && [ "$RC" -eq 2 ] && [ ! -e "$LANES" ]; then ok "refused runs (proxy, non-loopback endpoint, bad job) write no lane file"
else bad "refused runs: rc=$rc_p/$rc_nl/$RC $(ls "$HOME" 2>&1)"; fi
rm -rf "$HOME/catalyst"; run_batch "$EP" "$TMP/out-ln5" "$TMP/a.txt"; rc_a=$RC
if [ "$rc_a" -eq 0 ] && [ ! -e "$HOME/catalyst" ]; then ok "without Catalyst installed (no \$HOME/catalyst), a run leaves no trace"
else bad "no-catalyst trace: rc=$rc_a $(ls "$HOME" 2>&1)"; fi
# run_split <outdir>: like run_batch, but stdout and stderr apart; prints a normalized stdout + output-file digest
run_split() {
  LOCAL_LLM_ENDPOINT_URL="$EP" node "$RUN" --job "$TMP/job.json" --out "$1" "$TMP/a.txt" > "$TMP/split.so" 2> "$TMP/split.se"; RC=$?
  { sed -E "s#$1#OUT#g; s#Started [0-9TZ:.-]+#Started T#; s#wall time [0-9]+ s#wall time N s#" "$TMP/split.so"; cat "$1"/rows.jsonl "$1"/dropped.jsonl "$1"/failures.jsonl; sed -E "s#Started [0-9TZ:.-]+#Started T#; s#wall time [0-9]+ s#wall time N s#" "$1/index.md"; } > "$2"
}
run_split "$TMP/out-ln5b" "$TMP/run-a.norm"; rc_a=$RC
cp "$TMP/split.se" "$TMP/split-a.se"
mkdir -p "$HOME/catalyst"; : > "$HOME/catalyst/band" # a regular file where the lane dir would go: mkdir fails
run_split "$TMP/out-ln6" "$TMP/run-b.norm"; rc_b=$RC
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] && cmp -s "$TMP/run-a.norm" "$TMP/run-b.norm" \
   && [ "$(grep -c '^local-llm:' "$TMP/split.se")" -eq 1 ] && grep -qE "^local-llm: could not write a lane file in .*/catalyst/band/lanes \([A-Z]+\); running without a band lane$" "$TMP/split.se" \
   && ! grep -q '^local-llm:' "$TMP/split-a.se" && cmp -s "$TMP/split-a.se" <(grep -v '^local-llm:' "$TMP/split.se"); then ok "a failed lane write prints exactly one local-llm: stderr line; exit status, stdout and output files match a run without it"
else bad "fail-open: rc=$rc_a/$rc_b stderr=$(head -c 300 "$TMP/split.se") $(diff "$TMP/run-a.norm" "$TMP/run-b.norm" | head -5)"; fi
rm -rf "$HOME/catalyst"; : > "$HOME/catalyst" # Catalyst's dir is a regular file: not installed, silent
run_split "$TMP/out-ln7" "$TMP/run-c.norm"; rc_c=$RC
if [ "$rc_c" -eq 0 ] && cmp -s "$TMP/run-a.norm" "$TMP/run-c.norm" && cmp -s "$TMP/split-a.se" "$TMP/split.se"; then ok "with \$HOME/catalyst a regular file there is no lane and nothing changes (silent)"
else bad "catalyst-as-file: rc=$rc_c $(head -c 200 "$TMP/split.se")"; fi
rm -rf "$HOME/catalyst"

# --- shortLabel ----------------------------------------------------------------------------------
labels=$(node --input-type=module -e '
import { shortLabel } from "'"$REPO"'/batch/lane.mjs";
console.log(JSON.stringify([shortLabel("qwen3-7b"), shortLabel("a\u0007b\nc"), shortLabel(""), shortLabel("x".repeat(40)).length, shortLabel("acme/m@q4.gguf")]));')
if [ "$labels" = '["qwen3-7b","abc","local",24,"m"]' ]; then ok "shortLabel: plain name kept, control characters stripped, empty becomes local, 24-character cap, prefix/quant/.gguf stripped"
else bad "shortLabel: $labels"; fi

# --- a failed rename leaves no temp file, and remove() is then a no-op ----------------------------
mkdir -p "$HOME/catalyst"
tmpleft=$(node --input-type=module -e '
import { registerLane } from "'"$REPO"'/batch/lane.mjs";
import { mkdirSync, writeFileSync, readdirSync, existsSync } from "node:fs";
const dir = `${process.env.HOME}/catalyst/band/lanes`;
mkdirSync(`${dir}/local-${process.pid}.json`, { recursive: true }); // a non-empty directory: rename onto it fails
writeFileSync(`${dir}/local-${process.pid}.json/keep`, "x");
const rm = registerLane({ label: "m" }); rm(); rm();
console.log(readdirSync(dir).filter((f) => f.endsWith(".tmp")).length, existsSync(`${dir}/local-${process.pid}.json/keep`));' 2>/dev/null)
if [ "$tmpleft" = "0 true" ]; then ok "a failed rename leaves no .tmp file and remove() deletes nothing"
else bad "temp cleanup: $tmpleft"; fi
rm -rf "$HOME/catalyst"

# --- the runner still dies by the signal, not by an exit code --------------------------------------
mkdir -p "$HOME/catalyst"; start_fake sg batch-stall
sigs=$(EP="$EP" RUN="$RUN" JOBF="$TMP/job.json" INPUT="$TMP/m.txt" node --input-type=module -e '
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
const lanes = `${process.env.HOME}/catalyst/band/lanes`;
const out = [];
for (const [n, sig, twice] of [[0, "SIGINT"], [1, "SIGTERM"], [2, "SIGTERM", true]]) {
  const c = spawn(process.execPath, [process.env.RUN, "--job", process.env.JOBF, "--out", `${process.env.HOME}/o-${n}`, process.env.INPUT], { env: { ...process.env, LOCAL_LLM_ENDPOINT_URL: process.env.EP }, stdio: "ignore" });
  const done = new Promise((r) => c.on("exit", (code, signal) => r(signal ?? `code${code}`)));
  for (let i = 0; i < 100 && !existsSync(`${lanes}/local-${c.pid}.json`); i++) await new Promise((r) => setTimeout(r, 100));
  c.kill(sig); if (twice) c.kill(sig); out.push(await done); if (twice) out.push(existsSync(`${lanes}/local-${c.pid}.json`) ? "leaked" : "clean");
}
console.log(out.join(" "));')
if [ "$sigs" = "SIGINT SIGTERM SIGTERM clean" ]; then ok "SIGINT and SIGTERM end the runner by the signal itself (WIFSIGNALED), not an exit code; the same signal twice back to back still leaves no lane file"
else bad "death by signal: $sigs"; fi
rm -rf "$HOME/catalyst"

# --- the git lookup can never hold the run up: a git that ignores SIGTERM is killed ---------------
mkdir -p "$TMP/gitstub" "$HOME/catalyst"
printf '#!/bin/sh\ntrap "" TERM\nexec sleep 30\n' > "$TMP/gitstub/git"; chmod +x "$TMP/gitstub/git"
t0=$(date +%s)
repo_out=$(PATH="$TMP/gitstub:$PATH" node --input-type=module -e '
import { registerLane } from "'"$REPO"'/batch/lane.mjs";
import { readFileSync } from "node:fs";
const rm = registerLane({ label: "m" });
const f = `${process.env.HOME}/catalyst/band/lanes/local-${process.pid}.json`;
console.log(JSON.stringify(JSON.parse(readFileSync(f, "utf8")).repo)); rm();')
t1=$(date +%s)
if [ "$repo_out" = "null" ] && [ $((t1 - t0)) -le 4 ]; then ok "a git that ignores SIGTERM is killed at the timeout: registration returns in $((t1 - t0)) s with repo null"
else bad "git stub: repo=$repo_out took $((t1 - t0)) s"; fi
rm -rf "$HOME/catalyst"

# --- the label comes from the models query when the job sets no window and LOCAL_LLM_MODEL is unset ---
job quote-in-line 2000; jq 'del(.max_window_chars)' "$TMP/job.json" > "$TMP/job-nocap.json"
mkdir -p "$HOME/catalyst"
start_fake lm batch-stall-model
JOB="$TMP/job-nocap.json" start_stalled
lane_wait; lf="$LANES/local-$st_pid.json"
if jq -e '.label == "qwen3-7b"' "$lf" >/dev/null 2>&1; then ok "with no max_window_chars and no LOCAL_LLM_MODEL, the label is the single loaded model's short id"
else bad "models-query label: $(head -c 300 "$lf" 2>&1)"; fi
kill -TERM "$st_pid" 2>/dev/null; wait "$st_pid" 2>/dev/null
# A planted symlink at the lane's tmp name must not be followed: the victim stays intact, and the write fails open.
rm -rf "$HOME/catalyst"; mkdir -p "$LANES"; printf 'victim\n' > "$TMP/victim"
LOCAL_LLM_ENDPOINT_URL="$EP" bash -c 'ln -s "$1" "$2/local-$$.json.tmp"; exec node "$3" --job "$4" --out "$5" "$6"' _ "$TMP/victim" "$LANES" "$RUN" "$TMP/job.json" "$TMP/out-ln8" "$TMP/a.txt" > /dev/null 2> "$TMP/lnk.se"; rc_k=$?
if [ "$(cat "$TMP/victim")" = victim ] && grep -q '^local-llm: could not write a lane file' "$TMP/lnk.se"; then ok "a symlink planted at the lane tmp name is not followed (victim intact, run fails open)"
else bad "lane symlink: rc=$rc_k victim=$(cat "$TMP/victim") $(head -c 200 "$TMP/lnk.se")"; fi
rm -rf "$HOME/catalyst"

echo "batch pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
