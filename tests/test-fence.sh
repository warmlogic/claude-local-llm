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

TMP=$(mktemp -d)                                  # outside $HOME's repo; holds roots and fixtures
HOME_TMP=$(mktemp -d "$REPO/tests/.tmp-XXXXXX")   # under $HOME when the repo is
trap 'rm -rf "$TMP" "$HOME_TMP"' EXIT

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
# gen_text <chars>: deterministic synthetic text, about 2.7 chars per token
gen_text() {
  awk -v n="$1" 'BEGIN{while(length(s)<n){i++; s=s sprintf("Record %d: the inventory of station %d lists %d widgets, %d gadgets, and note code %x.\n", i, i%97, (i*7)%113, (i*13)%251, i*2654435761%65536)} printf "%s", substr(s,1,n)}'
}

echo "fence test suite (LM Studio reachable: $lm_up)"

# --- fail closed: no usable root means houtini never starts --------------------
check_refuses() {
  local label="$1" dirs="$2" out
  out=$(run_launcher "$dirs")
  if [ "$(jq -r '.init' <<<"$out")" = "false" ] \
     && [ "$(jq -r '.exit' <<<"$out")" != "null" ] && [ "$(jq -r '.exit' <<<"$out")" != "0" ]; then
    ok "launcher refuses to start: $label"
  else
    bad "launcher refuses to start: $label ($out)"
  fi
}
check_refuses "empty allowed_dirs" ""
check_refuses "whitespace-only allowed_dirs" "   "
check_refuses "only empty entries" " , ,"
check_refuses "relative entry" "some/relative/dir"
check_refuses "root '/' entry" "/"
out=$(env -u LOCAL_LLM_ALLOWED_DIRS node "$DRIVER" "$LAUNCHER")
if [ "$(jq -r '.init' <<<"$out")" = "false" ] && [ "$(jq -r '.exit' <<<"$out")" != "null" ] \
   && [ "$(jq -r '.exit' <<<"$out")" != "0" ]; then ok "launcher refuses to start: allowed_dirs unset"
else bad "launcher refuses to start: allowed_dirs unset ($out)"; fi
out=$(run_launcher "")
if jq -e '.stderr | test("no allowed folders")' >/dev/null <<<"$out"; then ok "refusal names the problem on stderr"
else bad "refusal names the problem on stderr ($out)"; fi

# --- loopback only: a remote endpoint is refused before houtini starts ---------
for ep in "http://example.com:1234" "http://127.0.0.1.example.com:1234" "http://user@evil.example/" "http://localhost:1@evil.example/" "ftp://127.0.0.1" "127.0.0.1:1234" "http://10.0.0.5:1234"; do
  out=$(LOCAL_LLM_ENDPOINT_URL="$ep" run_launcher "$TMP")
  if [ "$(jq -r '.init' <<<"$out")" = "false" ] && [ "$(jq -r '.exit' <<<"$out")" != "null" ] \
     && [ "$(jq -r '.exit' <<<"$out")" != "0" ] && jq -e '.stderr | test("loopback")' >/dev/null <<<"$out"; then
    ok "launcher refuses non-loopback endpoint: $ep"
  else
    bad "launcher refuses non-loopback endpoint: $ep ($out)"
  fi
done
for ep in "http://127.0.0.1:1234" "http://localhost:1234/v1" "http://[::1]:1234"; do
  out=$(LOCAL_LLM_ENDPOINT_URL="$ep" run_launcher "$TMP")
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

# --- $HOME and ~ in the configured roots are expanded --------------------------
case "$HOME_TMP" in
  "$HOME"/*)
    rel=${HOME_TMP#"$HOME"/}
    echo "home-relative fixture" > "$HOME_TMP/note.txt"
    for form in '$HOME' '${HOME}' '~'; do
      out=$(read_files "$form/$rel" "$HOME_TMP/note.txt")
      if jq -e '.init and (.call.text | test("outside the allowed roots") | not)' >/dev/null <<<"$out" \
         && { [ "$lm_up" = 0 ] || jq -e '.call != null and .call.isError == false' >/dev/null <<<"$out"; }; then
        ok "root given as literal $form/... is expanded"
      else
        bad "root given as literal $form/... is expanded ($(jq -c '.call' <<<"$out" | cut -c1-300))"
      fi
    done ;;
  *) skp "repo is not under \$HOME; \$HOME expansion cases" ;;
esac

# --- model-backed cases --------------------------------------------------------
gen_text 20000 > "$TMP/root/twenty-k.txt"
if [ "$lm_up" = 1 ]; then
  out=$(read_files "$TMP/root" "$TMP/root/twenty-k.txt")
  if jq -e '(.call != null and .call.isError == false) and (.call.text | test("1 file\\(s\\) read")) and (.call.text | test("Model:"))' >/dev/null <<<"$out"; then
    ok "happy path: ~20k-char file summarized, footer shows 1 file(s) read"
  else
    bad "happy path ($(jq -c '.call' <<<"$out" | cut -c1-300))"
  fi

  # Over the model's context window houtini surfaces the upstream error; no summary.
  gen_text 130000 > "$TMP/root/huge.txt"
  out=$(read_files "$TMP/root" "$TMP/root/huge.txt")
  if jq -e '.call.isError and (.call.text | test("context")) and (.call.text | test("Model:") | not)' >/dev/null <<<"$out"; then
    ok "oversized: ~130k chars exceeds the context window, error and no summary"
  elif jq -e '.call != null and .call.isError == false' >/dev/null <<<"$out"; then
    skp "oversized: loaded model's context fits ~130k chars; raise the fixture size"
  else
    bad "oversized ($(jq -c '.call' <<<"$out" | cut -c1-300))"
  fi
else
  skp "happy path: LM Studio not reachable at $ENDPOINT"
  skp "oversized: LM Studio not reachable at $ENDPOINT"
fi

echo
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
