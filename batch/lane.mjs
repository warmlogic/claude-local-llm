// Shows a running batch as a lane in Catalyst's band: ~/catalyst/band/lanes/local-<pid>.json while it runs.
// Harmless without Catalyst, and fail-open: no step here may change the run's output or exit status.
import { writeFileSync, renameSync, mkdirSync, rmSync } from 'node:fs';
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
    const out = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { stdio: ['ignore', 'pipe', 'ignore'], timeout: GIT_TIMEOUT_MS, encoding: 'utf8' }).trim();
    return out.startsWith('/') && !out.includes('\n') ? out : null;
  } catch { return null; }
};

// Returns an idempotent, synchronous remove(); a no-op when registering failed.
export const registerLane = ({ label, task = null }) => {
  let file = null;
  try {
    const dir = join(homedir(), 'catalyst', 'band', 'lanes');
    mkdirSync(dir, { recursive: true });
    const target = join(dir, `local-${process.pid}.json`);
    const tmp = `${target}.tmp`;
    const lane = { v: 1, kind: 'local', label: shortLabel(label), task: task || null, pid: process.pid, started: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), repo: gitCommonDir() };
    writeFileSync(tmp, JSON.stringify(lane) + '\n');
    renameSync(tmp, target);
    file = target;
  } catch { /* the band is optional */ }
  return () => { if (file) { try { rmSync(file, { force: true }); } catch { /* the reader prunes dead pids */ } } };
};
