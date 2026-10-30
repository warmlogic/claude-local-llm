#!/usr/bin/env bash
# Offline self-test of the measurement harness: footer.jq, trace.jq, mechanical.jq, the lib.sh rules run.sh relies
# on, select-corpus.sh on a fake $HOME, judge.sh with a fake judge, and report.sh on synthetic runs. No session, no
# quota, no LM Studio. Every assertion is one `check` call; tests/test-fence.sh checks the printed total against the
# count of them.
set -uo pipefail
unset MEASURE_CONFIGS MEASURE_ENDPOINT   # the run.sh checks below set their own

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
FX="$MDIR/fixtures"
total=0; fails=0
check() { # check <label> <expected> <actual>
  total=$((total+1))
  if [ "$2" = "$3" ]; then echo "  measure selftest PASS: $1"; else echo "  measure selftest FAIL: $1 (want $2, got $3)"; fails=$((fails+1)); fi
}
TMP=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
trap 'kill $(cat "$TMP/ctx.pids" 2>/dev/null) 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT   # stops the fake endpoints; undoes the chmod 000 fixtures first
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
check "trace: empty usage is facts-error with T null, never T = 0" '["facts-error","usage",null]' "$(facts usage-empty off ctl 0 | jq -c '[.status, .stage, .T]')"
check "trace: a modelUsage entry missing a counter is facts-error, not a zero" '["facts-error",null]' "$(facts usage-missing off ctl 0 | jq -c '[.status, .T]')"
check "trace: a non-numeric usage counter is facts-error" '["facts-error",null]' "$(facts usage-string off ctl 0 | jq -c '[.status, .T]')"
check "trace: a bad line before the last is facts-error at stage parse" '["facts-error","parse",1]' "$(facts midparse on job 0 | jq -c '[.status, .stage, .parse_errors]')"
check "trace: is_error wins over a missing result, and subtype is kept" '["is-error","error_during_execution"]' "$(facts is-error off ctl 0 | jq -c '[.status, .subtype]')"
check "trace: a plugin-off control that lists the tool is plugin-leak" '"plugin-leak"' "$(facts ctl-on off ctl 0 | jq -c .status)"
check "trace: a plugin-on control without the tool is no-server" '"no-server"' "$(facts ctl-off on ctl 0 | jq -c .status)"
check "trace: a baseline Grep in content mode that matched is a read" '"ok"' "$(facts off-grep off job 0 | jq -c .status)"
check "trace: a Read whose result is an error is not a read" '"base-no-read"' "$(facts off-readerr off job 0 | jq -c .status)"
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
check "results_path: a full run stays in the run dir by default" 'run' "$(rp '{"partial":false,"allow_short":false}')"
check "results_path: a full run with MEASURE_PUBLISH=1 writes docs/results.md" 'docs' "$(MEASURE_PUBLISH=1 rp '{"partial":false,"allow_short":false}')"
check "results_path: MEASURE_PUBLISH=1 never publishes a partial run" 'run' "$(MEASURE_PUBLISH=1 rp '{"partial":true,"allow_short":false}')"
check "results_path: MEASURE_PUBLISH=1 never publishes a short-corpus run" 'run' "$(MEASURE_PUBLISH=1 rp '{"partial":false,"allow_short":true}')"
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
LF="$TMP/lf"; mkdir -p "$LF/skills/delegate-local" "$LF/scripts"
cp "$MDIR/../skills/delegate-local/SKILL.md" "$LF/skills/delegate-local/"; cp "$MDIR/../scripts/context-cap.mjs" "$LF/scripts/"
lower_floor "$LF"; rc=$?
check "lower_floor: the current skill and size hint get a 1k floor, no 30k left in the skill" '0,1,1,0,1' \
  "$rc,$(grep -cE '^description:.*about 1k characters up to' "$LF/skills/delegate-local/SKILL.md"),$(grep -vE '^description:' "$LF/skills/delegate-local/SKILL.md" | grep -cE '(^|[^0-9])1k.*cap'),$(grep -c '30k' "$LF/skills/delegate-local/SKILL.md"),$(grep -c '^export const MIN_DELEGATE_CHARS = 1_000;' "$LF/scripts/context-cap.mjs")"
LF2="$TMP/lf2"; mkdir -p "$LF2/skills/delegate-local" "$LF2/scripts"
printf -- '---\ndescription: big files (over 30k characters)\n---\nDelegate anything over 30k.\n' > "$LF2/skills/delegate-local/SKILL.md"
cp "$MDIR/../scripts/context-cap.mjs" "$LF2/scripts/"; cp -R "$LF2" "$TMP/lf2.orig"
lower_floor "$LF2"; rc=$?
check "lower_floor: a reworded skill fails loudly and both files stay untouched" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(diff -r "$LF2" "$TMP/lf2.orig" >/dev/null && echo 1 || echo 0)"
copy_plugin "$MDIR/.." "$TMP/snap1"; rc=$?
mkdir -p "$TMP/repo2" && cp -R "$MDIR/../.claude-plugin" "$MDIR/../.mcp.json" "$MDIR/../package.json" "$MDIR/../scripts" "$MDIR/../skills" "$MDIR/../hooks" "$TMP/repo2/" \
  && mkdir -p "$TMP/repo2/server" && echo x > "$TMP/repo2/server/index.mjs"   # a checkout that ships a server
copy_plugin "$TMP/repo2" "$TMP/snap2"; rc2=$?
check "copy_plugin: copies server/ only when the checkout has one" "0,$([ -e "$MDIR/../server" ] && echo 1 || echo 0),1,0,1" \
  "$rc,$([ -e "$TMP/snap1/server" ] && echo 1 || echo 0),$([ -s "$TMP/snap1/skills/delegate-local/SKILL.md" ] && echo 1 || echo 0),$rc2,$([ -s "$TMP/snap2/server/index.mjs" ] && echo 1 || echo 0)"
mkdir -p "$TMP/pin/.claude-plugin"
pin_plugin_config "$MDIR/.." "$TMP/pin" some-model; rc=$?
# The expected roots come from evaluating select-corpus.sh's own ROOTS line with HOME set to the literal text $HOME.
want_roots=$(HOME='$HOME' bash -c "$(grep '^ROOTS=' "$MDIR/select-corpus.sh"); printf '%s\n' \"\${ROOTS[@]}\"" | jq -R . | jq -sc .)
check "pin_plugin_config: the snapshot pins the model and allows the roots select-corpus.sh scans" "0,some-model,$want_roots" \
  "$rc,$(jq -r '.userConfig.model.default' "$TMP/pin/.claude-plugin/plugin.json"),$(jq -c '.userConfig.allowed_dirs.default' "$TMP/pin/.claude-plugin/plugin.json")"
