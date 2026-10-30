// Loopback HTTP listener standing in for LM Studio. Usage: node fake-endpoint.mjs <port-file> <log-file> [mode] [redirect-url|context-tokens]
// Writes its random port to <port-file> and appends one JSON line of request headers per request to <log-file>.
// Modes:
//   context   loaded chat plus embeddings/unloaded decoys; argv[5] is loaded_context_length (comma-separated for multiple loaded chat models).
//             Chat completions behave like batch.
//   models    (default) answers every request with an OpenAI-style list of two fake chat models.
//   error500  lists one loaded model but fails every chat completion with HTTP 500 (an "Other failure" for the skill).
//   no-model  mirrors LM Studio with nothing loaded: /v1/models is an empty list, /api/v0/models shows one
//             downloaded model with state "not-loaded", and chat completions fail with LM Studio's
//             "No models loaded" error (HTTP 404).
//   verify    stands in for the verify server's model: /api/v0/models shows one loaded chat model (after a
//             loaded embeddings model), and a chat completion answers after a short delay from a marker in
//             the CLAIM line: "[yes]" -> SUPPORTED; "[split]" -> SUPPORTED on even seeds, CONTRADICTED on
//             odd; "[stall]" -> never answers; "[fail]" -> HTTP 500 whose error message echoes the prompt;
//             "[echo400]" -> HTTP 400 likewise; "[html]" -> a non-JSON 200; "[badfinish]" -> non-JSON content
//             and a finish_reason that echo the prompt; "[ctx]" -> LM Studio's real context-overflow 400
//             (captured from LM Studio 0.4's Splash engine); "[nomodel]" -> a 404 with code model_not_found;
//             "[fail-seed0]" -> an immediate 500 for the claim's first seed only; "[oddcode]" -> a 400 with an
//             unlisted error code; "[cutbody]" -> a 200 whose body is cut off mid-stream; "[badheaders]" ->
//             raw, malformed HTTP headers that echo the prompt (an HTTP parser error carries those bytes);
//             else NOT_IN_SOURCE. Logs the
//             parsed request body and the number of chat requests in flight (inflight) as it arrives.
//   verify-stall-once  as verify, but the first request for each seed never answers.
//   verify-stall       chat completions never answer.
//   verify-slowlist-once  as verify, but the first /api/v0/models request never answers (a call parked in its model lookup).
//   verify-garbage-once  as verify, but a first-draw seed (seed % 1000 < 500) gets a cut-off answer of
//             newlines (finish_reason "length"), as a temperature-1 sample sometimes does.
//   verify-garbage       every answer is cut off.
//   verify-redirect      as verify, but chat completions answer 307 to <redirect-url> (which must never see them).
//   verify-v1            as verify, but /api/v0/models is a 404 and /v1/models lists an embeddings model and
//             one chat model (a server without LM Studio's API).
//   verify-v1-many       as verify-v1, with two chat models listed.
//   verify-nostate       as verify, but /api/v0/models entries carry no load state.
//   verify-badlist       as verify, but /api/v0/models answers an object with no data array.
//   verify-nolists       as verify, but both /api/v0/models and /v1/models are 404s (endpoint_url with /v1).
//   verify-twoloaded     as verify, but /api/v0/models shows two loaded chat models.
//   verify-embedonly     as verify, but only an embeddings model is loaded.
//   verify-slowlist      as verify, but /api/v0/models never answers.
//   batch     stands in for the model behind batch/run.mjs: a chat completion answers two rows for the first
//             "L<n>\t..." line of the request text, one quoting that line truly and one with a fabricated
//             quote (each also carries a bogus file/window/reason the runner must override), and logs the parsed request body (body). usage reports 10 prompt and 5 completion tokens.
//   batch-bad          as batch, but every reply's content is not JSON.
//   batch-bad-once     as batch, but the first reply to each distinct request is not JSON.
//   batch-length       as batch, but every reply is cut off (finish_reason "length").
//   batch-empty-some   as batch, but every even request returns an empty rows array.
//   batch-all-dropped  as batch, but returns only the row with a fabricated quote.
//   batch-flaky        as batch, but every other request (the 1st, 3rd, ...) fails with HTTP 500.
//   batch-then-fail    as batch, but only the first request is answered; every later one fails with HTTP 500.
//   batch-stall        logs the request and never answers.
//   batch-stall-model  as batch-stall, and /api/v0/models shows one loaded chat model, acme/qwen3-7b@q4_k_m.
//   proxy     an HTTP proxy that must never be used: logs each request (absolute URL) and answers 502.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const [portFile, logFile, mode = 'models', redirectUrl] = process.argv.slice(2);
const json = (res, status, body) => {
  res.statusCode = status;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(body));
};
const seen = new Set();
let inflight = 0;
const DELAY_MS = 20; // keeps requests in flight long enough to overlap
const LMSTUDIO_CTX_ERROR = "{\"error\":\"Engine protocol predict request returned 400: {\\\"error\\\":{\\\"message\\\":\\\"prompt exceeds the context window\\\",\\\"type\\\":\\\"invalid_request_error\\\",\\\"code\\\":\\\"context_length_exceeded\\\"}}\"}";
const claimOf = (body) => (body.messages?.at(-1)?.content.match(/^CLAIM: (.*)$/m) || [])[1] ?? '';
const verifyLabel = (body) => {
  const claim = claimOf(body);
  if (claim.includes('[yes]')) return 'SUPPORTED';
  if (claim.includes('[split]')) return body.seed % 2 === 0 ? 'SUPPORTED' : 'CONTRADICTED';
  return 'NOT_IN_SOURCE';
};
const answer = (res, content, finish = 'stop') =>
  json(res, 200, { choices: [{ message: { role: 'assistant', content }, finish_reason: finish }] });
