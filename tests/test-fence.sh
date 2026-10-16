#!/usr/bin/env bash
# Test suite for the launcher's read fence (scripts/launch-server.sh + houtini-lm).
# Run from repo root: bash tests/test-fence.sh
# Drives the launcher over stdio MCP (tests/mcp-call.mjs). Fixtures are generated
# synthetic text. Cases that need a model SKIP when LM Studio is not reachable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$SCRIPT_DIR/.."
LAUNCHER="$REPO/scripts/launch-server.sh"
DRIVER="$SCRIPT_DIR/mcp-call.mjs"
ENDPOINT="${LOCAL_LLM_ENDPOINT_URL:-http://127.0.0.1:1234}"

pass=0; fail=0; skip=0; tn=0
ok()   { pass=$((pass+1)); tn=$((tn+1)); echo "  Test $tn PASS: $1"; }
bad()  { fail=$((fail+1)); tn=$((tn+1)); echo "  Test $tn FAIL: $1"; }
skp()  { skip=$((skip+1)); tn=$((tn+1)); echo "  Test $tn SKIP: $1"; }

for tool in node jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required to run this suite"; exit 1; }
done

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }                                 # roots and fixtures
HOME_TMP=$(mktemp -d "$REPO/tests/.tmp-XXXXXX") || { echo "FAIL: mktemp"; exit 1; }  # under $HOME when the repo is
FAKE_PID=""
trap '[ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP" "$HOME_TMP"' EXIT

# Ambient houtini variables must not leak into any case; the scrub test sets them explicitly.
unset OPENROUTER_API_KEY LM_STUDIO_URL LM_STUDIO_PASSWORD LM_STUDIO_MODEL LM_PASSWORD LM_CONTEXT_WINDOW \
  HOUTINI_LM_MODEL HOUTINI_LM_THINKING HOUTINI_LM_STRUCTURED HOUTINI_LM_SERIALISE HOUTINI_LM_RETRY_RATELIMIT \
  HOUTINI_LM_PROVIDER HOUTINI_LM_MIN_TOKENS HOUTINI_LM_CROSS_PROCESS_LOCK HOUTINI_LM_CONTEXT_WINDOW

lm_up=0
curl -s -m 3 "$ENDPOINT/v1/models" >/dev/null 2>&1 && lm_up=1

# run_launcher <allowed-dirs> [tool json-args] -> one JSON line from the driver
run_launcher() {
  local dirs="$1"; shift
  LOCAL_LLM_ALLOWED_DIRS="$dirs" node "$DRIVER" "$LAUNCHER" "$@"
}
read_files() { # <allowed-dirs> <path> -> driver JSON for code_task_files on one path
  local args
  args=$(jq -nc --arg p "$2" '{paths:[$p], task:"Summarize this file in two sentences."}')
  run_launcher "$1" code_task_files "$args"
}
# gen_text <chars>: deterministic synthetic text, about 2.7 chars/token
gen_text() {
  awk -v n="$1" 'BEGIN{while(length(s)<n){i++; s=s sprintf("Record %d: the inventory of station %d lists %d widgets, %d gadgets, and note code %x.\n", i, i%97, (i*7)%113, (i*13)%251, i*2654435761%65536)} printf "%s", substr(s,1,n)}'
}
# did_not_start <json> <stderr-fragment>: launcher exited non-zero, no MCP initialize, fragment on stderr
did_not_start() {
  jq -e --arg f "$2" '(.timedOut | not) and (.init | not) and .exit != null and .exit != 0 and (.stderr | contains($f))' >/dev/null <<<"$1"
}
check_refuses() { # <label> <allowed-dirs> <stderr-fragment> [endpoint]
  local out
  out=$(LOCAL_LLM_ENDPOINT_URL="${4:-http://127.0.0.1:1234}" run_launcher "$2")
  if did_not_start "$out" "$3"; then ok "launcher refuses to start: $1"
  else bad "launcher refuses to start: $1 ($out)"; fi
}
# check_reads <label> <allowed-dirs> <path>: the read is not fenced off (and succeeds with a model)
check_reads() {
  local out
  out=$(read_files "$2" "$3")
  if jq -e '(.timedOut | not) and .init and (.call.text | test("outside the allowed roots|READ FAILED") | not)' >/dev/null <<<"$out" \
     && { [ "$lm_up" = 0 ] || jq -e '.call != null and .call.isError == false' >/dev/null <<<"$out"; }; then
    ok "$1"
  else
    bad "$1 ($(jq -c '{stderr,call}' <<<"$out" | cut -c1-300))"
  fi
}

