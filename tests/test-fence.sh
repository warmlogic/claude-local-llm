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
FAKE_PID=""; NM_PID=""; E5_PID=""; CONTEXT_PID=""; CTX16_PID=""
trap '[ -z "$CTX16_PID" ] || kill "$CTX16_PID" 2>/dev/null; [ -z "$CONTEXT_PID" ] || kill "$CONTEXT_PID" 2>/dev/null; [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null; [ -z "$NM_PID" ] || kill "$NM_PID" 2>/dev/null; [ -z "$E5_PID" ] || kill "$E5_PID" 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP" "$HOME_TMP"' EXIT

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
  # no proxy: with Node's env proxy turned on, houtini's requests still go straight to the endpoint.
  # Its positive control (the same environment does send a plain Node fetch to the proxy) is the
  # "control:" case in tests/test-verify.sh, which this suite runs below.
  node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/proxy-port" "$TMP/proxy.log" proxy &
  PROXY_PID=$!
  for _ in $(seq 1 50); do [ -s "$TMP/proxy-port" ] && break; sleep 0.1; done
  pp="http://127.0.0.1:$(cat "$TMP/proxy-port" 2>/dev/null)"; : > "$TMP/proxy.log"; before=$(wc -l < "$TMP/requests.log")
  out=$(NODE_USE_ENV_PROXY=1 NODE_OPTIONS=--use-env-proxy HTTP_PROXY="$pp" http_proxy="$pp" HTTPS_PROXY="$pp" ALL_PROXY="$pp" NO_PROXY= no_proxy= \
        LOCAL_LLM_ENDPOINT_URL="http://127.0.0.1:$(cat "$TMP/port")" run_launcher "$A" list_models)
  if [ -s "$TMP/proxy-port" ] && [ ! -s "$TMP/proxy.log" ] && [ "$(wc -l < "$TMP/requests.log")" -gt "$before" ]; then
    ok "houtini with Node's env proxy on and *_PROXY set: the proxy gets nothing, the endpoint gets the requests"
  else bad "houtini proxy bypass (proxy log: $(wc -l < "$TMP/proxy.log" 2>/dev/null) lines; $(jq -c '{init,stderr}' <<<"$out" | cut -c1-200))"; fi
  kill "$PROXY_PID" 2>/dev/null
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

# The plugin root's package.json stops npm climbing to a planted ancestor of the plugin itself.
rm -f "$TMP/planted-ran"
plant "$TMP/anc"; mkdir -p "$TMP/anc/plug"
cp -R "$REPO/scripts" "$REPO/package.json" "$TMP/anc/plug/"
out=$(cd "$TMP" && LOCAL_LLM_ALLOWED_DIRS="$A" node "$DRIVER" "$TMP/anc/plug/scripts/launch-server.sh")
if [ ! -e "$TMP/planted-ran" ] && ! grep -q CANARY-PLANTED <<<"$out" && jq -e '.init and (.serverName | test("houtini"; "i"))' >/dev/null <<<"$out"; then
  ok "a planted @houtini/lm above the plugin root is not run (package.json boundary)"
else bad "planted houtini above the plugin ($([ -e "$TMP/planted-ran" ] && echo CANARY-RAN) $out)"; fi

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

# --- the bad-answer flags the skill lists still exist in the pinned houtini (string check; the harness reads them off the footer line) ---
if [ -n "$dist" ]; then
  flag_json=$(DELEG_SELFTEST=1 DELEG_JUDGE=stub DELEG_PRINT_FLAGS=1 bash "$SCRIPT_DIR/test-delegation.sh" 2>/dev/null); flag_rc=$?
  flag_count=$(jq 'length' <<<"$flag_json" 2>/dev/null || echo 0)
  flag_missing=""
  while IFS= read -r flag; do [ -z "$flag" ] || grep -qF -- "$flag" "$dist/index.js" || flag_missing="$flag_missing [$flag]"; done < <(jq -r '.[]' <<<"$flag_json" 2>/dev/null)
  if [ "$flag_rc" -eq 0 ] && [ "$flag_count" -gt 0 ] && [ -z "$flag_missing" ] && grep -q "parts.join(' | ')" "$dist/index.js"; then
    ok "all $flag_count bad-answer flags the harness takes from the skill table appear in houtini's dist, and the dist joins footer parts with ' | ' (a string check, not a footer render)"
  else bad "skill flags (rc=$flag_rc, $flag_count parsed) missing from houtini's dist:${flag_missing:- none} (or the footer is no longer one joined line)"; fi
