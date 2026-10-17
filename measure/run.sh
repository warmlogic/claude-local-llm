#!/usr/bin/env bash
# The measurement: bash measure/run.sh
#   preflight, corpus (frozen manifest, or a fresh pick), warm-ups, no-file controls, jobs, the judge pass and the
#   report. Writes docs/results.md and prints the private run dir. Every session is a real `claude -p` run.
# bash measure/run.sh --report <run-dir>: re-render a stored run (mechanical checks, operator verdicts, tables);
#   no new sessions.
#
# Private state lives under MEASURE_HOME (default $HOME/.cache/local-llm-measure), outside every allowed folder:
# corpus.tsv (the frozen manifest, with paths), runs/<stamp>/ (traces, answers, the graded file copies, judge prompts,
# review.md).
# Sessions run in an empty temp dir outside $HOME (see work_dir in lib.sh).
# Env: MEASURE_HOME; MEASURE_MODEL (empty = Claude Code's default model, unpinned); MEASURE_LOCAL_MODEL
# (qwen3.6-35b-a3b-splash, must be listed by LM Studio); MEASURE_RESELECT=1 (pick the corpus again);
# MEASURE_CONFIGS ("off on"); MEASURE_ONLY (space-separated ids, e.g. "f01": a partial run, whose results go to
# <run-dir>/results.md instead of docs/results.md); MEASURE_JUDGE_MODEL, MEASURE_JUDGE_JOBS (see judge.sh).
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$MDIR/.." && pwd -P)"
# shellcheck source=lib.sh
. "$MDIR/lib.sh"
MEASURE_HOME="${MEASURE_HOME:-$HOME/.cache/local-llm-measure}"
CONFIGS="${MEASURE_CONFIGS:-off on}"
ONLY="${MEASURE_ONLY:-}"
MODEL="${MEASURE_MODEL:-}"
LOCAL_MODEL="${MEASURE_LOCAL_MODEL:-qwen3.6-35b-a3b-splash}"
CLAUDE="${MEASURE_CLAUDE:-claude}"
ENDPOINT="http://127.0.0.1:1234"
FILE_TOOL="mcp__plugin_local-llm_local-llm__code_task_files"
CTL_REPS=3; SMALL_REPS=3; RUN_TIMEOUT_SEC=300
die() { echo "measure: $*" >&2; exit 1; }

results_path() { if [ "$(jq -r .partial "$1/meta.json")" = true ]; then echo "$1/results.md"; else echo "$REPO/docs/results.md"; fi; }

if [ "${1:-}" = --report ]; then
  RUN_DIR="${2:?usage: run.sh --report <run-dir>}"
  bash "$MDIR/judge.sh" "$RUN_DIR" --mech-only || die "mechanical checks failed"
  bash "$MDIR/report.sh" "$RUN_DIR" "$(results_path "$RUN_DIR")" || die "report failed"
  exit 0
fi

# --- preflight: nothing is spent unless every check passes ---------------------------------------------------
for tool in "$CLAUDE" jq node curl shasum git; do command -v "$tool" >/dev/null 2>&1 || die "$tool is required"; done
[ -n "$TIMEOUT" ] || die "timeout (or gtimeout) is required; on macOS: brew install coreutils"
mkdir -p "$MEASURE_HOME" && chmod 700 "$MEASURE_HOME" || die "cannot create $MEASURE_HOME"
MEASURE_HOME="$(cd "$MEASURE_HOME" && pwd -P)"
case "$MEASURE_HOME/" in
  "$HOME/github/"*|"$HOME/catalyst/"*) die "MEASURE_HOME must sit outside \$HOME/github and \$HOME/catalyst: traces hold file text" ;;
esac
case " $CONFIGS " in *" on "*)
  curl -s -m 5 "$ENDPOINT/v1/models" | jq -e --arg m "$LOCAL_MODEL" '[.data[]?.id] | index($m) != null' >/dev/null 2>&1 \
    || die "LM Studio at $ENDPOINT does not list $LOCAL_MODEL" ;;
esac