mkdir -p "$TMP/noroots"; echo 'echo no roots here' > "$TMP/noroots/select-corpus.sh"
pin_plugin_config "$MDIR/.." "$TMP/pin" some-model http://127.0.0.1:4321
check "pin_plugin_config: a MEASURE_ENDPOINT override reaches the snapshot's endpoint_url, so sessions use the server whose context was recorded" \
  'http://127.0.0.1:4321' "$(jq -r '.userConfig.endpoint_url.default' "$TMP/pin/.claude-plugin/plugin.json")"
pin_plugin_config "$MDIR/.." "$TMP/pin" some-model
check "pin_plugin_config: without an endpoint the snapshot keeps the manifest's default" 'http://127.0.0.1:1234' \
  "$(jq -r '.userConfig.endpoint_url.default' "$TMP/pin/.claude-plugin/plugin.json")"
( MDIR="$TMP/noroots"; pin_plugin_config "$MDIR/.." "$TMP/pin" other-model ) 2>/dev/null; rc_nr=$?
check "pin_plugin_config: a select-corpus.sh without a ROOTS line fails and leaves the snapshot's manifest alone" '1,some-model' \
  "$rc_nr,$(jq -r '.userConfig.model.default' "$TMP/pin/.claude-plugin/plugin.json")"
mkdir -p "$TMP/fh/t"
check "work_dir: refuses a TMPDIR under \$HOME and creates nothing there" '1,0' \
  "$( (HOME="$TMP/fh" TMPDIR="$TMP/fh/t" work_dir >/dev/null) && echo 0 || echo 1),$(ls -A "$TMP/fh/t" | wc -l | tr -d ' ')"
check "work_dir: refuses to recreate a resumed cwd under \$HOME" '1' "$( (HOME="$TMP/fh" work_dir "$TMP/fh/t/x" >/dev/null) && echo 0 || echo 1)"
printf 'f02\tmain\tdoc\tsummary\t300\tT\t%s\t%s\n' "$(sha256_of "$DOC")" "$TMP/locked.md" > "$L/corpus.tsv"; cp "$DOC" "$TMP/locked.md"; chmod 000 "$TMP/locked.md"
snapshot_ok "$L" f02; rc=$?; chmod 644 "$TMP/locked.md"
check "snapshot_ok: an unreadable file is a copy failure (snapshot-failed), not corpus-changed" '2' "$rc"
check "task_field: a missing field fails instead of printing null" '1' "$(task_field nosuch prompt >/dev/null 2>&1 && echo 0 || echo 1)"
printf 'f01\tmain\nf02\tmain\nf11\ts2k\n' > "$TMP/short.tsv"
check "corpus_shortfall names what a full run lacks" '2 of 10 main files, no s5k file, no s10k file' "$(corpus_shortfall "$TMP/short.tsv")"

