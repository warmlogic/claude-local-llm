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
  [ -e "$1/batch" ] && parts+=(batch)
  mkdir -p "$2" || return 1
  for part in "${parts[@]}"; do cp -R "$1/$part" "$2/" || return 1; done
}

# pin_plugin_config <repo> <plugin-copy> <model> [endpoint]: the copy's manifest with the local model pinned (and
# endpoint_url, when given, so sessions use the server whose context was recorded) and allowed_dirs
# defaulting to the corpus roots, read from select-corpus.sh's ROOTS line (its one definition), since the real
# manifest has no default and a headless run cannot be asked.
# Callers must set $MDIR (the measure/ directory) first; returns 1 when select-corpus.sh has no ROOTS line.
pin_plugin_config() {
  local roots
  roots=$(sed -n 's/^ROOTS=(\(.*\))$/\1/p' "$MDIR/select-corpus.sh" | tr -d '"')
  [ -n "$roots" ] || return 1
  jq --arg m "$3" --arg e "${4:-}" --arg r "$roots" '.userConfig.model.default = $m | (if $e != "" then .userConfig.endpoint_url.default = $e else . end) | .userConfig.allowed_dirs.default = ($r | split(" "))' "$1/.claude-plugin/plugin.json" > "$2/.claude-plugin/plugin.json"
}

# results_path <run-dir> <repo>: where a run's table goes. A run's table stays in its run dir; only a full run
# (not MEASURE_ONLY, not MEASURE_ALLOW_SHORT) with MEASURE_PUBLISH=1 writes the committed docs/results.md.
results_path() {
  if [ "${MEASURE_PUBLISH:-}" = 1 ] && jq -e '(.partial or .allow_short) | not' "$1/meta.json" >/dev/null 2>&1; then echo "$2/docs/results.md"; else echo "$1/results.md"; fi
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

# lower_floor <plugin-dir>: lower the delegation floor from 30k to 1k in a plugin copy, for the small-file runs: the
# skill's size-range sentences (they name the 30k floor and the cap) and the size hint's MIN_DELEGATE_CHARS. Fails,
# leaving both files untouched, unless the description and a body sentence changed, no 30k is left in the skill, and
# the constant changed.
lower_floor() {
  local skill="$1/skills/delegate-local/SKILL.md" cap="$1/scripts/context-cap.mjs"
  sed -E '/30k/{/cap/s/(^|[^0-9])30k/\11k/g;}' "$skill" > "$skill.new" \
    && sed -E 's/^(export const MIN_DELEGATE_CHARS = )30_000;/\11_000;/' "$cap" > "$cap.new" || { rm -f "$skill.new" "$cap.new"; return 1; }
  if grep -qE '^description:.*(^|[^0-9])1k.*cap' "$skill.new" \
     && [ "$(grep -vE '^description:' "$skill.new" | grep -cE '(^|[^0-9])1k.*cap')" -ge 1 ] && ! grep -q '30k' "$skill.new" \
     && grep -q '^export const MIN_DELEGATE_CHARS = 1_000;' "$cap.new"; then
    mv "$skill.new" "$skill"; mv "$cap.new" "$cap"
  else rm -f "$skill.new" "$cap.new"; return 1; fi
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

# observe_context <repo> <endpoint> <model>: the context LM Studio reports, as {tokens, source, reason}. tokens is the
# loaded context, or null when the source is not `loaded` (an assumed 32k proves nothing). Asked of scripts/context-cap.mjs,
# the plugin's own lookup, so the record and the plugin's hint agree.
observe_context() {
  LOCAL_LLM_ENDPOINT_URL="$2" LOCAL_LLM_MODEL="$3" node "$1/scripts/context-cap.mjs" 2>/dev/null \
    | jq -ce '{tokens: (if .source == "loaded" then .contextTokens else null end), source, reason: (.reason // null)}' \
    || echo '{"tokens":null,"source":"unknown","reason":"context lookup failed"}'
}

# context_warning <context-json> <model>: what a measurement run should say about the observed context; nothing when
# the loaded context holds the delegation floor. The same derived rule as the size hint: a loaded context whose cap is
# under MIN_DELEGATE_CHARS cannot delegate.
context_warning() {
  local ctx="$1" source tokens
  source=$(jq -r .source <<<"$ctx") && tokens=$(jq -r '.tokens // empty' <<<"$ctx") || return 1
  if [ "$source" != loaded ]; then
    echo "warning: could not read the loaded context ($(jq -r '.reason // .source' <<<"$ctx")); the plugin assumes 32k. Load the model with: lms load $2 --context-length 32768"
  elif node --input-type=module -e 'const { capForContext, MIN_DELEGATE_CHARS } = await import(process.argv[2]); process.exit(capForContext(Number(process.argv[3])) < MIN_DELEGATE_CHARS ? 0 : 1)' \
         read-floor "$MDIR/../scripts/context-cap.mjs" "$tokens"; then
    echo "warning: LM Studio has $tokens tokens loaded, too few for the plugin's 30k-char delegation floor, so delegation jobs will fail. Reload with: lms load $2 --context-length 32768"
  fi
}

# context_mismatch <recorded-json> <observed-json>: a warning when a resumed run sees another context than it started
# with; nothing when it recorded none (an older run, or one without plugin-on sessions).
context_mismatch() {
  [ -n "$1" ] && [ "$1" != null ] || return 0
  [ "$(jq -S -c '{tokens, source}' <<<"$1")" = "$(jq -S -c '{tokens, source}' <<<"$2")" ] \
    || echo "warning: the loaded context changed since this run started (recorded $(jq -c '{tokens, source}' <<<"$1"), now $(jq -c '{tokens, source}' <<<"$2")); the new observation is not recorded"
}
