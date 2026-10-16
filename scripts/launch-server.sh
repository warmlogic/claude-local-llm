#!/bin/sh
# Launch the houtini-lm MCP server against LM Studio, fenced to the allowed folders.
#
# Env in: LOCAL_LLM_ALLOWED_DIRS (comma-separated; a leading $HOME, ${HOME} or ~ is expanded),
#         LOCAL_LLM_ENDPOINT_URL (default http://127.0.0.1:1234), LOCAL_LLM_MODEL (optional)
#
# Why this exists: houtini reads ANY absolute path when HOUTINI_LM_FILE_ROOTS is unset or
# empty. This script refuses to start unless at least one existing, non-"/" root remains.
# resolve-roots.mjs resolves the folders with houtini's own parse (see its header for the
# invariant); a missing folder is skipped with a warning.
# Limits: no "," or ":" in folder names (houtini splits on both); "/" is refused.
# The endpoint must be loopback, so file contents never leave the machine.
# Never prints file contents; stderr carries only short status lines.
set -efu

command -v node >/dev/null 2>&1 || { echo "local-llm: node (Node.js) is required" >&2; exit 2; }
command -v npx >/dev/null 2>&1 || { echo "local-llm: npx (Node.js) is required" >&2; exit 2; }

# npx runs a matching @houtini/lm found in node_modules up the cwd's ancestry (and reads a project
# .npmrc), so never run from the spawner's cwd; the plugin root has neither. Roots are absolute.
cd "$(dirname "$0")/.."

roots=$(node ./scripts/resolve-roots.mjs)  # exits 2 (and stops here) on a refused entry

if [ -z "$roots" ]; then
  echo "local-llm: no allowed folders configured; set allowed_dirs in the plugin options" >&2
  exit 2
fi
echo "local-llm: allowed folders: $roots" >&2

endpoint=${LOCAL_LLM_ENDPOINT_URL:-http://127.0.0.1:1234}
hostport=${endpoint#*://}
hostport=${hostport%%[/?#]*}
case $endpoint in http://*|https://*) ;; *) hostport=invalid ;; esac
case $hostport in *@*) hostport=invalid ;; esac
case $hostport in
  127.0.0.1*) rest=${hostport#127.0.0.1} ;;
  localhost*) rest=${hostport#localhost} ;;
  '[::1]'*) rest=${hostport#'[::1]'} ;;
  *) rest=bad ;;
esac
case $rest in ''|:[0-9]*) ;; *) rest=bad ;; esac
case ${rest#:} in
  *[!0-9]*) echo "local-llm: endpoint must be loopback (127.0.0.1, localhost or [::1]) with a numeric port (set endpoint_url in the plugin options): $endpoint" >&2; exit 2 ;;
esac

# houtini 3.3.4 also reads these (every process.env.* in its dist); drop any ambient value so only
# what is exported below applies. Re-derive this list from the dist when the pin changes.
unset OPENROUTER_API_KEY LM_STUDIO_URL LM_STUDIO_PASSWORD LM_STUDIO_MODEL LM_PASSWORD LM_CONTEXT_WINDOW \
  HOUTINI_LM_MODEL HOUTINI_LM_THINKING HOUTINI_LM_STRUCTURED HOUTINI_LM_SERIALISE HOUTINI_LM_RETRY_RATELIMIT \
  HOUTINI_LM_PROVIDER HOUTINI_LM_MIN_TOKENS HOUTINI_LM_CROSS_PROCESS_LOCK HOUTINI_LM_CONTEXT_WINDOW
export HOUTINI_LM_FILE_ROOTS=$roots
export HOUTINI_LM_ENDPOINT_URL=$endpoint
[ -z "${LOCAL_LLM_MODEL:-}" ] || export HOUTINI_LM_MODEL=$LOCAL_LLM_MODEL
export HOUTINI_LM_API_KEY=not-needed
export HOUTINI_LM_MAX_FILE_MB=1
export npm_config_prefer_offline=true
exec npx -y @houtini/lm@3.3.4
