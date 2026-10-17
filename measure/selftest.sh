#!/usr/bin/env bash
# Offline self-test of the measurement harness: footer.jq, trace.jq, mechanical.jq, the lib.sh rules run.sh relies
# on, select-corpus.sh on a fake $HOME, judge.sh with a fake judge, and report.sh on synthetic runs. No session, no
# quota, no LM Studio. Every assertion is one `check` call; tests/test-fence.sh checks the printed total against the
# count of them.
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
FX="$MDIR/fixtures"
total=0; fails=0
check() { # check <label> <expected> <actual>
  total=$((total+1))
  if [ "$2" = "$3" ]; then echo "  measure selftest PASS: $1"; else echo "  measure selftest FAIL: $1 (want $2, got $3)"; fails=$((fails+1)); fi
}
TMP=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# judge.sh wraps each call in timeout; a pass-through shim keeps this test free of coreutils
mkdir -p "$TMP/bin" && printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$TMP/bin/timeout" && chmod +x "$TMP/bin/timeout"
export PATH="$TMP/bin:$PATH"
# shellcheck source=lib.sh
. "$MDIR/lib.sh"
cp "$FX/doc.md" "$TMP/doc.md"
DOC="$TMP/doc.md"

# --- footer.jq ---------------------------------------------------------------------------------------------
foot() { printf '%s' "$1" | jq -Rsc -L "$MDIR" "include \"footer\"; houtini_footer | $2"; }
F1=$'- a\n\n---\nModel: qwen-x | 9954→480 tokens (12 reasoning / 468 visible) | 300 prompt tokens cached | TTFT: 3190ms, 150.0 tok/s, 6.4s | unknown · 1 file(s) read\n📊 First measured call'
check "footer: model, tokens, timing, files" '["qwen-x",9954,480,3190,150.0,6.4,1,1,[]]' \
  "$(foot "$F1" '[.model, .prompt_tokens, .completion_tokens, .ttft_ms, .tok_s, .total_s, .files_read, .files_total, .flags]')"
check "footer: partial read and quality flags" '[1,2,["TRUNCATED","hit-max-tokens"]]' \
  "$(foot $'x\n\n---\nModel: m | 5→6 tokens | TTFT: 9ms, 2.0s | unknown · 1/2 file(s) read | Quality: TRUNCATED, hit-max-tokens' '[.files_read, .files_total, .flags]')"
check "footer: no tok/s still yields the total" '[null,2.0]' "$(foot $'x\n\n---\nModel: m | 5→6 tokens | TTFT: 9ms, 2.0s | unknown · 1 file(s) read' '[.tok_s, .total_s]')"
check "footer: a markdown rule alone is no footer" 'null' "$(foot $'intro\n\n---\nmore text' '.')"
check "footer: an error text is no footer" 'null' "$(foot 'Error: fetch failed' '.')"

# --- trace.jq, through lib.sh's trace_facts ----------------------------------------------------------------------
facts() { # facts <fixture> <cfg> <kind> <rc>
  sed "s|@PATH@|$DOC|g" "$FX/$1.jsonl" > "$TMP/trace.jsonl"
  trace_facts "$TMP/tf" "$TMP/trace.jsonl" "$1" "$2" "$3" fx 1 "$([ "$3" = job ] && echo "$DOC")" "$4" 7
}
check "trace: control status, T and context" '["ok",17006,17002,true]' "$(facts ctl-off off ctl 0 | jq -c '[.status, .T, .ctx_max, .usage_match]')"
check "trace: baseline that read the file" '["ok",43304,26002,2]' "$(facts off-ok off job 0 | jq -c '[.status, .T, .ctx_max, .turns]')"
check "trace: baseline with no content read" '"base-no-read"' "$(facts off-noread off job 0 | jq -c .status)"
check "trace: delegated run with a good call" '["ok",36404,18502,1,6.4,false,7]' \
  "$(facts on-ok on job 0 | jq -c '[.status, .T, .ctx_max, .calls, .footer.total_s, .also_read, .wall_s]')"
