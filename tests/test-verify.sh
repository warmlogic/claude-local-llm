#!/usr/bin/env bash
# Offline tests for the local-verify server (scripts/launch-verify.sh + server/verify-server.mjs).
# Run from repo root: bash tests/test-verify.sh (test-fence.sh runs it on every commit).
# Every model answer comes from tests/fake-endpoint.mjs in a verify mode; nothing needs LM Studio.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$SCRIPT_DIR/.."
LAUNCHER="$REPO/scripts/launch-verify.sh"
DRIVER="$SCRIPT_DIR/mcp-call.mjs"
TOOL=verify_claims

pass=0; fail=0; tn=0
ok()  { pass=$((pass+1)); tn=$((tn+1)); echo "  Test $tn PASS: $1"; }
bad() { fail=$((fail+1)); tn=$((tn+1)); echo "  Test $tn FAIL: $1"; }

for tool in node jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required to run this suite"; exit 1; }
done

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT

# start_fake <name> <mode>: a fake endpoint on a random loopback port; sets EP and LOG
start_fake() {
  : > "$TMP/$1.log"
  node "$SCRIPT_DIR/fake-endpoint.mjs" "$TMP/$1.port" "$TMP/$1.log" "$2" &
  PIDS+=($!)
  for _ in $(seq 1 50); do [ -s "$TMP/$1.port" ] && break; sleep 0.1; done
  EP="http://127.0.0.1:$(cat "$TMP/$1.port")"; LOG="$TMP/$1.log"
}
chat_count() { jq -s '[.[] | select(.headers and .url == "/v1/chat/completions")] | length' "$1"; }  # one header line per request
# call <root> <json-args> [env...]: one verify_claims call through the launcher
call() {
  local root="$1" args="$2"; shift 2
  env LOCAL_LLM_ALLOWED_DIRS="$root" LOCAL_LLM_ENDPOINT_URL="$EP" LOCAL_LLM_MODEL= "$@" node "$DRIVER" "$LAUNCHER" "$TOOL" "$args"
}
did_not_start() { # <json> <stderr-fragment>
  jq -e --arg f "$2" '(.timedOut | not) and (.init | not) and .exit != null and .exit != 0 and (.stderr | contains($f))' >/dev/null <<<"$1"
}

echo "verify server test suite"

ROOT="$TMP/root"; mkdir -p "$ROOT" "$TMP/root-evil" "$TMP/outside" "$ROOT/sub"
echo "canary-outside" > "$TMP/outside/secret.txt"
echo "canary-evil" > "$TMP/root-evil/sibling.txt"
printf 'canary-inside: the api service started with workers=8\n' > "$ROOT/inside.txt"
ln -s "$TMP/outside/secret.txt" "$ROOT/link-out.txt"
awk 'BEGIN{while(n<1100000){s="canary-big line of synthetic text for the size cap\n"; printf "%s", s; n+=length(s)}}' > "$ROOT/big.txt"

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
  if did_not_start "$out" "loopback"; then ok "launcher refuses non-loopback endpoint $ep"
  else bad "launcher refuses non-loopback endpoint $ep ($out)"; fi
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

# --- tools/list ----------------------------------------------------------------------------
start_fake ok verify
out=$(LOCAL_LLM_ALLOWED_DIRS="$ROOT" LOCAL_LLM_ENDPOINT_URL="$EP" node "$DRIVER" "$LAUNCHER" --list)
if jq -e '.serverName == "local-verify" and (.call.text | fromjson | .tools | length == 1 and .[0].name == "verify_claims"
          and .[0].inputSchema.required == ["paths","claims"] and .[0].annotations.readOnlyHint)' >/dev/null <<<"$out"; then
  ok "tools/list offers verify_claims with paths and claims required"
else bad "tools/list ($out)"; fi

# --- the fence: nothing outside the roots is read, nothing is sent, no file text comes back ----
claim_args() { jq -nc --arg p "$1" '{paths:[$p], claims:["[yes] The api service started."]}'; }
check_refused() { # <label> <path> <message-fragment>
  local before after out
  before=$(chat_count "$LOG")
  out=$(call "$ROOT" "$(claim_args "$2")")
  after=$(chat_count "$LOG")
  if jq -e --arg f "$3" '.call.isError and (.call.text | startswith("Error:")) and (.call.text | contains($f))' >/dev/null <<<"$out" \
     && ! grep -q canary <<<"$out" && [ "$before" = "$after" ]; then ok "refused: $1"
  else bad "refused: $1 (chat requests $before -> $after; $(jq -c '.call' <<<"$out" | cut -c1-300))"; fi
}
check_refused "path outside every root" "$TMP/outside/secret.txt" "outside the allowed roots"
check_refused "symlink inside the root pointing outside it" "$ROOT/link-out.txt" "outside the allowed roots"
check_refused "sibling directory sharing the root's name prefix" "$TMP/root-evil/sibling.txt" "outside the allowed roots"
check_refused "dot-dot escape from inside the root" "$ROOT/../outside/secret.txt" "outside the allowed roots"
check_refused "relative path" "root/inside.txt" "must be absolute"
check_refused "missing file" "$ROOT/missing.txt" "no such file"
check_refused "a directory" "$ROOT/sub" "not a regular file"
check_refused "file over 1 MB" "$ROOT/big.txt" "over the 1 MB limit"
out=$(call "$ROOT" "$(jq -nc --arg a "$ROOT/inside.txt" --arg b "$TMP/outside/secret.txt" '{paths:[$a,$b], claims:["[yes] x"]}')")
if jq -e '.call.isError and (.call.text | contains("outside the allowed roots"))' >/dev/null <<<"$out" && ! grep -q canary <<<"$out"; then
  ok "one path outside the roots fails the whole call"
