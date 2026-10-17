#!/usr/bin/env bash
# report.sh <run-dir> <results-md>: renders a run's stored facts, mechanical checks and verdicts into <results-md>
# (ids, types, tasks, size buckets and numbers only) and the private review sheet <run-dir>/review.md.
# Operator verdicts in <run-dir>/review-verdicts.tsv (<id>-<cfg> TAB agree|disagree TAB note) are applied; a line
# that does not parse or names an unknown answer stops the report with its line number.
# Fails when any local-model footer names a model other than the run's pinned MEASURE_LOCAL_MODEL.
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
RUN_DIR="${1:?usage: report.sh <run-dir> <results-md>}"
OUT="${2:?usage: report.sh <run-dir> <results-md>}"
die() { echo "report: $*" >&2; exit 1; }
# shellcheck source=lib.sh
. "$MDIR/lib.sh"
[ -f "$RUN_DIR/meta.json" ] && [ -f "$RUN_DIR/corpus.tsv" ] && [ -d "$RUN_DIR/facts" ] || die "$RUN_DIR is not a run dir"

tmp=$(mktemp -d) || die "mktemp"; trap 'rm -rf "$tmp"' EXIT
cat "$RUN_DIR"/facts/*.json 2>/dev/null | jq -s . > "$tmp/runs.json" || die "unreadable facts"
awk -F'\t' 'BEGIN{OFS="\t"} {print $1, $2, $3, $4, $5}' "$RUN_DIR/corpus.tsv" \
  | jq -R 'split("\t") | {id: .[0], slot: .[1], type: .[2], task: .[3], chars: (.[4] | tonumber)}' | jq -s . > "$tmp/corpus.json" \
  || die "unreadable manifest"
awk -F'\t' '{print $1 "\t" $8}' "$RUN_DIR/corpus.tsv" | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add // {}' > "$tmp/paths.json" \
  || die "unreadable manifest paths"

want=$(jq -r '.local_model // empty' "$RUN_DIR/meta.json")
if [ -n "$want" ]; then
  other=$(jq -r --arg m "$want" '[.[] | .call_footers[]?.model // empty | select(. != $m)] | unique | join(", ")' "$tmp/runs.json") \
    || die "unreadable footers"
  [ -z "$other" ] || die "footers name $other, not the pinned local model $want: the run did not measure that model"
fi

# collect <suffix>: {"<id>-<cfg>": <file contents>} for judge/<id>-<cfg><suffix>
collect() {
  local f out="{}"
  for f in "$RUN_DIR"/judge/*"$1"; do
    [ -s "$f" ] || continue
    out=$(jq --arg k "$(basename "$f" "$1")" --slurpfile v "$f" '. + {($k): $v[0]}' <<<"$out") || die "unreadable $f"
  done
  printf '%s\n' "$out"
}
collect .mech.json > "$tmp/mech.json" || exit 1
collect .verdict.json > "$tmp/verdicts.json" || exit 1
# a verdict graded some other answer (its run was redone) counts as no verdict
for f in "$RUN_DIR"/judge/*.verdict.json; do
  [ -s "$f" ] || continue
  a=$(basename "$f" .verdict.json)
  if [ "$(jq -r '.answer_sha // empty' "$f")" != "$(answer_sha "$RUN_DIR/facts/$a-1.json")" ]; then
    jq --arg a "$a" 'del(.[$a])' "$tmp/verdicts.json" > "$tmp/v.new" && mv "$tmp/v.new" "$tmp/verdicts.json" || die "dropping the stale verdict for $a"
  fi
done

# Operator verdicts: \r stripped, blank lines skipped, anything else must be "<known id>-<cfg> TAB agree|disagree".
: > "$tmp/ops.jsonl"
if [ -f "$RUN_DIR/review-verdicts.tsv" ]; then
  known=$(cd "$RUN_DIR/facts" && ls f*-1.json 2>/dev/null | sed 's/-1\.json$//')
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line=${line%$'\r'}
    [ -n "${line//[[:space:]]/}" ] || continue
    IFS=$'\t' read -r aid verdict note <<<"$line"
    case "$verdict" in agree|disagree) ;; *) die "review-verdicts.tsv line $n: expected <id>-<cfg> TAB agree|disagree TAB note" ;; esac
    grep -qxF -- "$aid" <<<"$known" || die "review-verdicts.tsv line $n: $aid is not an answer in this run"
    jq -nc --arg a "$aid" --arg v "$verdict" --arg note "${note:-}" '{($a): {agree: ($v == "agree"), note: $note}}' >> "$tmp/ops.jsonl" \
      || die "review-verdicts.tsv line $n"
  done < "$RUN_DIR/review-verdicts.tsv"
fi
jq -s 'add // {}' "$tmp/ops.jsonl" > "$tmp/ops.json" || die "operator verdicts"

render() { # <mode> <paths-json-file>
  jq -n --arg mode "$1" --slurpfile paths "$2" --slurpfile runs "$tmp/runs.json" --slurpfile corpus "$tmp/corpus.json" \
    --slurpfile mech "$tmp/mech.json" --slurpfile verdicts "$tmp/verdicts.json" --slurpfile ops "$tmp/ops.json" \
    --slurpfile meta "$RUN_DIR/meta.json" --slurpfile tasks "$MDIR/tasks.json" \
    '{mode: $mode, paths: $paths[0], runs: $runs[0], corpus: $corpus[0], mech: $mech[0], verdicts: $verdicts[0],
      ops: $ops[0], meta: $meta[0], tasks: $tasks[0]}' | jq -r -f "$MDIR/report.jq"
}
echo '{}' > "$tmp/nopaths.json"
render results "$tmp/nopaths.json" > "$tmp/results.md" || die "rendering the results failed"
render review "$tmp/paths.json" > "$RUN_DIR/review.md" || die "rendering the review sheet failed"
mkdir -p "$(dirname "$OUT")" && cp "$tmp/results.md" "$OUT" || die "writing $OUT"
echo "  report: $OUT; review sheet: $RUN_DIR/review.md"
