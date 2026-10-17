# Renders a run as markdown. Input (built by report.sh), one object of:
#   runs (facts objects: run kind id cfg rep + trace.jq output), corpus ({id slot type task bytes}),
#   mech and verdicts ({"<id>-<cfg>": ...}), ops (operator review: {"<id>-<cfg>": {agree, note}}),
#   meta (header facts), mode ("results" or "review"), paths ({id: path}, review mode only) and tasks.
# Results mode prints only ids, types, tasks, size buckets and numbers; paths and answers never reach it.

def median_by(f): map(select(f != null)) | sort_by(f) | if length == 0 then null else .[(length - 1) / 2 | floor] end;
def na: if . == null then "n/a" else tostring end;
def pct: if . == null then "n/a" else ((. * 1000 | round) / 10 | tostring) + "%" end;
def usd: if . == null then "n/a" else "$" + ((. * 10000 | round) / 10000 | tostring) end;
def sec: if . == null then "n/a" else ((. * 10 | round) / 10 | tostring) end;
def ratio(a; b): if a == null or b == null or b == 0 then null else 1 - a / b end;
def bucket: if .slot == "main" then (if .bytes < 30000 then "20–30k" elif .bytes < 40000 then "30–40k" else "40–50k" end)
  else ({"s2k": "~2k", "s5k": "~5k", "s10k": "~10k"}[.slot] // "?") end;
def status_cell: if . == null then "not run" elif . == "ok" then "ok" else "FAILED: " + . end;
def row: "| " + (map(na) | join(" | ")) + " |";
def table(h): (h | row), (h | map("---") | row);

. as {runs: $runs, corpus: $corpus, mech: $mech, verdicts: $verdicts, ops: $ops, meta: $meta, mode: $mode, paths: $paths, tasks: $tasks}
| ($runs | map(select(.kind == "ctl" and .status == "ok"))) as $ctls
| (reduce ("off", "on") as $c ({}; .[$c] = ($ctls | map(select(.cfg == $c)) | median_by(.T)))) as $C
| (reduce ("off", "on") as $c ({}; .[$c] = ($ctls | map(select(.cfg == $c) | .T) | if length == 0 then null else "\(min)–\(max) (n=\(length))" end))) as $spread
| def job: if .T == null or $C[.cfg].T == null then null else .T - $C[.cfg].T end;
  def jobusd: if .usd == null or $C[.cfg].usd == null then null else .usd - $C[.cfg].usd end;
  def growth: if .ctx_max == null or $C[.cfg].ctx_max == null then null else .ctx_max - $C[.cfg].ctx_max end;
  # usable <aid> <status>: FAILED, a mechanical failure or a missing verdict is not usable; operator overrides win
  def usable($aid; $status):
    ($mech[$aid] // null) as $m | ($verdicts[$aid] // null) as $v
    | (if $status != "ok" then {u: false, why: "FAILED"}
       elif $m == null then {u: false, why: "not checked"}
       elif ($m.ok | not) then {u: false, why: ("mechanical: " + $m.reason)}
       elif $v == null then {u: false, why: "not judged"}
       else {u: (($v.invented | length) == 0 and ($v.missed | length) == 0), why: null,
             disagree: ($v.usable != (($v.invented | length) == 0 and ($v.missed | length) == 0))} end) as $x
    | if $ops[$aid] != null and ($ops[$aid].agree | not) then $x + {u: ($x.u | not), op: true} else $x end;
  def ucell: if .u then "yes" else "no" end + (if .op then " (op)" else "" end) + (if .disagree then " (judge bool differs)" else "" end);

  [$corpus[] | . as $f
   | reduce ("off", "on") as $c ($f;
       ([$runs[] | select(.kind == "job" and .id == $f.id and .cfg == $c) | . + {job: job, jobusd: jobusd, growth: growth}]) as $reps
       | .[$c] = (if ($reps | length) == 0 then null
                  else (if $f.slot == "main" then ($reps | map(select(.rep == 1)) | first) else ($reps | median_by(.job)) end)
                    + {ok_reps: ([$reps[] | select(.status == "ok")] | length), n_reps: ($reps | length),
                       answer1: ($reps | map(select(.rep == 1)) | first | .answer),
                       ttft_s: ([$reps[] | .footer.ttft_ms // empty | . / 1000] | sort | if length == 0 then null else .[(length - 1) / 2 | floor] end),
                       total_s: ([$reps[] | .footer.total_s // empty] | sort | if length == 0 then null else .[(length - 1) / 2 | floor] end),
                       usable: usable("\($f.id)-\($c)"; ($reps | map(select(.rep == 1)) | first | .status))}
                  end))
   | . + {savings: ratio(.on.job; .off.job), savings_usd: ratio(.on.jobusd; .off.jobusd)}] as $F
| ($F | map(select(.slot == "main"))) as $M
| ($M | map(.off.job) | if any(. == null) or length == 0 then null else add end) as $sum_off
| ($M | map(.on.job) | if any(. == null) or length == 0 then null else add end) as $sum_on
| ($M | map(.off.jobusd) | if any(. == null) or length == 0 then null else add end) as $usd_off
| ($M | map(.on.jobusd) | if any(. == null) or length == 0 then null else add end) as $usd_on
| ratio($sum_on; $sum_off) as $headline
| (if $C.on.T != null and $C.off.T != null then $C.on.T - $C.off.T else null end) as $fixed
| ($M | map(select(.off.job != null and .on.job != null) | .off.job - .on.job) | if length == 0 then null else add / length end) as $gain
| ([$M[] | select(.off.usable.u)] | length) as $u_off
| ([$M[] | select(.on.usable.u)] | length) as $u_on
| ($M | length) as $n
| ((($n * 8) + 9) / 10 | floor) as $u_target
| ([$ops | to_entries[] | select(.value.agree)] | length) as $op_agree
| ($ops | length) as $op_n
|
if $mode == "review" then
  "# Operator review sheet (private; never commit)", "",
  "Write `review-verdicts.tsv` beside this file, one line per entry: `<id>-<cfg><TAB>agree|disagree<TAB>note`.",
  "Then re-render with `bash measure/run.sh --report \($meta.run_dir)`. A disagreement flips that answer's usable.", "",
  ([$F[] | . as $f | ("off", "on") as $c | select($f[$c] != null and $f[$c].rep != null) | {f: $f, c: $c, r: $f[$c]}
     | select(.r.usable.u | not)] +
   ([$M[] | select(.on != null and .on.usable.u) | {f: ., c: "on", r: .on}] | if length == 0 then [] else [first, last] | unique_by(.f.id) end)
   | .[] | "## \(.f.id)-\(.c) (\(if .r.usable.u then "usable" else "not usable" end))", "",
     "- Path: `\($paths[.f.id])`", "- Task: \(.f.task); status \(.r.status | status_cell)",
     "- Usable means: \($tasks.tasks[.f.task].usable)",
     "- Mechanical: \($mech["\(.f.id)-\(.c)"] // {} | tojson)", "",
     "Answer:", "", "~~~~text", (.r.answer1 // "(none)"), "~~~~", "",
     "Verdict:", "", "~~~~json", ($verdicts["\(.f.id)-\(.c)"] // "not judged" | tojson), "~~~~", "")
else
  "<!-- Generated by measure/run.sh; do not edit. Re-render: bash measure/run.sh --report <run-dir> -->",
  "# Measured savings and quality", "",
  "- Run: \($meta.date_start) to \($meta.date_end); corpus cutoff \($meta.cutoff); repo \($meta.repo_sha)\(if $meta.repo_dirty then " (dirty)" else "" end)",
  "- Claude Code \($meta.claude_version); job models \([$runs[] | .models[]?] | unique | join(", ") | if . == "" then "n/a" else . end); judge \([$verdicts[] | .judge_models[]?] | unique | join(", ") | if . == "" then "n/a" else . end)",
  "- Local model (footer) \([$runs[] | .footer.model // empty] | unique | join(", ") | if . == "" then "n/a" else . end); server \($meta.server_pin); LM Studio CLI \($meta.lms_version)",
  "- Every session: `claude -p --output-format stream-json --setting-sources project --no-session-persistence`, default model\(if $meta.model != "" then " pinned to " + $meta.model else "" end), a constant empty cwd, claude.ai connectors off (`ENABLE_CLAUDEAI_MCP_SERVERS=false`). Plugin on adds `--plugin-dir` (a snapshot of the repo; the ~2k, ~5k and ~10k files use a copy whose skill floor reads 1k instead of 10k).",
  "",
  "**Metrics.** T = input + cache_creation + cache_read + output, summed over the result event's `modelUsage`. A job's cost is its run's T minus the median control of its configuration (`Reply with the single word OK.`, \($meta.ctl_reps) per configuration, after one discarded warm-up). Savings = 1 − Σ job on / Σ job off over the main files; a FAILED job stays in at its actual tokens, and a run without usage leaves the total incomplete. Fixed cost = T(control on) − T(control off); break-even = ceil(fixed / mean(job off − job on)). Context growth = the largest single-call input side (input + cache_read + cache_creation) in the run minus the control's: the file tokens that entered the main context. USD, turns and context growth are reported, not gated.",
  "",
  "## Definition of done", "",
  table(["Metric", "Baseline (plugin off)", "Delegated (plugin on)", "Target", "Result"]),
  (["Claude tokens per job (Σ T over \($n) main files)", $sum_off, ($sum_on | na) + " (savings " + ($headline | pct) + ")", "≥ 80% fewer",
    (if $headline == null then "FAIL (incomplete)" elif $headline >= 0.8 then "PASS" else "FAIL" end)] | row),
  (["Usable answers", "\($u_off) of \($n)", "\($u_on) of \($n)", "≥ \($u_target) of \($n)", (if $u_on >= $u_target and $n > 0 then "PASS" else "FAIL" end)] | row),
  "",
  "- Fixed cost per session: \($fixed | na) tokens (\(if $C.on.usd != null and $C.off.usd != null then $C.on.usd - $C.off.usd else null end | usd)).",
  "- Break-even: \(if $fixed == null or $gain == null then "n/a" elif $gain <= 0 then "never (delegation costs more per job)" else (($fixed / $gain) | ceil | tostring) + " job(s) per session" end).",
  "- Not gated: Σ job USD off \($usd_off | usd), on \($usd_on | usd) (savings \(ratio($usd_on; $usd_off) | pct)); mean context growth off \($M | map(.off.growth // empty) | if length == 0 then null else add / length | round end | na), on \($M | map(.on.growth // empty) | if length == 0 then null else add / length | round end | na) tokens.",
  "- Operator review: \(if $op_n == 0 then "not done yet" else "agreed on \($op_agree) of \($op_n)" end).",
  "",
  "## Fixed cost (median control)", "",
  table(["config", "input", "cache_creation", "cache_read", "output", "T", "USD", "context", "control spread (T)"]),
  (("off", "on") as $c | [$c, $C[$c].input, $C[$c].cache_creation, $C[$c].cache_read, $C[$c].output, $C[$c].T, ($C[$c].usd | usd), $C[$c].ctx_max, $spread[$c]] | row),
  "",
  "## Main jobs", "",
  table(["id", "type", "task", "size", "T off", "T on", "savings T", "savings USD", "growth off", "growth on", "turns off", "turns on", "status off", "status on", "TTFT s", "total s", "slow", "usable off", "usable on", "notes"]),
  ($M[] | [.id, .type, .task, bucket, .off.job, .on.job, (.savings | pct), (.savings_usd | pct), .off.growth, .on.growth, .off.turns, .on.turns,
           (.off.status | status_cell), (.on.status | status_cell), (.on.ttft_s | sec), (.on.total_s | sec),
           (if .on.total_s == null then "n/a" elif .on.total_s > 60 then "SLOW" else "" end),
           (.off.usable // null | if . == null then "n/a" else ucell end), (.on.usable // null | if . == null then "n/a" else ucell end),
           ([(if .on.also_read then "on: also opened the file" else empty end),
             (("off", "on") as $c | select(.[$c].usage_match == false) | "\($c): usage differs from modelUsage"),
             (("off", "on") as $c | .[$c].denials // [] | select(length > 0) | "\($c) denied: \(unique | join(" "))"),
             (("off", "on") as $c | .[$c].usable.why // empty | select(startswith("mechanical")) | "\($c) \(.)")] | join("; "))] | row),
  "",
  "## Per-field breakdown (raw run totals)", "",
  table(["id", "config", "turns", "input", "cache_creation", "cache_read", "output", "T", "USD", "context"]),
  (("off", "on") as $c | ["control", $c, $C[$c].turns, $C[$c].input, $C[$c].cache_creation, $C[$c].cache_read, $C[$c].output, $C[$c].T, ($C[$c].usd | usd), $C[$c].ctx_max] | row),
  ($F[] | . as $f | ("off", "on") as $c | $f[$c] // empty
     | [$f.id, $c, .turns, .input, .cache_creation, .cache_read, .output, .T, (.usd | usd), .ctx_max] | row),
  "",
  "## Threshold (per size; small files are the median of their reps)", "",
  table(["id", "size", "job off", "job on", "savings T", "ok reps off", "ok reps on", "TTFT s", "total s", "usable off", "usable on"]),
  ($F | sort_by(.bytes)[] | [.id, bucket, .off.job, .on.job, (.savings | pct), "\(.off.ok_reps // 0)/\(.off.n_reps // 0)", "\(.on.ok_reps // 0)/\(.on.n_reps // 0)",
     (.on.ttft_s | sec), (.on.total_s | sec), (.off.usable // null | if . == null then "n/a" else ucell end), (.on.usable // null | if . == null then "n/a" else ucell end)] | row)
end
