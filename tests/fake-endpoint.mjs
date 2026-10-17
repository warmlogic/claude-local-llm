// Loopback HTTP listener standing in for LM Studio. Usage: node fake-endpoint.mjs <port-file> <log-file> [mode]
// Writes its random port to <port-file> and appends one JSON line of request headers per request to <log-file>.
// Modes:
//   models    (default) answers every request with an OpenAI-style list of two fake chat models.
//   error500  lists one loaded model but fails every chat completion with HTTP 500 (an "Other failure" for the skill).
//   no-model  mirrors LM Studio with nothing loaded: /v1/models is an empty list, /api/v0/models shows one
//             downloaded model with state "not-loaded", and chat completions fail with LM Studio's
//             "No models loaded" error (HTTP 404).
//   verify    stands in for the verify server's model: /api/v0/models shows one loaded model, and a chat
//             completion answers {"label": ...} from a marker in the CLAIM line: "[yes]" -> SUPPORTED,
//             "[split]" -> SUPPORTED on even seeds and CONTRADICTED on odd ones, else NOT_IN_SOURCE.
//             Logs the parsed request body too.
//   verify-stall-once  as verify, but the first request for each seed never answers.
//   verify-stall       chat completions never answer.
//   verify-garbage-once  as verify, but a first-draw seed (seed % 1000 < 500) gets a cut-off answer of
//             newlines (finish_reason "length"), as a temperature-1 sample sometimes does.
//   verify-garbage       every answer is cut off.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const [portFile, logFile, mode = 'models'] = process.argv.slice(2);
const json = (res, status, body) => {
  res.statusCode = status;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(body));
};
const seen = new Set();
const verifyLabel = (body) => {
  const claim = (body.messages?.at(-1)?.content.match(/^CLAIM: (.*)$/m) || [])[1] ?? '';
  if (claim.includes('[yes]')) return 'SUPPORTED';
  if (claim.includes('[split]')) return body.seed % 2 === 0 ? 'SUPPORTED' : 'CONTRADICTED';
  return 'NOT_IN_SOURCE';
};
const verify = (req, res) => {
  if (req.url === '/api/v0/models') {
    return json(res, 200, { object: 'list', data: [{ id: 'fake-verify-model', object: 'model', type: 'llm', state: 'loaded' }] });
  }
  if (req.url !== '/v1/chat/completions') return json(res, 404, { error: `Unexpected endpoint (${req.url})` });
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    const body = JSON.parse(raw);
    appendFileSync(logFile, JSON.stringify({ url: req.url, body }) + '\n');
    if (mode === 'verify-stall' || (mode === 'verify-stall-once' && !seen.has(body.seed))) {
      seen.add(body.seed);
      return; // never answer
    }
    if (mode === 'verify-garbage' || (mode === 'verify-garbage-once' && body.seed % 1000 < 500)) {
      return json(res, 200, { choices: [{ message: { role: 'assistant', content: '\n\n\n{\n  "label": "S' }, finish_reason: 'length' }] });
    }
    json(res, 200, { choices: [{ message: { role: 'assistant', content: JSON.stringify({ label: verifyLabel(body) }) } }] });
  });
};
const server = createServer((req, res) => {
  appendFileSync(logFile, JSON.stringify({ url: req.url, headers: req.headers }) + '\n');
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
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