else bad "one path outside the roots fails the whole call ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi

# --- JSON shape, vote shares and the request each sample sends -----------------------------
: > "$LOG"
args=$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] The api service started.","[split] The api service stopped.","The service is written in Go."]}')
out=$(call "$ROOT" "$args")
res=$(jq -r '.call.text' <<<"$out")
if jq -e '.call.isError == false' >/dev/null <<<"$out" && jq -e '
     .model == "fake-verify-model" and .k == 10 and (.results | length == 3)
     and all(.results[]; (keys - ["auto_accept"]) == ["agreement","claim","kind","label","p_supported"])
     and ([.results[] | [.label, .p_supported, .agreement]] == [["SUPPORTED",1,1],["NOT_SUPPORTED",0.5,0.5],["NOT_SUPPORTED",0,1]])
     and .results[0].claim == "[yes] The api service started."' >/dev/null <<<"$res"; then
  ok "result shape: {model, k, results[{claim, label, p_supported, agreement, kind}]}, vote shares collapse to two labels"
else bad "result shape ($(cut -c1-400 <<<"$res"))"; fi
if [ "$(chat_count "$LOG")" = 30 ] && jq -se '[.[] | select(.body) | .body] |
     all(.[]; .temperature == 1 and .reasoning_effort == "none" and .model == "fake-verify-model"
              and (.response_format.json_schema.schema.properties.label.enum | sort) == ["CONTRADICTED","NOT_IN_SOURCE","SUPPORTED"]
              and (.messages[-1].content | contains("canary-inside")))
     and ([.[].response_format.json_schema.schema.properties.label.enum] | unique | length) > 1
     and ([.[].seed] | unique | length) == 30' "$LOG" >/dev/null; then
  ok "k=10 samples per claim: temperature 1, reasoning off, schema-forced labels in shuffled orders, distinct seeds"
else bad "sample requests ($(chat_count "$LOG") chat requests)"; fi
if ! grep -q canary <<<"$out"; then ok "the result never echoes file text"
else bad "the result echoes file text"; fi

# --- kind: numbers, counts, dates and comparisons are computed, and never auto-accepted -------
computed=("There are exactly 3 ERROR lines." "The db service logged no ERROR lines." "Exactly one test failed."
          "The api service logged more WARN lines than the db service." "The first ERROR line came from the db service."
          "Mitigation took under an hour." "The next sync is on Thursday." "The memory limit is doubled."
          "All tests passed." "The release moved one week later." "Coverage is 85%.")
lookup=("The service was shut down via SIGTERM." "Tom owns the migration runbook." "The diff adds a readiness probe."
        "A null field crashed the pricing worker." "The cache is stored in Redis.")
args=$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:$ARGS.positional, k:1}' --args "${computed[@]}" "${lookup[@]}")
res=$(call "$ROOT" "$args" | jq -r '.call.text')
want=$(jq -nc --argjson c "${#computed[@]}" --argjson l "${#lookup[@]}" '[range($c) | "computed"] + [range($l) | "lookup"]')
if jq -e --argjson want "$want" '[.results[].kind] == $want
     and all(.results[] | select(.kind == "computed"); .auto_accept == false)
     and all(.results[] | select(.kind == "lookup"); has("auto_accept") | not)' >/dev/null <<<"$res"; then
  ok "kind: ${#computed[@]} computed claims carry auto_accept false, ${#lookup[@]} lookup claims are lookup"
else bad "kind ($(jq -c '[.results[]? | [.claim[:30], .kind]]' <<<"$res" 2>/dev/null || cut -c1-300 <<<"$res"))"; fi

# --- arguments are validated before anything is read or sent -------------------------------
for args in '{"paths":[],"claims":["x"]}' '{"paths":["/x"],"claims":[]}' '{"paths":["/x"],"claims":[""]}' \
            '{"paths":["/x"],"claims":["x"],"k":0}' '{"paths":["/x"],"claims":["x"],"k":21}' '{"paths":["/x"],"claims":["x"],"k":2.5}'; do
  out=$(call "$ROOT" "$args")
  if jq -e '.call.isError and (.call.text | startswith("Error:"))' >/dev/null <<<"$out"; then ok "invalid arguments refused: $args"
  else bad "invalid arguments refused: $args ($(jq -c '.call' <<<"$out"))"; fi