# --- select-corpus.sh on a fake $HOME: the privacy boundary ----------------------------------------------------
H="$TMP/home"
mk() { # mk <path> <chars> <touch-stamp> [char]: unique text of exactly <chars> characters
  mkdir -p "$(dirname "$1")"
  awk -v n="$2" -v seed="$(printf '%s' "${1#"$TMP"}" | tr '/._-' '    ')" -v ch="${4:-}" 'BEGIN{ if (ch != "") { for (i = 0; i < n; i++) printf "%s", ch; exit }
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
# every credential form, in otherwise eligible files newer than all kept ones; values stay short so only the
# credential patterns, not the entropy guard, can catch them
i=0
for form in 'Authorization: Bearer abcdefgh12345678' 'authorization: Basic dXNlcjpwYXNz' '{"headers": {"Authorization": "Bearer abc.def.ghi"}}' \
            "curl -H 'Authorization: Bearer xyz12345678' https://example.test" 'Bearer abcdefgh12345678 was sent' '"token": "abc123def"' \
            'Cookie: session=abc' 'client_secret=abc' 'PASSWORD = hunter2' 'password    = hunter2' '"api_key"   :   "abc"' '**Password:** hunter2' 'config["password"] = "hunter2"' "settings['api-key']: abc" \
            'see https://alice:s3cret@db.example.test/x' 'postgres://app:pw@localhost/db' 'curl --user alice:s3cret https://x.test' \
            'curl -u alice:s3cret https://x.test' 'mysqldump --password hunter2 db' 'mysql -uroot -phunter2 db'; do
  i=$((i+1)); mk "$H/github/auth$i/notes.md" 31000 202602010000; printf '\n%s\n' "$form" >> "$H/github/auth$i/notes.md"; touch -t 202602010000 "$H/github/auth$i/notes.md"
done
mk "$H/github/ent/notes.md" 31000 202602010000; printf '\nx Zm9vYmFyQmF6UXV4MTIzNDU2Nzg5MHF3ZXJ0eXVpb3BAc2Rm x\n' >> "$H/github/ent/notes.md"; touch -t 202602010000 "$H/github/ent/notes.md"
printf '\nchecksum %s\n' "$(printf a | shasum -a 256 | cut -c1-64)" >> "$H/github/d6/notes.md"; touch -t 202601061200 "$H/github/d6/notes.md"
printf '\nsee https://example.test/a@b and run psql -h db -U app\n' >> "$H/github/d5/notes.md"; touch -t 202601051200 "$H/github/d5/notes.md"
mk "$H/github/locked/inner/n.md" 31000 202602010000; chmod 000 "$H/github/locked"
mk "$H/github/unread/n.md" 31000 202602010000; chmod 000 "$H/github/unread/n.md"
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
check "select: every Authorization, token, cookie, password, URL-userinfo and credential-argument form, and a high-entropy token, are excluded" '0' \
  "$(grep -cE '/auth[0-9]+/|/ent/' "$M")"
check "select: a 64-hex checksum alone does not trip the entropy guard" '1' "$(grep -c '/d6/notes.md' "$M")"
check "select: a plain URL and a psql call without a password stay in" '1' "$(grep -c '/d5/notes.md' "$M")"
check "select: an unreadable folder and an unreadable file are counted in warnings that never name a file" '1,1,0' \
  "$(grep -c 'find could not read' "$TMP/select.err"),$(grep -c '1 file(s) could not be read' "$TMP/select.err"),$(grep -c "$H/github/" "$TMP/select.err")"
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
[ "${1:-}" != --version ] || { echo "0.0.0 (fake)"; exit 0; }
p=$(cat); echo call >> "$FAKE_LOG"
[ -z "${FAKE_FAIL:-}" ] || exit 1
if [ -n "${FAKE_BAD:-}" ]; then echo '{"structured_output":{"reference":[],"invented":"none","missed":[],"usable":true,"reason":"r"}}'; exit 0; fi
if grep -qi 'by the local model' <<<"$p"; then echo '{}'; exit 0; fi
if grep -q '^Classify ' <<<"$p"; then
  echo '{"structured_output":{"reference":["report-or-analysis"],"invented":[],"missed":["kind"],"usable":true,"reason":"r"},"modelUsage":{"fake-judge":{}}}'
else
  echo '{"structured_output":{"reference":["build failed"],"invented":[],"missed":[],"usable":true,"reason":"r"},"modelUsage":{"fake-judge":{}}}'
fi
exit "${FAKE_RC:-0}"
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
FAKE_RC=3 MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" >/dev/null 2> "$TMP/judge.err"; rc=$?
check "judge: valid output followed by a nonzero exit is rejected, not stored" '1,1,0' \
  "$([ "$rc" -ne 0 ] && echo 1 || echo 0),$(grep -c 'claude rc=3' "$TMP/judge.err" | awk '{print ($1 > 0)}'),$(ls "$R"/judge/*.verdict.json 2>/dev/null | wc -l | tr -d ' ')"
: > "$FAKE_LOG"
MEASURE_CLAUDE="$TMP/fake-claude" MEASURE_JUDGE_JOBS=2 bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: one call per ok answer that passed the mechanical checks (FAILED f02-on and both mechanical failures of f03 skipped)" \
  'f01-off f01-on f02-off' "$(cd "$R/judge" && ls ./*.verdict.json | sed 's|^\./||; s|\.verdict\.json$||' | tr '\n' ' ' | sed 's/ $//')"
cp "$FAKE_LOG" "$TMP/calls.keep"; rm -f "$R"/judge/*.verdict.json
(cd "$(dirname "$R")" && MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$(basename "$R")" >/dev/null 2>&1)
check "judge: a relative run dir works (the judge runs from a temp cwd)" '3' "$(ls "$R"/judge/*.verdict.json 2>/dev/null | wc -l | tr -d ' ')"
cp "$TMP/calls.keep" "$FAKE_LOG"  # later checks count the calls of the run above, not this one
check "judge: the mechanical failure is recorded" '"evidence not verbatim"' "$(jq -c .reason "$R/judge/f03-off.mech.json")"
MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: stored verdicts are not re-judged" '3' "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
jq -c '.answer = "- a redone answer"' "$R/facts/f01-on-1.json" > "$R/x" && mv "$R/x" "$R/facts/f01-on-1.json"
MEASURE_CLAUDE="$TMP/fake-claude" bash "$MDIR/judge.sh" "$R" >/dev/null 2>&1
check "judge: a redone answer is judged again, not given the old verdict" '4' "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
note=$(sed -n "s/^ATTRIBUTION_NOTE='\(.*\)'$/\1/p" "$MDIR/judge.sh")
check "judge: blinding drops the attribution note and keeps claims about the local model" 'drop,keep,0' \
  "$(printf '%s\n' '_Summarized by the local model._' 'The local model requires 128 GB RAM.' | jq -R --arg n "$note" 'if test($n; "i") then "drop" else "keep" end' | jq -rs 'join(",")'),$(grep -c 'by the local model' "$R/judge/f01-on.prompt")"
echo "an edit after the freeze" >> "$DOC"; mv "$R/files/f02" "$TMP/f02.away"
bash "$MDIR/judge.sh" "$R" --mech-only >/dev/null 2>&1
check "judge: grading reads the run's copy, not the live file, and a missing copy is incomplete (ok null), not a fail" '[true,null,"no graded copy"]' \
  "$(jq -sc '[.[0].ok, .[1].ok, .[1].reason]' "$R/judge/f01-off.mech.json" "$R/judge/f02-off.mech.json")"
cp "$FX/doc.md" "$DOC"

# --- report.sh on synthetic runs: the completeness rule ------------------------------------------------------------
# base: a full corpus (10 main summaries + 3 small), every run counted, off jobs 30000 and on jobs 3000 tokens
B="$TMP/base"; mkdir -p "$B/facts" "$B/judge"
mkf() { # mkf <dir> <name> <cfg> <kind> <id> <rep> <T|null> [status] [extra-json]
  jq -nc --arg run "$2" --arg cfg "$3" --arg kind "$4" --arg id "$5" --argjson rep "$6" --argjson T "$7" --arg st "${8:-ok}" --argjson x "${9:-{\}}" \
    '{run: $run, cfg: $cfg, kind: $kind, id: $id, rep: $rep, status: $st, T: $T, input: 2, cache_creation: 0,
      cache_read: (if $T == null then null else $T - 6 end), output: 4, usd: (if $T == null then null else $T / 1000000 end),
      turns: 2, duration_ms: 5000, wall_s: 5, ctx_max: (if $T == null then null else $T - 2 end), models: ["claude-fixture"],
      parse_errors: 0, tool_listed: ($cfg == "on"), plugin_denials: [],
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
  jq -nc --arg sha "$(answer_sha "$f")" '{reference: ["x"], invented: [], missed: [], usable: true, reason: "r", judge_models: ["fake-judge"], answer_sha: $sha}' \
    > "$B/judge/$a.verdict.json"
done
jq -n '{date_start: "2026-01-06T00:00:00", date_end: "2026-01-06T01:00:00", cutoff: "2026-01-05", repo_sha: "abc1234", repo_dirty: false,
  claude_version: "0.0.0 (fake)", server_pin: "@houtini/lm@3.3.4", lms_version: "unknown", model: "", local_model: "local-fixture",
  ctl_reps: 3, small_reps: 3, run_dir: "RUN", partial: false, allow_short: false, configs: "off on"}' > "$B/meta.json"
variant() { rm -rf "$TMP/v"; cp -R "$B" "$TMP/v"; }   # a fresh copy of the base run in $TMP/v
render() { bash "$MDIR/report.sh" "$TMP/v" "$TMP/v/results.md" > /dev/null 2> "$TMP/v/report.err"; }
cell() { grep -E "$1" "$TMP/v/results.md" | head -n 1; }

variant; render
check "report PASS: the cost gate passes on a complete run" '| Claude cost per job (Σ USD over 10 main files) | $0.3 | $0.03 (savings 90%) | ≥ 50% lower | PASS |' "$(cell '^\| Claude cost')"
check "report: the token sum and context growth stay beside the gate, ungated" '| Claude tokens per job (Σ T, not gated) | 300000 | 30000 (savings 90%) | reported | not gated |,| Context growth per job (mean tokens, not gated) | 30000 | 3000 | reported | not gated |' \
  "$(cell '^\| Claude tokens'),$(cell '^\| Context growth')"
check "report PASS: usable gate passes" '| Usable answers | 10 of 10 | 10 of 10 | ≥ 8 of 10 | PASS |' "$(cell '^\| Usable answers')"
check "report PASS: fixed cost and break-even on cost, tokens beside" '- Fixed cost per session: $0.0007 (700 tokens).,- Break-even (on cost): 1 job(s) per session.' "$(cell '^- Fixed'),$(cell '^- Break-even')"
check "report: main row carries job T, local timing, e2e for both configs and usable" \
  '| f01 | doc | summary | 20–30k | 30000 | 3000 | 90% | 90% | 30000 | 3000 | 2 | 2 | ok | ok | 2 | 5 | 5 | 9 |  | yes | yes |  |' "$(cell '^\| f01 \| doc')"
check "report: no path or answer text in the results" '0' "$(grep -cE '/private/f|build failed' "$TMP/v/results.md")"

variant; rm "$TMP/v/facts/f03-on-1.json"; render
check "report FAIL-incomplete: a missing main run makes both gates incomplete" '2' \
  "$(grep -cE '^\| (Claude cost|Usable answers) .*\| FAIL \(incomplete: .*f03 on' "$TMP/v/results.md")"
check "report FAIL-incomplete: totals and break-even say incomplete, not a number" '| Claude cost per job (Σ USD over 10 main files) | incomplete | incomplete |,- Break-even (on cost): incomplete.' \
  "$(cell '^\| Claude cost' | cut -d'|' -f1-4)|,$(cell '^- Break-even')"

variant; rm "$TMP/v/facts/ctl-on-3.json"; render
check "report: a missing control leaves every plugin-on job cost incomplete (10 main rows, 13 threshold rows)" '23,1' \
  "$(grep -cE '^\| f[01][0-9] \| [^|]+ \| ([^|]+ \| [^|]+ \| )?[0-9]+ \| incomplete \(controls\) \|' "$TMP/v/results.md"),$(grep -cE '^\| Claude cost .*FAIL \(incomplete: controls on: 2/3 counted\)' "$TMP/v/results.md")"

variant; jq -c '.answer = "- a redone answer"' "$B/facts/f02-on-1.json" > "$TMP/v/facts/f02-on-1.json"; render
check "report: a verdict for an earlier answer (the run was redone) counts as no verdict" 'incomplete,1' \
  "$(cell '^\| f02 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}'),$(grep -c 'f02 on: no usable verdict' "$TMP/v/results.md")"

variant; rm "$TMP/v/facts/f11-on-2.json"; mkf "$TMP/v" f12-on-2 on job f12 2 null timeout; mkf "$TMP/v" f12-on-3 on job f12 3 null timeout; render
check "report: a missing small rep and two timeouts leave those rows incomplete, never a median of what is left" '2' \
  "$(grep -cE '^\| f1[12] \| ~[25]k \| 10000 \| incomplete \([12]/3\) \| n/a \|' "$TMP/v/results.md")"
check "report: small-file gaps do not touch the main gate; a timeout is SLOW" 'PASS,1' \
  "$(cell '^\| Claude cost' | awk -F'|' '{gsub(/ /, "", $6); print $6}'),$(grep -cE '^\| f12 .*\| SLOW \|' "$TMP/v/results.md")"

variant; for i in 01 02 03 04 05 06 07 08 09 10; do mkf "$TMP/v" "f$i-on-1" on job "f$i" 1 50000 ok "$ONF"; done; render
check "report: break-even is never when delegation costs more" '- Break-even (on cost): never (delegation costs more per job).' "$(cell '^- Break-even')"

variant; awk -F'\t' '$1 == "f01"' "$B/corpus.tsv" > "$TMP/v/corpus.tsv"; jq '.allow_short = true' "$B/meta.json" > "$TMP/v/meta.json"; render
check "report: a 1-main-file corpus can never pass" '2' "$(grep -cE '^\| (Claude cost|Usable answers) .*\| FAIL \(incomplete: 1 of 10 main files; no s2k file; no s5k file; no s10k file\) \|$' "$TMP/v/results.md")"
check "report: a short corpus labels break-even incomplete too" '1' "$(grep -c '^- Break-even (on cost): 1 job(s) per session (incomplete: 1 of 10 main files' "$TMP/v/results.md")"

variant; mkf "$TMP/v" f04-on-1 on job f04 1 20700 no-call; mkf "$TMP/v" f05-off-1 off job f05 1 47000
h() { answer_sha "$TMP/v/facts/$1-1.json" | cut -c1-12; }
printf 'f04-on\t%s\tdisagree\tlooks fine\r\n\nf05-off\t%s\tdisagree\tmissed a point\r\nf06-on\t%s\tagree\t\n' "$(h f04-on)" "$(h f05-off)" "$(h f06-on)" \
  > "$TMP/v/review-verdicts.tsv"; render
check "report: an operator disagreement flips a judged answer, but a FAILED job stays not usable" 'no (op),no' \
  "$(cell '^\| f05 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $21); print $21}'),$(cell '^\| f04 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}')"
check "report: operator lines with CRLF and blank lines parse; agreement counted" '- Operator review: agreed on 1 of 3.' "$(cell '^- Operator review')"
check "report: the review sheet shows each entry's answer hash" '1' "$(grep -c "^- Answer hash: \`$(h f05-off)\`$" "$TMP/v/review.md" | awk '{print ($1 > 0) ? 1 : 0}')"
jq -c '.answer = "- a redone answer"' "$TMP/v/facts/f05-off-1.json" > "$TMP/v/x" && mv "$TMP/v/x" "$TMP/v/facts/f05-off-1.json"
jq --arg s "$(answer_sha "$TMP/v/facts/f05-off-1.json")" '.answer_sha = $s' "$TMP/v/judge/f05-off.verdict.json" > "$TMP/v/x" \
  && mv "$TMP/v/x" "$TMP/v/judge/f05-off.verdict.json"   # the redone answer, judged again
render
check "report: an operator line for an answer since redone is ignored with a warning; the new verdict stands" 'yes,1' \
  "$(cell '^\| f05 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $21); print $21}'),$(grep -c 'f05-off was redone since that review' "$TMP/v/report.err")"
printf 'f01-on\t%s\tagree\nf01-on\t%s\tmaybe\n' "$(h f01-on)" "$(h f01-on)" > "$TMP/v/review-verdicts.tsv"; render; rc=$?
check "report: a malformed operator line fails with its line number" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'line 2' "$TMP/v/report.err")"
printf 'f99-on\t0123456789ab\tagree\n' > "$TMP/v/review-verdicts.tsv"; render; rc=$?
check "report: an operator line naming an unknown answer fails" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'f99-on is not an answer' "$TMP/v/report.err")"

variant; mkf "$TMP/v" f02-on-1 on job f02 1 20700 ok '{"call_footers":[{"model":"some-other-model","ttft_ms":1,"total_s":1,"flags":[]}]}'; render; rc=$?
check "report: a footer naming another model fails the report" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'some-other-model' "$TMP/v/report.err")"

variant; jq '.date_end = null' "$B/meta.json" > "$TMP/v/meta.json"
mkf "$TMP/v" f03-on-1 on job f03 1 20700 call-error '{"call_footers":[{"model":"local-fixture","ttft_ms":3000,"total_s":75.0,"flags":["hit-max-tokens"]}],"duration_ms":81000}'
mkf "$TMP/v" f04-on-1 on job f04 1 20700 no-call '{"duration_ms":12000}'; render
check "report: an unrecorded end date renders as such" '1' "$(grep -c 'to (not recorded);' "$TMP/v/results.md")"
check "report: a 75 s call that hit max tokens keeps its timing and is SLOW" '1' "$(grep -cE '^\| f03 .*\| FAILED: call-error \| 3 \| 75 \| 5 \| 81 \| SLOW \|' "$TMP/v/results.md")"
check "report: with no footer, local time falls back to the session's" '1' "$(grep -cE '^\| f04 .*\| FAILED: no-call \| n/a \| 12 \(session\) \| 5 \| 12 \|  \|' "$TMP/v/results.md")"

# --- valid_run: positive evidence only ----------------------------------------------------------------------------
gates_incomplete() { grep -cE '^\| (Claude cost|Usable answers) .*\| FAIL \(incomplete: ' "$TMP/v/results.md"; }
variant; mkf "$TMP/v" f03-on-1 on job f03 1 20700 corpus-changed "$ONF"; render
check "valid_run: a corpus-changed run that still carries usage leaves both gates incomplete" '2' "$(gates_incomplete)"
variant; mkf "$TMP/v" f04-off-1 off job f04 1 47000 plugin-leak '{"tool_listed":true}'; render
check "valid_run: a plugin-leak run with usage leaves both gates incomplete" '2' "$(gates_incomplete)"
variant; mkf "$TMP/v" f04-off-1 off job f04 1 47000 ok '{"tool_listed":true}'; render
check "valid_run: plugin presence must match the config even when the status says ok" '2' "$(gates_incomplete)"
variant; mkf "$TMP/v" ctl-on-1 on ctl "" 1 17700 ok '{"tool_listed":false}'; render
check "valid_run: a plugin-on control without the tool (dead server) does not count" '1' "$(grep -c 'controls on: 2/3 counted' "$TMP/v/results.md")"
variant; mkf "$TMP/v" ctl-on-1 on ctl "" 1 17700 no-call; render
check "valid_run: a delegation-failure status counts only for a plugin-on job, never a control" '1' "$(grep -c 'controls on: 2/3 counted' "$TMP/v/results.md")"
variant; mkf "$TMP/v" f05-on-1 on job f05 1 20700 no-server '{"tool_listed":false}'; render
check "valid_run: no-server on a job leaves the gates incomplete" '2' "$(gates_incomplete)"
variant; mkf "$TMP/v" f06-off-1 off job f06 1 47000 ok '{"parse_errors":1}'; render
check "valid_run: a run with a parse error does not count" '2' "$(gates_incomplete)"
variant; mkf "$TMP/v" f07-on-1 on job f07 1 20700 ok '{"output":null}'; render
check "valid_run: a missing usage counter does not count" '2' "$(gates_incomplete)"
variant; mkf "$TMP/v" f08-on-1 on job f08 1 20700 no-call; render
check "valid_run: a no-call job stays in the totals at its real cost and tokens and the gates stay complete" '1,1,1,1' \
  "$(grep -c '^| Claude cost per job (Σ USD over 10 main files) | \$0.3 | \$0.03 (savings 90%) | ≥ 50% lower | PASS |$' "$TMP/v/results.md"),$(grep -c '^| Claude tokens per job (Σ T, not gated) | 300000 | 30000 ' "$TMP/v/results.md"),$(grep -cE '^\| f08 .*\| FAILED: no-call \|' "$TMP/v/results.md"),$(grep -c '^| Usable answers | 10 of 10 | 9 of 10 | ≥ 8 of 10 | PASS |$' "$TMP/v/results.md")"

# --- gates on complete runs ----------------------------------------------------------------------------------------
onjobs() { variant; for i in 01 02 03 04 05 06 07 08 09 10; do mkf "$TMP/v" "f$i-on-1" on job "f$i" 1 "$((17700 + $1))" ok "$ONF"; done; render; }
onjobs 20000
check "gate: a complete run well below 50% is a plain FAIL" '| Claude cost per job (Σ USD over 10 main files) | $0.3 | $0.2 (savings 33.3%) | ≥ 50% lower | FAIL |' "$(cell '^\| Claude cost')"
variant; for i in 01 02 03 04 05 06 07 08 09 10; do mkf "$TMP/v" "f$i-on-1" on job "f$i" 1 41700 ok "$(jq -c '. + {usd: 0.0297}' <<<"$ONF")"; done; render
check "gate: cost, not tokens, decides (60% cheaper, 17.7% fewer tokens: cost PASS, token row ungated)" \
  '| Claude cost per job (Σ USD over 10 main files) | $0.3 | $0.12 (savings 60%) | ≥ 50% lower | PASS |,| Claude tokens per job (Σ T, not gated) | 300000 | 240000 (savings 20%) | reported | not gated |' \
  "$(cell '^\| Claude cost'),$(cell '^\| Claude tokens')"
onjobs 15300
check "gate: 49% lower cost is FAIL" '| Claude cost per job (Σ USD over 10 main files) | $0.3 | $0.153 (savings 49%) | ≥ 50% lower | FAIL |' "$(cell '^\| Claude cost')"
onjobs 14700
check "gate: 51% lower cost is PASS" '| Claude cost per job (Σ USD over 10 main files) | $0.3 | $0.147 (savings 51%) | ≥ 50% lower | PASS |' "$(cell '^\| Claude cost')"
missed() { jq '.missed = ["a key point"]' "$TMP/v/judge/$1.verdict.json" > "$TMP/v/x" && mv "$TMP/v/x" "$TMP/v/judge/$1.verdict.json"; }
variant; missed f01-on; missed f02-on; missed f03-on; render
check "gate: 7 of 10 usable is FAIL" '| Usable answers | 10 of 10 | 7 of 10 | ≥ 8 of 10 | FAIL |' "$(cell '^\| Usable answers')"
check "gate: usable true with a missed point reads no (judge bool differs)" 'no (judge bool differs)' "$(cell '^\| f01 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}')"
variant; missed f01-on; missed f02-on; render
check "gate: 8 of 10 usable is PASS" '| Usable answers | 10 of 10 | 8 of 10 | ≥ 8 of 10 | PASS |' "$(cell '^\| Usable answers')"
variant; echo '{"ok":false,"reason":"evidence not verbatim","extra_text":false}' > "$TMP/v/judge/f05-on.mech.json"; rm "$TMP/v/judge/f06-on.mech.json"
echo '{"ok":null,"reason":"no graded copy","extra_text":false}' > "$TMP/v/judge/f07-on.mech.json"; render
check "usable: a failed mechanical check is no with its note; a missing check or graded copy is incomplete" 'no,1,incomplete,incomplete' \
  "$(cell '^\| f05 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}'),$(grep -c 'on mechanical: evidence not verbatim' "$TMP/v/results.md"),$(cell '^\| f06 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}'),$(cell '^\| f07 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $22); print $22}')"

# --- timing, notes, header, review warnings ------------------------------------------------------------------------
variant; mkf "$TMP/v" f04-on-1 on job f04 1 20700 no-call '{"duration_ms":70000}'
mkf "$TMP/v" f05-on-1 on job f05 1 20700 ok '{"call_footers":[{"model":"local-fixture","ttft_ms":10,"total_s":null,"flags":[]}],"plugin_denials":["Skill"]}'; render
check "slow: no footer falls back to the session time; a missing call time is unknown, not fast" 'SLOW,unknown' \
  "$(cell '^\| f04 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $20); print $20}'),$(cell '^\| f05 \| doc' | awk -F'|' '{gsub(/^ | $/, "", $20); print $20}')"
check "notes: plugin permission denials are shown" '1' "$(grep -cE '^\| f05 .*on PLUGIN denied: Skill' "$TMP/v/results.md")"
variant; for f in "$TMP"/v/facts/*.json; do jq -c '.call_footers = [] | .footer = null' "$f" > "$TMP/v/x" && mv "$TMP/v/x" "$f"; done; render
check "header: no footer-match claim when no footer was recorded" '1,0' "$(grep -c 'no footer recorded' "$TMP/v/results.md"),$(grep -c 'footers matched' "$TMP/v/results.md")"
variant; printf 'f01-on\t%s\tagree\nf01-on\t%s\tdisagree\n' "$(h f01-on)" "$(h f01-on)" > "$TMP/v/review-verdicts.tsv"
jq -c '.answer = "- redone"' "$B/facts/f02-on-1.json" > "$TMP/v/facts/f02-on-1.json"; render
check "review: a duplicate line and a dropped stale verdict both warn" '1,1' \
  "$(grep -c 'a second line for f01-on' "$TMP/v/report.err"),$(grep -c 'stored verdict for f02-on graded an earlier answer' "$TMP/v/report.err")"

variant; for r in 1 2 3; do mkf "$TMP/v" "ctl-on-$r" on ctl "" "$r" 17700 ok '{"usd":null}'; done; render
check "report: controls without total_cost_usd do not count, now that cost is gated" '- Fixed cost per session: incomplete.,1' \
  "$(cell '^- Fixed'),$(grep -c 'controls on: 0/3 counted' "$TMP/v/results.md")"
variant; for i in 01 02 03 04 05 06 07 08 09 10; do mkf "$TMP/v" "f$i-off-1" off job "f$i" 1 17000; done; render
check "report: a zero baseline cost names its reason instead of an empty incomplete" '1' "$(grep -c '^| Claude cost .*| FAIL (incomplete: baseline cost is zero) |$' "$TMP/v/results.md")"
variant; jq 'del(.local_model)' "$B/meta.json" > "$TMP/v/meta.json"; render; rc=$?
check "report: a run without a recorded local_model fails" '1,1' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'records no local_model' "$TMP/v/report.err")"
check "trace_facts: a non-numeric rep fails instead of dropping it" '1' \
  "$(sed "s|@PATH@|$DOC|g" "$FX/ctl-off.jsonl" > "$TMP/t2.jsonl"; trace_facts "$TMP/tf2" "$TMP/t2.jsonl" n off ctl "" x "" 0 1 >/dev/null 2>&1 && echo 0 || echo 1)"

# Exercise run.sh's actual job routing with session and file-integrity work stubbed.
# The standard floor comes from the same helper as run.sh; no paid session can run.
routes=$(
  RUN_DIR="$TMP/routing"; mkdir -p "$RUN_DIR/facts"
  MIN_DELEGATE_CHARS=$(node --input-type=module -e 'const { MIN_DELEGATE_CHARS } = await import(process.argv[2]); console.log(MIN_DELEGATE_CHARS)' read-floor "$MDIR/../scripts/context-cap.mjs")
  snapshot_ok() { return 0; }; live_unchanged() { return 0; }
  task_field() { echo 'Summarize fixture'; }
  run_one() { basename "$8"; }
  . <(sed -n '/^job() {/,/^}/p' "$MDIR/run.sh")
  for spec in 'main 20000' 'main 29999' 'main 30000' 'main 50000' 's2k 2000'; do
    set -- $spec
    printf 'f01\t%s\tdoc\tsummary\t%s\tT\thash\t/fixture\n' "$1" "$2" > "$RUN_DIR/corpus.tsv"
    job f01 on 1
  done
)
check "run.sh: main slots below the delegation floor use the low-floor copy, boundary and larger slots use the normal copy" \
  'plugin-lowfloor plugin-lowfloor plugin plugin plugin-lowfloor' "$(echo "$routes" | tr '\n' ' ' | sed 's/ $//')"

# --- run.sh refuses bad inputs before any session ------------------------------------------------------------------
MH="$TMP/mh"; mkdir -p "$MH"; cp "$B/corpus.tsv" "$MH/corpus.tsv"; selector_rule > "$MH/corpus.rule"
runsh() { HOME="$TMP/rh" TMPDIR="$TMP" MEASURE_HOME="$MH" MEASURE_CLAUDE="${FAKE_CLAUDE:-$TMP/fake-claude}" MEASURE_CONFIGS="${1:-off}" "$TIMEOUT" 60 bash "$MDIR/run.sh" "${@:2}" > "$TMP/run.out" 2>&1 < /dev/null; }
mkdir -p "$TMP/rh"; : > "$FAKE_LOG"
MEASURE_ONLY="f01 f99" runsh; rc=$?
check "run.sh: an unknown MEASURE_ONLY id is an error, before any session" '1,1,0' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'MEASURE_ONLY names f99' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"
MEASURE_ONLY=f01 runsh; rc=$?
check "run.sh: a missing cutoff is an error, not a guess from the manifest's mtime" '1,1,0' "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'corpus.cutoff is missing' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"

echo stale > "$MH/corpus.rule"; MEASURE_ONLY=f01 runsh; rc=$?
check "run.sh: a manifest frozen under another corpus rule (selector or entropy guard) is refused" '1,1' \
  "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'corpus rule .* changed since the manifest was frozen' "$TMP/run.out")"
check "selector_rule covers the entropy guard" '1' "$(cp -R "$MDIR" "$TMP/mcopy" && echo '// x' >> "$TMP/mcopy/entropy.mjs" && [ "$(MDIR="$TMP/mcopy" selector_rule)" != "$(selector_rule)" ] && echo 1 || echo 0)"

# --- the loaded context run.sh records and warns about (against the fake endpoint's `context` mode) ---------------
REPO="$(cd "$MDIR/.." && pwd -P)"
ctx_ep() { # ctx_ep <tokens> [mode]: start a fake LM Studio with that loaded context (mode `context`, or e.g. verify-v1: no context metadata); prints its endpoint
  local n="ctx-$1-${2:-context}"
  : > "$TMP/$n.port"
  node "$REPO/tests/fake-endpoint.mjs" "$TMP/$n.port" "$TMP/$n.log" "${2:-context}" "$1" > /dev/null 2>&1 &
  echo $! >> "$TMP/ctx.pids"   # a file: ctx_ep runs in a command substitution
  for _ in $(seq 100); do [ -s "$TMP/$n.port" ] && break; sleep 0.05; done
  [ -s "$TMP/$n.port" ] || { echo "ctx_ep: the fake endpoint for $1 tokens did not start" >&2; return 1; }
  echo "http://127.0.0.1:$(cat "$TMP/$n.port")"
}
ctx() { local ep; ep=$(ctx_ep "$1") || return 1; observe_context "$REPO" "$ep" "${2:-}"; }
check "context: a loaded context is recorded as tokens and source" '{"tokens":8192,"source":"loaded","reason":null}' "$(ctx 8192 | jq -c .)"
check "context: a pinned model that is not loaded is an assumed source with no tokens" \
  '{"tokens":null,"source":"pinned model not loaded","reason":"pinned model not loaded"}' "$(ctx 8192 nope | jq -c .)"
check "context: an unreachable endpoint is an assumed source with no tokens" '{"tokens":null,"source":"fallback","reason":"no metadata"}' \
  "$(observe_context "$REPO" http://127.0.0.1:9 '' | jq -c .)"
check "context: 8192 tokens loaded warns with the lms load command for the model" '1,1' \
  "$(context_warning "$(ctx 8192 | jq -c .)" qwen-x | grep -c 'qwen-x --context-length 32768'),$(context_warning "$(ctx 8192 | jq -c .)" qwen-x | grep -c '8192 tokens loaded')"
check "context: 22846 tokens (the first that fits the 30k floor) and 32768 do not warn" '0,0' \
  "$(context_warning "$(ctx 22846 | jq -c .)" m | wc -l | tr -d ' '),$(context_warning "$(ctx 32768 | jq -c .)" m | wc -l | tr -d ' ')"
check "context: 22845 tokens still warns" '1' "$(context_warning "$(ctx 22845 | jq -c .)" m | wc -l | tr -d ' ')"
w=$(context_warning "$(ctx 8192 nope | jq -c .)" nope)
check "context: a pinned model that is not loaded is told to be loaded, with no context-length remedy" '1,0' "$(grep -c 'load nope in LM Studio' <<<"$w"),$(grep -c 'context-length' <<<"$w")"
w=$(context_warning '{"tokens":null,"source":"fallback","reason":"timeout"}' m)
check "context: another assumed source states its reason and the 32k assumption, with no lms load" '1,1,0' "$(grep -c 'timeout' <<<"$w"),$(grep -c 'assum.* 32k' <<<"$w"),$(grep -c 'lms load' <<<"$w")"
check "context: a floor check that cannot run is an error, not a fit" '1' "$( (MDIR=/nonexistent context_warning '{"tokens":8192,"source":"loaded","reason":null}' m >/dev/null 2>&1) && echo 0 || echo 1)"

# the report header shows what the run saw
variant; jq '.context = {tokens: 8192, source: "loaded", reason: null} | .endpoint = "http://127.0.0.1:4321"' "$B/meta.json" > "$TMP/v/meta.json"; render
check "report: the header names the endpoint and the loaded context" '- Local server http://127.0.0.1:4321; loaded context 8192 tokens (loaded)' "$(cell '^- Local server')"
variant; jq '.context = {tokens: null, source: "fallback", reason: "timeout"} | .endpoint = "http://127.0.0.1:1234"' "$B/meta.json" > "$TMP/v/meta.json"; render
check "report: an assumed context shows its source and reason" '- Local server http://127.0.0.1:1234; loaded context unknown (fallback: timeout)' "$(cell '^- Local server')"
variant; jq '.context = {tokens: null, source: "pinned model not loaded", reason: "pinned model not loaded"} | .endpoint = "http://127.0.0.1:1234"' "$B/meta.json" > "$TMP/v/meta.json"; render
check "report: a reason equal to the source is not repeated" '- Local server http://127.0.0.1:1234; loaded context unknown (pinned model not loaded)' "$(cell '^- Local server')"
variant; render
check "report: a run without a recorded context says so" '- Local server n/a; loaded context not recorded' "$(cell '^- Local server')"

# run.sh warns about a small context in its preflight and goes on (the stale corpus rule stops it right after, before any session)
echo stale > "$MH/corpus.rule"; : > "$FAKE_LOG"
MEASURE_ENDPOINT="$(ctx_ep 8192)" MEASURE_LOCAL_MODEL=fake-context MEASURE_ONLY=f01 runsh on; rc=$?
check "run.sh: a small loaded context is warned about in the preflight, which then goes on to the next check" '1,1,0' \
  "$(grep -c 'lms load fake-context --context-length 32768' "$TMP/run.out"),$(grep -c 'corpus rule .* changed' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"
MEASURE_ENDPOINT="$(ctx_ep 32768)" MEASURE_LOCAL_MODEL=fake-context MEASURE_ONLY=f01 runsh on; rc=$?
check "run.sh: a loaded context that fits the floor draws no warning" '0,1' "$(grep -c '^warning' "$TMP/run.out"),$(grep -c 'corpus rule .* changed' "$TMP/run.out")"

: > "$FAKE_LOG"
MEASURE_ENDPOINT=http://192.168.1.5:1234 MEASURE_LOCAL_MODEL=fake-context MEASURE_ONLY=f01 runsh on; rc=$?
check "run.sh: a non-loopback MEASURE_ENDPOINT dies in the preflight, before any session" '1,1,0' \
  "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'recorded endpoint must be loopback' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"

# a fresh run records the context and endpoint it saw and hands the endpoint to its sessions (a typo here would disable the resume guard)
cat > "$TMP/env-claude" <<'EOF2'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "0.0.0 (fake)"; exit 0; }
echo "$LOCAL_LLM_ENDPOINT_URL $LOCAL_LLM_MODEL" >> "$ENV_LOG"
exit 0
EOF2
chmod +x "$TMP/env-claude"
selector_rule > "$MH/corpus.rule"; date +%s > "$MH/corpus.cutoff"; export ENV_LOG="$TMP/env.log"; : > "$ENV_LOG"
ep32=$(ctx_ep 32768)
FAKE_CLAUDE="$TMP/env-claude" MEASURE_ENDPOINT="$ep32" MEASURE_LOCAL_MODEL=fake-context MEASURE_ONLY=f01 runsh on > /dev/null 2>&1
fresh=$(ls -d "$MH"/runs/*/ | tail -n 1)   # the newest run dir: this one
check "run.sh: a fresh run records the loaded context and the endpoint in meta.json" 'loaded,32768,'"$ep32" \
  "$(jq -r '[.context.source, .context.tokens, .endpoint] | join(",")' "${fresh}meta.json" 2>/dev/null)"
check "run.sh: a session gets the run's endpoint and pinned model as LOCAL_LLM_ENDPOINT_URL and LOCAL_LLM_MODEL" "$ep32 fake-context" "$(head -n 1 "$ENV_LOG")"
echo stale > "$MH/corpus.rule"

# a resumed run measures under the context it started with: another loaded context dies before any session
rr="$TMP/resume-ctx"; mkdir -p "$rr"; cp "$B/corpus.tsv" "$rr/corpus.tsv"
resume_meta() { # resume_meta <endpoint> <context-json> [local model]
  jq -n --arg e "$1" --argjson c "$2" --arg m "${3:-fake-context}" '{configs: "on", only: "", model: "", local_model: $m, endpoint: $e, context: $c}' > "$rr/meta.json"; }
ep8=$(ctx_ep 8192)
: > "$FAKE_LOG"; resume_meta "$ep8" '{"tokens":32768,"source":"loaded","reason":null}'; runsh on --resume "$rr"; rc=$?
check "run.sh: a resume under another loaded context dies before any session, naming both values" '1,1,1,0' \
  "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'recorded {"tokens":32768' "$TMP/run.out"),$(grep -c 'now {"tokens":8192' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"
resume_meta "$ep8" '{"tokens":8192,"source":"loaded","reason":null}'; runsh on --resume "$rr"
check "run.sh: a resume under the recorded context goes past the check" '0,1' "$(grep -c 'loaded context is not the one' "$TMP/run.out"),$(grep -c 'predates --resume' "$TMP/run.out")"
resume_meta "$ep8" '{"tokens":null,"source":"pinned model not loaded","reason":"pinned model not loaded"}'; runsh on --resume "$rr"
check "run.sh: a resume of a run that recorded an assumed source goes past the check" '0,1' "$(grep -c 'loaded context is not the one' "$TMP/run.out"),$(grep -c 'predates --resume' "$TMP/run.out")"
resume_meta "$ep8" '{"tokens":8192,"source":"loaded","reason":null}' fake-idle; : > "$FAKE_LOG"; runsh on --resume "$rr"; rc=$?
check "run.sh: a resume of a loaded-context run whose model is no longer loaded dies before any session, naming the tokens and the cause" '1,1,1,0' \
  "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'reload fake-idle at 8192 tokens' "$TMP/run.out"),$(grep -c 'pinned model not loaded' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"
resume_meta "$(ctx_ep 0 verify-v1)" '{"tokens":32768,"source":"loaded","reason":null}' v1-chat-model; : > "$FAKE_LOG"; runsh on --resume "$rr"; rc=$?
check "run.sh: a resume whose lookup now fails dies before any session, naming the reason (retry if it was transient)" '1,1,1,0' \
  "$([ $rc -ne 0 ] && echo 1 || echo 0),$(grep -c 'now {"tokens":null,"source":"fallback","reason":"http 404"}' "$TMP/run.out"),$(grep -c 'reload v1-chat-model at 32768 tokens, retry if the lookup failed' "$TMP/run.out"),$(wc -l < "$FAKE_LOG" | tr -d ' ')"
MEASURE_ENDPOINT=http://127.0.0.1:9 runsh on --resume "$rr"
check "run.sh: a resume says when it ignores a different MEASURE_ENDPOINT for the recorded one" '1' "$(grep -c 'using the recorded endpoint' "$TMP/run.out")"
resume_meta "$ep8" null; runsh on --resume "$rr"
check "run.sh: a resume whose recorded context is null (an off-only run) skips the check" '0,1' "$(grep -c 'loaded context is not the one' "$TMP/run.out"),$(grep -c 'predates --resume' "$TMP/run.out")"
jq 'del(.context)' "$rr/meta.json" > "$rr/m" && mv "$rr/m" "$rr/meta.json"; runsh on --resume "$rr"
check "run.sh: a resume whose meta.json has no context (an older run) skips the check" '0,1' "$(grep -c 'loaded context is not the one' "$TMP/run.out"),$(grep -c 'predates --resume' "$TMP/run.out")"

echo "measure selftest total: $total, failed: $fails"
[ "$fails" -eq 0 ]
