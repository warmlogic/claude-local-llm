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
import { parseRoots } from './fence.mjs';
import { DEFAULT_K, KINDS, MAX_CLAIM_CHARS, MAX_CLAIMS, MAX_K, MAX_PATHS, verifyClaims } from './verify-claims.mjs';

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
    'entering your context. Returns JSON {model, k, results: [{claim, kind, auto_accept: false, label: ' +
    'SUPPORTED|NOT_SUPPORTED|NOT_RUN, p_supported (share of k samples that said SUPPORTED), agreement (share ' +
    'that agreed with label)}]}; when some claims could not finish it adds partial: true and error, and those ' +
    'claims are NOT_RUN with a reason. The result is a hint, never verification. Pass a claim as ' +
    '{text, kind: "lookup"} only when it is a plain fact you could check by finding one passage: no counts, ' +
    'order, comparisons, dates or quantifiers. Anything else, and a bare string, is "computed": the model is ' +
    'often unanimously wrong on those, so check them with Grep or code.',
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
        items: {
          anyOf: [
            { type: 'string', maxLength: MAX_CLAIM_CHARS },
            {
              type: 'object',
              properties: { text: { type: 'string', maxLength: MAX_CLAIM_CHARS }, kind: { type: 'string', enum: KINDS } },
              required: ['text'],
              additionalProperties: false,
            },
          ],
        },
        minItems: 1,
        maxItems: MAX_CLAIMS,
        description: 'Short, self-contained claims, one fact each: a string (kind computed) or {text, kind}',
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
const isId = (id) => typeof id === 'string' || (typeof id === 'number' && Number.isFinite(id));
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const short = (s) => JSON.stringify(s.slice(0, 80));

async function callTool(id, params) {
  if (typeof params?.name !== 'string') return fail(id, -32602, 'invalid params: name must be a string');
  if (params.name !== TOOL.name) return fail(id, -32602, `unknown tool: ${short(params.name)}`);
  if (params.arguments !== undefined && !isPlainObject(params.arguments)) {
    return fail(id, -32602, 'invalid params: arguments must be an object');
  }
  try {
    reply(id, text(JSON.stringify(await verifyClaims(cfg, params.arguments))));
  } catch (e) {
    console.error(`local-verify: verify_claims failed: ${e?.stack ?? e}`); // stderr is the MCP log
    reply(id, text(`Error: ${e?.message ?? 'internal error'}`, true));
  }
}

// Every field is type-checked before use, so no request shape can throw out of the handler.
function handle(msg) {
  if (!isPlainObject(msg)) return fail(null, -32600, 'invalid request');
  const { id, method, params } = msg;
  if (id === undefined) return undefined; // a notification (initialized, cancelled): no answer
  if (!isId(id)) return fail(null, -32600, 'invalid request: id must be a string or a number');
  if (typeof method !== 'string') return fail(id, -32600, 'invalid request: method must be a string');
  if (params !== undefined && !isPlainObject(params)) return fail(id, -32602, 'invalid params: params must be an object');
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
      return fail(id, -32601, `method not found: ${short(method)}`);
  }
}

const internalError = (id, e) => {
  console.error(`local-verify: internal error: ${e?.stack ?? e}`);
  fail(isId(id) ? id : null, -32603, 'internal error');
};

console.error(`local-verify: ready; allowed folders: ${roots.join(',')}`);
createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    fail(null, -32700, 'parse error');
    return;
  }
  try {
    Promise.resolve(handle(msg)).catch((e) => internalError(msg?.id, e));
  } catch (e) {
    internalError(msg?.id, e);
  }
});