done

# --- the model pin is used as-is; no model lookup ---------------------------------------------
: > "$LOG"
out=$(call "$ROOT" "$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] x"], k:2}')" LOCAL_LLM_MODEL=pinned-model)
if jq -e '.call.isError == false and (.call.text | fromjson | .model == "pinned-model")' >/dev/null <<<"$out" \
   && ! grep -q '/api/v0/models' "$LOG" && jq -se '[.[] | select(.body) | .body.model] == ["pinned-model","pinned-model"]' "$LOG" >/dev/null; then
  ok "LOCAL_LLM_MODEL pins the model and skips the model lookup"
else bad "model pin ($(jq -c '.call' <<<"$out" | cut -c1-300))"; fi

# --- outages: the error strings the skill's table keys on -----------------------------------
dead_port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
out=$(EP="http://127.0.0.1:$dead_port" call "$ROOT" "$(claim_args "$ROOT/inside.txt")")
if jq -e '.call.isError and (.call.text | contains("fetch failed"))' >/dev/null <<<"$out"; then ok "dead endpoint: 'fetch failed'"
else bad "dead endpoint ($(jq -c '.call' <<<"$out"))"; fi
saved_ep=$EP saved_log=$LOG
start_fake nomodel no-model
out=$(call "$ROOT" "$(claim_args "$ROOT/inside.txt")")
if jq -e '.call.isError and (.call.text | contains("No models loaded"))' >/dev/null <<<"$out" && [ "$(chat_count "$LOG")" = 0 ]; then
  ok "no model loaded: 'No models loaded', and no chat request that could trigger a load"
else bad "no model loaded ($(jq -c '.call' <<<"$out"))"; fi

# --- time: a stalled request is retried once; the call stops at its budget ------------------
start_fake once verify-stall-once
out=$(call "$ROOT" "$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] x"], k:2}')" LOCAL_VERIFY_REQUEST_TIMEOUT_MS=300)
if jq -e '.call.isError == false and (.call.text | fromjson | .results[0].label == "SUPPORTED")' >/dev/null <<<"$out" && [ "$(chat_count "$LOG")" = 4 ]; then
  ok "a request that stalls once is retried and the call succeeds (4 requests for k=2)"
else bad "stall-once retry ($(chat_count "$LOG") requests; $(jq -c '.call' <<<"$out"))"; fi
start_fake stall verify-stall
out=$(call "$ROOT" "$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] x"], k:1}')" LOCAL_VERIFY_REQUEST_TIMEOUT_MS=200)
if jq -e '.call.isError and (.call.text | contains("timed out twice"))' >/dev/null <<<"$out" && [ "$(chat_count "$LOG")" = 2 ]; then
  ok "a request that stalls twice fails the call after one retry"
else bad "stall twice ($(chat_count "$LOG") requests; $(jq -c '.call' <<<"$out"))"; fi
start_fake garbage1 verify-garbage-once
out=$(call "$ROOT" "$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] x"], k:3}')")
if jq -e '.call.isError == false and (.call.text | fromjson | .results[0].p_supported == 1)' >/dev/null <<<"$out" \
   && [ "$(chat_count "$LOG")" = 6 ] && jq -se '[.[] | select(.body) | .body.seed] | sort == [0,1,2,500,501,502]' "$LOG" >/dev/null; then
  ok "a cut-off answer is redrawn once with another seed (6 requests for k=3)"
else bad "redraw ($(chat_count "$LOG") requests; $(jq -c '.call' <<<"$out"))"; fi
start_fake garbage verify-garbage
out=$(call "$ROOT" "$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] x"], k:1}')")
if jq -e '.call.isError and (.call.text | contains("no valid label twice"))' >/dev/null <<<"$out" && [ "$(chat_count "$LOG")" = 2 ]; then
  ok "a sample cut off twice fails the call"
else bad "cut off twice ($(chat_count "$LOG") requests; $(jq -c '.call' <<<"$out"))"; fi
start_fake stall2 verify-stall
t0=$(date +%s)
out=$(call "$ROOT" "$(jq -nc --arg p "$ROOT/inside.txt" '{paths:[$p], claims:["[yes] x","[yes] y"], k:4}')" \
      LOCAL_VERIFY_REQUEST_TIMEOUT_MS=60000 LOCAL_VERIFY_BUDGET_MS=500)
elapsed=$(( $(date +%s) - t0 ))
if jq -e '.call.isError and (.call.text | contains("budget"))' >/dev/null <<<"$out" && [ "$elapsed" -lt 10 ]; then
  ok "the call stops at its total budget (${elapsed}s)"
else bad "budget (${elapsed}s; $(jq -c '.call' <<<"$out"))"; fi
EP=$saved_ep LOG=$saved_log

echo
echo "verify pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
