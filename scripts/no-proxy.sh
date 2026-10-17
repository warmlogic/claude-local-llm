# Sourced by both launchers (sh). Node's fetch sends requests through HTTP_PROXY / HTTPS_PROXY /
# ALL_PROXY when NODE_USE_ENV_PROXY=1 or --use-env-proxy is set, which would route the loopback
# inference request, file text included, through a proxy that may be remote. Drop every proxy
# setting, and exempt every host in case a flag (e.g. in NODE_OPTIONS) re-enables proxying anyway.
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NODE_USE_ENV_PROXY
export NO_PROXY='*'
export no_proxy='*'
