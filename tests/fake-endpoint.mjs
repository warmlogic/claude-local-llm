// Loopback HTTP listener standing in for LM Studio. Usage: node fake-endpoint.mjs <port-file> <log-file> [mode] [redirect-url]
// Writes its random port to <port-file> and appends one JSON line of request headers per request to <log-file>.
// Modes:
//   models    (default) answers every request with an OpenAI-style list of two fake chat models.
//   error500  lists one loaded model but fails every chat completion with HTTP 500 (an "Other failure" for the skill).
//   no-model  mirrors LM Studio with nothing loaded: /v1/models is an empty list, /api/v0/models shows one
//             downloaded model with state "not-loaded", and chat completions fail with LM Studio's
//             "No models loaded" error (HTTP 404).
//   verify    stands in for the verify server's model: /api/v0/models shows one loaded chat model (after a
//             loaded embeddings model), and a chat completion answers after a short delay from a marker in
//             the CLAIM line: "[yes]" -> SUPPORTED; "[split]" -> SUPPORTED on even seeds, CONTRADICTED on
//             odd; "[stall]" -> never answers; "[fail]" -> HTTP 500 whose error message echoes the prompt;
//             "[echo400]" -> HTTP 400 likewise; "[html]" -> a non-JSON 200; else NOT_IN_SOURCE. Logs the
//             parsed request body and the number of chat requests in flight (inflight) as it arrives.
//   verify-stall-once  as verify, but the first request for each seed never answers.
//   verify-stall       chat completions never answer.
//   verify-garbage-once  as verify, but a first-draw seed (seed % 1000 < 500) gets a cut-off answer of
//             newlines (finish_reason "length"), as a temperature-1 sample sometimes does.
//   verify-garbage       every answer is cut off.
//   verify-redirect      as verify, but chat completions answer 307 to <redirect-url> (which must never see them).
//   verify-v1            as verify, but /api/v0/models is a 404 and /v1/models lists an embeddings model and
//             one chat model (a server without LM Studio's API).
//   verify-v1-many       as verify-v1, with two chat models listed.
//   verify-nostate       as verify, but /api/v0/models entries carry no load state.
//   verify-badlist       as verify, but /api/v0/models answers an object with no data array.
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
};
const MODELS_V1 = {
  'verify-v1': [{ id: 'text-embedding-fake' }, { id: 'v1-chat-model' }],
  'verify-v1-many': [{ id: 'v1-a' }, { id: 'v1-b' }],
};
const verify = (req, res) => {
  if (req.url === '/api/v0/models') {
    if (MODELS_V1[mode]) return json(res, 404, { error: 'Unexpected endpoint' });
    if (mode === 'verify-badlist') return json(res, 200, { object: 'list' });
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
    setTimeout(() => {
      if (claim.includes('[fail]')) return json(res, 500, { error: { message: `upstream echo: ${prompt}`, code: 'server_error' } });
      if (claim.includes('[echo400]')) return json(res, 400, { error: `bad request: ${prompt}` });
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
const proxy = (req, res) => {
  req.resume();
  json(res, 502, { error: 'proxy must not be used' });
};
const server = createServer((req, res) => {
  appendFileSync(logFile, JSON.stringify({ url: req.url, headers: req.headers }) + '\n');
  if (mode === 'proxy') return proxy(req, res);
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
