#!/usr/bin/env bash
# Offline tests for the local-verify server (scripts/launch-verify.sh + server/*.mjs).
# Run from repo root: bash tests/test-verify.sh (test-fence.sh runs it on every commit).
# Every model answer comes from tests/fake-endpoint.mjs in a verify mode; nothing needs LM Studio.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$SCRIPT_DIR/.."
LAUNCHER="$REPO/scripts/launch-verify.sh"
DRIVER="$SCRIPT_DIR/mcp-call.mjs"
RAW="$SCRIPT_DIR/mcp-raw.mjs"
TOOL=verify_claims

pass=0; fail=0; tn=0
ok()  { pass=$((pass+1)); tn=$((tn+1)); echo "  Test $tn PASS: $1"; }
bad() { fail=$((fail+1)); tn=$((tn+1)); echo "  Test $tn FAIL: $1"; }

for tool in node jq mkfifo; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required to run this suite"; exit 1; }
done

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT

# start_fake <name> <mode> [redirect-url]: a fake endpoint on a random loopback port; sets EP and LOG
start_fake() {
  : > "$TMP/$1.log"
  node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/$1.port" "$TMP/$1.log" "$2" ${3:+"$3"} &
  PIDS+=($!)
  for _ in $(seq 1 50); do [ -s "$TMP/$1.port" ] && break; sleep 0.1; done
  [ -s "$TMP/$1.port" ] || { echo "FAIL: fake endpoint '$1' ($2) did not start"; exit 1; }
  EP="http://127.0.0.1:$(cat "$TMP/$1.port")"; LOG="$TMP/$1.log"
}
chat_count() { jq -s '[.[] | select(.headers and .url == "/v1/chat/completions")] | length' "$1"; }  # one header line per request
# call <json-args> [env...]: one verify_claims call through the launcher, fenced to $ROOT, against $EP
call() {
  local args="$1"; shift
  env LOCAL_LLM_ALLOWED_DIRS="$ROOT" LOCAL_LLM_ENDPOINT_URL="$EP" LOCAL_LLM_MODEL= "$@" node "$DRIVER" "$LAUNCHER" "$TOOL" "$args"
}
claims_on() { # <path> <claims-json> [k]: tool arguments
  jq -nc --arg p "$1" --argjson c "$2" --argjson k "${3:-10}" '{paths:[$p], claims:$c, k:$k}'
}
did_not_start() { # <json> <stderr-fragment>
  jq -e --arg f "$2" '(.timedOut | not) and (.init | not) and .exit != null and .exit != 0 and (.stderr | contains($f))' >/dev/null <<<"$1"
}
call_text() { jq -r '.call.text // empty' <<<"$1"; }
brief() { jq -c '.call' <<<"$1" | cut -c1-300; }

echo "verify server test suite"

ROOT="$TMP/root"; mkdir -p "$ROOT" "$TMP/root-evil" "$TMP/outside" "$ROOT/sub"
REAL_ROOT=$(cd -P "$ROOT" && pwd -P)
echo "canary-outside" > "$TMP/outside/secret.txt"
echo "canary-evil" > "$TMP/root-evil/sibling.txt"
printf 'canary-inside: the api service started with workers=8\n' > "$ROOT/inside.txt"
printf 'canary-second: the db service is on port 5432\n' > "$ROOT/second.txt"
ln -s "$TMP/outside/secret.txt" "$ROOT/link-out.txt"
awk 'BEGIN{while(n<1100000){s="canary-big line of synthetic text for the size cap\n"; printf "%s", s; n+=length(s)}}' > "$ROOT/big.txt"
awk 'BEGIN{while(n<600000){s="canary-half line of synthetic text for the combined cap\n"; printf "%s", s; n+=length(s)}}' > "$ROOT/half1.txt"
cp "$ROOT/half1.txt" "$ROOT/half2.txt"
: > "$ROOT/empty.txt"
printf 'canary-bin \377\376\000\001 binary' > "$ROOT/binary.bin"
mkfifo "$ROOT/pipe"
INSIDE="$ROOT/inside.txt"

# --- the launcher refuses to start without a fence or with a remote endpoint ---------------
EP=http://127.0.0.1:1234
for dirs in "" " , " "$TMP/nope" "relative/dir" "/"; do
  out=$(LOCAL_LLM_ALLOWED_DIRS="$dirs" LOCAL_LLM_ENDPOINT_URL="$EP" node "$DRIVER" "$LAUNCHER")
  if did_not_start "$out" "allowed folder"; then ok "launcher refuses allowed_dirs '${dirs}'"
  else bad "launcher refuses allowed_dirs '${dirs}' ($out)"; fi
done
for ep in "http://example.com:1234" "http://127.0.0.1.example.com:1234" "http://user@127.0.0.1:1234" \
          "http://localhost:1@evil.example/" "http://10.0.0.5:1234" "http://127.1:1234" "127.0.0.1:1234"; do
  out=$(LOCAL_LLM_ALLOWED_DIRS="$ROOT" LOCAL_LLM_ENDPOINT_URL="$ep" node "$DRIVER" "$LAUNCHER")
  if did_not_start "$out" "local-verify: endpoint must be loopback"; then ok "launcher refuses non-loopback endpoint $ep"
  else bad "launcher refuses non-loopback endpoint $ep ($out)"; fi
