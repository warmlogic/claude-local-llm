#!/usr/bin/env bash
# Picks the measurement corpus by a fixed rule (AGENTS.md, "Measuring"). Prints the private manifest TSV:
# id <TAB> slot <TAB> type <TAB> task <TAB> chars <TAB> mtime_iso <TAB> sha256 <TAB> path
# Paths never leave $MEASURE_HOME: run.sh writes this output there and nowhere else. Sizes are characters (wc -m in
# UTF-8), as the spec states them. Warnings go to stderr and never name a file; a missing root is a warning, and a
# failed filter command exits non-zero ("selection crashed") rather than letting a file through.
# Usage: select-corpus.sh [cutoff_epoch]   (default: now)
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CUTOFF="${1:-$(date +%s)}"
ROOTS=("$HOME/github" "$HOME/catalyst")
SELF_EXCLUDE=("$HOME/github/warmlogic/claude-local-llm" "$HOME/catalyst/projects/local-llm")
EXT_RE='\.(md|markdown|rst|adoc|txt|log|out|jsonl|vtt|srt)$'
SECRET_NAME_RE='(^|/)\.env|(^|[._/-])(secrets?|credentials?|passwords?|passwd|tokens?|private|id_rsa|id_ed25519|keys?)([._-]|$)|\.(pem|key|p12|pfx|kdbx|gpg|asc)$'
LOCK_RE='(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|uv\.lock|poetry\.lock|Cargo\.lock|Gemfile\.lock|go\.sum|composer\.lock)$|\.lock$'
SECRET_BODY_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|AIza[0-9A-Za-z_-]{35}|(password|passwd|secret|api[_-]?key|access[_-]?token)["'\'']?[[:space:]]*[:=][[:space:]]*["'\'']?[^[:space:]"'\'']{12,}'
# Conservative on purpose: a borderline file is excluded. A credential keyword next to a value, in any case and in
# headers, JSON or config ("Authorization: Bearer x", "\"token\": \"x\"", "password    = x", "**Password:** x", 'config["password"] = x': any
# run of non-alphanumeric characters on the line before the separator), and bare Bearer or Basic
# credentials. measure/entropy.mjs then drops any file with a high-entropy token, which no pattern list can name.
CRED_RE='(authorization|bearer|basic|token|secret|password|passwd|api[_-]?key|cookie|set-cookie|private[_-]?key|client[_-]?secret|session)[^[:alnum:]]*[:=][[:space:]]*[^[:space:]]|(bearer|basic)[[:space:]]+[A-Za-z0-9._~+/=-]{8,}'

TRANSCRIPT_RE='transcript|meeting|standup|1on1|1-on-1|interview|call-notes'
LOG_NAME_RE='(^|[_.-])(logs?|stderr|stdout|trace)([_.-]|$)|^(train|run|job)_'
LOG_DIR_RE='^(logs?|debug|runs?)$'

warn() { echo "select-corpus: warning: $*" >&2; }
# keep <grep args...>: a name filter; grep's 1 means "no line kept", anything above it is a crash
keep() { local rc=0; grep "$@" || rc=$?; [ "$rc" -le 1 ] || { echo "select-corpus: grep failed (rc=$rc)" >&2; exit 2; }; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
roots=()
for r in "${ROOTS[@]}"; do if [ -d "$r" ]; then roots+=("$r"); else warn "root $r does not exist; skipped"; fi; done
[ "${#roots[@]}" -gt 0 ] || { echo "select-corpus: none of the roots exist" >&2; exit 2; }
# 1. walk: prune dot-dirs and build/vendor dirs, regular files only (no symlinks), allowed extensions
find -P "${roots[@]}" \( -type d \( -name '.*' -o -name node_modules -o -name worktrees -o -name venv \
    -o -name __pycache__ -o -name dist -o -name build -o -name target -o -name site-packages -o -name vendor \
    -o -name fixtures \) -prune \) -o -type f -print > "$tmp/all" 2> "$tmp/find.err" || true
[ ! -s "$tmp/find.err" ] || warn "find could not read $(wc -l < "$tmp/find.err" | tr -d ' ') folder(s) or file(s); they were skipped"
keep -E -i "$EXT_RE" "$tmp/all" > "$tmp/w1"
keep -E -v -i "$SECRET_NAME_RE" "$tmp/w1" > "$tmp/w2"
keep -E -v "$LOCK_RE" "$tmp/w2" > "$tmp/walk"
for x in "${SELF_EXCLUDE[@]}"; do keep -F -v "$x/" "$tmp/walk" > "$tmp/w3"; mv "$tmp/w3" "$tmp/walk"; done
# 2. stat, cutoff, text + UTF-8, size windows in characters, no secret pattern; classify
n_scan_fail=0; n_secret=0; n_unreadable=0
while IFS= read -r p; do
  read -r m b < <(stat -f '%m %z' "$p" 2>/dev/null) || { n_unreadable=$((n_unreadable+1)); continue; }
  [ "$m" -le "$CUTOFF" ] || continue
  [ "$b" -ge 1800 ] && [ "$b" -le 200000 ] || continue   # bytes bound chars from both sides (1 to 4 bytes each)
  rc=0; grep -Iq . "$p" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] || n_unreadable=$((n_unreadable+1)); continue; }   # 1: binary or empty; 2: unreadable
  iconv -f UTF-8 -t UTF-8 "$p" >/dev/null 2>&1 || continue
  c=$(LC_ALL=en_US.UTF-8 wc -m < "$p" 2>/dev/null | tr -d ' ') && [ -n "$c" ] || { n_unreadable=$((n_unreadable+1)); continue; }
  slot=""
  if [ "$c" -ge 20000 ] && [ "$c" -le 50000 ]; then slot=main
  elif [ "$c" -ge 1800 ] && [ "$c" -le 2200 ]; then slot=s2k
  elif [ "$c" -ge 4500 ] && [ "$c" -le 5500 ]; then slot=s5k
  elif [ "$c" -ge 9000 ] && [ "$c" -le 11000 ]; then slot=s10k
  else continue; fi
  rc=0; grep -E -i -q -e "$SECRET_BODY_RE" -e "$CRED_RE" "$p" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || { [ "$rc" -eq 0 ] && n_secret=$((n_secret+1)) || n_scan_fail=$((n_scan_fail+1)); continue; }   # only "no match" passes
  base=$(basename "$p" | tr '[:upper:]' '[:lower:]'); lp=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$base" | grep -E -q "$TRANSCRIPT_RE" && printf '%s' "$base" | grep -E -q '\.(txt|md|vtt|srt)$'; then t=transcript
  elif printf '%s' "$base" | grep -E -q '\.(log|out)$' \
    || { printf '%s' "$base" | grep -E -q '\.(txt|jsonl)$' \
         && { printf '%s' "$base" | grep -E -q "$LOG_NAME_RE" \
              || basename "$(dirname "$lp")" | grep -E -q "$LOG_DIR_RE"; }; }; then t=log
  else t=doc; fi
  [ "$t" != doc ] || ! printf '%s' "$base" | grep -E -q '\.(jsonl|log|out)$' || continue   # structured/log ext never counts as a doc
  sha=$(shasum -a 256 "$p" 2>/dev/null | cut -c1-64) && [ -n "$sha" ] || { n_unreadable=$((n_unreadable+1)); continue; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$m" "$slot" "$t" "$c" "$sha" "$p"
done < "$tmp/walk" > "$tmp/cands0"
node "$SCRIPT_DIR/entropy.mjs" < "$tmp/cands0" > "$tmp/cands" || { echo "select-corpus: the entropy guard failed" >&2; exit 2; }
[ "$n_scan_fail" -eq 0 ] || warn "the secret scan failed on $n_scan_fail candidate(s); they were excluded"
[ "$n_unreadable" -eq 0 ] || warn "$n_unreadable file(s) could not be read; skipped"
[ "$n_secret" -eq 0 ] || echo "select-corpus: the secret patterns dropped $n_secret candidate(s)" >&2
# 3. newest first (mtime desc, path asc); drop duplicate contents (keep first); max 1 per parent dir per (slot, type)
sort -t $'\t' -k1,1nr -k6,6 "$tmp/cands" \
 | awk -F'\t' '!seen[$5]++' \
 | awk -F'\t' '{d=$6; sub(/\/[^\/]*$/,"",d); if (!dirslot[d SUBSEP $2 SUBSEP $3]++) print}' > "$tmp/ranked"
# 4. quotas: main = 3 log, 3 transcript, 4 doc (shortfall filled by newest remaining main of any type); one per small slot
awk -F'\t' 'BEGIN{q["log"]=3;q["transcript"]=3;q["doc"]=4}
  $2=="main" && n[$3] < q[$3] {n[$3]++; print; used[$6]=1; tot++; next}
  $2=="main" {rest[++r]=$0; next}
  $2!="main" && !small[$2]++ {sm[$2]=$0}
  END{for(i=1;i<=r && tot<10;i++){print rest[i]; tot++}
      split("s2k s5k s10k",o," "); for(i=1;i<=3;i++) if (o[i] in sm) print sm[o[i]]}' "$tmp/ranked" \
 | awk -F'\t' 'BEGIN{OFS="\t"}
   {task = ($2!="main") ? "summary" : ($3=="log" ? "extraction" : ($3=="transcript" ? "summary" : "classification"))
    sortkey = ($2=="main") ? 0 : ($2=="s2k" ? 1 : ($2=="s5k" ? 2 : 3))
    print sortkey, $1, $2, $3, task, $4, $5, $6}' \
 | sort -t $'\t' -k1,1n -k2,2nr \
 | awk -F'\t' 'BEGIN{OFS="\t"} {cmd="date -r " $2 " +%Y-%m-%dT%H:%M:%S"; cmd | getline iso; close(cmd)
     printf "f%02d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", NR, $3, $4, $5, $6, iso, $7, $8}' \
 | awk -F'\t' 'BEGIN{OFS="\t"}   # 5. balance: each task gets >= 3 main files, taking the oldest classification docs
   {row[NR]=$0; id[NR]=$1; slot[NR]=$2; type[NR]=$3; task[NR]=$4; if ($2=="main") cnt[$4]++}
   END{split("extraction summary", need, " ")
       for (k=1; k<=2; k++) for (i=NR; i>=1 && cnt[need[k]] < 3; i--)
         if (slot[i]=="main" && type[i]=="doc" && task[i]=="classification" && cnt["classification"] > 3) {
           task[i]=need[k]; cnt[need[k]]++; cnt["classification"]--; n=split(row[i], f, "\t"); f[4]=need[k]
           row[i]=f[1]; for (j=2; j<=n; j++) row[i]=row[i] OFS f[j] }
       for (i=1; i<=NR; i++) print row[i]}'