echo "fence test suite (LM Studio reachable: $lm_up)"

# --- fail closed: no usable root means houtini never starts --------------------
A="$TMP/a"; B="$TMP/b"; mkdir -p "$A" "$B"
check_refuses "empty allowed_dirs" "" "no allowed folders"
check_refuses "whitespace-only allowed_dirs" "   " "no allowed folders"
check_refuses "only empty entries" " , ," "no allowed folders"
check_refuses "only nonexistent folders" "$TMP/nope" "none of the allowed folders exist"
check_refuses "relative entry" "some/relative/dir" "absolute path"
check_refuses "valid root plus relative entry" "$A,relative" "absolute path"
check_refuses "root '/' entry" "/" "refusing '/'"
check_refuses "valid root plus '/'" "$A,/" "refusing '/'"
check_refuses "'//' resolves to /" "//" "refusing '/'"
check_refuses "'/.' resolves to /" "/." "refusing '/'"
check_refuses "dot-dot chain resolves to /" "$A$(printf '/..%.0s' $(seq 1 40))" "refusing '/'"
# houtini trims each piece after splitting, so a root that differs from its trimmed form is refused
mkdir -p "$TMP/d" "$TMP/d "
ln -s "$TMP/d " "$TMP/link-trailing-space"
mkdir -p "$TMP/c:d"; ln -s "$TMP/c:d" "$TMP/link-colon"
echo f > "$TMP/plain-file"
check_refuses "entry resolving to a dir with trailing whitespace" "$TMP/d /" "altered by houtini"
check_refuses "symlink root whose target ends in whitespace" "$TMP/link-trailing-space" "altered by houtini"
check_refuses "symlink root whose target contains ':'" "$TMP/link-colon" "':'"
# Characters JS trim() strips but [[:space:]] misses (any locale): the root must survive houtini's trim.
feff=$(printf '\xef\xbb\xbf'); nbsp=$(printf '\xc2\xa0'); nl=$(printf '\n_'); nl=${nl%_}
mkdir -p "$TMP/d$feff" "$TMP/d$nbsp" "$TMP/d$nl"
check_refuses "dir ending in U+FEFF" "$TMP/d$feff/" "altered by houtini"
check_refuses "dir ending in NBSP" "$TMP/d$nbsp/" "altered by houtini"
check_refuses "trailing NBSP without a slash (sibling dir exists)" "$TMP/d$nbsp" "leading/trailing whitespace"
check_refuses "trailing space without a slash (sibling dir exists)" "$TMP/d " "leading/trailing whitespace"
check_refuses "dir ending in a newline" "$TMP/d$nl/" "altered by houtini"
mkdir -p "$TMP/p/x"; chmod 000 "$TMP/p"
check_refuses "unreadable parent (EACCES) is an error, not a skip" "$TMP/p/x" "EACCES"
check_refuses "path through a regular file (ENOTDIR)" "$TMP/plain-file/x" "ENOTDIR"
ln -s "$TMP/loop2" "$TMP/loop1"; ln -s "$TMP/loop1" "$TMP/loop2"
check_refuses "symlink loop (ELOOP)" "$TMP/loop1" "ELOOP"
out=$(HOME= LOCAL_LLM_ALLOWED_DIRS="~/x" node "$DRIVER" "$LAUNCHER")
if did_not_start "$out" "HOME is not an absolute path"; then ok "empty HOME with ~/x is refused"
else bad "empty HOME with ~/x is refused ($out)"; fi
check_refuses "regular file as a root" "$TMP/plain-file" "not a directory"
check_refuses "entry with ':' (houtini splits on it)" "$A,$A/x:y" "':'"
check_refuses "'path:suffix' (would authorize path plus a cwd-relative suffix)" "$TMP/a:b" "':'"
out=$(env -u LOCAL_LLM_ALLOWED_DIRS node "$DRIVER" "$LAUNCHER")
if did_not_start "$out" "no allowed folders"; then ok "launcher refuses to start: allowed_dirs unset"
else bad "launcher refuses to start: allowed_dirs unset ($out)"; fi

# --- loopback only: a remote endpoint is refused before houtini starts ---------
for ep in "http://example.com:1234" "http://127.0.0.1.example.com:1234" "http://user@evil.example/" \
          "http://localhost:1@evil.example/" "http://127.0.0.1:1.evil.com" "http://localhost:12x" \
          "ftp://127.0.0.1" "127.0.0.1:1234" "http://10.0.0.5:1234"; do
  check_refuses "non-loopback endpoint $ep" "$A" "loopback" "$ep"
