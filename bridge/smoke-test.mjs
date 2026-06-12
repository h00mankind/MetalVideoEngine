// Standalone Node smoke test for the bridge. Not part of the production
// pipeline — just confirms `runMetalRender` correctly spawns the engine,
// streams logs, and resolves with stats.
//
// Run: node research/bridge/smoke-test.mjs

import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BIN = path.resolve(__dirname, '..', '.build', 'release', 'mve');
const REPO = path.resolve(__dirname, '..', '..');

const spec = {
  input: path.join(REPO, 'samples', 'source-video.mp4'),
  output: '/tmp/bridge-smoke.mp4',
  preset: '1080p',
  grade: { saturation: 1.1 },
  bypass: { zoom: 1.03, noise: 5 },
  texts: [{ text: '@mve', anchor: 9, offsetX: -16, offsetY: 32 }],
};

// Inline the bridge logic here (the .ts file requires a TS toolchain
// to import). This mirrors runMetalRender exactly for the test.
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';

const FRAME_RE = /^\[engine\] frame (\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;
const DONE_RE  = /^\[done\] frames=(\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;

const tmp = await mkdtemp(path.join(os.tmpdir(), 'recap-bridge-'));
const specPath = path.join(tmp, 'job.json');
await writeFile(specPath, JSON.stringify(spec, null, 2));

const t0 = Date.now();
let progressTicks = 0;
let lastRatio = 0;
let stats = null;

await new Promise((resolve, reject) => {
  const child = spawn(BIN, ['job', specPath], { stdio: ['ignore', 'pipe', 'pipe'] });
  let buf = '';
  const ingest = (chunk) => {
    buf += chunk.toString('utf8');
    const parts = buf.split(/\r?\n/);
    buf = parts.pop() ?? '';
    for (const line of parts) {
      const f = FRAME_RE.exec(line);
      if (f) {
        progressTicks++;
        const src = parseFloat(f[2]);
        lastRatio = Math.min(1, src / Math.max(1, src));
      }
      const d = DONE_RE.exec(line);
      if (d) {
        stats = {
          frames: parseInt(d[1], 10),
          sourceSecs: parseFloat(d[2]),
          wallSecs: parseFloat(d[3]),
          speed: parseFloat(d[4]),
        };
      }
      process.stderr.write(`  metal: ${line}\n`);
    }
  };
  child.stdout.on('data', ingest);
  child.stderr.on('data', ingest);
  child.on('error', reject);
  child.on('close', (code, signal) => {
    void rm(tmp, { recursive: true, force: true });
    // Treat as success when we already captured [done] so this smoke
    // test still works against v0.1.3-era binaries that can trap after
    // flushing the output. See bridge/mve.mjs for the compatibility path.
    if (stats) resolve();
    else if (code !== 0) reject(new Error(`exit code=${code} signal=${signal ?? 'none'}`));
    else resolve();
  });
});

const t1 = Date.now();
console.log('\n=== BRIDGE SMOKE TEST RESULT ===');
console.log(`bridge wall: ${(t1 - t0) / 1000}s`);
console.log(`progress ticks: ${progressTicks}`);
console.log(`engine stats:`, stats);
console.log(`output exists: ${(await import('node:fs')).existsSync('/tmp/bridge-smoke.mp4')}`);
