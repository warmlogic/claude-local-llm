// local-verify: a minimal stdio MCP server (node stdlib, no dependencies) with one tool,
// verify_claims (see verify-claims.mjs). Start it through scripts/launch-verify.sh, which resolves
// the allowed folders and checks the endpoint; this file re-checks both and refuses to start
// without them, so running it directly cannot read outside a fence or talk to a remote host.
// Env: LOCAL_VERIFY_ROOTS (resolved roots, comma-joined), LOCAL_LLM_ENDPOINT_URL, LOCAL_LLM_MODEL,
//      LOCAL_VERIFY_REQUEST_TIMEOUT_MS, LOCAL_VERIFY_BUDGET_MS (tests shorten these).
// Protocol: newline-delimited JSON-RPC 2.0; initialize, ping, tools/list, tools/call. Notifications
// are ignored. stdout carries protocol messages only; status lines go to stderr.
import { createInterface } from 'node:readline';
import { isLoopbackEndpoint, loopbackError } from '../scripts/loopback.mjs';
import { DEFAULT_K, MAX_CLAIMS, MAX_K, MAX_PATHS, parseRoots, verifyClaims } from './verify-claims.mjs';

const SERVER_INFO = { name: 'local-verify', version: '0.1.0' };
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']; // newest first
const DEFAULT_REQUEST_TIMEOUT_MS = 45000;
const DEFAULT_BUDGET_MS = 240000;

const die = (msg) => {
  console.error(`local-verify: ${msg}`);
  process.exit(2);
};
const positiveInt = (name, fallback) => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : die(`${name} must be a positive integer`);
};

const endpoint = process.env.LOCAL_LLM_ENDPOINT_URL || 'http://127.0.0.1:1234';
if (!isLoopbackEndpoint(endpoint)) die(loopbackError(endpoint));
let roots;
try {
  roots = parseRoots(process.env.LOCAL_VERIFY_ROOTS);
} catch (e) {
  die(e.message);
}
const cfg = {
  endpoint,
  base: endpoint.replace(/\/+$/, ''),
  model: process.env.LOCAL_LLM_MODEL || '',
  roots,
  requestTimeoutMs: positiveInt('LOCAL_VERIFY_REQUEST_TIMEOUT_MS', DEFAULT_REQUEST_TIMEOUT_MS),
  budgetMs: positiveInt('LOCAL_VERIFY_BUDGET_MS', DEFAULT_BUDGET_MS),
};

const TOOL = {
  name: 'verify_claims',
  description:
    'Ask the local model (LM Studio) whether each claim is supported by the given files, without the files ' +
    'entering your context. Returns JSON {model, k, results: [{claim, label: SUPPORTED|NOT_SUPPORTED, ' +
    'p_supported (share of k samples that said SUPPORTED), agreement (share that agreed with label), ' +
    'kind: lookup|computed}]}. The result is a hint, never verification. Claims with numbers, counts, dates ' +
    'or comparisons are kind "computed" and carry auto_accept: false, because the model is often unanimously ' +
    'wrong on them; check those with Grep or code.',
  inputSchema: {
    type: 'object',
    properties: {
      paths: {
        type: 'array',
        items: { type: 'string' },
        minItems: 1,
        maxItems: MAX_PATHS,
        description: 'Absolute paths of the source files (inside the allowed folders, at most 1 MB each)',
      },
      claims: {
        type: 'array',
        items: { type: 'string' },
        minItems: 1,
        maxItems: MAX_CLAIMS,
        description: 'Short, self-contained claims to check, one fact each',
      },
      k: { type: 'integer', minimum: 1, maximum: MAX_K, default: DEFAULT_K, description: 'Samples per claim' },
    },
    required: ['paths', 'claims'],
    additionalProperties: false,
  },
  annotations: { readOnlyHint: true, openWorldHint: false },
};

const send = (msg) => process.stdout.write(`${JSON.stringify(msg)}\n`);
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });
const text = (t, isError = false) => ({ content: [{ type: 'text', text: t }], isError });

async function callTool(id, params) {
  if (params?.name !== TOOL.name) return fail(id, -32602, `unknown tool: ${String(params?.name)}`);
  try {
    reply(id, text(JSON.stringify(await verifyClaims(cfg, params.arguments))));
  } catch (e) {
    reply(id, text(`Error: ${e.message}`, true));
  }
}

function handle(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;
  if (!isRequest) return; // notifications (initialized, cancelled) need no answer
  switch (method) {
    case 'initialize': {
      const asked = params?.protocolVersion;
      const protocolVersion = PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0];
      return reply(id, { protocolVersion, capabilities: { tools: {} }, serverInfo: SERVER_INFO });
    }
    case 'ping':
      return reply(id, {});
    case 'tools/list':
      return reply(id, { tools: [TOOL] });
    case 'tools/call':
      return callTool(id, params);
    default:
      return fail(id, -32601, `method not found: ${String(method)}`);
  }
}

console.error(`local-verify: ready; allowed folders: ${roots.join(',')}`);
createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return fail(null, -32700, 'parse error');
  }
  if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) return fail(null, -32600, 'invalid request');
  handle(msg);
});
