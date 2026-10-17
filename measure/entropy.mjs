// Corpus guard: drops every candidate holding a high-entropy token, the shape of a key or credential that no pattern
// list names. Reads the selector's candidate TSV on stdin (path in the last column), writes the rows that pass to
// stdout, and prints only counts to stderr, never a path or file text. A file that cannot be read is dropped.
// Rule: a run of at least MIN_LEN characters from [A-Za-z0-9+/_=-] whose Shannon entropy exceeds MAX_BITS per char.
// Known gap: a pure-hex run has at most 4.0 bits per char, so a bare hex key never trips it (best-effort, by design).
import { readFileSync } from "node:fs";

const MIN_LEN = 32;
const MAX_BITS = 4.0;
const TOKEN = new RegExp(`[A-Za-z0-9+/_=-]{${MIN_LEN},}`, "g");

function entropy(s) {
  const n = new Map();
  for (const c of s) n.set(c, (n.get(c) || 0) + 1);
  let h = 0;
  for (const k of n.values()) { const p = k / s.length; h -= p * Math.log2(p); }
  return h;
}
export function hasSecretLikeToken(text) {
  for (const m of text.matchAll(TOKEN)) if (entropy(m[0]) > MAX_BITS) return true;
  return false;
}

const rows = readFileSync(0, "utf8").split("\n").filter(Boolean);
let dropped = 0, unreadable = 0;
for (const row of rows) {
  const path = row.split("\t").at(-1);
  let text;
  try { text = readFileSync(path, "utf8"); } catch { unreadable++; continue; }
  if (hasSecretLikeToken(text)) { dropped++; continue; }
  process.stdout.write(row + "\n");
}
if (dropped) process.stderr.write(`select-corpus: the entropy guard dropped ${dropped} candidate(s)\n`);
if (unreadable) process.stderr.write(`select-corpus: warning: ${unreadable} candidate(s) could not be read for the entropy guard; dropped\n`);