done
for ep in "http://127.0.0.1:1234" "http://localhost:1234/v1" "http://[::1]:1234" "http://[::1]" "https://localhost"; do
  out=$(LOCAL_LLM_ENDPOINT_URL="$ep" run_launcher "$A")
  if [ "$(jq -r '.init' <<<"$out")" = "true" ]; then ok "launcher accepts loopback endpoint: $ep"
  else bad "launcher accepts loopback endpoint: $ep ($out)"; fi
done

# --- the fence: reads outside every root are rejected --------------------------
mkdir -p "$TMP/root" "$TMP/root-evil" "$TMP/outside"
echo "canary-outside" > "$TMP/outside/secret.txt"
echo "canary-evil"    > "$TMP/root-evil/sibling.txt"
echo "inside the root" > "$TMP/root/inside.txt"
ln -s "$TMP/outside/secret.txt" "$TMP/root/link-out.txt"

check_rejected() {
  local label="$1" path="$2" out
  out=$(read_files "$TMP/root" "$path")
  if [ "$(jq -r '.init' <<<"$out")" = "true" ] \
     && jq -e '.call.isError and (.call.text | test("outside the allowed roots")) and (.call.text | test("Model:") | not)' >/dev/null <<<"$out" \
     && ! grep -q "canary" <<<"$out"; then
    ok "rejected: $label"
  else
    bad "rejected: $label ($(jq -c '.call' <<<"$out" | cut -c1-300))"
  fi
}
check_rejected "path outside every root" "$TMP/outside/secret.txt"
check_rejected "symlink inside a root pointing outside it" "$TMP/root/link-out.txt"
check_rejected "sibling directory sharing the root's name prefix" "$TMP/root-evil/sibling.txt"
check_rejected "dot-dot escape from inside the root" "$TMP/root/../outside/secret.txt"

# --- root list handling --------------------------------------------------------
echo "second root" > "$B/second.txt"
check_reads "two roots joined with a bare comma: read from the second" "$A,$B" "$B/second.txt"
check_refuses "padding around an entry is refused, not trimmed" " $A , $B " "leading/trailing whitespace"
mkdir -p "$TMP/with space"; echo "spaced" > "$TMP/with space/f.txt"
check_reads "root with a space in its name" "$TMP/with space" "$TMP/with space/f.txt"
out=$(read_files "$TMP/missing,$B" "$B/second.txt")
if jq -e '.init and (.stderr | contains("not found, skipping")) and (.stderr | contains("allowed folders: ")) and (.call.text | test("outside the allowed roots|READ FAILED") | not)' >/dev/null <<<"$out" \
   && { [ "$lm_up" = 0 ] || jq -e '.call != null and .call.isError == false' >/dev/null <<<"$out"; }; then
  ok "nonexistent root is skipped with a warning; the valid root still works"
else bad "nonexistent root skipped ($(jq -c '{stderr,call}' <<<"$out" | cut -c1-300))"; fi
out=$(run_launcher "$A")
if jq -e --arg a "$(cd -P "$A" && pwd -P)" '.stderr | contains("allowed folders: " + $a)' >/dev/null <<<"$out"; then
  ok "startup logs the resolved roots on stderr"
else bad "startup logs the resolved roots ($out)"; fi

