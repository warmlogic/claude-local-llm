#!/usr/bin/env bash
# Offline self-test of the measurement harness: footer.jq, trace.jq, mechanical.jq, judge.sh (with a fake judge)
# and report.sh, on the synthetic traces in measure/fixtures/. No session, no quota, no LM Studio.
# Every assertion is one `check` call; tests/test-fence.sh checks the printed total against the count of them.
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
FX="$MDIR/fixtures"
FT="mcp__plugin_local-llm_local-llm__code_task_files"
total=0; fails=0
check() { # check <label> <expected> <actual>
  total=$((total+1))
  if [ "$2" = "$3" ]; then echo "  measure selftest PASS: $1"; else echo "  measure selftest FAIL: $1 (want $2, got $3)"; fails=$((fails+1)); fi
}
TMP=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
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

# --- trace.jq ----------------------------------------------------------------------------------------------
facts() { # facts <fixture> <cfg> <kind> <rc>
  sed "s|@PATH@|$DOC|g" "$FX/$1.jsonl" | jq -cR 'fromjson? // empty' \
    | jq -sc -L "$MDIR" --arg path "$([ "$3" = job ] && echo "$DOC")" --arg cfg "$2" --arg kind "$3" --argjson rc "$4" --arg ft "$FT" -f "$MDIR/trace.jq"
}
check "trace: control status, T and context" '["ok",17006,17002,true]' "$(facts ctl-off off ctl 0 | jq -c '[.status, .T, .ctx_max, .usage_match]')"
check "trace: baseline that read the file" '["ok",43304,26002,2]' "$(facts off-ok off job 0 | jq -c '[.status, .T, .ctx_max, .turns]')"
check "trace: baseline with no content read" '"base-no-read"' "$(facts off-noread off job 0 | jq -c .status)"
check "trace: delegated run with a good call" '["ok",36404,18502,1,6.4,false]' \
  "$(facts on-ok on job 0 | jq -c '[.status, .T, .ctx_max, .calls, .footer.total_s, .also_read]')"
check "trace: delegated run without the tool call is FAILED no-call" '["no-call",true]' "$(facts on-nocall on job 0 | jq -c '[.status, .also_read]')"
check "trace: every call errored" '"call-error"' "$(facts on-callerror on job 0 | jq -c .status)"
check "trace: tool missing from init" '"no-server"' "$(facts on-noserver on job 0 | jq -c .status)"
check "trace: cut-off trace without a result" '["unknown",null]' "$(facts cut on job 0 | jq -c '[.status, .T]')"
check "trace: exit 124 is a timeout" '"timeout"' "$(facts on-ok on job 124 | jq -c .status)"
check "trace: the plugin tool in a plugin-off run" '"plugin-leak"' "$(facts on-ok off job 0 | jq -c .status)"

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

# --- judge.sh with a fake judge, then report.sh -------------------------------------------------------------
R="$TMP/run"; mkdir -p "$R/facts" "$R/judge"
sha=$(shasum -a 256 "$DOC" | cut -c1-64)
printf 'f01\tmain\tdoc\tsummary\t24000\t2026-01-05T00:00:00\t%s\t%s\nf02\tmain\tlog\tclassification\t41000\t2026-01-04T00:00:00\t%s\t%s\nf11\ts2k\tdoc\tsummary\t2000\t2026-01-03T00:00:00\t%s\t%s\n' \
  "$sha" "$DOC" "$sha" "$DOC" "$sha" "$DOC" > "$R/corpus.tsv"