check "trace: delegated run without the tool call is FAILED no-call" '["no-call",true]' "$(facts on-nocall on job 0 | jq -c '[.status, .also_read]')"
check "trace: every call errored" '"call-error"' "$(facts on-callerror on job 0 | jq -c .status)"
check "trace: a partial read (1/2 file(s) read) is call-error" '"call-error"' "$(facts on-partial on job 0 | jq -c .status)"
check "trace: a quality flag is call-error, and the failed call keeps its 75 s timing" '["call-error",75.0,["hit-max-tokens"]]' \
  "$(facts on-flag on job 0 | jq -c '[.status, .call_footers[0].total_s, .call_footers[0].flags]')"
check "trace: tool missing from init" '"no-server"' "$(facts on-noserver on job 0 | jq -c .status)"
check "trace: cut-off trace without a result" '["unknown",null]' "$(facts cut on job 0 | jq -c '[.status, .T]')"
check "trace: exit 124 is a timeout" '"timeout"' "$(facts on-ok on job 124 | jq -c .status)"
check "trace: the plugin tool in a plugin-off run" '"plugin-leak"' "$(facts on-ok off job 0 | jq -c .status)"
check "trace: a failing stage is facts-error naming it" '["facts-error","trace.jq"]' \
  "$(facts on-ok on job not-a-number | jq -c '[.status, .stage]')"

# --- mechanical.jq -----------------------------------------------------------------------------------------
mech() { printf '%s' "$2" | jq -Rsc -L "$MDIR" --arg task "$1" --rawfile file "$DOC" --argjson labels "$(jq -c .labels "$MDIR/tasks.json")" \
  -f "$MDIR/mechanical.jq" | jq -c '[.ok, .reason]'; }
check "mech: summary passes" '[true,null]' "$(mech summary '- a point')"
check "mech: empty answer" '[false,"empty answer"]' "$(mech summary '  ')"
check "mech: fenced classification with a trailing note, whitespace-collapsed evidence" '[true,null]' \
  "$(mech classification $'```json\n{"kind": "other", "topic": "t", "evidence": "The build failed at step 3."}\n```\n\n_Classified by the local model._')"
check "mech: kind outside the label set" '[false,"kind not in the label set"]' "$(mech classification '{"kind":"memo","topic":"t","evidence":"pin the compiler"}')"
check "mech: evidence not in the file" '[false,"evidence not verbatim"]' "$(mech classification '{"kind":"other","topic":"t","evidence":"pin the linker"}')"
check "mech: extraction passes" '[true,null]' \
  "$(mech extraction '{"subject":"s","first_date":"2026-01-02","last_date":"2026-01-05","key_items":[{"quote":"We decided to pin the compiler.","why":"w"}]}')"
check "mech: invented date" '[false,"first_date not verbatim"]' \
  "$(mech extraction '{"subject":"s","first_date":"2026-01-03","last_date":null,"key_items":[{"quote":"pin the compiler","why":"w"}]}')"
check "mech: invented quote" '[false,"key_items[1].quote not verbatim"]' \
  "$(mech extraction '{"subject":"s","first_date":null,"last_date":null,"key_items":[{"quote":"pin the compiler","why":"w"},{"quote":"no such line","why":"w"}]}')"
check "mech: extra field" '[false,"fields are not exactly subject, first_date, last_date, key_items"]' \
  "$(mech extraction '{"subject":"s","first_date":null,"last_date":null,"key_items":[],"x":1}')"
check "mech: not JSON" '[false,"not a JSON object"]' "$(mech extraction 'here is the summary')"

