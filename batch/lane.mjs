// Shows a running batch as a lane in Catalyst's band: ~/catalyst/band/lanes/local-<pid>.json while it runs.
// Silent without Catalyst; if the write fails with Catalyst present, one stderr line says so. Fail-open: nothing here changes the run's results or exit status.
import { writeFileSync, renameSync, mkdirSync, rmSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const MAX_LABEL = 24;
const GIT_TIMEOUT_MS = 2000;

// "publisher/name@quant.gguf" -> "name": what the band has room for.
export const shortLabel = (name) => {
  const s = String(name ?? '').replace(/[\u0000-\u001f\u007f]/g, '').replace(/^.*\//, '').replace(/@.*$/, '').replace(/\.gguf$/i, '').trim();
  return (s || 'local').slice(0, MAX_LABEL);
};

const gitCommonDir = () => {
  try {
    const out = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { stdio: ['ignore', 'pipe', 'ignore'], timeout: GIT_TIMEOUT_MS, killSignal: 'SIGKILL', encoding: 'utf8' }).trim();
    return out.startsWith('/') && !out.includes('\n') ? out : null;
  } catch { return null; }
};

// Returns an idempotent, synchronous remove(); a no-op when registering failed.
export const registerLane = ({ label, task = null }) => {
  try { if (!statSync(join(homedir(), 'catalyst')).isDirectory()) return () => {}; } catch { return () => {}; } // no Catalyst, no trace: never create ~/catalyst itself
  const dir = join(homedir(), 'catalyst', 'band', 'lanes');
  let file = null;
  let tmp = null;
  try {
    mkdirSync(dir, { recursive: true });
    const target = join(dir, `local-${process.pid}.json`);
    tmp = `${target}.tmp`;
    const lane = { v: 1, kind: 'local', label: shortLabel(label), task: task || null, pid: process.pid, started: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), repo: gitCommonDir() };
    writeFileSync(tmp, JSON.stringify(lane) + '\n');
    renameSync(tmp, target);
    file = target;
  } catch (e) { // Catalyst is installed but the write failed: say so once, and run on
    console.error(`local-llm: could not write a lane file in ${dir} (${e.code ?? e.name}); running without a band lane`);
    if (tmp) { try { rmSync(tmp, { force: true }); } catch { /* the reader prunes dead pids */ } }
  }
  return () => { if (file) { try { rmSync(file, { force: true }); } catch { /* the reader prunes dead pids */ } } };
};