done
for v in abc 0 -5 1.5; do
  for name in LOCAL_VERIFY_REQUEST_TIMEOUT_MS LOCAL_VERIFY_BUDGET_MS; do
    out=$(env "$name=$v" LOCAL_LLM_ALLOWED_DIRS="$ROOT" LOCAL_LLM_ENDPOINT_URL="$EP" node "$DRIVER" "$LAUNCHER")
    if did_not_start "$out" "$name must be a positive integer"; then ok "server refuses $name=$v"
    else bad "server refuses $name=$v ($out)"; fi
  done
done

# --- the server re-checks both itself when run without the launcher -------------------------
printf '#!/bin/sh\nexec node "%s/server/verify-server.mjs"\n' "$REPO" > "$TMP/direct.sh"; chmod +x "$TMP/direct.sh"
out=$(LOCAL_VERIFY_ROOTS="$ROOT" LOCAL_LLM_ENDPOINT_URL=http://example.com:1234 node "$DRIVER" "$TMP/direct.sh")
if did_not_start "$out" "loopback"; then ok "server refuses a non-loopback endpoint in code"
else bad "server refuses a non-loopback endpoint in code ($out)"; fi
for roots in "" "/" "relative"; do
  out=$(env LOCAL_VERIFY_ROOTS="$roots" LOCAL_LLM_ENDPOINT_URL=http://127.0.0.1:1234 node "$DRIVER" "$TMP/direct.sh")
  if did_not_start "$out" "allowed folder"; then ok "server refuses roots '${roots}' in code"
  else bad "server refuses roots '${roots}' in code ($out)"; fi
done

# --- protocol: version negotiation, tools/list, and no request shape can take the server down ---
start_fake ok verify
init() { jq -nc --arg v "$2" --argjson id "$1" '{jsonrpc:"2.0",id:$id,method:"initialize",params:{protocolVersion:$v,capabilities:{},clientInfo:{name:"t",version:"0"}}}'; }
lines=$(jq -nc --argjson a "$(init 1 2025-06-18)" --argjson b "$(init 2 1999-01-01)" '[$a, $b,
  {jsonrpc:"2.0",id:3,method:"tools/list"},
  {jsonrpc:"2.0",id:4,method:{toString:null}},
  {jsonrpc:"2.0",id:{x:1},method:"ping"},
  {jsonrpc:"2.0",id:5,method:"ping",params:[1]},
  "not json", "[1,2]", "null",
  {jsonrpc:"2.0",id:6,method:"no/such/method"},
  {jsonrpc:"2.0",id:7,method:"tools/call",params:{name:{toString:null}}},
  {jsonrpc:"2.0",id:8,method:"tools/call",params:{name:"other_tool",arguments:{}}},
  {jsonrpc:"2.0",id:9,method:"tools/call",params:{name:"verify_claims",arguments:"x"}},
  {jsonrpc:"2.0",method:"notifications/initialized"},
  {jsonrpc:"2.0",id:10,method:"ping"}]')
out=$(LOCAL_LLM_ALLOWED_DIRS="$ROOT" LOCAL_LLM_ENDPOINT_URL="$EP" node "$RAW" "$LAUNCHER" "$lines" 14)
rsp() { jq -c --argjson i "$1" '.responses[] | select(.id == $i) | del(.at_ms)' <<<"$out"; }
if jq -e '.responses[0].result.protocolVersion == "2025-06-18" and .responses[1].result.protocolVersion == "2025-11-25"
          and .responses[0].result.capabilities == {tools:{}} and .responses[0].result.serverInfo.name == "local-verify"' >/dev/null <<<"$out"; then
  ok "initialize echoes a supported protocol version and answers 2025-11-25 for an unknown one"
else bad "version negotiation ($(jq -c '.responses[0:2]' <<<"$out" | cut -c1-300))"; fi
if rsp 3 | jq -e '.result.tools | length == 1 and .[0].name == "verify_claims" and .[0].inputSchema.required == ["paths","claims"]
                  and .[0].annotations.readOnlyHint and (.[0].description | contains("lookup"))' >/dev/null; then
  ok "tools/list offers verify_claims with paths and claims required"
else bad "tools/list ($(rsp 3 | cut -c1-300))"; fi
codes=$(jq -c '[.responses[] | select(.error) | [.id, .error.code]]' <<<"$out")
want='[[4,-32600],[null,-32600],[5,-32602],[null,-32700],[null,-32600],[null,-32600],[6,-32601],[7,-32602],[8,-32602],[9,-32602]]'
if [ "$codes" = "$want" ]; then ok "malformed, unknown and ill-typed requests get JSON-RPC errors"
else bad "JSON-RPC errors: got $codes, want $want"; fi
if rsp 10 | jq -e '.result == {}' >/dev/null && jq -e '.exit == null and (.timedOut | not)' >/dev/null <<<"$out"; then
  ok "a ping after the malformed requests still succeeds; the server is still running"
else bad "server survived malformed requests ($(jq -c '{exit,timedOut,stderr}' <<<"$out" | cut -c1-300))"; fi

# --- the fence: nothing outside the roots is read, nothing is sent, no file text comes back ----
check_refused() { # <label> <path> <message-fragment>
  local before after out
  before=$(chat_count "$LOG")
  out=$(call "$(claims_on "$2" '["[yes] The api service started."]')")
  after=$(chat_count "$LOG")
  if jq -e --arg f "$3" '.call.isError and (.call.text | startswith("Error:")) and (.call.text | contains($f))' >/dev/null <<<"$out" \
     && ! grep -q canary <<<"$out" && [ "$before" = "$after" ]; then ok "refused: $1"
  else bad "refused: $1 (chat requests $before -> $after; $(brief "$out"))"; fi
}
OUTSIDE="outside the allowed folders ($REAL_ROOT); widen allowed_dirs in the plugin options if intended"
check_refused "path outside every root, naming the allowed folders" "$TMP/outside/secret.txt" "$OUTSIDE"
check_refused "symlink inside the root pointing outside it" "$ROOT/link-out.txt" "outside the allowed folders"
check_refused "sibling directory sharing the root's name prefix" "$TMP/root-evil/sibling.txt" "outside the allowed folders"
check_refused "dot-dot escape from inside the root" "$ROOT/../outside/secret.txt" "outside the allowed folders"
check_refused "relative path" "root/inside.txt" "must be absolute"
check_refused "missing file" "$ROOT/missing.txt" "no such file"
check_refused "a directory" "$ROOT/sub" "not a regular file"
check_refused "a FIFO (opened non-blocking, so no hang)" "$ROOT/pipe" "not a regular file"
check_refused "file over 1 MB, sized in bytes near the cap" "$ROOT/big.txt" "file is $(wc -c < "$ROOT/big.txt" | tr -d ' ') bytes, over the 1 MB limit"
check_refused "empty file" "$ROOT/empty.txt" "the file is empty"
check_refused "binary file" "$ROOT/binary.bin" "not UTF-8 text"
out=$(call "$(jq -nc --arg a "$INSIDE" --arg b "$TMP/outside/secret.txt" '{paths:[$a,$b], claims:["[yes] x"]}')")
if jq -e '.call.isError and (.call.text | contains("outside the allowed folders"))' >/dev/null <<<"$out" && ! grep -q canary <<<"$out"; then
  ok "one path outside the roots fails the whole call"
else bad "one path outside the roots fails the whole call ($(brief "$out"))"; fi
out=$(call "$(jq -nc --arg a "$ROOT/missing.txt" --arg b "$TMP/outside/secret.txt" --arg c "$INSIDE" '{paths:[$a,$b,$c], claims:["[yes] x"]}')")
if jq -e --arg a "$ROOT/missing.txt: no such file" --arg b "$TMP/outside/secret.txt: path is outside" \
     '.call.isError and (.call.text | contains("cannot use 2 paths") and contains($a) and contains($b))' >/dev/null <<<"$out" && ! grep -q canary <<<"$out"; then
  ok "several bad paths: every one is listed with its cause"
else bad "several bad paths ($(brief "$out"))"; fi
before=$(chat_count "$LOG")
out=$(call "$(jq -nc --arg a "$ROOT/half1.txt" --arg b "$ROOT/half2.txt" '{paths:[$a,$b], claims:["[yes] x"]}')")
if jq -e '.call.isError and (.call.text | contains("over the 1 MB combined limit"))' >/dev/null <<<"$out" \
   && ! grep -q canary <<<"$out" && [ "$(chat_count "$LOG")" = "$before" ]; then ok "files over 1 MB combined are refused before any request"
else bad "combined cap ($(brief "$out"))"; fi

# --- JSON shape, declared kinds, vote shares and the request each sample sends ----------------
: > "$LOG"
out=$(call "$(claims_on "$INSIDE" '["[yes] The api service started.", {"text":"[split] The api service stopped.","kind":"lookup"}, {"text":"The service is written in Go."}]')")
res=$(call_text "$out")
if jq -e '.call.isError == false' >/dev/null <<<"$out" && jq -e '
     .model == "fake-verify-model" and .k == 10 and (.results | length == 3) and (has("partial") | not)
     and all(.results[]; keys == ["agreement","auto_accept","claim","kind","label","p_supported"] and .auto_accept == false)
     and ([.results[] | [.kind, .label, .p_supported, .agreement]]
          == [["computed","SUPPORTED",1,1],["lookup","NOT_SUPPORTED",0.5,0.5],["computed","NOT_SUPPORTED",0,1]])
     and .results[1].claim == "[split] The api service stopped."' >/dev/null <<<"$res"; then
  ok "result shape: every result has auto_accept false; kind is as declared, computed when undeclared; votes collapse to two labels"
else bad "result shape ($(cut -c1-400 <<<"$res"))"; fi
if [ "$(chat_count "$LOG")" = 30 ] && jq -se '[.[] | select(.body) | .body] |
     all(.[]; .temperature == 1 and .reasoning_effort == "none" and .model == "fake-verify-model"
              and (.response_format.json_schema.schema.properties.label.enum | sort) == ["CONTRADICTED","NOT_IN_SOURCE","SUPPORTED"]
              and (.messages[-1].content | contains("canary-inside")))
     and ([.[].response_format.json_schema.schema.properties.label.enum] | unique | length) > 1
     and ([.[].seed] | unique | length) == 30' "$LOG" >/dev/null; then
  ok "k=10 samples per claim: temperature 1, reasoning off, schema-forced labels in shuffled orders, distinct seeds"
else bad "sample requests ($(chat_count "$LOG") chat requests)"; fi
peak=$(jq -s '[.[] | select(.body) | .inflight] | max' "$LOG")
if [ "$peak" -le 4 ] && [ "$peak" -ge 2 ]; then ok "at most 4 requests in flight (peak $peak of 30)"
else bad "concurrency peak $peak (want 2..4)"; fi
if ! grep -q canary <<<"$out"; then ok "the result never echoes file text"
else bad "the result echoes file text"; fi
: > "$LOG"
out=$(call "$(jq -nc --arg a "$INSIDE" --arg b "$ROOT/second.txt" '{paths:[$a,$b], claims:["[yes] x"], k:2}')")
if jq -e '.call.isError == false' >/dev/null <<<"$out" && ! grep -q canary <<<"$out" \
   && jq -se '[.[] | select(.body) | .body.messages[-1].content] | length == 2 and
              all(.[]; contains("=== inside.txt ===\ncanary-inside") and contains("=== second.txt ===\ncanary-second"))' "$LOG" >/dev/null; then
  ok "several files: each reaches every request under its own header; no file text comes back"
else bad "multi-file ($(brief "$out"))"; fi

# --- arguments are validated before anything is read or sent -------------------------------
long=$(printf 'x%.0s' $(seq 1 1001))
arg_case() { # <label> <json-args> <message-fragment>
  local before out
  before=$(chat_count "$LOG")
  out=$(call "$2")
  if jq -e --arg f "$3" '.call.isError and (.call.text | startswith("Error:")) and (.call.text | contains($f))' >/dev/null <<<"$out" \
     && [ "$(chat_count "$LOG")" = "$before" ]; then ok "invalid arguments refused: $1"
  else bad "invalid arguments refused: $1 ($(brief "$out"))"; fi
}
arg_case "no paths" "$(jq -nc '{paths:[], claims:["x"]}')" "paths must be an array of 1 to 10"
arg_case "11 paths" "$(jq -nc --arg p "$INSIDE" '{paths:[range(11) | $p], claims:["x"]}')" "paths must be an array of 1 to 10"
arg_case "a non-string path" "$(jq -nc '{paths:[5], claims:["x"]}')" "must be absolute strings"
arg_case "no claims" "$(claims_on "$INSIDE" '[]')" "claims must be an array of 1 to 20"
arg_case "21 claims" "$(claims_on "$INSIDE" "$(jq -nc '[range(21) | "x"]')")" "claims must be an array of 1 to 20"
arg_case "a claim over 1000 characters" "$(claims_on "$INSIDE" "[\"$long\"]")" "at most 1000 characters"
arg_case "a whitespace-only claim" "$(claims_on "$INSIDE" '["   "]')" "non-blank"
arg_case "a non-string claim" "$(claims_on "$INSIDE" '[5]')" "a string or {text, kind}"
arg_case "a claim with an unknown key" "$(claims_on "$INSIDE" '[{"text":"x","type":"lookup"}]')" "a string or {text, kind}"
arg_case "an unknown kind" "$(claims_on "$INSIDE" '[{"text":"x","kind":"maybe"}]')" 'kind must be "lookup" or "computed"'
for k in 0 2.5 1000; do
  arg_case "k=$k" "$(claims_on "$INSIDE" '["x"]' "$k")" "k must be an integer from 1 to 20"
done

# --- model selection: the pin, LM Studio's load state, the /v1/models fallback ----------------
: > "$LOG"
out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 2)" LOCAL_LLM_MODEL=pinned-model)
if jq -e '.call.isError == false and (.call.text | fromjson | .model == "pinned-model")' >/dev/null <<<"$out" \
   && ! grep -q '/api/v0/models' "$LOG" && jq -se '[.[] | select(.body) | .body.model] == ["pinned-model","pinned-model"]' "$LOG" >/dev/null; then
  ok "LOCAL_LLM_MODEL pins the model and skips the model lookup"
else bad "model pin ($(brief "$out"))"; fi
model_case() { # <label> <mode> <jq test on the call>
  local out
  start_fake "m-$2" "$2"
  out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 1)")
  if jq -e "$3" >/dev/null <<<"$out"; then ok "$1"; else bad "$1 ($(brief "$out"))"; fi
}
model_case "/v1/models fallback when /api/v0 is a 404, skipping the embeddings model" verify-v1 \
  '.call.isError == false and (.call.text | fromjson | .model == "v1-chat-model")'
