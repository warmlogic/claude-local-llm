// Loopback HTTP listener standing in for LM Studio. Usage: node fake-endpoint.mjs <port-file> <log-file>
// Writes its random port to <port-file>, appends one JSON line of request headers per request to
// <log-file>, and answers every request with an empty OpenAI-style model list.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const [portFile, logFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  appendFileSync(logFile, JSON.stringify({ url: req.url, headers: req.headers }) + '\n');
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ object: 'list', data: [{ id: 'fake-model', object: 'model' }] }));
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