# --- $HOME and ~ in the configured roots are expanded --------------------------
case "$HOME_TMP" in
  "$HOME"/*)
    rel=${HOME_TMP#"$HOME"/}
    echo "home-relative fixture" > "$HOME_TMP/note.txt"
    for form in '$HOME' '${HOME}' '~'; do
      check_reads "root given as literal $form/... is expanded" "$form/$rel" "$HOME_TMP/note.txt"
    done ;;
  *) skp "repo is not under \$HOME; \$HOME expansion cases" ;;
esac

# --- the endpoint is the one configured, and no other key is sent --------------
node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/port" "$TMP/requests.log" &
FAKE_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
if [ -s "$TMP/port" ]; then
  out=$(OPENROUTER_API_KEY=sk-canary LOCAL_LLM_ENDPOINT_URL="http://127.0.0.1:$(cat "$TMP/port")" run_launcher "$A" list_models)
  if [ -s "$TMP/requests.log" ] && ! grep -q "sk-canary" "$TMP/requests.log" && ! grep -q "sk-canary" <<<"$out"; then
    ok "requests reach the configured endpoint; OPENROUTER_API_KEY is never sent"
  else
    bad "endpoint passthrough (requests: $(wc -l < "$TMP/requests.log" 2>/dev/null), $(jq -c '{init,stderr}' <<<"$out" | cut -c1-200))"
  fi
  # model pin: LOCAL_LLM_MODEL reaches houtini as HOUTINI_LM_MODEL; empty means no pin
  ep="http://127.0.0.1:$(cat "$TMP/port")"
  out=$(LOCAL_LLM_MODEL=fake-model LOCAL_LLM_ENDPOINT_URL="$ep" run_launcher "$A" discover)
  if jq -e '.call.text | test("pinned via HOUTINI_LM_MODEL")' >/dev/null <<<"$out"; then ok "LOCAL_LLM_MODEL pins the model"
  else bad "LOCAL_LLM_MODEL pins the model ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
  out=$(LOCAL_LLM_MODEL= LOCAL_LLM_ENDPOINT_URL="$ep" run_launcher "$A" discover)
  if jq -e '.call.text | test("no HOUTINI_LM_MODEL pin")' >/dev/null <<<"$out"; then ok "empty LOCAL_LLM_MODEL leaves the model unpinned"
  else bad "empty LOCAL_LLM_MODEL leaves the model unpinned ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
  out=$(HOUTINI_LM_MODEL=fake-model-2 LM_STUDIO_MODEL=x HOUTINI_LM_STRUCTURED=1 LOCAL_LLM_MODEL= LOCAL_LLM_ENDPOINT_URL="$ep" run_launcher "$A" discover)
  if jq -e '.call.text | test("no HOUTINI_LM_MODEL pin")' >/dev/null <<<"$out"; then ok "ambient houtini variables are scrubbed"
  else bad "ambient houtini variables are scrubbed ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
else
  bad "endpoint passthrough: fake endpoint did not start"
fi

# --- file size cap: no model needed --------------------------------------------
gen_text 1100000 > "$TMP/root/over-1mb.txt"
out=$(read_files "$TMP/root" "$TMP/root/over-1mb.txt")
if jq -e '.call.isError and (.call.text | test("over the 1 MB limit")) and (.call.text | test("Model:") | not)' >/dev/null <<<"$out"; then
  ok "file over 1 MB is rejected without a model"
else bad "file over 1 MB ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi

# --- environment houtini receives: scrub list is read from the launcher --------
unset_names=$(awk '/^unset /{f=1} f{print} f&&!/\\$/{exit}' "$LAUNCHER" | tr -d '\\' | sed 's/^unset//')
exported_names=$(grep -oE '^(\[ -z [^]]*\] \|\| )?export [A-Za-z_]+' "$LAUNCHER" | sed -E 's/.*export //' | sort -u | tr '\n' ' ')
mkdir -p "$TMP/stubbin"
printf '#!/bin/sh\nenv > "%s"\nexit 0\n' "$TMP/stub-env" > "$TMP/stubbin/npx"; chmod +x "$TMP/stubbin/npx"
ambient=(); for n in $unset_names; do ambient+=("$n=ambient-$n"); done
stub_err=$(env "${ambient[@]}" LOCAL_LLM_ENDPOINT_URL=http://127.0.0.1:1234 LOCAL_LLM_MODEL= PATH="$TMP/stubbin:$PATH" LOCAL_LLM_ALLOWED_DIRS="$A" "$LAUNCHER" 2>&1 >/dev/null); stub_rc=$?
leaked=""; for n in $unset_names; do grep -q "^$n=" "$TMP/stub-env" 2>/dev/null && leaked="$leaked $n"; done
want_roots=$(cd -P "$A" && pwd -P)
if [ -s "$TMP/stub-env" ] && [ "$(wc -w <<<"$unset_names")" -ge 15 ] && [ -z "$leaked" ] \
   && grep -qxF "HOUTINI_LM_FILE_ROOTS=$want_roots" "$TMP/stub-env" \
   && grep -qxF "HOUTINI_LM_ENDPOINT_URL=http://127.0.0.1:1234" "$TMP/stub-env" \
   && grep -qxF "HOUTINI_LM_API_KEY=not-needed" "$TMP/stub-env" \
   && grep -qxF "HOUTINI_LM_MAX_FILE_MB=1" "$TMP/stub-env"; then
  ok "houtini's environment: ${#ambient[@]} ambient variables dropped, launcher values set"
else bad "houtini's environment (rc=$stub_rc, leaked:$leaked; unset list: $(wc -w <<<"$unset_names") names; stderr: $stub_err)"; fi

# --- the launcher never runs from the spawner's cwd ----------------------------
# npx prefers a matching @houtini/lm under node_modules in cwd or any ancestor; planted copies
# (with a working .bin/lm, so they would run) in the cwd and one directory above must not run.
plant() { # <dir>: a runnable fake @houtini/lm 3.3.4 under <dir>/node_modules
  mkdir -p "$1/node_modules/@houtini/lm" "$1/node_modules/.bin"
  echo '{"name":"@houtini/lm","version":"3.3.4","bin":{"lm":"planted.js"}}' > "$1/node_modules/@houtini/lm/package.json"
  printf '#!/usr/bin/env node\nrequire("fs").writeFileSync(%s,"ran");console.log("CANARY-PLANTED");\n' "'$TMP/planted-ran'" > "$1/node_modules/@houtini/lm/planted.js"
  chmod +x "$1/node_modules/@houtini/lm/planted.js"
  ln -s ../@houtini/lm/planted.js "$1/node_modules/.bin/lm"
}
plant "$TMP/outer"; plant "$TMP/outer/proj"
out=$(cd "$TMP/outer/proj" && run_launcher "$A")
if [ ! -e "$TMP/planted-ran" ] && ! grep -q CANARY-PLANTED <<<"$out" \
   && jq -e '.init and (.serverName | test("houtini"; "i"))' >/dev/null <<<"$out"; then
  ok "planted @houtini/lm in the cwd and above it is not run; real houtini answers"
else bad "planted houtini in cwd ($([ -e "$TMP/planted-ran" ] && echo CANARY-RAN) $out)"; fi

# --- houtini's env reads (the cache is filled by the launcher runs above) ------
# Every variable the pinned dist reads is either scrubbed or deliberately exported.
dist=""
for d in "$(npm config get cache 2>/dev/null)"/_npx/*/node_modules/@houtini/lm; do
  [ -f "$d/package.json" ] && grep -q '"version": "3.3.4"' "$d/package.json" && dist="$d/dist" && break