model_case "/v1/models fallback with two chat models: refuses to guess" verify-v1-many \
  '.call.isError and (.call.text | contains("cannot tell which of 2 listed models is loaded"))'
model_case "/api/v0/models without load state: refuses to guess" verify-nostate \
  '.call.isError and (.call.text | contains("cannot tell which model is loaded"))'
model_case "/api/v0/models without a data array: an unexpected response, not 'nothing loaded'" verify-badlist \
  '.call.isError and (.call.text | contains("unexpected response from /api/v0/models"))'
model_case "both model lists 404: endpoint_url probably ends in /v1" verify-nolists \
  '.call.isError and (.call.text | contains("endpoint_url should be the server root, without /v1"))'
model_case "nothing loaded: 'No models loaded'" no-model \
  '.call.isError and (.call.text | contains("No models loaded"))'
if [ "$(chat_count "$LOG")" = 0 ]; then ok "no chat request goes out when no model is known to be loaded"
else bad "no-model: $(chat_count "$LOG") chat requests"; fi

# --- upstream errors are fixed diagnostics: no upstream text, no retry ------------------------
start_fake errs verify
upstream_case() { # <label> <claim> <message-fragment>
  local before out
  before=$(chat_count "$LOG")
  out=$(call "$(claims_on "$INSIDE" "[\"$2\"]" 1)")
  if jq -e --arg f "$3" '.call.isError and (.call.text | contains($f))' >/dev/null <<<"$out" && ! grep -q canary <<<"$out" \
     && [ "$(chat_count "$LOG")" = $((before + 1)) ]; then ok "$1"
  else bad "$1 ($(( $(chat_count "$LOG") - before )) requests; $(brief "$out"))"; fi
}
upstream_case "a 400 whose message echoes the prompt: status only, no file text" "[echo400] x" "endpoint error (HTTP 400)"
upstream_case "a 500 with an error field: status and allowlisted code, not retried" "[fail] x" "endpoint error (HTTP 500, server_error)"
upstream_case "a non-JSON 200: a fixed message, no body" "[html] x" "non-JSON response (HTTP 200)"
upstream_case "LM Studio's real context-overflow 400: the context hint, no file text" "[ctx] x" \
  "endpoint error (HTTP 400, context_length_exceeded): the files are too large for the model's context"
upstream_case "a 404 with code model_not_found: the model-option hint" "[nomodel] x" \
  "endpoint error (HTTP 404, model_not_found): check the model plugin option, or leave it empty"
printf 'canary-ctx: the context window is 32k tokens and the context length is fixed\n' > "$ROOT/mentions-context.txt"
out=$(call "$(claims_on "$ROOT/mentions-context.txt" '["[echo400] x"]' 1)")
if jq -e '.call.isError and (.call.text | endswith("endpoint error (HTTP 400)"))' >/dev/null <<<"$out" && ! grep -q canary <<<"$out"; then
  ok "a file that mentions the context window, echoed in a 400: no context hint is read out of the echo"
else bad "echoed context words ($(brief "$out"))"; fi
before=$(chat_count "$LOG")
out=$(call "$(claims_on "$INSIDE" '["[badfinish] x"]' 1)")
if jq -e '.call.isError and (.call.text | contains("finish_reason unrecognized, non-JSON content"))' >/dev/null <<<"$out" \
   && ! grep -q canary <<<"$out" && [ "$(chat_count "$LOG")" = $((before + 2)) ]; then
  ok "an answer whose finish_reason and content echo the prompt: neither is reported"
else bad "echoing finish_reason ($(brief "$out"))"; fi

# --- outages and redirects ------------------------------------------------------------------
dead_port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
out=$(EP="http://127.0.0.1:$dead_port" call "$(claims_on "$INSIDE" '["[yes] x"]')")
if jq -e '.call.isError and (.call.text | contains("fetch failed (ECONNREFUSED)"))' >/dev/null <<<"$out"; then ok "dead endpoint: 'fetch failed'"
else bad "dead endpoint ($(brief "$out"))"; fi
start_fake target verify; target_log=$LOG
start_fake redirect verify-redirect "$EP"
out=$(call "$(claims_on "$INSIDE" '["[yes] x"]')")
if jq -e '.call.isError and (.call.text | contains("HTTP 307): redirects are not followed"))' >/dev/null <<<"$out" \
   && [ "$(chat_count "$target_log")" = 0 ] && [ "$(chat_count "$LOG")" -ge 1 ] && ! grep -q canary <<<"$out"; then
  ok "a 307 from the endpoint is not followed: the call fails and the redirect target gets nothing"
else bad "redirect (target got $(chat_count "$target_log") chat requests; $(brief "$out"))"; fi

# --- no proxy: nothing reaches a proxy, through the launcher or with the server started directly ---
start_fake proxy proxy; proxy_ep=$EP proxy_log=$LOG
start_fake viaproxy verify
proxy_env=(HTTP_PROXY="$proxy_ep" http_proxy="$proxy_ep" HTTPS_PROXY="$proxy_ep" ALL_PROXY="$proxy_ep" NO_PROXY= no_proxy=)
# Positive control (test-fence.sh's houtini proxy case relies on it too): with this environment a
# plain Node fetch of the endpoint really does go to the proxy, so a silent proxy below means a refusal.
env "${proxy_env[@]}" NODE_USE_ENV_PROXY=1 node -e "fetch('$EP/v1/models').catch(() => {})" >/dev/null 2>&1
if [ -s "$proxy_log" ]; then ok "control: Node's env proxy does catch a loopback fetch in this environment"
else bad "control: the proxy saw nothing, so the proxy cases below prove nothing"; fi
for variant in "NODE_USE_ENV_PROXY=1" "NODE_OPTIONS=--use-env-proxy"; do
  : > "$proxy_log"; before=$(chat_count "$LOG")
  out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 1)" "${proxy_env[@]}" "$variant")
  if jq -e '.call.isError == false' >/dev/null <<<"$out" && [ ! -s "$proxy_log" ] && [ "$(chat_count "$LOG")" = $((before + 1)) ]; then
    ok "launcher with $variant and *_PROXY set: the proxy gets nothing, the endpoint gets the request"
  else bad "proxy bypass with $variant (proxy log $(wc -l < "$proxy_log") lines; $(brief "$out"))"; fi
  : > "$proxy_log"
  out=$(env "${proxy_env[@]}" "$variant" LOCAL_VERIFY_ROOTS="$REAL_ROOT" LOCAL_LLM_ENDPOINT_URL="$EP" node "$DRIVER" "$TMP/direct.sh" "$TOOL" "$(claims_on "$INSIDE" '["[yes] x"]' 1)")
  if did_not_start "$out" "refusing to start: Node's env proxy is on" && [ ! -s "$proxy_log" ]; then
    ok "server started directly with $variant and *_PROXY set refuses to start; the proxy gets nothing"
  else bad "direct start with $variant (proxy log $(wc -l < "$proxy_log") lines; $(jq -c '{init,exit,stderr}' <<<"$out" | cut -c1-300))"; fi