# --- corpus: reuse the frozen manifest; pick a new one only on the first run or MEASURE_RESELECT=1 -------------
MANIFEST="$MEASURE_HOME/corpus.tsv"
if [ ! -s "$MANIFEST" ] || [ "${MEASURE_RESELECT:-}" = 1 ]; then
  cutoff=$(date +%s)
  echo "selecting the corpus (cutoff $(date -r "$cutoff" +%Y-%m-%dT%H:%M:%S))"
  (umask 077 && bash "$MDIR/select-corpus.sh" "$cutoff" > "$MANIFEST.new") && [ -s "$MANIFEST.new" ] || die "corpus selection found no files"
  mv "$MANIFEST.new" "$MANIFEST" && echo "$cutoff" > "$MEASURE_HOME/corpus.cutoff" || die "writing the manifest"
fi
rows=$(wc -l < "$MANIFEST" | tr -d ' ')
[ "$rows" -eq 13 ] || echo "warning: the manifest has $rows files, not 13 (10 main + 3 small)" >&2

RUN_DIR="$MEASURE_HOME/runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR/traces" "$RUN_DIR/facts" "$RUN_DIR/judge" "$RUN_DIR/files" || die "mkdir $RUN_DIR"
# The sessions' cwd: empty, constant for the run, and outside $HOME. Under $HOME, Claude Code finds
# $HOME/.claude/CLAUDE.md while walking the cwd's ancestors and loads the user's own instructions as project memory.
WORK=$(work_dir) || die "the session cwd must sit outside \$HOME; set TMPDIR to a folder outside it"
trap 'rmdir "$WORK" 2>/dev/null' EXIT
if [ -n "$ONLY" ]; then
  awk -F'\t' -v only=" $ONLY " 'index(only, " " $1 " ") > 0' "$MANIFEST" > "$RUN_DIR/corpus.tsv"
  [ -s "$RUN_DIR/corpus.tsv" ] || die "MEASURE_ONLY=\"$ONLY\" names no manifest id"
else
  cp "$MANIFEST" "$RUN_DIR/corpus.tsv" || die "copying the manifest"
fi

# --- plugin snapshots: the repo as committed in this checkout, and a copy whose skill floor is 1k ---------------
for d in plugin plugin-lowfloor; do
  mkdir -p "$RUN_DIR/$d" && cp -R "$REPO/.claude-plugin" "$REPO/.mcp.json" "$REPO/package.json" "$REPO/scripts" \
    "$REPO/skills" "$REPO/hooks" "$RUN_DIR/$d/" || die "copying the plugin to $RUN_DIR/$d"
done
SKILL_LOW="$RUN_DIR/plugin-lowfloor/skills/delegate-local/SKILL.md"
n_floor=$(grep -oE '(^|[^0-9])10k' "$SKILL_LOW" | wc -l | tr -d ' ')
sed -i.bak -E 's/(^|[^0-9])10k/\11k/g' "$SKILL_LOW" && rm -f "$SKILL_LOW.bak"
[ "$n_floor" -eq 2 ] && ! grep -q '10k' "$SKILL_LOW" || die "the low-floor skill copy expected exactly 2 '10k' floors (found $n_floor)"

cutoff_epoch=$(cat "$MEASURE_HOME/corpus.cutoff" 2>/dev/null || stat -f %m "$MANIFEST")
jq -n --arg date_start "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg cutoff "$(date -r "$cutoff_epoch" +%Y-%m-%d)" \
  --arg repo_sha "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --argjson repo_dirty "$([ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] && echo true || echo false)" \
  --arg claude_version "$("$CLAUDE" --version 2>/dev/null | head -n 1)" \
  --arg server_pin "$(grep -oE '@houtini/lm@[0-9.]+' "$REPO/scripts/launch-server.sh" | head -n 1)" \
  --arg lms_version "$( (lms version 2>/dev/null || true) | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^CLI commit: */commit /p' | head -n 1)" \
  --arg model "$MODEL" --argjson ctl_reps "$CTL_REPS" --arg run_dir "$RUN_DIR" --argjson partial "$([ -n "$ONLY" ] && echo true || echo false)" \
  --arg configs "$CONFIGS" \
  '{date_start: $date_start, date_end: null, cutoff: $cutoff, repo_sha: $repo_sha, repo_dirty: $repo_dirty,
    claude_version: $claude_version, server_pin: $server_pin, lms_version: (if $lms_version == "" then "unknown" else $lms_version end),
    model: $model, ctl_reps: $ctl_reps, run_dir: $run_dir, partial: $partial, configs: $configs}' > "$RUN_DIR/meta.json" \
  || die "writing meta.json"

