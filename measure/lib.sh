# shellcheck shell=bash disable=SC2034
# Shared helpers for run.sh, judge.sh and selftest.sh (sourced; MDIR must be set). Each is small enough to test
# offline, which is why run.sh's file-integrity and output-path rules live here rather than inline.

# task_field <task> <key> [path]: a tasks.json field with <LABELS> and <P> filled in; fails when the field is missing
task_field() {
  jq -er --arg t "$1" --arg k "$2" --arg p "${3:-}" \
    '(.labels | join(", ")) as $l | .tasks[$t][$k] | strings | gsub("<LABELS>"; $l) | gsub("<P>"; $p)' "$MDIR/tasks.json"
}
# manifest_field <manifest> <id> <field-number>: id slot type task chars mtime sha256 path = fields 1..8
manifest_field() { awk -F'\t' -v id="$2" -v f="$3" '$1 == id {print $f}' "$1"; }
# sha256_of <file>: its hex digest, or nothing when unreadable
sha256_of() { shasum -a 256 "$1" 2>/dev/null | cut -c1-64; }
# answer_sha <facts-file>: the digest of a run's answer text; a verdict counts only for the answer it graded
answer_sha() { jq -j '.answer // ""' "$1" 2>/dev/null | shasum -a 256 | cut -c1-64; }
# selector_rule: the fingerprint of the corpus rule (the selector and its entropy guard); a manifest frozen under a
# different fingerprint is refused
selector_rule() { cat "$MDIR/select-corpus.sh" "$MDIR/entropy.mjs" | shasum -a 256 | cut -c1-64; }
TIMEOUT=$(command -v timeout || command -v gtimeout) || TIMEOUT=""
FILE_TOOL="mcp__plugin_local-llm_local-llm__code_task_files"

# trace_facts <scratch-prefix> <trace> <name> <cfg> <kind> <id> <rep> <path> <rc> <wall-s>: trace.jq's facts for one
# run plus its identity, on stdout. A stage that fails gives status facts-error naming the stage, never "unknown";
# a line that is not JSON reaches trace.jq as "__bad__", which fails the run unless it is the last line.
trace_facts() {
  local base="$1" stage="" ident
  ident=$(jq -nc --arg run "$3" --arg cfg "$4" --arg kind "$5" --arg id "$6" --argjson rep "$7" --argjson wall_s "${10}" \
    '{run: $run, cfg: $cfg, kind: $kind, id: $id, rep: $rep, wall_s: $wall_s}' 2>/dev/null) \
    || { echo "trace_facts: rep '$7' or wall seconds '${10}' is not a number for $3" >&2; return 1; }
  jq -cR 'fromjson? // "__bad__"' "$2" > "$base.events" 2> "$base.log" || stage="parse"
  [ -n "$stage" ] || jq -s -L "$MDIR" --arg path "$8" --arg cfg "$4" --arg kind "$5" --argjson rc "$9" --arg ft "$FILE_TOOL" \
    -f "$MDIR/trace.jq" "$base.events" > "$base.trace" 2>> "$base.log" || stage="trace.jq"
  [ -n "$stage" ] || jq -c --argjson i "$ident" '. + $i' "$base.trace" 2>> "$base.log" || stage="merge"
  if [ -n "$stage" ]; then
    jq -nc --argjson i "$ident" --arg stage "$stage" --arg log "$(head -n 1 "$base.log" 2>/dev/null)" \
      '$i + {status: "facts-error", stage: $stage, error: $log, T: null}'
  fi
  rm -f "$base.events" "$base.trace" "$base.log"
}

# work_dir [path]: an empty dir outside $HOME for a session's cwd (from any cwd under $HOME, Claude Code loads
# $HOME/.claude/CLAUDE.md as an ancestor's project memory). With a path (a resumed run), recreates that same dir so
# the session prefix stays identical; without, makes a new one. Prints the resolved path; fails under $HOME.
work_dir() {
  local d parent home
  home=$(cd "$HOME" 2>/dev/null && pwd -P) || home="$HOME"
  if [ -n "${1:-}" ]; then d="$1"; parent=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  else parent=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return 1; fi
  case "$parent/" in "$home/"*|"$HOME/"*) return 1 ;; esac   # refused before anything is created under $HOME
  if [ -n "${1:-}" ]; then mkdir -p "$d" || return 1; else d=$(mktemp -d "$parent/local-llm-measure.XXXXXX") || return 1; fi
  (cd "$d" && pwd -P)
}

