// Full-feature bridge integration test: drives every Metal engine
// capability the production render-final stage needs (grade, bypass,
// LUT, subtitles, text overlay, audio mix). Run with:
//
//   node research/bridge/full-feature-test.mjs

import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BIN = path.resolve(__dirname, '..', '.build', 'release', 'mve');
const REPO = path.resolve(__dirname, '..', '..');

const spec = {
  input: path.join(REPO, 'samples', 'source-video.mp4'),
  output: '/tmp/bridge-full.mp4',
  preset: '1080p',
  codec: 'h264',
  grade: { brightness: 0.02, contrast: 1.05, saturation: 1.10, lutMix: 1.0 },
  bypass: {
    zoom: 1.03,
    cropPct: 1.0,
    colorTintDeg: 3,
    noise: 6,
    grain: 8,
    edgeBlur: 14,
    edgeBlurBand: 0.14,
  },
  lutPath: path.join(REPO, 'static', 'luts', 'cinematic.cube'),
  subtitles: {
    srtPath: path.join(REPO, 'samples', 'force-aligned-en.srt'),
    fontSize: 72,
    primaryColorHex: 'FFFFFF',
    outlineColorHex: '000000',
    outlineThickness: 4,
    shadowDepth: 3,
    bold: true,
    alignment: 'bottom',
    marginV: 180,
  },
  texts: [
    {
      text: '@mve',
      anchor: 9,
      offsetX: -16,
      offsetY: 32,
      fontSize: 56,
      colorHex: 'FFFFFF',
      shadow: true,
      bgColorHex: '000000',
      bgOpacity: 0.4,
    },
  ],
  audio: {
    narrationPath: path.join(REPO, 'samples', 'recap-voiceover.mp3'),
    musicPath: path.join(REPO, 'samples', 'bg-music.mp3'),
    musicVolume: 0.25,
  },
};

const FRAME_RE = /^\[engine\] frame (\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;
const DONE_RE = /^\[done\] frames=(\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;

const tmp = await mkdtemp(path.join(os.tmpdir(), 'recap-bridge-'));
const specPath = path.join(tmp, 'job.json');
await writeFile(specPath, JSON.stringify(spec, null, 2));

const t0 = Date.now();
let stats = null;

await new Promise((resolve, reject) => {
  const child = spawn(BIN, ['job', specPath], { stdio: ['ignore', 'pipe', 'pipe'] });
  let buf = '';
  const ingest = (chunk) => {
    buf += chunk.toString('utf8');
    const parts = buf.split(/\r?\n/);
    buf = parts.pop() ?? '';
    for (const line of parts) {
      const d = DONE_RE.exec(line);
      if (d) {
        stats = {
          frames: parseInt(d[1], 10),
          sourceSecs: parseFloat(d[2]),
          wallSecs: parseFloat(d[3]),
          speed: parseFloat(d[4]),
        };
      }
      // Throttle log noise — only show every 30th frame line.
      const f = FRAME_RE.exec(line);
      if (f) {
        if (parseInt(f[1], 10) % 600 === 0) process.stderr.write(`  metal: ${line}\n`);
      } else {
        process.stderr.write(`  metal: ${line}\n`);
      }
    }
  };
  child.stdout.on('data', ingest);
  child.stderr.on('data', ingest);
  child.on('error', reject);
  child.on('close', (code, signal) => {
    void rm(tmp, { recursive: true, force: true });
    if (stats) resolve();
    else if (code !== 0) reject(new Error(`exit code=${code} signal=${signal ?? 'none'}`));
    else resolve();
  });
});

const t1 = Date.now();
const fs = await import('node:fs');
const sz = fs.existsSync(spec.output) ? fs.statSync(spec.output).size : 0;

// Probe output via ffprobe for sanity.
const probe = await new Promise((res) => {
  const p = spawn('ffprobe', [
    '-v', 'error',
    '-show_entries', 'stream=codec_name,codec_type,width,height',
    '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1',
    spec.output,
  ]);
  let out = '';
  p.stdout.on('data', (c) => (out += c));
  p.on('close', () => res(out));
});

console.log('\n=== FULL-FEATURE BRIDGE TEST RESULT ===');
console.log(`bridge wall:       ${(t1 - t0) / 1000}s`);
console.log(`engine stats:      ${JSON.stringify(stats)}`);
console.log(`output file:       ${spec.output}  (${(sz / 1024 / 1024).toFixed(1)} MB)`);
console.log('\n--- ffprobe ---');
console.log(probe.trim());