done
: > "$proxy_log"
out=$(env "${proxy_env[@]}" NODE_USE_ENV_PROXY=1 NO_PROXY='*' no_proxy='*' LOCAL_VERIFY_ROOTS="$REAL_ROOT" LOCAL_LLM_ENDPOINT_URL="$EP" \
      node "$DRIVER" "$TMP/direct.sh" "$TOOL" "$(claims_on "$INSIDE" '["[yes] x"]' 1)")
if jq -e '.call.isError == false' >/dev/null <<<"$out" && [ ! -s "$proxy_log" ]; then
  ok "started directly with the env proxy on but NO_PROXY='*': it runs, and the proxy gets nothing"
else bad "direct start with NO_PROXY='*' ($(jq -c '{init,stderr,call}' <<<"$out" | cut -c1-300))"; fi

# --- time: one retry on a stall, one redraw of a cut-off answer, the call budget ---------------
start_fake once verify-stall-once
out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 2)" LOCAL_VERIFY_REQUEST_TIMEOUT_MS=300)
if jq -e '.call.isError == false and (.call.text | fromjson | .results[0].label == "SUPPORTED")' >/dev/null <<<"$out" && [ "$(chat_count "$LOG")" = 4 ]; then
  ok "a request that stalls once is retried and the call succeeds (4 requests for k=2)"