# --- runs ------------------------------------------------------------------------------------------------------
# facts <trace> <name> <cfg> <kind> <id> <rep> <path> <rc>: trace.jq's output plus the run's identity
facts() {
  jq -cR 'fromjson? // empty' "$1" 2>/dev/null \
    | jq -s -L "$MDIR" --arg path "$7" --arg cfg "$3" --arg kind "$4" --argjson rc "$8" --arg ft "$FILE_TOOL" -f "$MDIR/trace.jq" \
    | jq -c --arg run "$2" --arg cfg "$3" --arg kind "$4" --arg id "$5" --argjson rep "$6" '. + {run: $run, cfg: $cfg, kind: $kind, id: $id, rep: $rep}' \
    || jq -nc --arg run "$2" --arg cfg "$3" --arg kind "$4" --arg id "$5" --argjson rep "$6" \
         '{run: $run, cfg: $cfg, kind: $kind, id: $id, rep: $rep, status: "unknown", T: null}'
}
# run_one <name> <cfg> <kind> <id> <rep> <path> <prompt> <plugin-dir>
run_one() {
  local t="$RUN_DIR/traces/$1.jsonl" rc
  local args=(-p "$7" --output-format stream-json --verbose --setting-sources project --no-session-persistence
              --add-dir "$HOME/github" --add-dir "$HOME/catalyst")
  [ -z "$MODEL" ] || args+=(--model "$MODEL")
  [ "$2" = off ] || args+=(--plugin-dir "$8")
  (cd "$WORK" && ENABLE_CLAUDEAI_MCP_SERVERS=false "$TIMEOUT" "$RUN_TIMEOUT_SEC" "$CLAUDE" "${args[@]}" > "$t" 2> "$t.err" < /dev/null)
  rc=$?
  facts "$t" "$1" "$2" "$3" "$4" "$5" "$6" "$rc" > "$RUN_DIR/facts/$1.json"
  jq -r '"  \(.run): \(.status)  T=\(.T)  turns=\(.turns)  \((.duration_ms // 0) / 1000 | floor)s\(if .footer then "  local total \(.footer.total_s)s" else "" end)"' \
    "$RUN_DIR/facts/$1.json"
}
# job <id> <cfg> <rep>: one job run, unless the file changed since the manifest froze it (checked before and after
# the session). The first job of a file keeps a hash-verified private copy in files/<id>, the text the quality pass
# grades against.
job() {
  local path task want snap="$RUN_DIR/files/$1" plugin="$RUN_DIR/plugin"
  path=$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 8); task=$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 4)
  want=$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 7)
  [ "$(manifest_field "$RUN_DIR/corpus.tsv" "$1" 2)" = main ] || plugin="$RUN_DIR/plugin-lowfloor"
  [ -f "$snap" ] || { cp "$path" "$snap.new" 2>/dev/null && [ "$(sha256_of "$snap.new")" = "$want" ] && mv "$snap.new" "$snap"; }
  rm -f "$snap.new"
  if [ ! -f "$snap" ] || [ "$(sha256_of "$path")" != "$want" ]; then
    jq -nc --arg run "$1-$2-$3" --arg cfg "$2" --arg id "$1" --argjson rep "$3" \
      '{run: $run, cfg: $cfg, kind: "job", id: $id, rep: $rep, status: "corpus-changed", T: null}' > "$RUN_DIR/facts/$1-$2-$3.json"
    echo "  $1-$2-$3: FAILED: corpus-changed"; return
  fi
  run_one "$1-$2-$3" "$2" job "$1" "$3" "$path" "$(task_field "$task" prompt "$path")" "$plugin"
  # The session read the live file: if it changed meanwhile, the answer is not about the graded copy. The run keeps
  # its usage but fails corpus-changed. (A change undone before the session ends goes unseen; that is the limit.)
  if [ "$(sha256_of "$path")" != "$want" ]; then
    jq -c '.status = "corpus-changed"' "$RUN_DIR/facts/$1-$2-$3.json" > "$RUN_DIR/facts/$1-$2-$3.json.new" \
      && mv "$RUN_DIR/facts/$1-$2-$3.json.new" "$RUN_DIR/facts/$1-$2-$3.json" || die "marking $1-$2-$3 corpus-changed"
    echo "  $1-$2-$3: FAILED: corpus-changed (the file changed during the session)"
  fi
}

CTL_PROMPT=$(jq -r .control_prompt "$MDIR/tasks.json")
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
bash "$MDIR/report.sh" "$RUN_DIR" "$(results_path "$RUN_DIR")" || die "report failed"
echo "$RUN_DIR"
