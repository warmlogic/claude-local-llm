// File access for verify_claims, with houtini's fence semantics: realpath the requested file, then
// accept it only when it equals a root or sits under `root + sep` (roots arrive already resolved by
// scripts/resolve-roots.mjs). Errors name the path's problem, never its contents. An empty file, or
// one that is not valid UTF-8, is refused: either would leave the model nothing true to judge.
//
// The read goes through one pinned descriptor: open the resolved path (O_NOFOLLOW, so a final
// component swapped for a symlink after the check fails; O_NONBLOCK, so a FIFO cannot hang the
// open), fstat that descriptor for type and size, and read at most MAX_FILE_BYTES + 1 bytes from it.
// A file swapped or grown after the check is therefore still the file that was checked and capped.
// Declined: an ancestor directory swapped for a symlink between realpath and open. Exploiting that
// needs a process that can already write inside the user's allowed folders, and such a process
// can read those files directly, so a per-component openat walk would buy nothing here.
import { constants } from 'node:fs';
import { open, realpath } from 'node:fs/promises';
import { isAbsolute, sep } from 'node:path';

export const MAX_FILE_BYTES = 1024 * 1024; // the same 1 MB cap houtini runs with
const OPEN_FLAGS = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK;
const UTF8 = new TextDecoder('utf-8', { fatal: true }); // throws where a lenient decode would insert U+FFFD
const overLimit = (bytes) => new Error(`file is ${(bytes / 1048576).toFixed(1)} MB, over the 1 MB limit`);

export function parseRoots(raw) {
  const roots = (raw ?? '').split(',').filter(Boolean);
  if (!roots.length) throw new Error('no allowed folders configured; set allowed_dirs in the plugin options');
  for (const r of roots) {
    if (!isAbsolute(r) || /^\/+$/.test(r)) throw new Error(`invalid allowed folder: ${JSON.stringify(r)}`);
  }
  return roots;
}

export async function readFenced(path, roots) {
  let real;
  try {
    real = await realpath(path);
  } catch (e) {
    throw new Error(e.code === 'ENOENT' ? 'no such file' : `cannot resolve the path (${e.code})`);
  }
  if (!roots.some((root) => real === root || real.startsWith(root + sep))) {
    throw new Error(
      `path is outside the allowed folders (${roots.join(', ')}); widen allowed_dirs in the plugin options if intended`,
    );
  }
  let fh;
  try {
    fh = await open(real, OPEN_FLAGS);
  } catch (e) {
    throw new Error(`cannot open the file (${e.code})`);
  }
  try {
    const info = await fh.stat();
    if (!info.isFile()) throw new Error('not a regular file');
    if (info.size > MAX_FILE_BYTES) throw overLimit(info.size);
    const buf = Buffer.alloc(MAX_FILE_BYTES + 1);
    let n = 0;
    while (n < buf.length) {
      const { bytesRead } = await fh.read(buf, n, buf.length - n, n);
      if (!bytesRead) break;
      n += bytesRead;
    }
    if (n > MAX_FILE_BYTES) throw overLimit(n);
    if (!n) throw new Error('the file is empty');
    try {
      return UTF8.decode(buf.subarray(0, n));
    } catch {
      throw new Error('the file is not UTF-8 text (binary or another encoding)');
    }
  } catch (e) {
    throw e.code ? new Error(`cannot read the file (${e.code})`) : e;
  } finally {
    await fh.close();
  }
}
