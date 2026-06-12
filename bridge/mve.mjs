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
 * Engine stderr emits three lines we care about:
 *
 *   [meta] sourceSecs=136.486
 *   [engine] frame 3600  src=119.97s  wall=18.41s  speed=6.50x
 *   [done] frames=4080  src=136.49s  wall=20.81s  speed=6.53x
 *
 * The meta line fires once, before the first frame, with the total
 * source duration — the only reliable denominator for the progress
 * ratio. The frame line gives a steady current-PTS signal; the done
 * line is the terminal stats blob. Anything else is informational and
 * passed through onLog unmodified.
 *
 * Older engine binaries (< v0.1.2) don't emit the meta line. We
 * preserve the previous "running-max as denominator" fallback so the
 * bridge still works against them, even though the ratio in that mode
 * pins at 1.0 once the first frame fires.
 */
const META_RE = /^\[meta\] sourceSecs=([\d.]+)/;
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

  // Source-duration denominator for onProgress. Preferred path: the
  // engine prints `[meta] sourceSecs=N` once, before the first frame.
  // Fallback (older binaries): running-max of seen PTS, which gives a
  // monotonic-but-pinned-at-1 ratio. Tracked separately so we can use
  // the meta value the moment it arrives without overwriting it later.
  let lastSourceSecs = 0;
  let metaSourceSecs = 0;
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
        const m = META_RE.exec(line);
        if (m) {
          metaSourceSecs = parseFloat(m[1]);
        }
        const f = FRAME_RE.exec(line);
        if (f) {
          const src = parseFloat(f[2]);
          lastSourceSecs = src;
          if (src > totalSourceEstimate) totalSourceEstimate = src;
          if (events.onProgress) {
            // Prefer the engine-reported total (denominator never moves,
            // ratio actually represents progress). Fall back to the
            // running-max heuristic for older engine binaries that
            // don't print a meta line.
            const denom = metaSourceSecs > 0 ? metaSourceSecs : totalSourceEstimate;
            if (denom > 0) {
              events.onProgress(Math.min(1, src / denom), src);
            }
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
      // v0.1.3 and older can signal SIGTRAP after `[done]` because the
      // engine disposed a drained in-flight semaphore. v0.1.4 fixes the
      // engine, but the bridge keeps this compatibility path for one
      // release so hosts can roll forward without breaking older local
      // binaries whose output file was already fully flushed.
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
