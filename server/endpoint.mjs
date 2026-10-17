// HTTP to the loopback model endpoint for verify_claims: one JSON exchange per request, the shared
// request slots, and model selection.
// Nothing upstream is ever forwarded as text: an error becomes a fixed diagnostic built from the
// HTTP status and an allowlisted error code, because an upstream message (or a body, or a JSON
// parse error quoting one) can echo the prompt, and the prompt holds file text.
// Redirects are an error, not followed: fetch would re-send the body to wherever they point.

export const PARALLEL_SLOTS = 4; // LM Studio's default parallel slots for one loaded model

export class RequestTimeout extends Error {}

export class EndpointError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

const ERROR_CODES = new Set([
  'context_length_exceeded',
  'invalid_request_error',
  'model_not_found',
  'no_models_loaded',
  'rate_limit_exceeded',
  'server_error',
]);
const CODE_HINTS = {
  context_length_exceeded: "the files are too large for the model's context; send smaller files",
  no_models_loaded: 'No models loaded in LM Studio; load one, then retry',
};

// The allowlisted code an error body carries, if any. The message is matched, never repeated.
export function upstreamCode(json) {
  const err = json?.error;
  for (const c of [err?.code, err?.type]) if (typeof c === 'string' && ERROR_CODES.has(c)) return c;
  const msg = typeof err === 'string' ? err : typeof err?.message === 'string' ? err.message : '';
  if (/no models loaded/i.test(msg)) return 'no_models_loaded';
  if (/context[ _-]?length|context window|too many tokens/i.test(msg)) return 'context_length_exceeded';
  return null;
}

const diagnostic = (status, code) =>
  `endpoint error (HTTP ${status}${code ? `, ${code}` : ''})${CODE_HINTS[code] ? `: ${CODE_HINTS[code]}` : ''}`;

export async function fetchJson(url, init, timeoutMs, signal) {
  const timer = AbortSignal.timeout(timeoutMs);
  let res;
  let text;
  try {
    res = await fetch(url, { ...init, redirect: 'manual', signal: AbortSignal.any([timer, signal]) });
    if (res.status >= 300 && res.status < 400) {
      throw new EndpointError(`endpoint error (HTTP ${res.status}): redirects are not followed`, res.status);
    }
    text = await res.text();
  } catch (e) {
    if (signal.aborted) throw signal.reason;
    if (timer.aborted) throw new RequestTimeout('a request to the endpoint timed out');
    if (e instanceof EndpointError) throw e;
    throw new Error(`fetch failed (${typeof e.cause?.code === 'string' ? e.cause.code : 'network error'})`);
  }
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  if (!res.ok) throw new EndpointError(diagnostic(res.status, upstreamCode(json)), res.status);
  if (json === undefined) throw new EndpointError(`the endpoint returned a non-JSON response (HTTP ${res.status})`, res.status);
  return json;
}

// --- request slots, shared by every call this server handles ------------------------------------
let freeSlots = PARALLEL_SLOTS;
const waiting = [];
const release = () => {
  const next = waiting.shift();
  if (next) next();
  else freeSlots++;
};

// Runs fn in a slot. A caller still queued when its signal aborts leaves the queue at once, so a
// call's budget holds even while other calls hold every slot.
export async function withSlot(signal, fn) {
  signal.throwIfAborted();
  if (freeSlots > 0) {
    freeSlots--;
  } else {
    await new Promise((resolve, reject) => {
      const onAbort = () => {
        const i = waiting.indexOf(granted);
        if (i >= 0) waiting.splice(i, 1);
        reject(signal.reason);
      };
      const granted = () => {
        signal.removeEventListener('abort', onAbort);
        resolve();
      };
      waiting.push(granted);
      signal.addEventListener('abort', onAbort, { once: true });
    });
  }
  try {
    return await fn();
  } finally {
    release();
  }
}

export const slotState = () => ({ freeSlots, waiting: waiting.length }); // for tests

// --- model selection --------------------------------------------------------------------------
const isEmbedding = (m) => m?.type === 'embeddings' || /embed/i.test(String(m?.id ?? ''));

// The pinned model; else the chat model LM Studio's /api/v0/models reports loaded; else, on a
// server without that API, the only non-embedding model /v1/models lists. Never names a model
// whose load state is unknown, since naming an unloaded model makes LM Studio load it.
export async function pickModel(cfg, signal) {
  if (cfg.model) return cfg.model;
  const get = (path) => fetchJson(`${cfg.base}${path}`, {}, cfg.requestTimeoutMs, signal);
  let v0;
  try {
    v0 = await get('/api/v0/models');
  } catch (e) {
    if (e.status !== 404) throw e;
    const v1 = await get('/v1/models');
    if (!Array.isArray(v1?.data)) throw new Error('unexpected response from /v1/models');
    const chat = v1.data.filter((m) => typeof m?.id === 'string' && !isEmbedding(m));
    if (chat.length === 1) return chat[0].id;
    if (!chat.length) throw new Error('No models loaded: the endpoint lists no chat model');
    throw new Error(`cannot tell which of ${chat.length} listed models is loaded; set the model plugin option`);
  }
  if (!Array.isArray(v0?.data)) throw new Error('unexpected response from /api/v0/models');
  const chat = v0.data.filter((m) => typeof m?.id === 'string' && !isEmbedding(m));
  const loaded = chat.find((m) => m.state === 'loaded');
  if (loaded) return loaded.id;
  if (chat.some((m) => m.state === undefined)) {
    throw new Error('cannot tell which model is loaded (no load state reported); set the model plugin option');
  }
  throw new Error('No models loaded in LM Studio; load one, then retry');
}
