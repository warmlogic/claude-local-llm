// Resolve the allowed folders for houtini's HOUTINI_LM_FILE_ROOTS, using houtini's own semantics.
// In: LOCAL_LLM_ALLOWED_DIRS (comma-separated; a leading $HOME, ${HOME} or ~ is expanded), HOME.
// Out: the resolved roots joined with "," on stdout; warnings and errors on stderr; exit 2 on refusal.
// Invariant: houtini 3.3.4 reads the variable as .split(/[:,]/).map(trim).filter(Boolean) and then
// realpathSync()s each piece (dist/index.js). Each root printed here parses back to exactly itself,
// so houtini reads precisely the folders resolved here and never a trimmed or split-off sibling.
// Entries are never trimmed: padding is refused rather than silently naming a sibling folder.
// Roots use realpathSync.native (on-disk case, like houtini's per-file fs/promises realpath);
// houtini's own realpathSync of that result returns it unchanged.
import { realpathSync, statSync } from 'node:fs';
import { isAbsolute } from 'node:path';

const fail = (msg) => { console.error(`local-llm: ${msg}`); process.exit(2); };
const home = process.env.HOME ?? '';
const roots = [];
let skipped = 0;

for (const raw of (process.env.LOCAL_LLM_ALLOWED_DIRS ?? '').split(',')) {
  if (!raw.trim()) continue;
  if (raw !== raw.trim()) fail(`allowed folder has leading/trailing whitespace (remove it in allowed_dirs): ${JSON.stringify(raw)}`);
  let entry = raw;
  entry = entry.replace(/^(\$HOME|\$\{HOME\}|~)(?=\/|$)/, () => isAbsolute(home) ? home : fail('HOME is not an absolute path'));
  if (entry.includes(':')) fail(`allowed folder must not contain ':' (houtini splits on it): ${entry}`);
  if (!isAbsolute(entry)) fail(`allowed folder must be an absolute path: ${entry}`);
  let resolved;
  let isDir;
  try { resolved = realpathSync.native(entry); isDir = statSync(resolved).isDirectory(); } catch (e) {
    if (e.code === 'ENOENT') { skipped++; console.error(`local-llm: allowed folder not found, skipping: ${entry}`); continue; }
    fail(`cannot resolve allowed folder (${e.code}): ${entry}`);
  }
  if (!isDir) fail(`allowed folder is not a directory: ${entry}`);
  if (/^\/+$/.test(resolved)) fail(`refusing '/' as an allowed folder: ${entry}`);
  const parsed = resolved.split(/[:,]/).map((r) => r.trim()).filter(Boolean);
  if (parsed.length !== 1 || parsed[0] !== resolved) {
    fail(`resolved folder would be altered by houtini's split/trim (',' ':' or edge whitespace): ${JSON.stringify(resolved)}`);
  }
  roots.push(resolved);
}
if (!roots.length && skipped) fail('none of the allowed folders exist (see warnings above); check allowed_dirs in the plugin options');
console.log(roots.join(','));