# copy_plugin <repo> <dest>: a snapshot of the plugin the harness loads with --plugin-dir. server/ (a bundled MCP
# server) is copied when the checkout has one, so the snapshot matches the plugin before and after it ships one.
copy_plugin() {
  local part parts=(.claude-plugin .mcp.json package.json scripts skills hooks)
  [ -e "$1/server" ] && parts+=(server)
  mkdir -p "$2" || return 1
  for part in "${parts[@]}"; do cp -R "$1/$part" "$2/" || return 1; done
}

# results_path <run-dir> <repo>: where a run's table goes. Only a full run writes the committed docs/results.md;
# a partial run (MEASURE_ONLY) or a run with a short corpus (MEASURE_ALLOW_SHORT) keeps it in the run dir.
results_path() {
  if jq -e '.partial or .allow_short' "$1/meta.json" >/dev/null 2>&1; then echo "$1/results.md"; else echo "$2/docs/results.md"; fi
}

# snapshot_ok <run-dir> <id>: before a job, keep a private copy of the file in files/<id> (first job only, kept only
# when its sha256 matches the frozen manifest). Returns 0 when the copy exists and the live file still matches,
# 1 when the file changed since the freeze (corpus-changed), 2 when the copy could not be made (snapshot-failed).
# The quality pass grades the copy.
snapshot_ok() {
  local m="$1/corpus.tsv" snap="$1/files/$2" path want
  path=$(manifest_field "$m" "$2" 8); want=$(manifest_field "$m" "$2" 7)
  [ -n "$want" ] || return 2
  if [ ! -f "$snap" ]; then
    cp "$path" "$snap.new" 2>/dev/null || { rm -f "$snap.new"; [ -e "$path" ] && return 2; return 1; }
    if [ "$(sha256_of "$snap.new")" = "$want" ]; then mv "$snap.new" "$snap" || return 2; else rm -f "$snap.new"; return 1; fi
  fi
  [ "$(sha256_of "$path")" = "$want" ] || return 1
}
# live_unchanged <run-dir> <id>: after a session, the live file still matches the manifest (a change undone before
# the session ended goes unseen; that is the limit)
live_unchanged() { [ "$(sha256_of "$(manifest_field "$1/corpus.tsv" "$2" 8)")" = "$(manifest_field "$1/corpus.tsv" "$2" 7)" ]; }

# lower_floor <SKILL.md>: rewrite the skill's 10k delegation floor to 1k for the small-file runs. Only the sentences
# that state the size range (they name both the 10k floor and the 60k ceiling) change; the edit fails, leaving the
# file untouched, unless the frontmatter description changed, a body sentence changed, and no 10k is left anywhere.
lower_floor() {
  local f="$1"
  sed -E '/10k/{/60k/s/(^|[^0-9])10k/\11k/g;}' "$f" > "$f.new" || { rm -f "$f.new"; return 1; }
  if grep -qE '^description:.*(^|[^0-9])1k.*60k' "$f.new" \
     && [ "$(grep -vE '^description:' "$f.new" | grep -cE '(^|[^0-9])1k.*60k')" -ge 1 ] && ! grep -q '10k' "$f.new"; then
    mv "$f.new" "$f"
  else rm -f "$f.new"; return 1; fi
}

# corpus_shortfall <manifest>: what a full measurement lacks (fewer than 10 main files, a missing small slot), as
# one line; empty when the manifest is full
corpus_shortfall() {
  awk -F'\t' '$2 == "main" {m++} $2 != "main" {s[$2] = 1}
    END {out = (m + 0 < 10) ? sprintf("%d of 10 main files", m) : ""
         n = split("s2k s5k s10k", slot, " ")
         for (i = 1; i <= n; i++) if (!(slot[i] in s)) out = out (out == "" ? "" : ", ") "no " slot[i] " file"
         print out}' "$1"
}
