#!/usr/bin/env bash
# Quality pass: one blind judge call per answer (rep 1 of every job, both configurations).
#   judge.sh <run-dir>              mechanical checks for every answer, then a judge call for each answer that
#                                   ran ok, passed them, and has no stored verdict yet
#   judge.sh <run-dir> --mech-only  mechanical checks only; never starts a session
# Writes <run-dir>/judge/<id>-<cfg>.mech.json and, per judged answer, .prompt, .out.json and .verdict.json.
# The judge sees the full file, the task, the usable definition and the answer, never the configuration: short
# the skill's attribution note (a line like "_Summarized by the local model._") is dropped before it reads the answer.
# Env: MEASURE_JUDGE_MODEL (opus), MEASURE_JUDGE_JOBS (4 in parallel), MEASURE_CLAUDE (claude; tests use a fake).
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
RUN_DIR="${1:?usage: judge.sh <run-dir> [--mech-only]}"
JUDGE_MODEL="${MEASURE_JUDGE_MODEL:-opus}"
JOBS="${MEASURE_JUDGE_JOBS:-4}"
CLAUDE="${MEASURE_CLAUDE:-claude}"
JUDGE_TIMEOUT_SEC=300
# The skill's attribution note ("_Summarized by the local model._", "(Extracted by the local LLM (qwen).)"): a whole
# line that is the attribution and nothing else. A line making any other claim about the local model stays.
ATTRIBUTION_NOTE='^[\s_*(>-]*(summari[sz]ed|classified|extracted|produced|generated|drafted|written|answered|done)\s+(by|with|using)\s+(the\s+)?local\s+(model|llm)(\s*\([^)]{0,60}\))?[\s.!_*)]*$'
# shellcheck source=lib.sh
. "$MDIR/lib.sh"
[ -n "$TIMEOUT" ] || { echo "judge: timeout (or gtimeout) is required" >&2; exit 1; }
die() { echo "judge: $*" >&2; exit 1; }
[ -d "$RUN_DIR/facts" ] && [ -f "$RUN_DIR/corpus.tsv" ] || die "$RUN_DIR has no facts/ or corpus.tsv"
mkdir -p "$RUN_DIR/judge" || die "mkdir judge"

manifest() { manifest_field "$RUN_DIR/corpus.tsv" "$1" "$2"; }

# judge_one <aid>: build the prompt, call the judge, keep its structured output
judge_one() {
  local aid="$1" id="${1%-*}" path task out work
  path=$(manifest "$id" 8); task=$(manifest "$id" 4)
  jq -rn --rawfile file "$path" --arg prompt "$(task_field "$task" prompt "$path")" \
    --arg usable "$(task_field "$task" usable)" --arg ref "$(task_field "$task" reference)" \
    --slurpfile f "$RUN_DIR/facts/$aid-1.json" --arg note "$ATTRIBUTION_NOTE" '
    ($f[0].answer // "" | split("\n") | map(select(test($note; "i") | not)) | join("\n")) as $answer
    | "You are grading one answer that an assistant gave to a task about a file. The full file comes first.\n\n"
      + "<file>\n" + $file + "\n</file>\n\n<task>\n" + $prompt + "\n</task>\n\n"
      + "Usable means: " + $usable + "\n\n"
      + "Step 1: write `reference` from the file alone, before you read the answer: " + $ref + ".\n"
      + "Step 2: read the answer. List in `invented` every claim it makes that the file does not support, and in "
      + "`missed` every reference point it lacks (paraphrase is fine). Set `usable` to true only when both lists are "
      + "empty. Keep `reason` under 300 characters.\n\n<answer>\n" + $answer + "\n</answer>\n"' \
    > "$RUN_DIR/judge/$aid.prompt" || { echo "  judge $aid: could not build the prompt" >&2; return 1; }
  out="$RUN_DIR/judge/$aid.out.json"
  work=$(work_dir) || { echo "  judge $aid: no temp dir outside \$HOME for the cwd" >&2; return 1; }
  (cd "$work" && ENABLE_CLAUDEAI_MCP_SERVERS=false "$TIMEOUT" "$JUDGE_TIMEOUT_SEC" "$CLAUDE" -p --model "$JUDGE_MODEL" \
    --tools "" --setting-sources project --no-session-persistence --output-format json \
    --json-schema "$(cat "$MDIR/judge-schema.json")" < "$RUN_DIR/judge/$aid.prompt" > "$out" 2> "$out.err")
  if jq -e '.structured_output | type == "object" and has("usable")' "$out" >/dev/null 2>&1; then
    jq '.structured_output + {judge_models: (.modelUsage // {} | keys)}' "$out" > "$RUN_DIR/judge/$aid.verdict.json"
    echo "  judge $aid: usable=$(jq -r .usable "$RUN_DIR/judge/$aid.verdict.json")"
  else
    echo "  judge $aid: no structured verdict (see $out.err)" >&2; rmdir "$work"; return 1
  fi
  rmdir "$work" 2>/dev/null
}

if [ "${2:-}" = --one ]; then judge_one "$3"; exit $?; fi

labels=$(jq -c .labels "$MDIR/tasks.json")
todo=()
for f in "$RUN_DIR"/facts/f*-1.json; do
  [ -e "$f" ] || continue
  aid=$(basename "$f" .json); aid="${aid%-1}"; id="${aid%-*}"
  path=$(manifest "$id" 8); task=$(manifest "$id" 4)
  [ -n "$path" ] || die "$id is not in the run's manifest"
  # Grade only against the text that was measured: a file that changed or vanished since the manifest froze it
  # is marked, never graded against different text.
  if [ "$(shasum -a 256 "$path" 2>/dev/null | cut -c1-64)" != "$(manifest "$id" 7)" ]; then
    echo '{"ok":false,"reason":"corpus-changed","extra_text":false}' > "$RUN_DIR/judge/$aid.mech.json"
    echo "  judge $aid: the file changed since the manifest froze it; not graded" >&2
    continue
  fi
  jq '.answer // ""' "$f" | jq -c -L "$MDIR" --arg task "$task" --rawfile file "$path" --argjson labels "$labels" \
    -f "$MDIR/mechanical.jq" > "$RUN_DIR/judge/$aid.mech.json" || die "mechanical check failed to run for $aid"
  [ "${2:-}" = --mech-only ] && continue
  [ "$(jq -r .status "$f")" = ok ] || continue
  jq -e .ok "$RUN_DIR/judge/$aid.mech.json" >/dev/null || continue
  [ -s "$RUN_DIR/judge/$aid.verdict.json" ] || todo+=("$aid")
done
[ "${2:-}" = --mech-only ] && exit 0
[ "${#todo[@]}" -gt 0 ] || { echo "  judge: nothing to judge"; exit 0; }
echo "  judge: ${#todo[@]} answers, $JOBS at a time, model $JUDGE_MODEL"
printf '%s\n' "${todo[@]}" | xargs -P "$JOBS" -I{} bash "$0" "$RUN_DIR" --one {} \
  || die "some answers got no verdict; rerun bash measure/judge.sh $RUN_DIR (stored verdicts are kept), then bash measure/run.sh --report $RUN_DIR"
