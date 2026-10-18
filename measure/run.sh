#!/usr/bin/env bash
# The measurement: bash measure/run.sh
#   preflight, corpus (frozen manifest, or a fresh pick), warm-ups, no-file controls, jobs, the judge pass and the
#   report. Writes <run-dir>/results.md (docs/results.md too with MEASURE_PUBLISH=1 on a full run) and prints the private run dir. Every session is a real `claude -p` run.
# bash measure/run.sh --resume <run-dir>: continue a run that stopped; every run whose facts/<name>.json exists is
#   kept as is (delete one to redo it), and the judge keeps its stored verdicts.
# bash measure/run.sh --report <run-dir>: re-render a stored run (mechanical checks, operator verdicts, tables);
#   no new sessions.
#
# Private state lives under MEASURE_HOME (default $HOME/.cache/local-llm-measure), outside every allowed folder:
# corpus.tsv (the frozen manifest, with paths), runs/<stamp>/ (traces, answers, the graded file copies, judge prompts,
# review.md). Sessions run in an empty temp dir outside $HOME (see work_dir in lib.sh).
# Env: MEASURE_HOME; MEASURE_MODEL (empty = Claude Code's default model, unpinned); MEASURE_LOCAL_MODEL
# (qwen3.6-35b-a3b-splash: LM Studio must list it, and the plugin snapshots pin it); MEASURE_RESELECT=1 (pick the
# corpus again); MEASURE_ALLOW_SHORT=1 (run a manifest short of 10 main files or a small slot: an incomplete private
# report whose gates cannot pass); MEASURE_CONFIGS ("off on"); MEASURE_ONLY (space-separated ids, e.g. "f01": a
# partial run, also incomplete and private); MEASURE_JUDGE_MODEL, MEASURE_JUDGE_JOBS (see judge.sh).
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$MDIR/.." && pwd -P)"
# shellcheck source=lib.sh
. "$MDIR/lib.sh"
MEASURE_HOME="${MEASURE_HOME:-$HOME/.cache/local-llm-measure}"
CLAUDE="${MEASURE_CLAUDE:-claude}"
ENDPOINT="http://127.0.0.1:1234"
CTL_REPS=3; SMALL_REPS=3; RUN_TIMEOUT_SEC=300
die() { echo "measure: $*" >&2; exit 1; }

MODE=new
case "${1:-}" in
  --report)
    RUN_DIR=$(cd "${2:?usage: run.sh --report <run-dir>}" && pwd -P) || die "no such run dir: $2"
    bash "$MDIR/judge.sh" "$RUN_DIR" --mech-only || die "mechanical checks failed"
    bash "$MDIR/report.sh" "$RUN_DIR" "$(results_path "$RUN_DIR" "$REPO")" || die "report failed"
    exit 0 ;;
  --resume)
    RUN_DIR=$(cd "${2:?usage: run.sh --resume <run-dir>}" && pwd -P) || die "no such run dir: $2"; MODE=resume   # sessions cd away
    [ -s "$RUN_DIR/meta.json" ] && [ -s "$RUN_DIR/corpus.tsv" ] || die "$RUN_DIR is not a run dir" ;;
  "") ;;
  *) die "unknown argument: $1 (use --resume <run-dir> or --report <run-dir>)" ;;
esac
if [ "$MODE" = resume ]; then   # a resumed run keeps the settings it started with
  CONFIGS=$(jq -r .configs "$RUN_DIR/meta.json"); ONLY=$(jq -r '.only // ""' "$RUN_DIR/meta.json")
  MODEL=$(jq -r .model "$RUN_DIR/meta.json"); LOCAL_MODEL=$(jq -r .local_model "$RUN_DIR/meta.json")
else
  CONFIGS="${MEASURE_CONFIGS:-off on}"; ONLY="${MEASURE_ONLY:-}"; MODEL="${MEASURE_MODEL:-}"
  LOCAL_MODEL="${MEASURE_LOCAL_MODEL:-qwen3.6-35b-a3b-splash}"
fi

# --- preflight: nothing is spent unless every check passes ---------------------------------------------------
for tool in "$CLAUDE" jq node curl shasum git; do command -v "$tool" >/dev/null 2>&1 || die "$tool is required"; done
[ -n "$TIMEOUT" ] || die "timeout (or gtimeout) is required; on macOS: brew install coreutils"
MIN_DELEGATE_CHARS=$(node --input-type=module -e 'const { MIN_DELEGATE_CHARS } = await import(process.argv[2]); console.log(MIN_DELEGATE_CHARS)' read-floor "$REPO/scripts/context-cap.mjs") \
  || die "could not read MIN_DELEGATE_CHARS"
