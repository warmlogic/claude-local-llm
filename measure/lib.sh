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
# work_dir: a new empty dir outside $HOME for a session's cwd (Claude Code would load $HOME/.claude/CLAUDE.md as
# an ancestor's project memory from any cwd under $HOME); prints its resolved path, fails when TMPDIR is under $HOME
work_dir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/local-llm-measure.XXXXXX") && d=$(cd "$d" && pwd -P) || return 1
  case "$d/" in "$HOME/"*) rmdir "$d"; return 1 ;; esac
  printf '%s\n' "$d"
}