# --- lib.sh rules that run.sh relies on ----------------------------------------------------------------------
L="$TMP/lib"; mkdir -p "$L/files"
rp() { echo "$1" > "$L/meta.json"; case "$(results_path "$L" /repo)" in /repo/docs/results.md) echo docs ;; "$L/results.md") echo run ;; *) echo other ;; esac; }
check "results_path: a full run writes docs/results.md" 'docs' "$(rp '{"partial":false,"allow_short":false}')"
check "results_path: a partial run stays in the run dir" 'run' "$(rp '{"partial":true,"allow_short":false}')"
check "results_path: a short-corpus run stays in the run dir" 'run' "$(rp '{"partial":false,"allow_short":true}')"
cp "$DOC" "$TMP/live.md"
printf 'f01\tmain\tdoc\tsummary\t300\tT\t%s\t%s\n' "$(sha256_of "$TMP/live.md")" "$TMP/live.md" > "$L/corpus.tsv"
snapshot_ok "$L" f01; rc=$?
check "snapshot_ok: first job keeps a verified copy" '0,1' "$rc,$(cmp -s "$L/files/f01" "$TMP/live.md" && echo 1 || echo 0)"
echo "edited" >> "$TMP/live.md"
snapshot_ok "$L" f01; rc=$?
live_unchanged "$L" f01; rc2=$?
check "snapshot_ok and live_unchanged: a changed live file fails the job (job() writes corpus-changed)" '1,1,0' \
  "$([ $rc -ne 0 ] && echo 1 || echo 0),$([ $rc2 -ne 0 ] && echo 1 || echo 0),$(grep -c edited "$L/files/f01")"
cp "$MDIR/../skills/delegate-local/SKILL.md" "$TMP/SKILL.md"; lower_floor "$TMP/SKILL.md"; rc=$?
check "lower_floor: the current skill gets a 1k floor in its description and body, no 10k left" '0,1,1,0' \
  "$rc,$(grep -cE '^description:.*about 1k to 60k' "$TMP/SKILL.md"),$(grep -vE '^description:' "$TMP/SKILL.md" | grep -cE '(^|[^0-9])1k.*60k'),$(grep -c '10k' "$TMP/SKILL.md")"
printf -- '---\ndescription: big files (over 10k characters)\n---\nDelegate anything over 10k.\n' > "$TMP/SKILL2.md"; cp "$TMP/SKILL2.md" "$TMP/SKILL2.orig"
lower_floor "$TMP/SKILL2.md"; rc=$?
check "lower_floor: a reworded skill fails loudly and stays untouched" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(cmp -s "$TMP/SKILL2.md" "$TMP/SKILL2.orig" && echo 1 || echo 0)"
printf 'f01\tmain\nf02\tmain\nf11\ts2k\n' > "$TMP/short.tsv"
check "corpus_shortfall names what a full run lacks" '2 of 10 main files, no s5k file, no s10k file' "$(corpus_shortfall "$TMP/short.tsv")"