else bad "stall-once retry ($(chat_count "$LOG") requests; $(brief "$out"))"; fi
start_fake stall verify-stall
out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 1)" LOCAL_VERIFY_REQUEST_TIMEOUT_MS=200)
if jq -e '.call.isError and (.call.text | contains("timed out twice") and contains("send fewer claims or a smaller k"))' >/dev/null <<<"$out" \
   && [ "$(chat_count "$LOG")" = 2 ]; then
  ok "a request that stalls twice fails after one retry, with a retry hint"
else bad "stall twice ($(chat_count "$LOG") requests; $(brief "$out"))"; fi
start_fake garbage1 verify-garbage-once
out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 3)")
if jq -e '.call.isError == false and (.call.text | fromjson | .results[0].p_supported == 1)' >/dev/null <<<"$out" \
   && [ "$(chat_count "$LOG")" = 6 ] && jq -se '[.[] | select(.body) | .body.seed] | sort == [0,1,2,500,501,502]' "$LOG" >/dev/null; then
  ok "a cut-off answer is redrawn once with another seed (6 requests for k=3)"
else bad "redraw ($(chat_count "$LOG") requests; $(brief "$out"))"; fi
start_fake garbage verify-garbage
out=$(call "$(claims_on "$INSIDE" '["[yes] x"]' 1)")
if jq -e '.call.isError and (.call.text | contains("no valid label twice") and contains("finish_reason length, non-JSON content"))' >/dev/null <<<"$out" \
   && [ "$(chat_count "$LOG")" = 2 ] && ! grep -q '"label": "S' <<<"$out"; then
  ok "a sample cut off twice fails, with finish_reason and content diagnostics but no model text"
