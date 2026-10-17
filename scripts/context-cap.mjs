// Shared delegation/window budget. Metadata only; no file contents are sent.
import { get as httpGet } from 'node:http';
import { get as httpsGet } from 'node:https';
import { pathToFileURL } from 'node:url';
import { isLoopbackEndpoint } from './loopback.mjs';

// Single-file delegation breaks even near 25k chars (about six Claude turns of fixed
// overhead); 30k leaves margin. Near 50k it saves about half the Claude tokens.
export const MIN_DELEGATE_CHARS = 30_000;
export const RESERVE_TOKENS = 4096; // prompt plus answer room
export const CHARS_PER_TOKEN = 2.5; // conservative against the measured 2.7 on dense text
const FALLBACK_TOKENS = 32768;
const LOOKUP_TIMEOUT_MS = 1000;
const budget = (contextTokens, source) => ({
  contextTokens, capChars: Math.max(0, Math.floor((contextTokens - RESERVE_TOKENS) * CHARS_PER_TOKEN)), source,
});

// http(s).get bypasses ambient env proxies and never follows redirects. The signal
// bounds both headers and body, so a stalled response cannot outlive the hook budget.
const models = (endpoint) => new Promise((resolve, reject) => {
  const get = endpoint.startsWith('https:') ? httpsGet : httpGet;
  const req = get(`${endpoint.replace(/\/+$/, '')}/api/v0/models`, {
    agent: false, // avoid a global agent configured by --use-env-proxy
    signal: AbortSignal.timeout(LOOKUP_TIMEOUT_MS),
  }, (res) => {
    if (res.statusCode !== 200) { res.resume(); reject(new Error('metadata unavailable')); return; }
    let text = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => { text += chunk; if (text.length > 1_000_000) req.destroy(new Error('metadata too large')); });
    res.on('error', reject);
    res.on('end', () => { try { resolve(JSON.parse(text)); } catch (e) { reject(e); } });
  });
  req.on('error', reject);
});

export async function getContextCap({
  endpoint = process.env.LOCAL_LLM_ENDPOINT_URL || 'http://127.0.0.1:1234',
  model = process.env.LOCAL_LLM_MODEL || '',
} = {}) {
  const fallback = budget(FALLBACK_TOKENS, 'fallback');
  if (!isLoopbackEndpoint(endpoint)) return fallback;
  try {
    const list = (await models(endpoint))?.data;
    if (!Array.isArray(list)) return fallback;
    const loaded = list.filter((m) => m?.state === 'loaded' && m.type !== 'embeddings' && (!model || m.id === model));
    if (loaded.length !== 1) return fallback;
    const tokens = loaded[0].loaded_context_length;
    return Number.isSafeInteger(tokens) && tokens > 0 ? budget(tokens, 'loaded') : fallback;
  } catch {
    return fallback;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(JSON.stringify(await getContextCap()));
}