# --- select-corpus.sh on a fake $HOME: the privacy boundary ----------------------------------------------------
H="$TMP/home"
mk() { # mk <path> <chars> <touch-stamp> [char]: unique text of exactly <chars> characters
  mkdir -p "$(dirname "$1")"
  awk -v n="$2" -v seed="$1" -v ch="${4:-}" 'BEGIN{ if (ch != "") { for (i = 0; i < n; i++) printf "%s", ch; exit }
    s = "seed " seed "\n"; while (length(s) < n) { i++; s = s sprintf("line %d of the text about %s\n", i, seed) }
    printf "%s", substr(s, 1, n) }' > "$1"
  touch -t "$3" "$1"
}
mk "$H/github/l1/logs/run.txt" 25000 202601010000
mk "$H/github/l2/build.log" 26000 202601020000
mk "$H/github/t1/meeting-notes.md" 27000 202601030000
mk "$H/github/t2/standup.txt" 28000 202601040000
mk "$H/github/t3/interview.vtt" 29000 202601050000
for i in 1 2 3 4 5 6; do mk "$H/github/d$i/notes.md" $((30000 + i)) "2026010${i}1200"; done
mk "$H/github/s2/a.md" 2000 202512010000
mk "$H/github/s5/a.md" 5000 202512010000
mk "$H/github/s10/acc.md" 10000 202512010000 'é'          # 10000 chars, 20000 bytes: s10k by characters
mk "$H/github/x8/euro.md" 12000 202602010000 '€'          # 36000 bytes but 12000 chars: in no window
# exclusions, all newer than every kept file, so any leak would be picked first
mk "$H/github/x1/secrets.md" 31000 202602010000
mk "$H/github/x2/api_key_notes.md" 31000 202602010000
mk "$H/github/x3/doc.md" 31000 202602010000; printf '\nkey AKIAABCDEFGHIJKLMNOP\n' >> "$H/github/x3/doc.md"; touch -t 202602010000 "$H/github/x3/doc.md"
mk "$H/github/x4/.env.md" 31000 202602010000
mk "$H/github/warmlogic/claude-local-llm/docs/self.md" 31000 202602010000
mk "$H/catalyst/projects/local-llm/plan.md" 31000 202602010000
mk "$H/github/.hidden/h.md" 31000 202602010000
mk "$H/github/x5/.git/x.md" 31000 202602010000
mk "$TMP/outside/real.md" 31000 202602010000; mkdir -p "$H/github/x6"; ln -s "$TMP/outside/real.md" "$H/github/x6/link.md"
mk "$H/github/x7/future.md" 31000 203001010000
cutoff=$(date -j -f %Y%m%d%H%M 202701010000 +%s)
HOME="$H" bash "$MDIR/select-corpus.sh" "$cutoff" > "$TMP/manifest.tsv" 2> "$TMP/select.err"; rc=$?
M="$TMP/manifest.tsv"
check "select: exits 0 with 13 rows" '0,13' "$rc,$(wc -l < "$M" | tr -d ' ')"
check "select: no secret name, secret body, own repo, planning dir, dot-dir, symlink or post-cutoff file" '0' \
  "$(grep -cE 'secrets\.md|api_key|/x3/|\.env|claude-local-llm|projects/local-llm|\.hidden|\.git/|link\.md|future\.md|euro\.md' "$M")"
check "select: types and tasks of the main files (2 logs, 3 transcripts, 5 docs after the fill)" 'doc:classification=4 doc:extraction=1 log:extraction=2 transcript:summary=3' \
  "$(awk -F'\t' '$2 == "main" {print $3 ":" $4}' "$M" | sort | uniq -c | awk '{printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1}')"
check "select: newest-first ids, the fill takes the newest leftover doc and the rebalance moves the oldest doc" 'd6 d2 d1-absent' \
  "$(awk -F'\t' '$1 == "f01" {sub(".*/github/", "", $8); sub("/.*", "", $8); a = $8} $3 == "doc" && $4 == "extraction" {sub(".*/github/", "", $8); sub("/.*", "", $8); b = $8} END {print a, b}' "$M") $(grep -q '/d1/' "$M" && echo d1-present || echo d1-absent)"
check "select: small slots by characters (the é file is s10k)" 's2k:2000:s2 s5k:5000:s5 s10k:10000:s10' \
  "$(awk -F'\t' '$2 != "main" {sub(".*/github/", "", $8); sub("/.*", "", $8); printf "%s%s:%s:%s", (n++ ? " " : ""), $2, $5, $8}' "$M")"
check "select: warnings never name a file" '0' "$(grep -c "$H/github/" "$TMP/select.err")"
mkdir -p "$TMP/home2/github/a"; mk "$TMP/home2/github/a/n.md" 25000 202601010000
HOME="$TMP/home2" bash "$MDIR/select-corpus.sh" "$cutoff" > /dev/null 2> "$TMP/select2.err"; rc=$?
check "select: a missing root is a warning, not silence" '0,1' "$rc,$(grep -c 'catalyst does not exist' "$TMP/select2.err")"

