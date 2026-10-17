# shellcheck shell=bash disable=SC2034
# Shared helpers for run.sh and judge.sh (sourced; MDIR must be set).

# task_field <task> <key> [path]: a tasks.json field with <LABELS> and <P> filled in
task_field() {
  jq -r --arg t "$1" --arg k "$2" --arg p "${3:-}" \
    '(.labels | join(", ")) as $l | .tasks[$t][$k] | gsub("<LABELS>"; $l) | gsub("<P>"; $p)' "$MDIR/tasks.json"
}
# manifest_field <manifest> <id> <field-number>: id slot type task bytes mtime sha256 path = fields 1..8
manifest_field() { awk -F'\t' -v id="$2" -v f="$3" '$1 == id {print $f}' "$1"; }
TIMEOUT=$(command -v timeout || command -v gtimeout) || TIMEOUT=""