mkdir -p "$MEASURE_HOME" && chmod 700 "$MEASURE_HOME" || die "cannot create $MEASURE_HOME"
MEASURE_HOME="$(cd "$MEASURE_HOME" && pwd -P)"
case "$MEASURE_HOME/" in
  "$HOME/github/"*|"$HOME/catalyst/"*) die "MEASURE_HOME must sit outside \$HOME/github and \$HOME/catalyst: traces hold file text" ;;
esac
case " $CONFIGS " in *" on "*)
  models=$(curl -s -m 5 "$ENDPOINT/v1/models") || die "LM Studio is unreachable at $ENDPOINT (start its server)"
  ids=$(jq -r '[.data[]?.id] | join(", ")' <<<"$models" 2>/dev/null) || die "LM Studio at $ENDPOINT answered /v1/models with something that is not JSON"
  jq -e --arg m "$LOCAL_MODEL" '[.data[]?.id] | index($m) != null' >/dev/null <<<"$models" \
    || die "LM Studio is up but does not list MEASURE_LOCAL_MODEL=$LOCAL_MODEL (listed: ${ids:-none}); load it or set MEASURE_LOCAL_MODEL" ;;
esac

# --- corpus: reuse the frozen manifest; pick a new one only on the first run or MEASURE_RESELECT=1 -------------
MANIFEST="$MEASURE_HOME/corpus.tsv"
RULE="$MEASURE_HOME/corpus.rule"   # selector_rule (lib.sh) of the rule that froze the manifest
if [ "$MODE" = new ]; then
  if [ ! -s "$MANIFEST" ] || [ "${MEASURE_RESELECT:-}" = 1 ]; then
    cutoff=$(date +%s)
    echo "selecting the corpus (cutoff $(date -r "$cutoff" +%Y-%m-%dT%H:%M:%S))"
    (umask 077 && bash "$MDIR/select-corpus.sh" "$cutoff" > "$MANIFEST.new") || die "corpus selection crashed (see its warnings above)"
    [ -s "$MANIFEST.new" ] || die "corpus selection found no files"
    mv "$MANIFEST.new" "$MANIFEST" && echo "$cutoff" > "$MEASURE_HOME/corpus.cutoff" \
      && selector_rule > "$RULE" || die "writing the manifest"
  fi
  [ "$(cat "$RULE" 2>/dev/null)" = "$(selector_rule)" ] \
    || die "the corpus rule (measure/select-corpus.sh or measure/entropy.mjs) changed since the manifest was frozen; MEASURE_RESELECT=1 picks the corpus again"
  short=$(corpus_shortfall "$MANIFEST")
  if [ -n "$short" ]; then
    [ "${MEASURE_ALLOW_SHORT:-}" = 1 ] || die "the manifest is short: $short. MEASURE_RESELECT=1 picks again; MEASURE_ALLOW_SHORT=1 runs it anyway, with an incomplete private report"
    echo "warning: the manifest is short ($short); this run's report is incomplete and private" >&2
  fi

  RUN_DIR="$MEASURE_HOME/runs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$RUN_DIR/traces" "$RUN_DIR/facts" "$RUN_DIR/judge" "$RUN_DIR/files" || die "mkdir $RUN_DIR"
  if [ -n "$ONLY" ]; then
    for id in $ONLY; do [ -n "$(manifest_field "$MANIFEST" "$id" 1)" ] || die "MEASURE_ONLY names $id, which is not in the manifest"; done
    awk -F'\t' -v only=" $ONLY " 'index(only, " " $1 " ") > 0' "$MANIFEST" > "$RUN_DIR/corpus.tsv"
  else
    cp "$MANIFEST" "$RUN_DIR/corpus.tsv" || die "copying the manifest"
  fi

  # Plugin snapshots: this checkout's plugin with the local model pinned, and a copy whose skill floor is 1k.
  for d in plugin plugin-lowfloor; do
    copy_plugin "$REPO" "$RUN_DIR/$d" || die "copying the plugin to $RUN_DIR/$d"
    jq --arg m "$LOCAL_MODEL" '.userConfig.model.default = $m' "$REPO/.claude-plugin/plugin.json" > "$RUN_DIR/$d/.claude-plugin/plugin.json" \
      || die "pinning the model in $RUN_DIR/$d"
  done
  lower_floor "$RUN_DIR/plugin-lowfloor" \
    || die "could not lower the 30k delegation floor: the skill's size-range sentences (30k with the cap) or MIN_DELEGATE_CHARS changed; update lower_floor in measure/lib.sh"

  WORK=$(work_dir) || die "the session cwd must sit outside \$HOME; set TMPDIR to a folder outside it"
  cutoff_epoch=$(cat "$MEASURE_HOME/corpus.cutoff" 2>/dev/null) && [[ "$cutoff_epoch" =~ ^[0-9]+$ ]] \
    || die "$MEASURE_HOME/corpus.cutoff is missing or not an epoch; MEASURE_RESELECT=1 picks the corpus again"
  jq -n --arg date_start "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg cutoff "$(date -r "$cutoff_epoch" +%Y-%m-%d)" \
    --arg repo_sha "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    --argjson repo_dirty "$([ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] && echo true || echo false)" \
    --arg claude_version "$("$CLAUDE" --version 2>/dev/null | head -n 1)" \
    --arg server_pin "$(grep -oE '@houtini/lm@[0-9.]+' "$REPO/scripts/launch-server.sh" | head -n 1)" \
    --arg lms_version "$( (lms version 2>/dev/null || true) | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^CLI commit: */commit /p' | head -n 1)" \
    --arg model "$MODEL" --arg local_model "$LOCAL_MODEL" --arg run_dir "$RUN_DIR" --arg work_dir "$WORK" \
    --arg configs "$CONFIGS" --arg only "$ONLY" --argjson ctl_reps "$CTL_REPS" --argjson small_reps "$SMALL_REPS" \
    --argjson partial "$([ -n "$ONLY" ] && echo true || echo false)" \
    --argjson allow_short "$([ -n "$(corpus_shortfall "$MANIFEST")" ] && echo true || echo false)" \
    '{date_start: $date_start, date_end: null, cutoff: $cutoff, repo_sha: $repo_sha, repo_dirty: $repo_dirty,
      claude_version: $claude_version, server_pin: $server_pin, lms_version: (if $lms_version == "" then "unknown" else $lms_version end),
      model: $model, local_model: $local_model, run_dir: $run_dir, work_dir: $work_dir, configs: $configs, only: $only,
      ctl_reps: $ctl_reps, small_reps: $small_reps, partial: $partial, allow_short: $allow_short}' > "$RUN_DIR/meta.json" \
    || die "writing meta.json"
