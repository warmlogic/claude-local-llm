# Renders a run as markdown. Input (built by report.sh), one object of:
#   runs (facts objects: run kind id cfg rep + trace.jq output), corpus ({id slot type task chars}),
#   mech and verdicts ({"<id>-<cfg>": ...}), ops (operator review: {"<id>-<cfg>": {agree, note}}),
#   meta (header facts), mode ("results" or "review"), paths ({id: path}, review mode only) and tasks.
# Results mode prints only ids, types, tasks, size buckets and numbers; paths and answers never reach it.
#
# Completeness, the one rule (valid_run below, used by every count, median, control, total and gate): a run is
# MEASURED only on positive evidence. All four usage counters are numbers; no trace line but the last failed to
# parse; the plugin tool is listed exactly when the configuration is on (controls included); and the status is ok,
# or, for a plugin-on job only, a delegation failure (no-call, call-error), which is real plugin behavior kept at
# its actual tokens. Anything else, including no-server (a dead server measures nothing about delegation), leaves
# the metric it feeds incomplete. A metric is complete only when every run it expects is measured (a job's cost
# also expects its configuration's controls) and the corpus is full (10 main files, each small slot, both
# configurations, not a partial run). An incomplete metric shows "incomplete" and can never PASS.

def median_by(f): map(select(f != null)) | sort_by(f) | if length == 0 then null else .[(length - 1) / 2 | floor] end;
def median: map(select(. != null)) | sort | if length == 0 then null else .[(length - 1) / 2 | floor] end;
def na: if . == null then "n/a" else tostring end;
def pct: if . == null then "n/a" else ((. * 1000 | round) / 10 | tostring) + "%" end;
def usd: if . == null then "n/a" else "$" + ((. * 10000 | round) / 10000 | tostring) end;
def sec: if . == null then "n/a" else ((. * 10 | round) / 10 | tostring) end;
def ratio(a; b): if a == null or b == null or b == 0 then null else 1 - a / b end;
def bucket: if .slot == "main" then (if .chars < 30000 then "20–30k" elif .chars < 40000 then "30–40k" else "40–50k" end)
  else ({"s2k": "~2k", "s5k": "~5k", "s10k": "~10k"}[.slot] // "?") end;
def status_cell: if . == null then "not run" elif . == "ok" then "ok" else "FAILED: " + . end;
def row: "| " + (map(na) | join(" | ")) + " |";
def table(h): (h | row), (h | map("---") | row);
def valid_run:
  ([.T, .input, .cache_creation, .cache_read, .output] | all(type == "number"))
  and .parse_errors == 0
  and .tool_listed == (.cfg == "on")
  and (.status == "ok" or (.kind == "job" and .cfg == "on" and (.status == "no-call" or .status == "call-error")));
def sumc: if any(.[]; . == null) or length == 0 then null else add end;
# gate <value> <complete> <reasons> <pass-test>: PASS needs a complete metric
def gate($v; $complete; $why; $pass): if ($complete | not) then "FAIL (incomplete: \($why | join("; ")))" elif $pass then "PASS" else "FAIL" end;

. as {runs: $runs, corpus: $corpus, mech: $mech, verdicts: $verdicts, ops: $ops, meta: $meta, mode: $mode, paths: $paths, tasks: $tasks}
| ($meta.configs // "off on" | split(" ") | map(select(. != ""))) as $cfgs
| ($meta.small_reps // 3) as $small_reps | ($meta.ctl_reps // 3) as $ctl_reps
# corpus completeness
| ([$corpus[] | select(.slot == "main")] | length) as $n
| ([(if $meta.partial then "partial run (MEASURE_ONLY)" else empty end),
    (if $n < 10 then "\($n) of 10 main files" else empty end),
    (("s2k", "s5k", "s10k") as $s | select([$corpus[] | select(.slot == $s)] | length == 0) | "no \($s) file"),
    (("off", "on") as $c | select($cfgs | index($c) == null) | "config \($c) not run")]) as $corpus_why
# controls: the median of the counted reps, complete when all expected reps count
| (reduce ("off", "on") as $c ({};
    ([$runs[] | select(.kind == "ctl" and .cfg == $c)]) as $all | ([$all[] | select(valid_run)]) as $ok
    | .[$c] = (($ok | median_by(.T)) // {}) + {complete: (($ok | length) == $ctl_reps), counted: ($ok | length),
        spread: ($ok | map(.T) | if length == 0 then null else "\(min)–\(max) (n=\(length))" end)})) as $C
| def job: if .T == null or $C[.cfg].T == null then null else .T - $C[.cfg].T end;
  def jobusd: if .usd == null or $C[.cfg].usd == null then null else .usd - $C[.cfg].usd end;
  def growth: if .ctx_max == null or $C[.cfg].ctx_max == null then null else .ctx_max - $C[.cfg].ctx_max end;
  def e2e: if .duration_ms != null then .duration_ms / 1000 else .wall_s end;
  # slow: "slow" for a timeout or a local call over 60 s; a plugin-on run with no footer falls back to its session
  # time; a call without a total, or no time at all, is "unknown", never fast
  def slow: if .status == "timeout" then "slow"
    elif (.call_footers // []) | length > 0 then
      (if any(.call_footers[]; (.total_s // 0) > 60) then "slow" elif any(.call_footers[]; .total_s == null) then "unknown" else "fast" end)
    elif .cfg == "on" then (e2e as $e | if $e == null then "unknown" elif $e > 60 then "slow" else "fast" end)
    else "fast" end;
  def slowcell: if .off.slow == "slow" or .on.slow == "slow" then "SLOW" elif .off.slow == "unknown" or .on.slow == "unknown" then "unknown" else "" end;
  # usable <aid> <rep-1 run>: null (incomplete) unless rep 1 is measured and, when it ran ok, was mechanically
  # checked against its graded copy (a missing copy is ok: null, so incomplete) and judged.
  # FAILED is never usable, and an operator disagreement cannot change that.
  def usable($aid; $r1):
    ($mech[$aid] // null) as $m | ($verdicts[$aid] // null) as $v
    | if $r1 == null or ($r1 | valid_run | not) then null
      elif $r1.status != "ok" then {u: false, why: "FAILED"}
      elif $m == null then null
      elif $m.ok == null then null
      else (if ($m.ok | not) then {u: false, why: ("mechanical: " + $m.reason)}
            elif $v == null then null
            else {u: (($v.invented | length) == 0 and ($v.missed | length) == 0), why: null,
                  disagree: ($v.usable != (($v.invented | length) == 0 and ($v.missed | length) == 0))} end)
           | if . != null and $ops[$aid] != null and ($ops[$aid].agree | not) then . + {u: (.u | not), op: true} else . end
      end;
  def ucell: if . == null then "incomplete" else (if .u then "yes" else "no" end) + (if .op then " (op)" else "" end)
    + (if .disagree then " (judge bool differs)" else "" end) end;

  [$corpus[] | . as $f | (if $f.slot == "main" then 1 else $small_reps end) as $want
   | reduce ("off", "on") as $c ($f;
       ([$runs[] | select(.kind == "job" and .id == $f.id and .cfg == $c) | . + {job: job, jobusd: jobusd, growth: growth}]) as $reps
       | ([$reps[] | select(valid_run)]) as $ok
       | ($reps | map(select(.rep == 1)) | first) as $r1
       | (($ok | length) == $want and ($reps | length) == $want and $C[$c].complete) as $complete
       | .[$c] = (if $complete then ($ok | median_by(.job)) else {} end)
           + {complete: $complete, counted: ($ok | length), want: $want, ran: ($reps | length),
              ok_reps: ([$reps[] | select(.status == "ok")] | length),
              status: (if $f.slot == "main" then ($r1.status // null) else null end), r1: $r1, answer1: ($r1.answer // null),
              ttft_s: ([$reps[] | (.footer // (.call_footers // [] | last)) | .ttft_ms // null | if . == null then null else . / 1000 end] | median),
              local_s: ([$reps[] | [.call_footers[]?.total_s // empty] | max] | median),
              e2e_s: ([$reps[] | e2e] | median),
              slow: ([$reps[] | slow] | if index("slow") != null then "slow" elif index("unknown") != null then "unknown" else "fast" end),
              usable: usable("\($f.id)-\($c)"; $r1)})
   | . + {savings: (if .off.complete and .on.complete then ratio(.on.job; .off.job) else null end),
          savings_usd: (if .off.complete and .on.complete then ratio(.on.jobusd; .off.jobusd) else null end)}] as $F
| ($F | map(select(.slot == "main"))) as $M
| ([$M[] | . as $f | ("off", "on") as $c | select(($f[$c].complete | not) and $C[$c].complete) | "\($f.id) \($c): \($f[$c].counted)/\($f[$c].want) runs counted"]
   + [("off", "on") as $c | select($C[$c].complete | not) | "controls \($c): \($C[$c].counted)/\($ctl_reps) counted"]) as $run_why
| ($corpus_why + $run_why) as $t_why
| ($t_why | length == 0) as $t_complete
| (if ($run_why | length) == 0 and ($M | length) > 0 then {off: ($M | map(.off.job) | sumc), on: ($M | map(.on.job) | sumc),
     usd_off: ($M | map(.off.jobusd) | sumc), usd_on: ($M | map(.on.jobusd) | sumc),
     g_off: ($M | map(.off.growth) | if any(.[]; . == null) then null else add / length | round end),
     g_on: ($M | map(.on.growth) | if any(.[]; . == null) then null else add / length | round end)} else {} end) as $S
| ratio($S.on; $S.off) as $headline
| (if $C.on.complete and $C.off.complete then $C.on.T - $C.off.T else null end) as $fixed
| (if ($run_why | length) == 0 and ($M | length) > 0 then ($M | map(.off.job - .on.job) | add / length) else null end) as $gain
| ($corpus_why + [$M[] | . as $f | ("off", "on") as $c | select($f[$c].usable == null) | "\($f.id) \($c): no usable verdict"]) as $u_why
| ([$M[] | select(.off.usable.u // false)] | length) as $u_off
| ([$M[] | select(.on.usable.u // false)] | length) as $u_on
| 8 as $u_target
| ([$ops | to_entries[] | select(.value.agree)] | length) as $op_agree
| ($ops | length) as $op_n
| def jcell($c): if .[$c].complete then .[$c].job elif ($C[$c].complete | not) then "incomplete (controls)"
    else "incomplete (\(.[$c].counted)/\(.[$c].want))" end;
if $mode == "review" then
  "# Operator review sheet (private; never commit)", "",
  "Write `review-verdicts.tsv` beside this file, one line per entry: `<id>-<cfg><TAB><answer hash><TAB>agree|disagree<TAB>note`, with the hash shown under the entry. A line for an answer that was since redone is ignored.",
  "Then re-render with `bash measure/run.sh --report \($meta.run_dir)`. A disagreement flips that answer's usable, except that a FAILED job is never usable.", "",
  ([$F[] | . as $f | ("off", "on") as $c | select($f[$c].r1 != null) | {f: $f, c: $c, r: $f[$c]}
     | select((.r.usable.u // false) | not)] +
   ([$M[] | select(.on.usable.u // false) | {f: ., c: "on", r: .on}] | if length == 0 then [] else [first, last] | unique_by(.f.id) end)
   | .[] | "## \(.f.id)-\(.c) (\(if .r.usable == null then "incomplete" elif .r.usable.u then "usable" else "not usable" end))", "",
     "- Path: `\($paths[.f.id])`", "- Task: \(.f.task); status \(.r.r1.status | status_cell)",
     "- Answer hash: `\(.r.r1.answer_sha // "" | .[0:12])`",
     "- Usable means: \($tasks.tasks[.f.task].usable)",
     "- Mechanical: \($mech["\(.f.id)-\(.c)"] // {} | tojson)", "",
     "Answer:", "", "~~~~text", (.r.answer1 // "(none)"), "~~~~", "",
     "Verdict:", "", "~~~~json", ($verdicts["\(.f.id)-\(.c)"] // "not judged" | tojson), "~~~~", "")
else
  "<!-- Generated by measure/run.sh; do not edit. Re-render: bash measure/run.sh --report <run-dir> -->",
  "# Measured savings and quality", "",
  "- Run: \($meta.date_start) to \($meta.date_end // "(not recorded)"); corpus cutoff \($meta.cutoff); repo \($meta.repo_sha)\(if $meta.repo_dirty then " (dirty)" else "" end)",
  "- Claude Code \($meta.claude_version); job models \([$runs[] | .models[]?] | unique | join(", ") | if . == "" then "n/a" else . end); judge \([$verdicts[] | .judge_models[]?] | unique | join(", ") | if . == "" then "n/a" else . end)",
  "- Local model \($meta.local_model // "n/a") (pinned in the plugin snapshots; \([$runs[] | .call_footers[]?] | length | if . == 0 then "no footer recorded" else "all \(.) footers matched" end)); server \($meta.server_pin); LM Studio CLI \($meta.lms_version)",
  "- Every session: `claude -p --output-format stream-json --setting-sources project --no-session-persistence`, default model\(if $meta.model != "" then " pinned to " + $meta.model else "" end), a constant empty cwd outside `$HOME`, claude.ai connectors off (`ENABLE_CLAUDEAI_MCP_SERVERS=false`). Plugin on adds `--plugin-dir` (a snapshot of the repo; the ~2k, ~5k and ~10k files use a copy whose skill floor reads 1k instead of 10k).",
  "",
  "**Metrics.** T = input + cache_creation + cache_read + output, summed over the result event's `modelUsage`. A job's cost is its run's T minus the median control of its configuration (`Reply with the single word OK.`, \($ctl_reps) per configuration, after one discarded warm-up). Savings = 1 − Σ job on / Σ job off over the main files. A plugin-on job's delegation failure (no-call, call-error) stays in at its actual tokens and is not usable. Any other run that is not positively measured (all four usage counters, a clean trace, the plugin tool present exactly when on, an ok status) leaves its metric incomplete, and an incomplete metric cannot pass. Fixed cost = T(control on) − T(control off); break-even = ceil(fixed / mean(job off − job on)). Context growth = the largest single-call input side (input + cache_read + cache_creation) in the run minus the control's: the file tokens that entered the main context. USD, turns, timing and context growth are reported, not gated. SLOW: a local call over 60 s, a timeout, or a plugin-on session over 60 s with no footer; \"unknown\" when a time is missing.",
  "",
  "## Definition of done", "",
  table(["Metric", "Baseline (plugin off)", "Delegated (plugin on)", "Target", "Result"]),
  (["Claude tokens per job (Σ T over \($n) main files)", ($S.off // "incomplete"), (if $S.on == null then "incomplete" else "\($S.on) (savings \($headline | pct))" end),
    "≥ 80% fewer", gate($headline; $t_complete and $headline != null;
      $t_why + (if $t_complete and $headline == null then ["baseline total is zero"] else [] end); ($headline // 0) >= 0.8)] | row),
  (["Usable answers", "\($u_off) of \($n)", "\($u_on) of \($n)", "≥ \($u_target) of 10", gate($u_on; ($u_why | length) == 0; $u_why; $u_on >= $u_target)] | row),
  "",
  "- Fixed cost per session: \(if $fixed == null then "incomplete" else "\($fixed) tokens (\(if $C.on.usd == null or $C.off.usd == null then "USD n/a" else ($C.on.usd - $C.off.usd | usd) end))" end).",
  "- Break-even: \(if $fixed == null or $gain == null then "incomplete" elif $gain <= 0 then "never (delegation costs more per job)" else (($fixed / $gain) | ceil | tostring) + " job(s) per session" end)\(if ($corpus_why | length) > 0 and $gain != null then " (incomplete: \($corpus_why | join("; ")))" else "" end).",
  "- Not gated: Σ job USD off \($S.usd_off | usd), on \($S.usd_on | usd) (savings \(ratio($S.usd_on; $S.usd_off) | pct)); mean context growth off \($S.g_off | na), on \($S.g_on | na) tokens.",
  "- Operator review: \(if $op_n == 0 then "not done yet" else "agreed on \($op_agree) of \($op_n)" end).",
  "",
  "## Fixed cost (median control)", "",
  table(["config", "input", "cache_creation", "cache_read", "output", "T", "USD", "context", "control spread (T)"]),
  (("off", "on") as $c | [$c, $C[$c].input, $C[$c].cache_creation, $C[$c].cache_read, $C[$c].output,
     (if $C[$c].complete then $C[$c].T else "incomplete (\($C[$c].counted)/\($ctl_reps))" end), ($C[$c].usd | usd), $C[$c].ctx_max, $C[$c].spread] | row),
  "",
  "## Main jobs", "",
  table(["id", "type", "task", "size", "T off", "T on", "savings T", "savings USD", "growth off", "growth on", "turns off", "turns on", "status off", "status on", "TTFT s", "local s", "e2e off s", "e2e on s", "slow", "usable off", "usable on", "notes"]),
  ($M[] | [.id, .type, .task, bucket, jcell("off"), jcell("on"), (.savings | pct), (.savings_usd | pct), .off.growth, .on.growth, .off.turns, .on.turns,
           (.off.status | status_cell), (.on.status | status_cell), (.on.ttft_s | sec),
           (if .on.local_s != null then (.on.local_s | sec) elif .on.e2e_s != null then "\(.on.e2e_s | sec) (session)" else "n/a" end),
           (.off.e2e_s | sec), (.on.e2e_s | sec), slowcell,
           (.off.usable | ucell), (.on.usable | ucell),
           ([(if .on.r1.also_read then "on: also opened the file" else empty end),
             (("off", "on") as $c | select(.[$c].r1.usage_match == false) | "\($c): usage differs from modelUsage"),
             (("off", "on") as $c | .[$c].r1.denials // [] | select(length > 0) | "\($c) denied: \(unique | join(" "))"),
             (("off", "on") as $c | .[$c].r1.plugin_denials // [] | select(length > 0) | "\($c) PLUGIN denied: \(unique | join(" "))"),
             (("off", "on") as $c | .[$c].usable.why // empty | select(startswith("mechanical")) | "\($c) \(.)")] | join("; "))] | row),
  "",
  "## Per-field breakdown (raw run totals)", "",
  table(["id", "config", "turns", "input", "cache_creation", "cache_read", "output", "T", "USD", "context"]),
  (("off", "on") as $c | ["control", $c, $C[$c].turns, $C[$c].input, $C[$c].cache_creation, $C[$c].cache_read, $C[$c].output, $C[$c].T, ($C[$c].usd | usd), $C[$c].ctx_max] | row),
  ($F[] | . as $f | ("off", "on") as $c | $f[$c] | select(.complete)
     | [$f.id, $c, .turns, .input, .cache_creation, .cache_read, .output, .T, (.usd | usd), .ctx_max] | row),
  "",
  "## Threshold (per size; small files are the median of their reps)", "",
  table(["id", "size", "job off", "job on", "savings T", "ok reps off", "ok reps on", "TTFT s", "local s", "e2e off s", "e2e on s", "slow", "usable off", "usable on"]),
  ($F | sort_by(.chars)[] | [.id, bucket, jcell("off"), jcell("on"), (.savings | pct), "\(.off.ok_reps)/\(.off.want)", "\(.on.ok_reps)/\(.on.want)",
     (.on.ttft_s | sec), (if .on.local_s != null then (.on.local_s | sec) elif .on.e2e_s != null then "\(.on.e2e_s | sec) (session)" else "n/a" end),
     (.off.e2e_s | sec), (.on.e2e_s | sec), slowcell,
     (.off.usable | ucell), (.on.usable | ucell)] | row)
end