else bad "cut off twice ($(chat_count "$LOG") requests; $(brief "$out"))"; fi
start_fake stall2 verify-stall
t0=$(date +%s)
out=$(call "$(claims_on "$INSIDE" '["[yes] x","[yes] y"]' 4)" LOCAL_VERIFY_REQUEST_TIMEOUT_MS=60000 LOCAL_VERIFY_BUDGET_MS=500)
elapsed=$(( $(date +%s) - t0 ))
if jq -e '.call.isError and (.call.text | contains("budget") and contains("send fewer claims or a smaller k"))' >/dev/null <<<"$out" && [ "$elapsed" -lt 10 ]; then
  ok "a call where no claim finishes stops at its budget with an error and a retry hint (${elapsed}s)"
else bad "budget (${elapsed}s; $(brief "$out"))"; fi

# --- partial results: finished claims survive a budget overrun or a failed sample --------------
start_fake partial verify
out=$(call "$(claims_on "$INSIDE" '["[yes] a","[stall] b"]' 2)" LOCAL_VERIFY_REQUEST_TIMEOUT_MS=60000 LOCAL_VERIFY_BUDGET_MS=1500)
if jq -e '.call.isError == false' >/dev/null <<<"$out" && call_text "$out" | jq -e '.partial == true and (.error | contains("budget") and contains("smaller k"))
     and .results[0].label == "SUPPORTED" and .results[1].label == "NOT_RUN" and (.results[1].reason | contains("budget"))
     and .results[1].auto_accept == false and (.results[1] | has("p_supported") | not)' >/dev/null; then
  ok "budget overrun: the finished claim is returned, the other is NOT_RUN, partial is true"