const MODELS_V0 = {
  verify: [{ id: 'fake-embed', type: 'embeddings', state: 'loaded' }, { id: 'fake-verify-model', type: 'llm', state: 'loaded' }],
  'verify-nostate': [{ id: 'fake-a', type: 'llm' }, { id: 'fake-b', type: 'llm' }],
  'verify-twoloaded': [{ id: 'fake-a', type: 'llm', state: 'loaded' }, { id: 'fake-b', type: 'vlm', state: 'loaded' }],
  'verify-embedonly': [{ id: 'fake-embed', type: 'embeddings', state: 'loaded' }, { id: 'fake-chat', type: 'llm', state: 'not-loaded' }],
};
const MODELS_V1 = {
  'verify-v1': [{ id: 'text-embedding-fake' }, { id: 'v1-chat-model' }],
  'verify-v1-many': [{ id: 'v1-a' }, { id: 'v1-b' }],
};
const verify = (req, res) => {
  if (req.url === '/api/v0/models') {
    if (MODELS_V1[mode] || mode === 'verify-nolists') return json(res, 404, { error: 'Unexpected endpoint' });
    if (mode === 'verify-badlist') return json(res, 200, { object: 'list' });
    if (mode === 'verify-slowlist') return undefined; // never answer
    if (mode === 'verify-slowlist-once' && !seen.has('models')) { seen.add('models'); appendFileSync(logFile, JSON.stringify({ url: req.url, stalled: true }) + '\n'); return undefined; } // only the first lookup never answers
    return json(res, 200, { object: 'list', data: MODELS_V0[mode] ?? MODELS_V0.verify });
  }
  if (req.url === '/v1/models' && MODELS_V1[mode]) return json(res, 200, { object: 'list', data: MODELS_V1[mode] });
  if (req.url !== '/v1/chat/completions') return json(res, 404, { error: `Unexpected endpoint (${req.url})` });
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    const body = JSON.parse(raw);
    inflight++;
    res.on('close', () => { inflight--; });
    appendFileSync(logFile, JSON.stringify({ url: req.url, inflight, body }) + '\n');
    const claim = claimOf(body);
    const prompt = body.messages?.at(-1)?.content ?? '';
    if (mode === 'verify-redirect') {
      res.writeHead(307, { location: `${redirectUrl}/v1/chat/completions` });
      return res.end();
    }
    if (claim.includes('[stall]') || mode === 'verify-stall' || (mode === 'verify-stall-once' && !seen.has(body.seed))) {
      seen.add(body.seed);
      return; // never answer
    }
    if (claim.includes('[fail-seed0]') && body.seed % 1000 === 0) return json(res, 500, { error: { code: 'server_error' } });
    setTimeout(() => {
      if (claim.includes('[fail]')) return json(res, 500, { error: { message: `upstream echo: ${prompt}`, code: 'server_error' } });
      if (claim.includes('[echo400]')) return json(res, 400, { error: `bad request: ${prompt}` });
      if (claim.includes('[ctx]')) {
        res.statusCode = 400;
        res.setHeader('content-type', 'application/json; charset=utf-8');
        return res.end(LMSTUDIO_CTX_ERROR);
      }
      if (claim.includes('[badheaders]')) {
        const echo = prompt.replace(/[\r\n]+/g, ' ');
        res.socket.write(`HTTP/1.1 200 OK\r\nX-Echo: ${echo}\r\nBad\u0001Header ${echo}\r\n\r\n`);
        return setTimeout(() => res.socket.destroy(), 20);
      }
      if (claim.includes('[oddcode]')) return json(res, 400, { error: { message: `odd ${prompt}`, code: 'weird_code_x' } });
      if (claim.includes('[cutbody]')) {
        res.writeHead(200, { 'content-type': 'application/json', 'content-length': '100000' });
        res.write('{"choices":[{"message":');
        return setTimeout(() => res.socket.destroy(), 20);
      }
      if (claim.includes('[nomodel]')) return json(res, 404, { error: { message: `model not found ${prompt}`, code: 'model_not_found' } });
      if (claim.includes('[badfinish]')) return answer(res, `not json ${prompt}`, `canary-finish ${prompt}`);
      if (claim.includes('[html]')) {
        res.setHeader('content-type', 'text/html');
        return res.end(`<html>${prompt}</html>`);
      }
      if (mode === 'verify-garbage' || (mode === 'verify-garbage-once' && body.seed % 1000 < 500)) {
        return answer(res, '\n\n\n{\n  "label": "S', 'length');
      }
      answer(res, JSON.stringify({ label: verifyLabel(body) }));
    }, DELAY_MS);
  });
};
let requests = 0;
const batch = (req, res) => {
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    if (req.url === '/api/v0/models' && mode === 'batch-stall-model') return json(res, 200, { data: [{ id: 'acme/qwen3-7b@q4_k_m', type: 'llm', state: 'loaded', loaded_context_length: 32768 }] });
    if (req.url !== '/v1/chat/completions') return json(res, 404, { error: `Unexpected endpoint (${req.url})` });
    const body = JSON.parse(raw);
    appendFileSync(logFile, JSON.stringify({ url: req.url, body }) + '\n');
    const text = body.messages.at(-1).content;
    const key = text.length + text.slice(-200);
    const first = !seen.has(key);
    seen.add(key);
    const line = text.match(/^(L\d+)\t(?:(?:user|assistant)\t[^\t]*\t)?(.*)$/m);
    const reply = (content, finish = 'stop') => json(res, 200, {
      choices: [{ message: { role: 'assistant', content }, finish_reason: finish }],
      usage: { prompt_tokens: 10, completion_tokens: 5 },
    });
    if (mode === 'batch-stall' || mode === 'batch-stall-model') return; // never answer
    if (mode === 'batch-then-fail' && ++requests > 1) return json(res, 500, { error: { code: 'server_error' } });
    if (mode === 'batch-flaky' && ++requests % 2 === 1) return json(res, 500, { error: { code: 'server_error' } });
    if (mode === 'batch-bad' || (mode === 'batch-bad-once' && first)) return reply('not json');
    if (mode === 'batch-length') return reply('{"rows":[', 'length');
    if (mode === 'batch-empty-some' && ++requests % 2 === 0) return reply('{"rows":[]}');
    const rows = line ? [
      // file and window are provenance the runner sets; a model-supplied value must never win
      { line: line[1], kind: 'correction', quote: line[2].slice(0, 12), note: 'true quote', file: 'model-says-so', window: 99 },
      { line: line[1], kind: 'stuck', quote: 'FABRICATED-QUOTE-NOT-IN-LINE', note: 'fabricated', reason: 'model-says-so' },
    ] : [];
    reply(JSON.stringify({ rows: mode === 'batch-all-dropped' ? rows.slice(1) : rows }));
  });
};
const proxy = (req, res) => {
  req.resume();
  json(res, 502, { error: 'proxy must not be used' });
};
const server = createServer((req, res) => {
  appendFileSync(logFile, JSON.stringify({ url: req.url, headers: req.headers }) + '\n');
  if (mode === 'proxy') return proxy(req, res);
  if (mode === 'context') {
    if (req.url === '/api/v0/models') return json(res, 200, { data: [
      { id: 'fake-embed', type: 'embeddings', state: 'loaded', loaded_context_length: 999999 },
      { id: 'fake-idle', type: 'llm', state: 'not-loaded', loaded_context_length: 999999 },
      ...redirectUrl.split(',').map((n, i) => ({ id: i ? `fake-context-${i + 1}` : 'fake-context', type: 'llm', state: 'loaded', loaded_context_length: Number(n) })),
    ] });
    return batch(req, res);
  }
  if (mode.startsWith('batch')) return batch(req, res);
  if (mode.startsWith('verify')) return verify(req, res);
  if (mode === 'error500') {
    const models = [{ id: 'broken-model', object: 'model', type: 'llm', state: 'loaded' }];
    if (req.url === '/v1/models' || req.url === '/api/v0/models') return json(res, 200, { object: 'list', data: models });
    req.resume();
    return json(res, 500, { error: 'Internal server error' });
  }
  if (mode === 'no-model') {
    if (req.url === '/v1/models') return json(res, 200, { object: 'list', data: [] });
    if (req.url === '/api/v0/models') {
      return json(res, 200, { object: 'list', data: [{ id: 'downloaded-model', object: 'model', type: 'llm', state: 'not-loaded' }] });
    }
    if (req.url === '/v1/chat/completions') {
      req.resume();
      return json(res, 404, { error: "No models loaded. Please load a model in the developer page or use the 'lms load' command." });
    }
    return json(res, 404, { error: `Unexpected endpoint or method. (${req.method} ${req.url})` });
  }
  json(res, 200, { object: 'list', data: [{ id: 'fake-model', object: 'model' }, { id: 'fake-model-2', object: 'model' }] });
});
if (mode === 'proxy') {
  server.on('connect', (req, socket) => { // an https proxy request
    appendFileSync(logFile, JSON.stringify({ url: req.url, connect: true }) + '\n');
    socket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n');
  });
}
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