done
if [ -n "$dist" ]; then
  missing=""
  for n in $(grep -rhoE 'process\.env\.[A-Z_]+' "$dist"/*.js | sed 's/process\.env\.//' | sort -u); do
    case " $unset_names $exported_names " in *" $n "*) ;; *) missing="$missing $n" ;; esac
  done
  grep -rqE 'process\.env\[|=[[:space:]]*process\.env[[:space:]]*;|\}[[:space:]]*=[[:space:]]*process\.env\b' "$dist"/*.js && missing="$missing (dynamic or destructured process.env)"
  if [ -z "$missing" ]; then ok "every process.env name in houtini 3.3.4's dist is scrubbed or exported"
  else bad "houtini env names neither scrubbed nor exported:$missing"; fi
else
  skp "houtini 3.3.4 dist not in the npx cache; env-name coverage check"
fi

# --- case-insensitive filesystems: root typed in another case than on disk -----
swapped=$(basename "$HOME_TMP" | tr 'a-zA-Z' 'A-Za-z')
if [ "$swapped" != "$(basename "$HOME_TMP")" ] && [ -d "$(dirname "$HOME_TMP")/$swapped" ]; then
  echo "case fixture" > "$HOME_TMP/case.txt"
  check_reads "root typed in different case than on disk still reads" "$(dirname "$HOME_TMP")/$swapped" "$HOME_TMP/case.txt"
else
  skp "case-insensitive root: filesystem is case-sensitive"
fi

# --- model-backed cases --------------------------------------------------------
gen_text 20000 > "$TMP/root/twenty-k.txt"
if [ "$lm_up" = 1 ]; then
  out=$(read_files "$TMP/root" "$TMP/root/twenty-k.txt")
  if jq -e '(.call != null and .call.isError == false) and (.call.text | test("1 file\\(s\\) read")) and (.call.text | test("Model:"))' >/dev/null <<<"$out"; then
    ok "happy path: ~20k-char file summarized, footer shows 1 file(s) read"
  else
    bad "happy path ($(jq -c '.call' <<<"$out" | cut -c1-300))"
  fi

  # LM Studio is expected at a 32k context. Over it, houtini surfaces the upstream error; no summary.
  gen_text 130000 > "$TMP/root/huge.txt"
  out=$(read_files "$TMP/root" "$TMP/root/huge.txt")
  if jq -e '.call.isError and (.call.text | test("context_length_exceeded|context length"; "i")) and (.call.text | test("Model:") | not)' >/dev/null <<<"$out"; then
    ok "oversized: ~130k chars exceeds the context window, error and no summary"
  else
    bad "oversized: expected a context-window error; the suite assumes the model is loaded at 32k context, so a context above ~45k tokens fails here by design ($(jq -c '.call' <<<"$out" | cut -c1-300))"
  fi
else
  skp "happy path: LM Studio not reachable at $ENDPOINT"
  skp "oversized: LM Studio not reachable at $ENDPOINT"
fi

echo
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
