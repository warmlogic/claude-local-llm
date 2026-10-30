// Shared delegation/window budget. Metadata only; no file contents are sent.
import { get as httpGet } from 'node:http';
import { get as httpsGet } from 'node:https';
import { pathToFileURL } from 'node:url';
import { isLoopbackEndpoint } from './loopback.mjs';

// Single-file delegation breaks even near 25k chars (about six Claude turns of fixed
// overhead); 30k leaves margin. Near 50k it saves about half the Claude tokens.
export const MIN_DELEGATE_CHARS = 30_000;
export const RESERVE_TOKENS = 4096; // prompt plus answer room
// Qwen splits each digit: gen_log measured 1.74 chars/token, LM Studio logs 2.4,
// numeric CSV about 1.0. Pure numeric data can still overflow at 1.6; that fails
// loudly (context_length_exceeded), and Claude reads the file itself.
export const CHARS_PER_TOKEN = 1.6;
const FALLBACK_TOKENS = 32768;
const LOOKUP_TIMEOUT_MS = 1000;
const MAX_METADATA_CHARS = 1_000_000;
// Houtini's HOUTINI_LM_MAX_FILE_MB=1 also bounds large loaded contexts.
export const capForContext = (contextTokens, reserveTokens = RESERVE_TOKENS) =>
  Math.min(1_000_000, Math.max(0, Math.floor((contextTokens - reserveTokens) * CHARS_PER_TOKEN)));
const budget = (contextTokens, source, reason, model) => ({
  contextTokens, capChars: capForContext(contextTokens), source, ...(reason ? { reason } : {}), ...(model ? { model } : {}),
});

// http(s).get bypasses ambient env proxies and never follows redirects. The signal
// bounds both headers and body, so a stalled response cannot outlive the hook budget.
const models = (endpoint) => new Promise((resolve, reject) => {
  const get = endpoint.startsWith('https:') ? httpsGet : httpGet;
  const req = get(`${endpoint.replace(/\/+$/, '')}/api/v0/models`, {
    agent: false, // avoid a global agent configured by --use-env-proxy
    signal: AbortSignal.timeout(LOOKUP_TIMEOUT_MS),
  }, (res) => {
    if (res.statusCode !== 200) { res.resume(); reject(new Error(`http ${res.statusCode}`)); return; }
    let text = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => { text += chunk; if (text.length > MAX_METADATA_CHARS) req.destroy(new Error('metadata too large')); });
    res.on('error', reject);
    res.on('end', () => { try { resolve(JSON.parse(text)); } catch { reject(new Error('no metadata')); } });
  });
  req.on('error', reject);
});

export async function getContextCap({
  endpoint = process.env.LOCAL_LLM_ENDPOINT_URL || 'http://127.0.0.1:1234',
  model = process.env.LOCAL_LLM_MODEL || '',
} = {}) {
  const fallback = (reason, source = 'fallback') => budget(FALLBACK_TOKENS, source, reason);
  if (!isLoopbackEndpoint(endpoint)) return fallback('not a loopback server root');
  try {
    const list = (await models(endpoint))?.data;
    if (!Array.isArray(list)) return fallback('no metadata');
    const loaded = list.filter((m) => m?.state === 'loaded' && m.type !== 'embeddings' && (!model || m.id === model));
    if (!loaded.length) return model
      ? fallback('pinned model not loaded', 'pinned model not loaded') : fallback('no chat model loaded');
    if (loaded.some((m) => !Number.isSafeInteger(m.loaded_context_length) || m.loaded_context_length <= 0)) return fallback('invalid context');
    // Name the model only when it is unambiguous: one loaded chat model, or the pinned one.
    const named = loaded.length === 1 || model ? loaded[0].id : undefined;
    return budget(Math.min(...loaded.map((m) => m.loaded_context_length)), 'loaded', undefined, typeof named === 'string' ? named : undefined);
  } catch (e) {
    const reason = e.name === 'AbortError' ? 'timeout'
      : /^(http \d{3}|metadata too large|no metadata)$/.test(e.message) ? e.message : 'no metadata';
    return fallback(reason);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(JSON.stringify(await getContextCap()));
}
