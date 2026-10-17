#!/usr/bin/env node
// Usage: node flatten-transcripts.mjs <out_dir> <session.jsonl>...
// Flattens Claude Code session transcripts into one line per content block:
//   L<n>\t<role>\t<kind>\t<text>
// kind is text, tool_use, tool_result or tool_error; text is one line (newlines become " ⏎ ") cut at MAX_BLOCK_CHARS.
// Thinking blocks and entries without content are skipped. Writes <out_dir>/<session-basename>.txt.
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from 'node:fs';
import { basename } from 'node:path';
import { pathToFileURL } from 'node:url';

export const MAX_BLOCK_CHARS = 2000;

export const oneLine = (s) => {
  const t = String(s).replace(/\r?\n/g, ' ⏎ ').replace(/[\t\r]/g, ' ');
  return t.length > MAX_BLOCK_CHARS ? t.slice(0, MAX_BLOCK_CHARS) + '…' : t;
};
const textOf = (c) => (typeof c === 'string' ? c : Array.isArray(c) ? c.map((p) => p?.text ?? '').join(' ') : '');

// One block -> [kind, text] or null.
const blockOf = (b) => {
  if (typeof b === 'string') return ['text', b];
  if (b?.type === 'text') return ['text', b.text ?? ''];
  if (b?.type === 'tool_use') return ['tool_use', `${b.name} ${JSON.stringify(b.input ?? {})}`];
  if (b?.type === 'tool_result') return [b.is_error ? 'tool_error' : 'tool_result', textOf(b.content)];
  return null; // thinking and anything else
};

export const flatten = (jsonl) => {
  const out = [];
  let n = 0;
  for (const line of jsonl.split('\n')) {
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (e.type !== 'user' && e.type !== 'assistant') continue;
    const content = e.message?.content;
    const blocks = typeof content === 'string' ? [content] : Array.isArray(content) ? content : [];
    for (const b of blocks) {
      const r = blockOf(b);
      if (!r || !r[1].trim()) continue;
      out.push(`L${++n}\t${e.type}\t${r[0]}\t${oneLine(r[1])}`);
    }
  }
  return out;
};

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const [outDir, ...files] = process.argv.slice(2);
  if (!outDir || files.length === 0) {
    console.error('usage: flatten-transcripts.mjs <out_dir> <session.jsonl>...');
    process.exit(2);
  }
  const destOf = (f) => `${outDir}/${basename(f).replace(/\.jsonl$/, '')}.txt`;
  if (new Set(files.map(destOf)).size !== files.length) {
    console.error('flatten-transcripts: two inputs would write the same output file (same basename); nothing written');
    process.exit(2);
  }
  mkdirSync(outDir, { recursive: true });
  for (const f of files) {
    const lines = flatten(readFileSync(f, 'utf8'));
    const dest = destOf(f);
    writeFileSync(dest, lines.join('\n') + '\n');
    console.log(`${dest}: ${lines.length} lines`);
  }
}