else bad "partial on budget ($(brief "$out"))"; fi
out=$(call "$(claims_on "$INSIDE" '["[yes] a","[fail] b"]' 2)")
if jq -e '.call.isError == false' >/dev/null <<<"$out" && call_text "$out" | jq -e '.partial == true
     and .results[0].label == "SUPPORTED" and .results[1].label == "NOT_RUN" and (.results[1].reason | contains("HTTP 500"))' >/dev/null \
   && ! grep -q canary <<<"$out"; then
  ok "a failed sample: only its claim is NOT_RUN"
else bad "partial on a failed sample ($(brief "$out"))"; fi

# --- slots: a queued request leaves on abort, and no failure or abort ever leaks a slot ---------
node --input-type=module -e "
  import { withSlot, slotState, PARALLEL_SLOTS } from '$REPO/server/endpoint.mjs';
  const never = new AbortController().signal;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const aborter = new AbortController();
  const holders = [
    withSlot(never, () => sleep(600)),
    withSlot(never, () => sleep(300).then(() => { throw new Error('holder failed'); })),
    withSlot(aborter.signal, () => new Promise((_, rej) => aborter.signal.addEventListener('abort', () => rej(aborter.signal.reason)))),
    withSlot(never, () => sleep(600)),
  ];
  setTimeout(() => aborter.abort(new Error('holder aborted')), 200);
  const t0 = Date.now();
  const err = await withSlot(AbortSignal.timeout(100), async () => 'ran').catch((e) => e);
  const waited = Date.now() - t0, queued = slotState().waiting;
  await Promise.allSettled(holders);
  const after = slotState();
  const ran = await withSlot(AbortSignal.timeout(500), async () => 'ran').catch((e) => String(e));
  const good = err instanceof Error && waited < 500 && queued === 0 && after.freeSlots === PARALLEL_SLOTS && after.waiting === 0 && ran === 'ran';
  console.log(JSON.stringify({ good, waited, queued, after, ran }));
" > "$TMP/slot.json" 2>&1
if jq -e '.good' "$TMP/slot.json" >/dev/null 2>&1; then
  ok "withSlot: a queued request leaves on abort; holders that resolve, reject or abort all return their slot ($(jq -c '{waited}' "$TMP/slot.json"))"
else bad "withSlot slots ($(cat "$TMP/slot.json"))"; fi
call_line() { jq -nc --argjson id "$1" --argjson a "$2" '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:"verify_claims",arguments:$a}}'; }
raw_env=(LOCAL_LLM_ALLOWED_DIRS="$ROOT" LOCAL_LLM_MODEL= LOCAL_VERIFY_REQUEST_TIMEOUT_MS=60000)
start_fake leak verify
lines=$(jq -nc --argjson i "$(init 1 2025-06-18)" --argjson a "$(call_line 2 "$(claims_on "$INSIDE" '["[stall] a"]' 8)")" \
  --argjson b "$(call_line 3 "$(claims_on "$INSIDE" '["[yes] b"]' 1)")" '[$i, $a, {delay_ms: 1500}, $b]')
out=$(env "${raw_env[@]}" LOCAL_VERIFY_BUDGET_MS=800 LOCAL_LLM_ENDPOINT_URL="$EP" node "$RAW" "$LAUNCHER" "$lines" 3 6000)
a=$(jq -c '.responses[] | select(.id == 2)' <<<"$out"); b=$(jq -c '.responses[] | select(.id == 3)' <<<"$out")
if jq -e '.result.isError and (.result.content[0].text | contains("budget"))' >/dev/null <<<"$a" \
   && jq -e '.at_ms < 3000 and .result.isError == false and (.result.content[0].text | fromjson | (has("partial") | not) and .results[0].label == "SUPPORTED")' >/dev/null <<<"$b"; then
  ok "same server: after a call overruns its budget with every slot stalled, the next call gets slots and answers ($(jq '.at_ms' <<<"$b") ms)"
