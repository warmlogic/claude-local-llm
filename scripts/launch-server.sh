#!/bin/sh
# Launch the houtini-lm MCP server against LM Studio, fenced to the allowed folders.
#
# Env in: LOCAL_LLM_ALLOWED_DIRS (comma-separated; a leading $HOME, ${HOME} or ~ is expanded),
#         LOCAL_LLM_ENDPOINT_URL (default http://127.0.0.1:1234), LOCAL_LLM_MODEL (optional)
#
# Why this exists: houtini reads ANY absolute path when HOUTINI_LM_FILE_ROOTS is unset or
# empty. This script refuses to start unless at least one existing, non-"/" root remains.
# Each folder is resolved (symlinks, ".", "..") and a missing one is skipped with a warning.
# Limits: no "," or ":" in folder names (houtini splits on both); "/" is refused.
# The endpoint must be loopback, so file contents never leave the machine.
# Never prints file contents; stderr carries only short status lines.
set -efu

roots=""
old_ifs=$IFS
IFS=,
for entry in ${LOCAL_LLM_ALLOWED_DIRS-}; do
  IFS=$old_ifs
  # trim surrounding whitespace
  entry=${entry#"${entry%%[![:space:]]*}"}
  entry=${entry%"${entry##*[![:space:]]}"}
  case $entry in
    '$HOME'|'${HOME}'|'~') entry=$HOME ;;
    '$HOME/'*) entry=$HOME/${entry#'$HOME/'} ;;
    '${HOME}/'*) entry=$HOME/${entry#'${HOME}/'} ;;
    '~/'*) entry=$HOME/${entry#'~/'} ;;
  esac
  case $entry in
    '') continue ;;
    *:*) echo "local-llm: allowed folder must not contain ':' (houtini splits on it): $entry" >&2; exit 2 ;;
    /*) ;;
    *) echo "local-llm: allowed folder must be an absolute path: $entry" >&2; exit 2 ;;
  esac
  # Pass houtini the folder it will actually use: symlinks and ".", ".." resolved.
  resolved=$(cd -P -- "$entry" 2>/dev/null && pwd -P) || {
    echo "local-llm: allowed folder not found, skipping: $entry" >&2; continue; }
  case $resolved in
    /) echo "local-llm: refusing '/' as an allowed folder: $entry" >&2; exit 2 ;;
    *[,:]*) echo "local-llm: resolved folder contains ',' or ':': $resolved" >&2; exit 2 ;;
  esac
  roots=${roots:+$roots,}$resolved
done

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
  127.0.0.1|localhost|'[::1]'|127.0.0.1:[0-9]*|localhost:[0-9]*|'[::1]:'[0-9]*) ;;
  *) echo "local-llm: endpoint must be loopback (127.0.0.1, localhost or [::1]): $endpoint" >&2; exit 2 ;;
esac

export HOUTINI_LM_FILE_ROOTS=$roots
export HOUTINI_LM_ENDPOINT_URL=$endpoint
[ -z "${LOCAL_LLM_MODEL:-}" ] || export HOUTINI_LM_MODEL=$LOCAL_LLM_MODEL
export HOUTINI_LM_API_KEY=not-needed
export HOUTINI_LM_MAX_FILE_MB=1
export npm_config_prefer_offline=true
exec npx -y @houtini/lm@3.3.4