else
  wd=$(jq -r '.work_dir // empty' "$RUN_DIR/meta.json"); [ -n "$wd" ] || die "$RUN_DIR has no recorded session cwd; it predates --resume"
  WORK=$(work_dir "$wd") || die "cannot recreate the run's session cwd $wd outside \$HOME"
  echo "resuming $RUN_DIR: runs with stored facts are kept"
fi
trap 'rmdir "$WORK" 2>/dev/null' EXIT

# --- runs ------------------------------------------------------------------------------------------------------
# run_one <name> <cfg> <kind> <id> <rep> <path> <prompt> <plugin-dir>; a run with stored facts is kept (--resume)
run_one() {
  local t="$RUN_DIR/traces/$1.jsonl" rc start
  if [ -s "$RUN_DIR/facts/$1.json" ]; then echo "  $1: kept ($(jq -r .status "$RUN_DIR/facts/$1.json"))"; return; fi
  local args=(-p "$7" --output-format stream-json --verbose --setting-sources project --no-session-persistence
              --add-dir "$HOME/github" --add-dir "$HOME/catalyst")
  [ -z "$MODEL" ] || args+=(--model "$MODEL")
  [ "$2" = off ] || args+=(--plugin-dir "$8")
  start=$SECONDS
  # the plugin's delegate_tasks default is off; "on" runs measure delegation, so opt every corpus task kind in
  # (an explicit CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS, even empty, wins)
  (cd "$WORK" && export CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS="${CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS-classify,extract,summarize}" && ENABLE_CLAUDEAI_MCP_SERVERS=false "$TIMEOUT" "$RUN_TIMEOUT_SEC" "$CLAUDE" "${args[@]}" > "$t" 2> "$t.err" < /dev/null)
  rc=$?
  trace_facts "$RUN_DIR/facts/.$1" "$t" "$1" "$2" "$3" "$4" "$5" "$6" "$rc" "$((SECONDS - start))" > "$RUN_DIR/facts/$1.json.new" \
    && mv "$RUN_DIR/facts/$1.json.new" "$RUN_DIR/facts/$1.json" || die "writing facts for $1"
  jq -r '"  \(.run): \(.status)\(if .stage then " (" + .stage + ")" else "" end)  T=\(.T)  turns=\(.turns)  \(.wall_s)s\(if .footer then "  local total \(.footer.total_s)s" else "" end)"' \
    "$RUN_DIR/facts/$1.json"
  if [ "$(jq -r .status "$RUN_DIR/facts/$1.json")" != ok ] && [ -s "$t.err" ]; then echo "    stderr: $(head -n 1 "$t.err" | cut -c1-200)"; fi
}
# job <id> <cfg> <rep>: one job run, unless the file changed since the manifest froze it (checked before and after)
job() {
  local name="$1-$2-$3" path task prompt rc st plugin="$RUN_DIR/plugin"
  if [ -s "$RUN_DIR/facts/$name.json" ]; then echo "  $name: kept ($(jq -r .status "$RUN_DIR/facts/$name.json"))"; return; fi
  path=$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 8); task=$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 4)
  if [ "$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 2)" != main ] \
      || [ "$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 5)" -lt "$MIN_DELEGATE_CHARS" ]; then
    plugin="$RUN_DIR/plugin-lowfloor"
  fi
  snapshot_ok "$RUN_DIR" "$1"; rc=$?
  if [ "$rc" -ne 0 ]; then
    st=$([ "$rc" -eq 1 ] && echo corpus-changed || echo snapshot-failed)
    jq -nc --arg run "$name" --arg cfg "$2" --arg id "$1" --argjson rep "$3" --arg st "$st" \
      '{run: $run, cfg: $cfg, kind: "job", id: $id, rep: $rep, status: $st, T: null}' > "$RUN_DIR/facts/$name.json.new" \
      && mv "$RUN_DIR/facts/$name.json.new" "$RUN_DIR/facts/$name.json" || die "writing facts for $name"
    echo "  $name: FAILED: $st"; return
  fi
  prompt=$(task_field "$task" prompt "$path") || die "tasks.json has no prompt for task '$task' ($1)"
  run_one "$name" "$2" job "$1" "$3" "$path" "$prompt" "$plugin"
  if ! live_unchanged "$RUN_DIR" "$1"; then   # the session read a file that changed meanwhile: usage kept, job failed
    jq -c '.status = "corpus-changed"' "$RUN_DIR/facts/$name.json" > "$RUN_DIR/facts/$name.json.new" \
      && mv "$RUN_DIR/facts/$name.json.new" "$RUN_DIR/facts/$name.json" || die "marking $name corpus-changed"
    echo "  $name: FAILED: corpus-changed (the file changed during the session)"
  fi
}

