// Errors and what may be said about them. One rule: a reply or a log carries only text this server
// wrote, plus allowlisted metadata. A VerifyError's message is built here from fixed text, paths,
// numbers and allowlisted codes, so it may go into a reply or a log. Any other error (from undici,
// node, JSON.parse, a bug) is described by metadata alone: an HTTP parser error, for one, keeps the
// raw response bytes in .data, and an upstream that echoes the prompt puts file text there.
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export class VerifyError extends Error {}

const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_.-]{0,63}$/;
const META = ['name', 'code', 'errno', 'syscall', 'status'];

// {name, code, errno, syscall, status}, each only when identifier-shaped or a number.
function metadata(e) {
  const out = {};
  for (const key of META) {
    const v = e?.[key];
    if ((typeof v === 'string' && IDENTIFIER.test(v)) || (typeof v === 'number' && Number.isFinite(v))) out[key] = v;
  }
  return out;
}

// Stack frames in this plugin's own files, read after the message so that no message text can
// pose as a frame.
function ownFrames(e) {
  const stack = typeof e.stack === 'string' ? e.stack : '';
  const head = `${e.name}: ${e.message}`;
  const frames = stack.startsWith(head) ? stack.slice(head.length) : '';
  return frames.split('\n').filter((l) => /^\s+at /.test(l) && l.includes(PLUGIN_ROOT)).map((l) => l.trim());
}

// A loggable description: our errors with message and own frames; anything else, and every link of
// a cause chain that is not ours, as metadata only.
export function describeError(e, depth = 0) {
  const ours = e instanceof VerifyError;
  const d = { ...metadata(e), ...(ours ? { message: e.message, frames: ownFrames(e) } : {}) };
  if (e?.cause !== undefined && depth < 4) d.cause = describeError(e.cause, depth + 1);
  return d;
}

export const logError = (label, e) => console.error(`local-verify: ${label}: ${JSON.stringify(describeError(e))}`);

// The text a reply may carry for an error.
export const safeMessage = (e) => (e instanceof VerifyError ? e.message : 'internal error (details in the MCP log)');