else skp "houtini 3.3.4 dist not in the npx cache; bad-answer flag check"; fi
# Exercise the real setup guard. Even a broken guard cannot start a paid session.
mkdir -p "$TMP/no-session"
printf '#!/bin/sh\nexit 1\n' > "$TMP/no-session/claude"
chmod +x "$TMP/no-session/claude"
# the harness refuses to start when the skill's flag rows cannot be read
for f in skill-renamed-bad-row.md skill-renamed-other-row.md; do
  out=$(env -u DELEG_SELFTEST -u DELEG_PRINT_FLAGS -u DELEG_JUDGE_CHECK PATH="$TMP/no-session:$PATH" DELEG_JUDGE=stub DELEG_SKILL_MD="$SCRIPT_DIR/fixtures/deleg/$f" bash "$SCRIPT_DIR/test-delegation.sh" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -qF "the skill's names table cannot supply the bad-answer flags (see above)" <<<"$out"; then ok "harness start fails on a skill table with a missing flag row ($f)"
  else bad "harness start should fail on $f (rc=$rc: ${out:0:150})"; fi
done

# --- case-insensitive filesystems: root typed in another case than on disk -----
swapped=$(basename "$HOME_TMP" | tr 'a-zA-Z' 'A-Za-z')
if [ "$swapped" != "$(basename "$HOME_TMP")" ] && [ -d "$(dirname "$HOME_TMP")/$swapped" ]; then
  echo "case fixture" > "$HOME_TMP/case.txt"
  check_reads "root typed in different case than on disk still reads" "$(dirname "$HOME_TMP")/$swapped" "$HOME_TMP/case.txt"
else
  skp "case-insensitive root: filesystem is case-sensitive"
fi

# --- delegate-local skill and its approval hook --------------------------------
HOOK="$REPO/scripts/approve-own-tools.mjs"
skill="$REPO/skills/delegate-local/SKILL.md"
hook_out() { printf '%s' "$1" | node "$HOOK"; }
if hook_out '{"tool_name":"Skill","tool_input":{"skill":"local-llm:delegate-local"}}' \
   | jq -e '.hookSpecificOutput.permissionDecision == "allow" and .hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null; then
  ok "approval hook allows the plugin's own skill"
else bad "approval hook allows the plugin's own skill"; fi
for t in mcp__plugin_local-llm_local-llm__code_task_files mcp__plugin_local-llm_local-verify__verify_claims; do
  if hook_out "{\"tool_name\":\"$t\",\"tool_input\":{}}" \
     | jq -e '.hookSpecificOutput.permissionDecision == "allow" and .hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null; then
    ok "approval hook allows the plugin's read-only tool $t"
  else bad "approval hook allows the plugin's read-only tool $t"; fi
done
# Whole-command approval, not prefix approval. Keep every allow/reject visible for mutation checks.
batch_cmd() {
  local label="$1" decision="$2" command="$3" background="${4:-false}" cwd="${5:-$PWD}" output
  output=$(hook_out "$(jq -nc --arg c "$command" --argjson b "$background" --arg cwd "$cwd" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,run_in_background:$b}}')")
  if { [ "$decision" = allow ] && jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null <<<"$output"; } \
     || { [ "$decision" = reject ] && [ -z "$output" ]; }; then ok "batch hook $decision: $label"; else bad "batch hook $decision: $label"; fi
}
# Use physical paths: the shell test REPO may contain a trailing /.. .
BROOT=$(cd "$REPO" && pwd -P)
# All paths exist: the hook must realpath inputs and explicit output directories.
HOOK_TMP=$(cd "$TMP" && pwd -P)
mkdir -p "$HOOK_TMP/allowed" "$HOOK_TMP/allowed-evil" "$HOOK_TMP/out" "$HOME_TMP/outside" "$HOOK_TMP/home/.claude/projects"
printf 'input\n' > "$HOOK_TMP/allowed/a.txt"
printf 'input\n' > "$HOOK_TMP/allowed/a b.txt"
printf 'literal glob\n' > "$HOOK_TMP/allowed/*.txt"
printf 'outside\n' > "$HOOK_TMP/allowed-evil/out.txt"
printf '{}\n' > "$HOOK_TMP/home/.claude/projects/session.jsonl"
ln -s "$HOOK_TMP/allowed-evil/out.txt" "$HOOK_TMP/allowed/link.txt"
ln -s "$HOME_TMP/outside" "$HOOK_TMP/out-link"
mkdir -p "$HOOK_TMP/allowed-evil/nested" "$HOOK_TMP/out/nested" "$HOOK_TMP/out/outside"
ln -s "$HOOK_TMP/allowed-evil/nested" "$HOOK_TMP/allowed/dirlink"
printf 'inside decoy\n' > "$HOOK_TMP/allowed/out.txt"
ln -s "$HOOK_TMP/out/nested" "$HOME_TMP/link"
# Isolate the hook options from the caller; restore them after the batch assertions.
SAVED_ALLOWED_DIRS=${CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS-}
HAD_ALLOWED_DIRS=${CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS+x}
export CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS="$HOOK_TMP/allowed"
RUN="node '$BROOT/batch/run.mjs'"
FLATTEN="node '$BROOT/batch/flatten-transcripts.mjs'"
INPUT="$HOOK_TMP/allowed/a.txt"
batch_cmd raw allow "$RUN --number --job-json '{}' '$INPUT'"
batch_cmd quoted allow "$RUN --job-json '{\"prompt\":\"a; | > < && || \$(literal) \`literal\`\"}' '$HOOK_TMP/allowed/a b.txt'" true
batch_cmd single-quotes allow "$RUN --job-json '{}' '$INPUT' &"
batch_cmd flatten allow "$FLATTEN '$HOOK_TMP/out' '$INPUT'" true
batch_cmd apostrophe allow "$RUN --job-json 'it'\\''s literal' '$INPUT'"
batch_cmd tmp-out reject "$RUN --out '$HOOK_TMP/out' --job-json '{}' '$INPUT'"
batch_cmd relative-input allow "$RUN --job-json '{}' a.txt" false "$HOOK_TMP/allowed"
if [ "$(uname -s)" = Darwin ]; then
  batch_cmd private-tmp-out reject "$RUN --out /private/tmp --job-json '{}' '$INPUT'"
fi
batch_cmd root-itself allow "$RUN --job-json '{}' '$HOOK_TMP/allowed'"
batch_cmd outside-input reject "$RUN --job-json '{}' '$HOOK_TMP/allowed-evil/out.txt'"
mkdir -p /tmp/local-llm-batch/hooktest && printf 'L1\tx\n' > /tmp/local-llm-batch/hooktest/staged.txt
batch_cmd staged-input allow "$RUN --job-json '{}' '/tmp/local-llm-batch/hooktest/staged.txt'"
# a staging dir that is a symlink is not trusted (it would widen the read boundary)
SL="$HOOK_TMP/sl-target"; mkdir -p "$SL"; printf 'L1\tx\n' > "$SL/f.txt"
ln -s "$SL" "$HOOK_TMP/sl-link"
st=$(printf '{}' | node --input-type=module -e "const m = await import('$REPO/scripts/approve-own-tools.mjs'); console.log(JSON.stringify([m.trustedStaging('$HOOK_TMP/sl-link').length, m.trustedStaging('$SL').length]))" 2>/dev/null)
if [ "$st" = "[0,1]" ]; then ok "batch hook: a symlinked staging dir is not trusted, a real one is"; else bad "batch hook: staging trust ($st)"; fi
printf 'L1\tx\n' > "$HOOK_TMP/out.txt"
batch_cmd tmp-not-staged reject "$RUN --job-json '{}' '$HOOK_TMP/out.txt'"
batch_cmd mixed-inputs reject "$RUN --job-json '{}' '$INPUT' '$HOOK_TMP/allowed-evil/out.txt'"
batch_cmd symlink-input reject "$RUN --job-json '{}' '$HOOK_TMP/allowed/link.txt'"
batch_cmd symlink-parent-input reject "$RUN --job-json '{}' '$HOOK_TMP/allowed/dirlink/../out.txt'"
batch_cmd job-file reject "$RUN --job /etc/x '$INPUT'"
batch_cmd outside-out reject "$RUN --out '$HOME/.ssh' --job-json '{}' '$INPUT'"
batch_cmd existing-outside-out reject "$RUN --out '$HOME_TMP/outside' --job-json '{}' '$INPUT'"
batch_cmd symlink-out-dir reject "$RUN --out '$HOOK_TMP/out-link' --job-json '{}' '$INPUT'"
batch_cmd normalized-out-escape reject "$RUN --out '$HOME_TMP/link/../outside' --job-json '{}' '$INPUT'"
batch_cmd unknown-flag reject "$RUN --job-json '{}' --surprise '$INPUT'"
batch_cmd missing-value reject "$RUN --out --job-json '{}' '$INPUT'"
batch_cmd repeated-out reject "$RUN --out '$HOOK_TMP/out' --out '$HOOK_TMP/out' --job-json '{}' '$INPUT'"
batch_cmd nonexistent-out reject "$RUN --out '$HOOK_TMP/missing-out' --job-json '{}' '$INPUT'"
batch_cmd missing-job reject "$RUN '$INPUT'"
batch_cmd unknown-short-flag reject "$RUN --job-json '{}' -x '$INPUT'"
batch_cmd missing-input reject "$RUN --job-json '{}' '$HOOK_TMP/allowed/missing'"
batch_cmd unquoted-glob reject "$RUN --job-json '{}' $HOOK_TMP/allowed/*.txt"
batch_cmd brace-expansion reject "$RUN --job-json '{}' $HOOK_TMP/{allowed,allowed-evil}/a.txt"
batch_cmd flatten-outside-input reject "$FLATTEN '$HOOK_TMP/out' '$HOOK_TMP/allowed-evil/out.txt'"
batch_cmd flatten-symlink-input reject "$FLATTEN '$HOOK_TMP/out' '$HOOK_TMP/allowed/link.txt'"
batch_cmd flatten-outside-out reject "$FLATTEN '$HOME_TMP/outside' '$INPUT'"
batch_cmd flatten-unknown-flag reject "$FLATTEN '$HOOK_TMP/out' --number '$INPUT'"
# Transcripts live outside the default allowed folders; only the flattener gets this extra root.
HOME="$HOOK_TMP/home" batch_cmd transcripts allow "$FLATTEN '$HOOK_TMP/out' '$HOOK_TMP/home/.claude/projects/session.jsonl'"
HOME="$HOOK_TMP/home" batch_cmd run-transcripts reject "$RUN --job-json '{}' '$HOOK_TMP/home/.claude/projects/session.jsonl'"
CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS="$HOOK_TMP/missing" batch_cmd unresolvable-roots reject "$RUN --job-json '{}' '$INPUT'"
CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS='' batch_cmd empty-roots reject "$RUN --job-json '{}' '$INPUT'"
CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS='/' batch_cmd slash-root reject "$RUN --job-json '{}' '$INPUT'"
CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS=" $HOOK_TMP/allowed" batch_cmd padded-root reject "$RUN --job-json '{}' '$INPUT'"
CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS='relative' batch_cmd relative-root reject "$RUN --job-json '{}' '$INPUT'"
HOME="$HOOK_TMP/home" CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS='~/../allowed' batch_cmd home-root allow "$RUN --job-json '{}' '$INPUT'"
# Manifest defaults must work without a saved option; no dependency on the real HOME tree.
mkdir -p "$HOOK_TMP/home/github"
printf 'input\n' > "$HOOK_TMP/home/github/default.txt"
unset CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS
HOME="$HOOK_TMP/home" batch_cmd manifest-default allow "$RUN --job-json '{}' '$HOOK_TMP/home/github/default.txt'"
export CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS="$HOOK_TMP/allowed"
for suffix in '; rm -rf ~' ' | sh' ' && true' ' || true' ' > /tmp/out' ' < /tmp/in' ' $(id)' ' `id`' $'\ntrue' ' &&' ' # comment' ' & true'; do
  batch_cmd "operator $(printf %q "$suffix")" reject "$RUN --job-json '{}' '$INPUT'$suffix"
done
batch_cmd foreign reject 'node /tmp/batch/run.mjs'
batch_cmd traversal reject "node $BROOT/../x.mjs"
batch_cmd internal-traversal reject "node $BROOT/batch/../batch/run.mjs"
batch_cmd other-script reject "node $BROOT/scripts/size-hint.mjs"
batch_cmd node-flags reject "node --eval 'evil()' $BROOT/batch/run.mjs"
batch_cmd double-substitution reject "node \"$BROOT/batch/run.mjs\" \"\$(id)\""
batch_cmd double-backtick reject 'node "'"$BROOT"'/batch/run.mjs" "`id`"'
batch_cmd unclosed reject "node '$BROOT/batch/run.mjs"
# A script with the right lexical path but resolving outside the copied plugin is not approved.
HOOK_TMP=$(cd "$TMP" && pwd -P)
mkdir -p "$HOOK_TMP/hook-plugin/scripts" "$HOOK_TMP/hook-plugin/batch"
cp "$HOOK" "$BROOT/scripts/resolve-roots.mjs" "$HOOK_TMP/hook-plugin/scripts/"
cp -R "$BROOT/.claude-plugin" "$HOOK_TMP/hook-plugin/"
ln -s "$BROOT/batch/run.mjs" "$HOOK_TMP/hook-plugin/batch/run.mjs"
ORIGINAL_HOOK="$HOOK"; HOOK="$HOOK_TMP/hook-plugin/scripts/approve-own-tools.mjs"
batch_cmd symlink-out reject "node $HOOK_TMP/hook-plugin/batch/run.mjs --job-json '{}' '$INPUT'"
HOOK="$ORIGINAL_HOOK"
if [ "$HAD_ALLOWED_DIRS" = x ]; then export CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS="$SAVED_ALLOWED_DIRS"; else unset CLAUDE_PLUGIN_OPTION_ALLOWED_DIRS; fi
if hook_out '{"tool_name":"Skill","tool_input":{"skill":"local-llm:batch-local"}}' | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null; then ok "approval hook allows batch-local skill"; else bad "approval hook allows batch-local skill"; fi
if [ "$(wc -l < "$BROOT/skills/batch-local/SKILL.md")" -lt 60 ] && jq -e '.hooks.PreToolUse[0].matcher | split("|") | index("Bash") != null' "$BROOT/hooks/hooks.json" >/dev/null; then ok "batch skill under 60 lines and Bash hook wired"; else bad "batch skill bounds/hook matcher"; fi
for input in '{"tool_name":"Skill","tool_input":{"skill":"other:delegate-local"}}' \
             '{"tool_name":"Skill","tool_input":{"skill":"local-llm:delegate-local2"}}' \
             '{"tool_name":"Skill","tool_input":{"skill":"delegate-local"}}' \
             '{"tool_name":"Bash","tool_input":{"skill":"local-llm:delegate-local"}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-llm__chat","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-llm__custom_prompt","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-llm__embed","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-llm__code_task","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-llm__code_task_files2","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-verify__verify_claims2","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-verify__verify","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_local-llm_local-llm__verify_claims","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_other_local-verify__verify_claims","tool_input":{}}' \
             '{"tool_name":"mcp__local-verify__verify_claims","tool_input":{}}' \
             '{"tool_name":"MCP__PLUGIN_LOCAL-LLM_LOCAL-VERIFY__VERIFY_CLAIMS","tool_input":{}}' \
             '{"tool_name":"mcp__plugin_other_local-llm__code_task_files","tool_input":{}}' \
             '{"tool_name":"Skill","tool_input":{}}' 'not json' ''; do
  if [ -z "$(hook_out "$input")" ]; then ok "approval hook stays silent for: ${input:-<empty>}"
  else bad "approval hook stays silent for: ${input:-<empty>}"; fi
done
if jq -e '.hooks.PreToolUse | any((.matcher | split("|") | index("Skill") != null) and any(.hooks[]; (.command | contains("scripts/approve-own-tools.mjs"))))' "$REPO/hooks/hooks.json" >/dev/null 2>&1 \
   && [ -f "$HOOK" ]; then ok "hooks.json registers scripts/approve-own-tools.mjs on PreToolUse"
else bad "hooks.json registers scripts/approve-own-tools.mjs on PreToolUse"; fi
matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$REPO/hooks/hooks.json" 2>/dev/null)
if [ "$matcher" = "Skill|Bash|mcp__plugin_local-llm_local-llm__code_task_files|mcp__plugin_local-llm_local-verify__verify_claims" ]; then
  ok "PreToolUse matcher covers Skill, Bash and the two read-only file tools"
else bad "PreToolUse matcher is: $matcher"; fi

# --- size-hint hook (UserPromptSubmit) -------------------------------------------
SH="$REPO/scripts/size-hint.mjs"
unset CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS # test the manifest default unless a case overrides it
node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/context.port" "$TMP/context.log" context 32768 &
CONTEXT_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/context.port" ] && break; sleep 0.1; done
[ -s "$TMP/context.port" ] || { echo "FAIL: context endpoint did not start"; exit 1; }
HINT_ENDPOINT="http://127.0.0.1:$(cat "$TMP/context.port")"
hint_out() { printf '%s' "$1" | LOCAL_LLM_ENDPOINT_URL="$HINT_ENDPOINT" LOCAL_LLM_MODEL= node "$SH"; }
SHD="$TMP/hint"; mkdir -p "$SHD/a dir"
head -c 35000 /dev/zero | tr '\0' 'a' > "$SHD/big.txt"; head -c 35000 /dev/zero | tr '\0' 'a' > "$SHD/a dir/big file.txt"
head -c 29999 /dev/zero | tr '\0' 'a' > "$SHD/just-under.txt"; head -c 300 /dev/zero | tr '\0' 'a' > "$SHD/small.txt"
for n in 1 2 3 4; do head -c 35000 /dev/zero | tr '\0' 'a' > "$SHD/many$n.txt"; done
# the prompt goes through stdin: a 260 KB value would exceed a single argument's limit on some systems
hint_json() { printf '%s' "$1" | jq -Rsc --arg c "$SHD" '{hook_event_name:"UserPromptSubmit",cwd:$c,prompt:.}'; }
# Unsaved options use the manifest's empty default; no instruction for an ordinary big file.
h=$(hint_out "$(hint_json "$SHD/big.txt")")
if [ -z "$h" ]; then ok "size hint: default is silent for a 35k file"
else bad "size hint: default emitted an instruction ($h)"; fi
head -c 45876 /dev/zero | tr '\0' 'a' > "$SHD/over-cap.txt"
h=$(hint_out "$(hint_json "$SHD/big.txt $SHD/over-cap.txt")")
if [ -n "$h" ] && jq -e '.hookSpecificOutput.additionalContext | (contains("over-cap.txt") and contains("too big for the loaded model") and (contains("invoke") | not) and (contains("big.txt") | not))' >/dev/null <<<"$h"; then
  ok "size hint: default retains only the too-big note"
else bad "size hint: default lost the too-big note ($h)"; fi
# Path parsing and metadata tests below deliberately opt in.
export CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS=classify,extract
h=$(hint_out "$(hint_json "Classify this document: $SHD/big.txt")")
if jq -e --arg p "$SHD/big.txt" '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | startswith("local-llm: " + $p + " is about 35,000 bytes (a char proxy). Context cap: 32,768 tokens, about 45,875 chars; loaded. If this turn\u0027s job on it is a read-only classify or extract task, invoke the local-llm:delegate-local skill with the Skill tool before reading the file, instead of reading it yourself; this holds for the user\u0027s own project files too. Send the Skill call and ToolSearch query \"select:mcp__plugin_local-llm_local-llm__code_task_files\" in the same assistant message (they are independent), and use the stated size instead of running `wc -c` again."))' >/dev/null <<<"$h"; then
  ok "size hint: classify,extract opt-in emits for a big absolute path"
else bad "size hint: emits for a big absolute path ($h)"; fi
h=$(CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS="classify,extract,summarize" hint_out "$(hint_json "$SHD/big.txt")")
if [ -n "$h" ] && jq -e '.hookSpecificOutput.additionalContext | contains("read-only classify, extract or summarize task, invoke")' >/dev/null <<<"$h"; then
  ok "size hint: delegate_tasks can enable measured summaries"
else bad "size hint: delegate_tasks summary override ($h)"; fi
head -c 45876 /dev/zero | tr '\0' 'a' > "$SHD/over-cap.txt"
for tasks in "" "unknown"; do
  h=$(CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS="$tasks" hint_out "$(hint_json "$SHD/big.txt $SHD/over-cap.txt")" 2>"$TMP/task-kinds.err")
  if [ -n "$h" ] && jq -e '.hookSpecificOutput.additionalContext | (contains("over-cap.txt") and contains("too big for the loaded model") and (contains("invoke") | not) and (contains("big.txt") | not))' >/dev/null <<<"$h"; then
    ok "size hint: empty or unknown task kinds keep only the too-big note ($tasks)"
  else bad "size hint: disabled task kinds ($tasks): $h"; fi
  h=$(CLAUDE_PLUGIN_OPTION_DELEGATE_TASKS="$tasks" hint_out "$(hint_json "$SHD/big.txt")" 2>"$TMP/task-kinds.err")
  if [ -z "$h" ]; then ok "size hint: disabled task kinds emit no fitting-file instruction ($tasks)"
  else bad "size hint: disabled task kinds still emit: $h"; fi
done
h=$(hint_out "$(hint_json "Classify big.txt please.")")
if jq -e '.hookSpecificOutput.additionalContext | contains("big.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: resolves a relative path against the input cwd"
else bad "size hint: relative path ($h)"; fi
h=$(hint_out "$(hint_json "Summarize (\"$SHD/a dir/big file.txt\")")")
if jq -e '.hookSpecificOutput.additionalContext | contains("a dir/big file.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: handles a parenthesized quoted path with spaces"
else bad "size hint: parenthesized quoted path with spaces ($h)"; fi
head -c 35000 /dev/zero | tr '\0' 'a' > "$SHD/customer's-notes.md"
h=$(hint_out "$(hint_json "Summarize $SHD/customer's-notes.md please")")
if jq -e '.hookSpecificOutput.additionalContext | contains("customer'"'"'s-notes.md is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: an unquoted path with an apostrophe in its name"
else bad "size hint: apostrophe in a file name ($h)"; fi
h=$(hint_out "$(hint_json "Don't summarize 'x' for me, just $SHD/big.txt")")
if jq -e '.hookSpecificOutput.additionalContext | contains("big.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: an apostrophe in prose does not hide a path"
else bad "size hint: apostrophe in prose ($h)"; fi
h=$(hint_out "$(hint_json "Summarize \"$SHD/a dir/big file.txt\"")")
if jq -e '.hookSpecificOutput.additionalContext | contains("a dir/big file.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: handles a quoted path with spaces"
else bad "size hint: quoted path with spaces ($h)"; fi
for p in "Summarize $SHD/small.txt" "Summarize $SHD/just-under.txt" "Summarize $SHD/missing.txt" "Summarize $SHD" "Summarize $SHD/a dir" "Say hello" ""; do
  if [ -z "$(hint_out "$(hint_json "$p")")" ]; then ok "size hint: silent for: ${p:-<empty prompt>}"
  else bad "size hint: silent for: ${p:-<empty prompt>}"; fi
done
for bad_in in 'not json' '' '{"prompt":42}' '{}'; do
  if [ -z "$(hint_out "$bad_in")" ]; then ok "size hint: silent for input: ${bad_in:-<empty>}"
  else bad "size hint: silent for input: ${bad_in:-<empty>}"; fi
done
h=$(hint_out "$(hint_json "Compare $SHD/many1.txt $SHD/many2.txt $SHD/many3.txt $SHD/many4.txt")")
if [ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$h" | wc -l | tr -d ' ')" = 4 ]; then ok "size hint: caps the hint at 3 files"
else bad "size hint: caps the hint at 3 files ($h)"; fi
many_words=$(awk 'BEGIN{for(i=0;i<130000;i++) printf "w "}')
h=$(hint_out "$(hint_json "$many_words $SHD/big.txt")"); rc=$?
if [ "$rc" -eq 0 ] && jq -e '.hookSpecificOutput.additionalContext | contains("big.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: 130k short words do not crash it, and the path after them still gets the hint"
else bad "size hint: 130k short words (rc=$rc, ${h:0:100})"; fi
filler=$(awk 'BEGIN{for(i=0;i<400;i++) printf "word%d ", i}')
h=$(hint_out "$(hint_json "$filler $SHD/big.txt")")
if jq -e '.hookSpecificOutput.additionalContext | contains("big.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: a path after 400 filler words gets the hint"
else bad "size hint: path after 400 filler words (${h:0:100})"; fi
h=$(printf '%s' "$(hint_json "Classify ~/big.txt")" | HOME="$SHD" LOCAL_LLM_ENDPOINT_URL="$HINT_ENDPOINT" LOCAL_LLM_MODEL= node "$SH")
if jq -e '.hookSpecificOutput.additionalContext | contains("/big.txt is about 35,000 bytes")' >/dev/null <<<"$h"; then ok "size hint: expands ~/ against HOME"
else bad "size hint: ~/ path (${h:0:100})"; fi
h=$(hint_out "$(hint_json "Compare \"$SHD/big.txt\" with $SHD/big.txt and big.txt")")
if [ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$h" | wc -l | tr -d ' ')" = 1 ]; then ok "size hint: one file named quoted and bare gets one line"
else bad "size hint: dedupe (${h:0:200})"; fi
long_prompt="Summarize $SHD/big.txt $(head -c 200000 /dev/zero | tr '\0' 'x')"
t0=$SECONDS
for _ in 1 2 3 4 5; do hint_out "$(hint_json "$long_prompt")" >/dev/null; done
if [ $((SECONDS - t0)) -le 5 ]; then ok "size hint: five runs on a 200 KB prompt finish within 5 s"
else bad "size hint: five runs took $((SECONDS - t0)) s"; fi
if jq -e '.hooks.UserPromptSubmit | any(.[]; any(.hooks[]; (.command | contains("scripts/size-hint.mjs"))))' "$REPO/hooks/hooks.json" >/dev/null 2>&1; then ok "hooks.json registers scripts/size-hint.mjs on UserPromptSubmit"
else bad "hooks.json registers scripts/size-hint.mjs on UserPromptSubmit"; fi

st=$(DELEG_SELFTEST=1 DELEG_JUDGE=stub bash "$SCRIPT_DIR/test-delegation.sh" 2>&1); st_rc=$?
st_calls=$(grep -cE '^  expect(_[a-z_]+)? "' "$SCRIPT_DIR/test-delegation.sh")
st_total=$(sed -n 's/^selftest total: \([0-9]*\), failed: 0$/\1/p' <<<"$st")
if [ "$st_rc" -eq 0 ] && [ -n "$st_total" ] && [ "$st_total" -eq "$st_calls" ] && ! grep -q 'selftest FAIL' <<<"$st"; then
  ok "delegation scorers pass their offline self-test ($st_total of $st_calls assertions)"
else bad "delegation scorer self-test (rc=$st_rc, total=${st_total:-none}, expect calls=$st_calls): $(grep 'selftest FAIL' <<<"$st" | head -3 | tr '\n' ';')"; fi
if ! grep -nE '^[[:space:]]*#[[:space:]]*expect(_[a-z_]+)?[[:space:]]+"' "$SCRIPT_DIR/test-delegation.sh" >/dev/null; then ok "no commented-out scorer assertions"
else bad "commented-out scorer assertion: $(grep -nE '^[[:space:]]*#[[:space:]]*expect(_[a-z_]+)?[[:space:]]+"' "$SCRIPT_DIR/test-delegation.sh" | head -2)"; fi
if [ "$(jq 'length' "$SCRIPT_DIR/fixtures/deleg/judge-labels.json" 2>/dev/null)" = 24 ]; then ok "judge self-check has its 24 labeled messages"
else bad "judge-labels.json does not hold 24 items"; fi
ms=$(bash "$REPO/measure/selftest.sh" 2>&1); ms_rc=$?
ms_calls=$(grep -cE '^check "' "$REPO/measure/selftest.sh")
ms_total=$(sed -n 's/^measure selftest total: \([0-9]*\), failed: 0$/\1/p' <<<"$ms")
if [ "$ms_rc" -eq 0 ] && [ -n "$ms_total" ] && [ "$ms_total" -eq "$ms_calls" ] && ! grep -q 'measure selftest FAIL' <<<"$ms"; then
  ok "measurement harness passes its offline self-test ($ms_total of $ms_calls assertions)"
else bad "measurement harness self-test (rc=$ms_rc, total=${ms_total:-none}, check calls=$ms_calls): $(grep 'measure selftest FAIL' <<<"$ms" | head -3 | tr '\n' ';')"; fi
allowed=$(sed -n 's/^allowed-tools: //p' "$skill")
missing=""
for t in $allowed; do grep -qF "\`$t\`" "$skill" || missing="$missing $t"; done
if [ -n "$allowed" ] && [ -z "$missing" ]; then ok "every allowed-tools entry in the skill also appears in its names table"
else bad "skill allowed-tools entries missing from the names table:${missing:- (no allowed-tools line)}"; fi
if [ "$(wc -l < "$skill")" -le 80 ]; then ok "skill stays within its 80-line budget"
else bad "skill is over its 80-line budget ($(wc -l < "$skill") lines)"; fi

# --- context bounds: helper, hook and default batch window (offline) ------------
if node --test "$SCRIPT_DIR/test-context-cap.mjs" > "$TMP/context-tests.log" 2>&1; then
  ok "context bounds suite (helper, hook and batch integration)"
else bad "context bounds suite: $(tail -15 "$TMP/context-tests.log" | tr '\n' ';')"; fi

# the hook reads the plugin's own endpoint_url and model options (Claude Code exports them to hooks as CLAUDE_PLUGIN_OPTION_*)
node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/context16.port" "$TMP/context16.log" context 16384,65536 &
CTX16_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/context16.port" ] && break; sleep 0.1; done
[ -s "$TMP/context16.port" ] || { echo "FAIL: context16 endpoint did not start"; exit 1; }
h=$(printf '%s' "$(hint_json "Classify $SHD/big.txt")" | env LOCAL_LLM_ENDPOINT_URL="$HINT_ENDPOINT" LOCAL_LLM_MODEL=fake-context CLAUDE_PLUGIN_OPTION_ENDPOINT_URL="http://127.0.0.1:$(cat "$TMP/context16.port")" CLAUDE_PLUGIN_OPTION_MODEL=fake-context-2 node "$SH")
if jq -e '.hookSpecificOutput.additionalContext | (contains("invoke the local-llm:delegate-local skill") and contains("65,536 tokens, about 98,304 chars; loaded"))' >/dev/null <<<"$h"; then ok "size hint: plugin endpoint_url and model options beat conflicting shell values (pin selects 64k over the 16k minimum)"
else bad "size hint: plugin endpoint_url option ignored ($h)"; fi
kill "$CTX16_PID" 2>/dev/null; wait "$CTX16_PID" 2>/dev/null; CTX16_PID=""

# --- the local-verify server: its own offline suite (fake endpoint only) --------
vt=$(bash "$SCRIPT_DIR/test-verify.sh" 2>&1); vt_rc=$?
if [ "$vt_rc" -eq 0 ] && grep -q '^verify pass=[1-9][0-9]* fail=0$' <<<"$vt"; then ok "local-verify suite ($(tail -1 <<<"$vt"))"
else bad "local-verify suite (rc=$vt_rc): $(grep -E 'FAIL|^verify pass' <<<"$vt" | head -5 | tr '\n' ';')"; fi

# --- the batch runner: its own offline suite (fake endpoint only) ----------------
bt=$(bash "$SCRIPT_DIR/test-batch.sh" 2>&1); bt_rc=$?
if [ "$bt_rc" -eq 0 ] && grep -q '^batch pass=[1-9][0-9]* fail=0$' <<<"$bt"; then ok "batch runner suite ($(tail -1 <<<"$bt"))"
else bad "batch runner suite (rc=$bt_rc): $(grep -E 'FAIL|^batch pass' <<<"$bt" | head -5 | tr '\n' ';')"; fi

# --- model-backed cases --------------------------------------------------------
gen_text 20000 > "$TMP/root/twenty-k.txt"

# --- the outage strings the skill keys on (skills/delegate-local/SKILL.md, names table) ---
dead_port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
out=$(LOCAL_LLM_ENDPOINT_URL="http://127.0.0.1:$dead_port" read_files "$TMP/root" "$TMP/root/twenty-k.txt")
if jq -e '.call.isError and (.call.text | contains("fetch failed"))' >/dev/null <<<"$out"; then ok "dead endpoint: the tool error says 'fetch failed'"
else bad "dead endpoint: expected 'fetch failed' ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/nm-port" "$TMP/nm-requests.log" no-model &
NM_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/nm-port" ] && break; sleep 0.1; done
if [ -s "$TMP/nm-port" ]; then
  out=$(LOCAL_LLM_ENDPOINT_URL="http://127.0.0.1:$(cat "$TMP/nm-port")" read_files "$TMP/root" "$TMP/root/twenty-k.txt")
  if jq -e '.call.isError and (.call.text | contains("No models loaded"))' >/dev/null <<<"$out"; then ok "no-model endpoint: the tool error says 'No models loaded'"
  else bad "no-model endpoint: expected 'No models loaded' ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
else bad "no-model fake endpoint did not start"; fi
node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/e5-port" "$TMP/e5-requests.log" error500 &
E5_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/e5-port" ] && break; sleep 0.1; done
if [ -s "$TMP/e5-port" ]; then
  out=$(LOCAL_LLM_ENDPOINT_URL="http://127.0.0.1:$(cat "$TMP/e5-port")" read_files "$TMP/root" "$TMP/root/twenty-k.txt")
  if jq -e '.call.isError and (.call.text | test("^Error: .*endpoint error 500")) and (.call.text | contains("No models loaded") | not)' >/dev/null <<<"$out"; then
    ok "HTTP 500 endpoint: the tool error is 'Error: … endpoint error 500' (the skill's Other failure row)"
  else bad "HTTP 500 endpoint: expected 'endpoint error 500' ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
  kill "$E5_PID" 2>/dev/null
else bad "error500 fake endpoint did not start"; fi

# malformed calls get houtini's own argument errors (the skill's "Bad call" row)
out=$(run_launcher "$TMP/root" code_task_files '{"paths":["relative/file.txt"],"task":"x"}')
if jq -e '.call.isError and (.call.text | contains("Error: all paths must be absolute"))' >/dev/null <<<"$out"; then ok "relative paths: the tool error says 'all paths must be absolute'"
else bad "relative paths: expected 'all paths must be absolute' ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
out=$(run_launcher "$TMP/root" code_task_files '{"paths":[],"task":"x"}')
if jq -e '.call.isError and (.call.text | contains("Error: paths must be a non-empty array"))' >/dev/null <<<"$out"; then ok "empty paths: the tool error says 'paths must be a non-empty array'"
else bad "empty paths: expected 'paths must be a non-empty array' ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi

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