CTL_PROMPT=$(jq -er '.control_prompt | strings' "$MDIR/tasks.json") || die "tasks.json has no control_prompt"
echo "run dir: $RUN_DIR"
echo "warm-ups and controls"
for c in $CONFIGS; do run_one "warm-$c" "$c" warm "" 0 "" "$CTL_PROMPT" "$RUN_DIR/plugin"; done
for r in $(seq 1 "$CTL_REPS"); do
  for c in $CONFIGS; do run_one "ctl-$c-$r" "$c" ctl "" "$r" "" "$CTL_PROMPT" "$RUN_DIR/plugin"; done
done
echo "main jobs"
for id in $(awk -F'\t' '$2 == "main" {print $1}' "$RUN_DIR/corpus.tsv"); do
  for c in $CONFIGS; do job "$id" "$c" 1; done
done
small=$(awk -F'\t' '$2 != "main" {print $1}' "$RUN_DIR/corpus.tsv")
if [ -n "$small" ]; then
  echo "small jobs"
  for r in $(seq 1 "$SMALL_REPS"); do
    for id in $small; do for c in $CONFIGS; do job "$id" "$c" "$r"; done; done
  done
fi

echo "quality pass"
bash "$MDIR/judge.sh" "$RUN_DIR" || die "judge pass failed"
jq --arg d "$(date +%Y-%m-%dT%H:%M:%S%z)" '.date_end = $d' "$RUN_DIR/meta.json" > "$RUN_DIR/meta.json.new" \
  && mv "$RUN_DIR/meta.json.new" "$RUN_DIR/meta.json" || die "updating meta.json"
bash "$MDIR/report.sh" "$RUN_DIR" "$(results_path "$RUN_DIR" "$REPO")" || die "report failed"
echo "$RUN_DIR"