else bad "slot leak after an overrun (a: $(cut -c1-200 <<<"$a"); b: $(cut -c1-200 <<<"$b"); $(jq -c '{timedOut,exit}' <<<"$out"))"; fi
start_fake cancel verify
lines=$(jq -nc --argjson i "$(init 1 2025-06-18)" --argjson a "$(call_line 2 "$(claims_on "$INSIDE" '["[stall] a"]' 8)")" \
  --argjson b "$(call_line 3 "$(claims_on "$INSIDE" '["[yes] b"]' 1)")" \
  '[$i, $a, {delay_ms: 300}, {jsonrpc:"2.0",method:"notifications/cancelled",params:{requestId:2,reason:"user interrupt"}}, {delay_ms: 100}, $b]')
out=$(env "${raw_env[@]}" LOCAL_VERIFY_BUDGET_MS=60000 LOCAL_LLM_ENDPOINT_URL="$EP" node "$RAW" "$LAUNCHER" "$lines" 3 3000)
b=$(jq -c '.responses[] | select(.id == 3)' <<<"$out")
if jq -e '.at_ms < 2000 and .result.isError == false and (.result.content[0].text | fromjson | .results[0].label == "SUPPORTED")' >/dev/null <<<"$b" \
   && ! jq -e '.responses[] | select(.id == 2)' >/dev/null <<<"$out" && jq -e '.stderr | contains("request 2 cancelled")' >/dev/null <<<"$out"; then
  ok "notifications/cancelled aborts the call: no reply for it, its slots free, the next call answers ($(jq '.at_ms' <<<"$b") ms)"
else bad "cancel ($(jq -c '[.responses[] | {id, at_ms}]' <<<"$out"); b: $(cut -c1-200 <<<"$b"))"; fi
start_fake twocalls verify
lines=$(jq -nc --argjson i "$(init 1 2025-06-18)" \
  --argjson a "$(call_line 2 "$(claims_on "$INSIDE" '["[stall] a"]' 3)")" \
  --argjson b "$(call_line 3 "$(claims_on "$INSIDE" '["[yes] c","[stall] d","[stall] e"]' 1)")" \
  '[$i, $a, {delay_ms: 300}, $b]')
out=$(env "${raw_env[@]}" LOCAL_VERIFY_BUDGET_MS=1500 LOCAL_LLM_ENDPOINT_URL="$EP" node "$RAW" "$LAUNCHER" "$lines" 3)
b=$(jq -c '.responses[] | select(.id == 3)' <<<"$out")
if jq -e '.at_ms < 4000 and .result.isError == false and (.result.content[0].text | fromjson |
          .partial == true and ([.results[].label] == ["SUPPORTED","NOT_RUN","NOT_RUN"]))' >/dev/null <<<"$b"; then
  ok "smoke: two concurrent calls on one server; the second returns partial results at its budget ($(jq '.at_ms' <<<"$b") ms; the withSlot check above is the discriminating one)"
else bad "smoke: two concurrent calls ($(cut -c1-300 <<<"$b"); $(jq -c '{timedOut,exit}' <<<"$out"))"; fi
start_fake siblings verify
# Claim a's first sample fails at once while its 19 siblings sit queued ahead of claim b's 20; the
# call stays open for b, so only the claim's own stop keeps a's siblings from being sent.
out=$(call "$(claims_on "$INSIDE" '["[fail-seed0] a","[yes] b"]' 20)")
sent_a=$(jq -s '[.[] | select(.body) | select(.body.messages[-1].content | contains("CLAIM: [fail-seed0]"))] | length' "$LOG")
if jq -e '.call.isError == false and (.call.text | fromjson | .partial and ([.results[].label] == ["NOT_RUN","SUPPORTED"]))' >/dev/null <<<"$out" \
   && [ "$sent_a" -le 5 ]; then
  ok "a failed sample stops its siblings while the call goes on: $sent_a of claim a's 20 requests sent"
else bad "sibling cancel ($sent_a of claim a's 20 requests; $(brief "$out"))"; fi

# --- the eval fixtures are well-formed: valid kinds, existing files, 24 easy lookup items -------
FIX="$SCRIPT_DIR/fixtures/verify"
missing=$(jq -r '.[].file' "$FIX/easy.json" "$FIX/hard.json" | sort -u | while read -r f; do [ -f "$FIX/$f" ] || echo "$f"; done)
if jq -e 'length == 48 and all(.[]; (.kind == "lookup" or .kind == "computed") and (.gold | type == "string") and (.claim | type == "string"))' "$FIX/easy.json" "$FIX/hard.json" >/dev/null \
   && [ "$(jq '[.[] | select(.kind == "lookup")] | length' "$FIX/easy.json")" = 24 ] \
   && [ "$(jq '[.[] | select(.kind == "lookup")] | length' "$FIX/hard.json")" = 0 ] && [ -z "$missing" ]; then
  ok "eval fixtures: 48 items per set, valid kinds, every file present, 24 easy lookup items"
else bad "eval fixtures (missing files: ${missing:-none})"; fi

echo
echo "verify pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
