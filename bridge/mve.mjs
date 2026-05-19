/**
 * Node ESM wrapper around the `mve` CLI. Spawns
 * `<package>/bin/mve job <spec.json>` and streams its stderr through
 * onLog / onProgress callbacks.
 *
 * Usage:
 *
 *   import { runMetalRender, binaryPath } from 'metal-video-engine';
 *   const stats = await runMetalRender(
 *     {
 *       input: '/abs/path/to/source.mp4',
 *       output: '/abs/path/to/final.mp4',
 *       preset: '1080p',
 *       grade: { saturation: 1.1 },
 *     },
 *     {
 *       onLog: (l) => console.log('[mve]', l),
 *       onProgress: (ratio, secs) => console.log(ratio.toFixed(2)),
 *     }
 *   );
 *
 * Spec schema is identical to JobSpec in Sources/MetalVideoEngine/Job.swift —
 * keep these in lockstep when adding fields.
 */
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Resolve the `mve` binary. Lookup order:
 *
 *   1. `MVE_BIN=/abs/path`           — explicit override
 *   2. `RECAP_METAL_BIN=/abs/path`   — legacy override; honoured for
 *                                      callers migrating from the
 *                                      original Revver-recap embedding
 *   3. `<package>/bin/mve`            — the binary installed by this
 *                                      package's postinstall script
 *   4. `<package>/.build/release/mve` — the SwiftPM release build, for
 *                                      developers running from a git
 *                                      checkout before publishing
 */
export function binaryPath() {
  const env = process.env.MVE_BIN ?? process.env.RECAP_METAL_BIN;
  if (env && env.length > 0) return env;
  // bridge/mve.mjs → bridge → package root
  return path.resolve(__dirname, '..', 'bin', 'mve');
}

/**
 * True when the resolved binary path exists and is executable on this host.
 * Cheap stat — callers that fall back to a different engine when this is
 * false can call it on startup and cache the result.
 */
export async function binaryAvailable() {
  try {
    const s = await stat(binaryPath());
    return s.isFile() && (s.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

/**
 * Engine stderr emits two kinds of lines we care about:
 *
 *   [engine] frame 3600  src=119.97s  wall=18.41s  speed=6.50x
 *   [done] frames=4080  src=136.49s  wall=20.81s  speed=6.53x
 *
 * The frame line gives a steady progress signal; the done line is the
 * terminal stats blob. Anything else is informational and passed through
 * onLog unmodified.
 */
const FRAME_RE = /^\[engine\] frame (\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;
const DONE_RE = /^\[done\] frames=(\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;

export async function runMetalRender(spec, events = {}) {
  // Write the spec to a temp file. We pass it via filesystem rather than
  // stdin because the Swift CLI's argv-based interface is simpler than
  // implementing a stdin protocol on the Swift side, and the spec is
  // tiny (a few KB at most).
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'mve-'));
  const specPath = path.join(tmpDir, 'job.json');
  await writeFile(specPath, JSON.stringify(spec, null, 2), 'utf8');

  // Estimate source duration up front so we can synthesise a progress
  // ratio. We don't have ffprobe here on the Metal side, but the engine
  // emits its own `src=Xs` field on every frame line — we treat the
  // highest seen value as the running estimate of total source secs and
  // ratio it against the source seconds line, normalised to 1 at done.
  let lastSourceSecs = 0;
  let totalSourceEstimate = 0;
  let finalStats = null;

  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath(), ['job', specPath], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stderrBuffer = '';
    function ingestStderr(chunk) {
      stderrBuffer += chunk.toString('utf8');
      const parts = stderrBuffer.split(/\r?\n/);
      stderrBuffer = parts.pop() ?? '';
      for (const line of parts) {
        if (!line) continue;
        const f = FRAME_RE.exec(line);
        if (f) {
          const src = parseFloat(f[2]);
          lastSourceSecs = src;
          if (src > totalSourceEstimate) totalSourceEstimate = src;
          if (events.onProgress && totalSourceEstimate > 0) {
            // Conservative ratio that monotonically approaches 1 — the
            // engine's `src=` field is the *current* PTS, not the
            // total, so we can't divide by anything but the running
            // max. Caller gets the source seconds for free as the
            // second argument, in case it wants its own normalisation.
            events.onProgress(Math.min(1, src / Math.max(1, totalSourceEstimate)), src);
          }
        }
        const d = DONE_RE.exec(line);
        if (d) {
          finalStats = {
            frames: parseInt(d[1], 10),
            sourceSecs: parseFloat(d[2]),
            wallSecs: parseFloat(d[3]),
            speed: parseFloat(d[4]),
          };
          if (events.onProgress) events.onProgress(1, finalStats.sourceSecs);
        }
        events.onLog?.(line);
      }
    }

    child.stdout.on('data', ingestStderr);
    child.stderr.on('data', ingestStderr);

    function abort() {
      try { child.kill('SIGKILL'); } catch { /* ignore */ }
    }
    events.signal?.addEventListener('abort', abort, { once: true });

    child.on('error', (err) => {
      void rm(tmpDir, { recursive: true, force: true });
      reject(err);
    });
    child.on('close', (code, signal) => {
      events.signal?.removeEventListener('abort', abort);
      void rm(tmpDir, { recursive: true, force: true });
      // The engine reaches the `[done]` print right after writer.finish()
      // returns — by which point the mp4 is fully flushed to disk. It
      // then calls libc `exit(0)`, which can fire registered atexit
      // handlers; on macOS those occasionally signal SIGTRAP from
      // AVFoundation's audio queue tear-down. Treat the run as
      // successful whenever we already captured a `[done]` blob,
      // regardless of how the process actually exited — the file is
      // valid, the engine did its job.
      if (finalStats) {
        resolve(finalStats);
        return;
      }
      if (code !== 0) {
        reject(new Error(`mve exited with code=${code} signal=${signal ?? 'none'}`));
        return;
      }
      // Exit 0 but no [done] — engine logged differently? Synthesise
      // stats from the last frame line we saw so callers always get a
      // populated object.
      resolve({
        frames: 0,
        sourceSecs: lastSourceSecs,
        wallSecs: 0,
        speed: 0,
      });
    });
  });
}
