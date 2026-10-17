#!/usr/bin/env bash
# report.sh <run-dir> <results-md>: renders a run's stored facts, mechanical checks and verdicts into <results-md>
# (ids, types, tasks, size buckets and numbers only) and the private review sheet <run-dir>/review.md.
# Operator verdicts in <run-dir>/review-verdicts.tsv (<id>-<cfg> TAB agree|disagree TAB note) are applied.
set -uo pipefail

MDIR="$(cd "$(dirname "$0")" && pwd -P)"
RUN_DIR="${1:?usage: report.sh <run-dir> <results-md>}"
OUT="${2:?usage: report.sh <run-dir> <results-md>}"
die() { echo "report: $*" >&2; exit 1; }
[ -f "$RUN_DIR/meta.json" ] && [ -f "$RUN_DIR/corpus.tsv" ] && [ -d "$RUN_DIR/facts" ] || die "$RUN_DIR is not a run dir"

tmp=$(mktemp -d) || die "mktemp"; trap 'rm -rf "$tmp"' EXIT
cat "$RUN_DIR"/facts/*.json 2>/dev/null | jq -s . > "$tmp/runs.json" || die "unreadable facts"
awk -F'\t' 'BEGIN{OFS="\t"} {print $1, $2, $3, $4, $5}' "$RUN_DIR/corpus.tsv" \
  | jq -R 'split("\t") | {id: .[0], slot: .[1], type: .[2], task: .[3], bytes: (.[4] | tonumber)}' | jq -s . > "$tmp/corpus.json" \
  || die "unreadable manifest"
awk -F'\t' '{print $1 "\t" $8}' "$RUN_DIR/corpus.tsv" | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add // {}' > "$tmp/paths.json"
# collect <suffix>: {"<id>-<cfg>": <file contents>} for judge/<id>-<cfg><suffix>
collect() {
  local f out="{}"
  for f in "$RUN_DIR"/judge/*"$1"; do
    [ -s "$f" ] || continue
    out=$(jq --arg k "$(basename "$f" "$1")" --slurpfile v "$f" '. + {($k): $v[0]}' <<<"$out") || die "unreadable $f"
  done
  printf '%s\n' "$out"
}
collect .mech.json > "$tmp/mech.json"
collect .verdict.json > "$tmp/verdicts.json"
ops='{}'
if [ -s "$RUN_DIR/review-verdicts.tsv" ]; then
  ops=$(jq -R 'split("\t") | select(length >= 2 and (.[1] == "agree" or .[1] == "disagree")) | {(.[0]): {agree: (.[1] == "agree"), note: (.[2] // "")}}' \
    "$RUN_DIR/review-verdicts.tsv" | jq -s 'add // {}') || die "unreadable review-verdicts.tsv"
fi
printf '%s\n' "$ops" > "$tmp/ops.json"

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