# --- judge.sh with a fake judge --------------------------------------------------------------------------------
R="$TMP/run"; mkdir -p "$R/facts" "$R/judge" "$R/files"
sha=$(sha256_of "$DOC")
printf 'f01\tmain\tdoc\tsummary\t24000\tT\t%s\t%s\nf02\tmain\tlog\tclassification\t41000\tT\t%s\t%s\nf03\tmain\tdoc\tclassification\t26000\tT\t%s\t%s\n' \
  "$sha" "$DOC" "$sha" "$DOC" "$sha" "$DOC" > "$R/corpus.tsv"
for id in f01 f02 f03; do cp "$DOC" "$R/files/$id"; done
put() { facts "$2" "$3" job 0 | jq -c --arg run "$1" --arg id "$4" '. + {run: $run, id: $id}' > "$R/facts/$1.json"; }
put f01-off-1 off-ok off f01; put f01-on-1 on-ok on f01
put f02-off-1 off-ok off f02; put f02-on-1 on-nocall on f02
put f03-off-1 off-ok off f03; put f03-on-1 on-ok on f03
jq -c '.answer = "{\"kind\": \"report-or-analysis\", \"topic\": \"rollout\", \"evidence\": \"Ended 2026-01-05\"}"' "$R/facts/f02-off-1.json" > "$R/x" && mv "$R/x" "$R/facts/f02-off-1.json"
jq -c '.answer = "{\"kind\": \"other\", \"topic\": \"t\", \"evidence\": \"not in the file\"}"' "$R/facts/f03-off-1.json" > "$R/x" && mv "$R/x" "$R/facts/f03-off-1.json"
cat > "$TMP/fake-claude" <<'EOF'
#!/usr/bin/env bash
# Fake judge: logs each call, refuses a prompt that still carries the attribution note, and answers by task.
p=$(cat); echo call >> "$FAKE_LOG"
[ -z "${FAKE_FAIL:-}" ] || exit 1
if [ -n "${FAKE_BAD:-}" ]; then echo '{"structured_output":{"reference":[],"invented":"none","missed":[],"usable":true,"reason":"r"}}'; exit 0; fi
if grep -qi 'by the local model' <<<"$p"; then echo '{}'; exit 0; fi
if grep -q '^Classify ' <<<"$p"; then
  echo '{"structured_output":{"reference":["report-or-analysis"],"invented":[],"missed":["kind"],"usable":true,"reason":"r"},"modelUsage":{"fake-judge":{}}}'
else
  echo '{"structured_output":{"reference":["build failed"],"invented":[],"missed":[],"usable":true,"reason":"r"},"modelUsage":{"fake-judge":{}}}'
fi
EOF
chmod +x "$TMP/fake-claude"
export FAKE_LOG="$TMP/calls.log"; : > "$FAKE_LOG"
MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" --mech-only >/dev/null 2>&1
check "judge --mech-only starts no session" '0' "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
FAKE_FAIL=1 MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" > /dev/null 2> "$TMP/judge.err"; rc=$?
check "judge: a failed call fails the pass, names its rc, and stores no verdict" '1,1,0' \
  "$([ "$rc" -ne 0 ] && echo 1 || echo 0),$(grep -c 'claude rc=1' "$TMP/judge.err" | awk '{print ($1 > 0)}'),$(ls "$R"/judge/*.verdict.json 2>/dev/null | wc -l | tr -d ' ')"
