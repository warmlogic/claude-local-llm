// Live eval of verify_claims on the jev spike's two 48-item synthetic sets (tests/fixtures/verify/),
// through the real launcher and MCP tool against the model LM Studio has loaded. The fixtures are
// the spike's items exactly: easy = six hand-written excerpts with hand labels (SUPPORTED,
// CONTRADICTED, NOT_IN_SOURCE); hard = eight generated 40-line logs (seed 7) whose claims test
// counts, comparisons and time spans, with gold computed in code. Not per-commit:
// it needs LM Studio at LOCAL_LLM_ENDPOINT_URL (default http://127.0.0.1:1234) and takes minutes.
// Usage: node tests/eval-verify.mjs [k]   (EVAL_OUT=<file> also writes one JSON line per item)
// The binary question: gold SUPPORTED vs anything else. A false accept is a SUPPORTED label on a
// claim whose gold is not SUPPORTED; the bar for lookup claims is zero at unanimous agreement.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX = join(HERE, 'fixtures', 'verify');
const LAUNCHER = join(HERE, '..', 'scripts', 'launch-verify.sh');
const k = Number(process.argv[2] ?? 10);

// The spike's numbers for the same items (planning/references/jev-research.md, spike/metrics*.md).
const SPIKE = {
  easy: { acc: '48/48', fa: 0, faUnan: 0, fr: 0, unan: 45 },
  hard: { acc: '33/48', fa: 15, faUnan: 7, fr: 0, unan: 30 },
};

function callTool(paths, claims) {
  const args = JSON.stringify({ paths, claims, k });
  const env = { ...process.env, LOCAL_LLM_ALLOWED_DIRS: FIX };
  const run = spawnSync('node', [join(HERE, 'mcp-call.mjs'), LAUNCHER, 'verify_claims', args], { env, encoding: 'utf8' });
  const out = JSON.parse(run.stdout);
  if (!out.call || out.call.isError) throw new Error(`verify_claims failed: ${out.call?.text ?? out.stderr}`);
  return JSON.parse(out.call.text);
}

function runSet(name) {
  const items = JSON.parse(readFileSync(join(FIX, `${name}.json`), 'utf8'));
  const rows = [];
  for (const file of [...new Set(items.map((it) => it.file))]) {
    const mine = items.filter((it) => it.file === file);
    const t0 = Date.now();
    const res = callTool([join(FIX, file)], mine.map((it) => it.claim));
    const ms = Date.now() - t0;
    res.results.forEach((r, i) => rows.push({ set: name, file, gold: mine[i].gold, ...r, call_ms: ms, model: res.model }));
    process.stderr.write(`${name} ${file}: ${mine.length} claims in ${ms} ms\n`);
  }
  return rows;
}

function metrics(rows) {
  const isFa = (r) => r.label === 'SUPPORTED' && r.gold !== 'SUPPORTED';
  const isFr = (r) => r.label !== 'SUPPORTED' && r.gold === 'SUPPORTED';
  const unan = rows.filter((r) => r.agreement === 1);
  return {
    n: rows.length,
    acc: `${rows.filter((r) => !isFa(r) && !isFr(r)).length}/${rows.length}`,
    fa: rows.filter(isFa).length,
    faUnan: unan.filter(isFa).length,
    fr: rows.filter(isFr).length,
    unan: unan.length,
  };
}

const all = [...runSet('easy'), ...runSet('hard')];
if (process.env.EVAL_OUT) writeFileSync(process.env.EVAL_OUT, all.map((r) => JSON.stringify(r)).join('\n') + '\n');

const line = (cells) => `| ${cells.join(' | ')} |`;
console.log(`verify_claims eval, model ${all[0].model}, k=${k}\n`);
console.log(line(['set', 'subset', 'n', 'correct', 'false accepts', 'false accepts at unanimous', 'false rejects', 'unanimous', 'spike (correct / FA / FA unanimous / FR / unanimous)']));
console.log(line(Array(9).fill('---')));
for (const set of ['easy', 'hard']) {
  const rows = all.filter((r) => r.set === set);
  const s = SPIKE[set];
  for (const [subset, sel] of [['all', rows], ['lookup', rows.filter((r) => r.kind === 'lookup')], ['computed', rows.filter((r) => r.kind === 'computed')]]) {
    if (!sel.length) continue;
    const m = metrics(sel);
    const spike = subset === 'all' ? `${s.acc} / ${s.fa} / ${s.faUnan} / ${s.fr} / ${s.unan}` : '';
    console.log(line([set, subset, m.n, m.acc, m.fa, m.faUnan, m.fr, m.unan, spike]));
  }
}
const ms = all.map((r) => r.call_ms);
console.log(`\ncalls: ${new Set(all.map((r) => r.file)).size}, slowest ${Math.max(...ms)} ms`);
const lookupFaUnan = metrics(all.filter((r) => r.kind === 'lookup')).faUnan;
console.log(`acceptance (lookup claims, false accepts at unanimous agreement = 0): ${lookupFaUnan === 0 ? 'PASS' : `FAIL (${lookupFaUnan})`}`);
process.exitCode = lookupFaUnan === 0 ? 0 : 1;
