# Sourced by both launchers (sh). Node's fetch sends requests through HTTP_PROXY / HTTPS_PROXY /
# ALL_PROXY when NODE_USE_ENV_PROXY=1 or --use-env-proxy is set, which would route the loopback
# inference request, file text included, through a proxy that may be remote. Unset every proxy
# variable (either case) and NODE_USE_ENV_PROXY: with no proxy defined, a flag that turns the env
# proxy on (e.g. in NODE_OPTIONS) has nothing to send through. This is exactly the set the verify
# server refuses to start with (server/verify-server.mjs); keep the two in step.
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NODE_USE_ENV_PROXY
