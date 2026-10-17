// Loopback check for the inference endpoint, shared by both launchers (via check-endpoint.mjs) and
// the verify server. Accepts only http(s)://127.0.0.1, localhost or [::1], with an optional numeric
// port, no userinfo, and nothing else before the path. A string check on purpose: the URL parser
// would normalize forms like 127.1 or 0x7f000001, so what passes is exactly what the user typed.
const LOOPBACK = /^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?(?:[/?#][^]*)?$/;

export const isLoopbackEndpoint = (url) => typeof url === 'string' && LOOPBACK.test(url);

export const loopbackError = (url) =>
  `endpoint must be loopback (127.0.0.1, localhost or [::1]) with a numeric port (set endpoint_url in the plugin options): ${url}`;

// The proxy variables Node's env proxy reads, plus the flag that turns it on. Any of these DEFINED, even empty,
// makes the verify server and the batch runner refuse to start, because file text could go through a proxy.
// scripts/no-proxy.sh (shell) unsets the same set for the launchers; tests/test-verify.sh checks the lists agree.
export const PROXY_VARS = ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NODE_USE_ENV_PROXY'];
