#!/bin/sh
# Launch the local-verify MCP server (server/verify-server.mjs), fenced to the allowed folders.
#
# Env in: LOCAL_LLM_ALLOWED_DIRS, LOCAL_LLM_ENDPOINT_URL (default http://127.0.0.1:1234),
#         LOCAL_LLM_MODEL (optional): the same plugin options launch-server.sh receives.
# The folders resolve with the same resolver as houtini's launcher (resolve-roots.mjs), and the
# endpoint passes the same loopback check (check-endpoint.mjs). Exits 2 before starting the server
# when no folder remains or the endpoint is not loopback. Never prints file contents.
set -efu

command -v node >/dev/null 2>&1 || { echo "local-verify: node (Node.js) is required" >&2; exit 2; }
CDPATH= cd -P -- "$(dirname -- "$0")/.." >/dev/null || { echo "local-verify: cannot enter the plugin directory" >&2; exit 2; }

roots=$(node ./scripts/resolve-roots.mjs)  # exits 2 (and stops here) on a refused entry
if [ -z "$roots" ]; then
  echo "local-verify: no allowed folders configured; set allowed_dirs in the plugin options" >&2
  exit 2
fi

endpoint=${LOCAL_LLM_ENDPOINT_URL:-http://127.0.0.1:1234}
node ./scripts/check-endpoint.mjs "$endpoint" || exit 2

. ./scripts/no-proxy.sh  # no proxy may carry the request off loopback
export LOCAL_VERIFY_ROOTS=$roots
export LOCAL_LLM_ENDPOINT_URL=$endpoint
exec node ./server/verify-server.mjs