FAKE_BAD=1 MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1; rc=$?
check "judge: a verdict whose invented is not an array is rejected" '1,0' "$([ "$rc" -ne 0 ] && echo 1 || echo 0),$(ls "$R"/judge/*.verdict.json 2>/dev/null | wc -l | tr -d ' ')"
: > "$FAKE_LOG"
MEASURE_CLAUDE="$TMP/fake-claude" MEASURE_JUDGE_JOBS=2 bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: one call per ok answer that passed the mechanical checks (FAILED f02-on and both mechanical failures of f03 skipped)" \
  'f01-off f01-on f02-off' "$(cd "$R/judge" && ls ./*.verdict.json | sed 's|^\./||; s|\.verdict\.json$||' | tr '\n' ' ' | sed 's/ $//')"
check "judge: the mechanical failure is recorded" '"evidence not verbatim"' "$(jq -c .reason "$R/judge/f03-off.mech.json")"
MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: stored verdicts are not re-judged" '3' "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
note=$(sed -n "s/^ATTRIBUTION_NOTE='\(.*\)'$/\1/p" "$MDIR/judge.sh")
check "judge: blinding drops the attribution note and keeps claims about the local model" 'drop,keep,0' \
  "$(printf '%s\n' '_Summarized by the local model._' 'The local model requires 128 GB RAM.' | jq -R --arg n "$note" 'if test($n; "i") then "drop" else "keep" end' | jq -rs 'join(",")'),$(grep -c 'by the local model' "$R/judge/f01-on.prompt")"
echo "an edit after the freeze" >> "$DOC"; mv "$R/files/f02" "$TMP/f02.away"
bash "$MDIR/judge.sh" "$R" --mech-only >/dev/null 2>&1
check "judge: grading reads the run's copy, not the live file, and a job without one is never graded" '[true,"corpus-changed"]' \
  "$(jq -sc '[.[0].ok, .[1].reason]' "$R/judge/f01-off.mech.json" "$R/judge/f02-off.mech.json")"
cp "$FX/doc.md" "$DOC"

# --- report.sh on synthetic runs: the completeness rule ------------------------------------------------------------
# base: a full corpus (10 main summaries + 3 small), every run counted, off jobs 30000 and on jobs 3000 tokens
B="$TMP/base"; mkdir -p "$B/facts" "$B/judge"
mkf() { # mkf <dir> <name> <cfg> <kind> <id> <rep> <T|null> [status] [extra-json]
  jq -nc --arg run "$2" --arg cfg "$3" --arg kind "$4" --arg id "$5" --argjson rep "$6" --argjson T "$7" --arg st "${8:-ok}" --argjson x "${9:-{\}}" \
    '{run: $run, cfg: $cfg, kind: $kind, id: $id, rep: $rep, status: $st, T: $T, input: 2, cache_creation: 0,
      cache_read: (if $T == null then null else $T - 6 end), output: 4, usd: (if $T == null then null else $T / 1000000 end),
      turns: 2, duration_ms: 5000, wall_s: 5, ctx_max: (if $T == null then null else $T - 2 end), models: ["claude-fixture"],
      footer: null, call_footers: [], answer: "- the build failed", denials: [], usage_match: true} + $x' > "$1/facts/$2.json"
}
ONF='{"footer":{"model":"local-fixture","ttft_ms":2000,"total_s":5.0,"files_read":1,"files_total":1,"flags":[]},"call_footers":[{"model":"local-fixture","ttft_ms":2000,"total_s":5.0,"flags":[]}],"duration_ms":9000}'
: > "$B/corpus.tsv"
for i in 01 02 03 04 05 06 07 08 09 10; do printf 'f%s\tmain\tdoc\tsummary\t%s\tT\tsha\t/private/f%s.md\n' "$i" "$((25000 + 10#$i * 1000))" "$i" >> "$B/corpus.tsv"; done
printf 'f11\ts2k\tdoc\tsummary\t2000\tT\tsha\t/private/f11.md\nf12\ts5k\tdoc\tsummary\t5000\tT\tsha\t/private/f12.md\nf13\ts10k\tdoc\tsummary\t10000\tT\tsha\t/private/f13.md\n' >> "$B/corpus.tsv"
for r in 1 2 3; do mkf "$B" "ctl-off-$r" off ctl "" "$r" 17000; mkf "$B" "ctl-on-$r" on ctl "" "$r" 17700; done
for i in 01 02 03 04 05 06 07 08 09 10; do mkf "$B" "f$i-off-1" off job "f$i" 1 47000; mkf "$B" "f$i-on-1" on job "f$i" 1 20700 ok "$ONF"; done
for id in f11 f12 f13; do for r in 1 2 3; do mkf "$B" "$id-off-$r" off job "$id" "$r" 27000; mkf "$B" "$id-on-$r" on job "$id" "$r" 19700 ok "$ONF"; done; done
for f in "$B"/facts/f*-1.json; do a=$(basename "$f" -1.json)
  echo '{"ok":true,"reason":null,"extra_text":false}' > "$B/judge/$a.mech.json"
  echo '{"reference":["x"],"invented":[],"missed":[],"usable":true,"reason":"r","judge_models":["fake-judge"]}' > "$B/judge/$a.verdict.json"
done
jq -n '{date_start: "2026-01-06T00:00:00", date_end: "2026-01-06T01:00:00", cutoff: "2026-01-05", repo_sha: "abc1234", repo_dirty: false,
  claude_version: "0.0.0 (fake)", server_pin: "@houtini/lm@3.3.4", lms_version: "unknown", model: "", local_model: "local-fixture",
  ctl_reps: 3, small_reps: 3, run_dir: "RUN", partial: false, allow_short: false, configs: "off on"}' > "$B/meta.json"
variant() { rm -rf "$TMP/v"; cp -R "$B" "$TMP/v"; }   # a fresh copy of the base run in $TMP/v
render() { bash "$MDIR/report.sh" "$TMP/v" "$TMP/v/results.md" > /dev/null 2> "$TMP/v/report.err"; }
cell() { grep -E "$1" "$TMP/v/results.md" | head -n 1; }

variant; render
check "report PASS: tokens gate passes on a complete run" '| Claude tokens per job (Σ T over 10 main files) | 300000 | 30000 (savings 90%) | ≥ 80% fewer | PASS |' "$(cell '^\| Claude tokens')"
check "report PASS: usable gate passes" '| Usable answers | 10 of 10 | 10 of 10 | ≥ 8 of 10 | PASS |' "$(cell '^\| Usable answers')"
check "report PASS: fixed cost and break-even" '- Fixed cost per session: 700 tokens ($0.0007).,- Break-even: 1 job(s) per session.' "$(cell '^- Fixed'),$(cell '^- Break-even')"
check "report: main row carries job T, local timing, e2e for both configs and usable" \
  '| f01 | doc | summary | 20–30k | 30000 | 3000 | 90% | 90% | 30000 | 3000 | 2 | 2 | ok | ok | 2 | 5 | 5 | 9 |  | yes | yes |  |' "$(cell '^\| f01 \| doc')"
check "report: no path or answer text in the results" '0' "$(grep -cE '/private/f|build failed' "$TMP/v/results.md")"

variant; rm "$TMP/v/facts/f03-on-1.json"; render
check "report FAIL-incomplete: a missing main run makes both gates incomplete" '2' \
  "$(grep -cE '^\| (Claude tokens|Usable answers) .*\| FAIL \(incomplete: .*f03 on' "$TMP/v/results.md")"
check "report FAIL-incomplete: totals and break-even say incomplete, not a number" '| Claude tokens per job (Σ T over 10 main files) | incomplete | incomplete |,- Break-even: incomplete.' \
  "$(cell '^\| Claude tokens' | cut -d'|' -f1-4)|,$(cell '^- Break-even')"

variant; rm "$TMP/v/facts/f11-on-2.json"; mkf "$TMP/v" f12-on-2 on job f12 2 null timeout; mkf "$TMP/v" f12-on-3 on job f12 3 null timeout; render
check "report: a missing small rep and two timeouts leave those rows incomplete, never a median of what is left" '2' \
  "$(grep -cE '^\| f1[12] \| ~[25]k \| 10000 \| incomplete \([12]/3\) \| n/a \|' "$TMP/v/results.md")"
check "report: small-file gaps do not touch the main gate; a timeout is SLOW" 'PASS,1' \
  "$(cell '^\| Claude tokens' | awk -F'|' '{gsub(/ /, "", $6); print $6}'),$(grep -cE '^\| f12 .*\| SLOW \|' "$TMP/v/results.md")"

variant; for i in 01 02 03 04 05 06 07 08 09 10; do mkf "$TMP/v" "f$i-on-1" on job "f$i" 1 50000 ok "$ONF"; done; render
check "report: break-even is never when delegation costs more" '- Break-even: never (delegation costs more per job).' "$(cell '^- Break-even')"

variant; awk -F'\t' '$1 == "f01"' "$B/corpus.tsv" > "$TMP/v/corpus.tsv"; jq '.allow_short = true' "$B/meta.json" > "$TMP/v/meta.json"; render
check "report: a 1-main-file corpus can never pass" '2' "$(grep -cE '^\| (Claude tokens|Usable answers) .*\| FAIL \(incomplete: 1 of 10 main files; no s2k file; no s5k file; no s10k file\) \|$' "$TMP/v/results.md")"
check "report: a short corpus labels break-even incomplete too" '1' "$(grep -c '^- Break-even: 1 job(s) per session (incomplete: 1 of 10 main files' "$TMP/v/results.md")"

variant; mkf "$TMP/v" f04-on-1 on job f04 1 20700 no-call; mkf "$TMP/v" f05-off-1 off job f05 1 47000
printf 'f04-on\tdisagree\tlooks fine\r\n\nf05-off\tdisagree\tmissed a point\r\nf06-on\tagree\t\n' > "$TMP/v/review-verdicts.tsv"; render
check "report: an operator disagreement flips a judged answer, but a FAILED job stays not usable" 'no (op),no' \
  "$(cell '^\| f05 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $21); print $21}'),$(cell '^\| f04 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}')"
check "report: operator lines with CRLF and blank lines parse; agreement counted" '- Operator review: agreed on 1 of 3.' "$(cell '^- Operator review')"
printf 'f01-on\tagree\nf01-on\tmaybe\n' > "$TMP/v/review-verdicts.tsv"; render; rc=$?
check "report: a malformed operator line fails with its line number" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'line 2' "$TMP/v/report.err")"
printf 'f99-on\tagree\n' > "$TMP/v/review-verdicts.tsv"; render; rc=$?
check "report: an operator line naming an unknown answer fails" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'f99-on is not an answer' "$TMP/v/report.err")"

variant; mkf "$TMP/v" f02-on-1 on job f02 1 20700 ok '{"call_footers":[{"model":"some-other-model","ttft_ms":1,"total_s":1,"flags":[]}]}'; render; rc=$?
check "report: a footer naming another model fails the report" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'some-other-model' "$TMP/v/report.err")"

variant; jq '.date_end = null' "$B/meta.json" > "$TMP/v/meta.json"
mkf "$TMP/v" f03-on-1 on job f03 1 20700 call-error '{"call_footers":[{"model":"local-fixture","ttft_ms":3000,"total_s":75.0,"flags":["hit-max-tokens"]}],"duration_ms":81000}'
mkf "$TMP/v" f04-on-1 on job f04 1 20700 no-call '{"duration_ms":12000}'; render
check "report: an unrecorded end date renders as such" '1' "$(grep -c 'to (not recorded);' "$TMP/v/results.md")"
check "report: a 75 s call that hit max tokens keeps its timing and is SLOW" '1' "$(grep -cE '^\| f03 .*\| FAILED: call-error \| 3 \| 75 \| 5 \| 81 \| SLOW \|' "$TMP/v/results.md")"
check "report: with no footer, local time falls back to the session's" '1' "$(grep -cE '^\| f04 .*\| FAILED: no-call \| n/a \| 12 \(session\) \| 5 \| 12 \|  \|' "$TMP/v/results.md")"

echo "measure selftest total: $total, failed: $fails"
[ "$fails" -eq 0 ]