put() { # put <name> <fixture> <cfg> <kind> <id> <rep>
  facts "$2" "$3" "$4" 0 | jq -c --arg run "$1" --arg cfg "$3" --arg kind "$4" --arg id "$5" --argjson rep "$6" \
    '. + {run: $run, cfg: $cfg, kind: $kind, id: $id, rep: $rep}' > "$R/facts/$1.json"
}
for r in 1 2 3; do put "ctl-off-$r" ctl-off off ctl "" "$r"; put "ctl-on-$r" ctl-on on ctl "" "$r"; done
put f01-off-1 off-ok off job f01 1; put f01-on-1 on-ok on job f01 1
put f02-off-1 off-ok off job f02 1; put f02-on-1 on-nocall on job f02 1
jq -c '.answer = "{\"kind\": \"report-or-analysis\", \"topic\": \"rollout\", \"evidence\": \"Ended 2026-01-05\"}"' "$R/facts/f02-off-1.json" > "$R/x" && mv "$R/x" "$R/facts/f02-off-1.json"
for r in 1 2 3; do put "f11-off-$r" off-ok off job f11 "$r"; put "f11-on-$r" on-ok on job f11 "$r"; done
jq -n '{date_start: "2026-01-06T00:00:00", date_end: "2026-01-06T01:00:00", cutoff: "2026-01-05", repo_sha: "abc1234", repo_dirty: false,
  claude_version: "0.0.0 (fake)", server_pin: "@houtini/lm@3.3.4", lms_version: "unknown", model: "", ctl_reps: 3, run_dir: "RUN", partial: false, configs: "off on"}' > "$R/meta.json"
cat > "$TMP/fake-claude" <<'EOF'
#!/usr/bin/env bash
# Fake judge: logs each call, refuses a prompt that still names the local model, and answers by task.
p=$(cat); echo call >> "$FAKE_LOG"
if grep -qi 'local model' <<<"$p"; then echo '{}'; exit 0; fi
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
MEASURE_CLAUDE="$TMP/fake-claude" MEASURE_JUDGE_JOBS=2 bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: one call per ok answer that passed the mechanical checks (FAILED f02-on skipped)" '5' "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
check "judge: verdicts stored, blinded prompt accepted" 'f01-off f01-on f02-off f11-off f11-on' \
  "$(cd "$R/judge" && ls ./*.verdict.json | sed 's|^\./||; s|\.verdict\.json$||' | tr '\n' ' ' | sed 's/ $//')"
MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: stored verdicts are not re-judged" '5' "$(wc -l < "$FAKE_LOG" | tr -d ' ')"

bash "$MDIR/report.sh" "$R" "$TMP/results.md" >/dev/null 2>&1
RES="$TMP/results.md"
check "report: main row with job T, savings and growth" '1' \
  "$(grep -c '^| f01 | doc | summary | 20–30k | 26298 | 18698 | 28.9% | .* | 9000 | 800 | 2 | 2 | ok | ok | 3 | 6.4 |  | yes | yes |' "$RES")"
check "report: a delegated run without the call stays in, FAILED and not usable" '1' \
  "$(grep -c '^| f02 | log | classification | 40–50k | 26298 | 20398 | .* | FAILED: no-call | .* | no (judge bool differs) | no |' "$RES")"
check "report: headline over both main files, gate FAIL" '1' "$(grep -c '^| Claude tokens per job (Σ T over 2 main files) | 52596 | 39096 (savings 25.7%) | ≥ 80% fewer | FAIL |' "$RES")"
check "report: usable counts" '1' "$(grep -c '^| Usable answers | 1 of 2 | 1 of 2 | ≥ 2 of 2 | FAIL |' "$RES")"
check "report: fixed cost and break-even" '2' "$(grep -cE '^- Fixed cost per session: 700 tokens|^- Break-even: 1 job\(s\) per session' "$RES")"
check "report: small file in the threshold table" '1' "$(grep -c '^| f11 | ~2k | 26298 | 18698 | 28.9% | 3/3 | 3/3 |' "$RES")"
check "report: no path, file text or answer text in the results" '0' "$(grep -cE "$TMP|ZEBRA-MARKER|build failed|pin the compiler" "$RES")"
check "report: the review sheet lists the failure with its path" '1,1' \
  "$(grep -c '^## f02-on (not usable)$' "$R/review.md"),$(grep -cF "Path: \`$DOC\`" "$R/review.md" | awk '{print ($1 > 0) ? 1 : 0}')"
printf 'f01-on\tdisagree\tmissed the open question\nf02-off\tagree\t\n' > "$R/review-verdicts.tsv"
bash "$MDIR/report.sh" "$R" "$TMP/results.md" >/dev/null 2>&1
check "report: an operator disagreement flips usable and is counted" '2' \
  "$(grep -cE '^\| f01 \| .* \| yes \| no \(op\) \|  \|$|^- Operator review: agreed on 1 of 2\.$' "$RES")"

echo "measure selftest total: $total, failed: $fails"
[ "$fails" -eq 0 ]
