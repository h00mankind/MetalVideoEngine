/**
 * Node/TypeScript wrapper around the `mve` CLI. Spawns
 * `.build/release/mve job <spec.json>` and streams its stderr through
 * typed onLog / onProgress callbacks.
 *
 * Usage:
 *
 *   import { runMetalRender } from 'metal-video-engine/bridge/mve';
 *   const stats = await runMetalRender(
 *     {
 *       input: '/abs/path/to/source.mp4',
 *       output: '/abs/path/to/final.mp4',
 *       preset: '1080p',
 *       grade: { saturation: 1.1 },
 *       bypass: { zoom: 1.03, cropPct: 1 },
 *       lutPath: '/abs/path/to/cinematic.cube',
 *       subtitles: { srtPath: '/abs/path/to/aligned.srt', fontSize: 72 },
 *       texts: [{ text: '@Channel', anchor: 9 }],
 *       audio: { narrationPath, musicPath, musicVolume: 0.25 },
 *     },
 *     {
 *       onLog: (l) => console.log('[metal]', l),
 *       onProgress: (ratio, secs) => console.log(ratio.toFixed(2)),
 *     }
 *   );
 *
 * Spec schema is identical to JobSpec in Sources/MetalVideoEngine/Job.swift —
 * keep these in lockstep when adding fields.
 */
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

export type MetalGrade = {
  brightness?: number;
  contrast?: number;
  saturation?: number;
  tint?: number;
  lutMix?: number;
};

export type MetalBypass = {
  mirror?: boolean;
  zoom?: number;        // 1.00..1.10
  cropPct?: number;     // 0..6 (percent per side)
  colorTintDeg?: number;
  noise?: number;
  grain?: number;
  edgeBlur?: number;
  edgeBlurBand?: number;
  speed?: number;       // reserved; PTS warp not yet implemented
};

export type MetalSubtitles = {
  srtPath: string;
  fontName?: string;
  fontSize?: number;
  primaryColorHex?: string;
  outlineColorHex?: string;
  outlineThickness?: number;
  shadowDepth?: number;
  bold?: boolean;
  italic?: boolean;
  alignment?: 'bottom' | 'middle' | 'top';
  marginV?: number;
};

export type MetalOverlay = {
  imagePath: string;
  anchor?: number;          // 1..9 numpad
  offsetX?: number;
  offsetY?: number;
  widthFraction?: number;   // 0..1 of canvas width
  opacity?: number;
};

export type MetalText = {
  text: string;
  anchor?: number;          // 1..9 numpad
  offsetX?: number;
  offsetY?: number;
  fontName?: string;
  fontSize?: number;
  colorHex?: string;
  shadow?: boolean;
  bgColorHex?: string;
  bgOpacity?: number;
};

export type MetalAudio = {
  narrationPath: string;
  musicPath?: string;
  musicVolume?: number;
  bitrate?: number;
};

export type MetalJobSpec = {
  input: string;
  output: string;
  preset?: '720p' | '1080p' | string;   // "1080p" or "<W>x<H>"
  bitrate?: number;
  codec?: 'h264' | 'hevc';
  maxInflight?: number;
  grade?: MetalGrade;
  bypass?: MetalBypass;
  lutPath?: string;
  subtitles?: MetalSubtitles;
  overlays?: MetalOverlay[];
  texts?: MetalText[];
  audio?: MetalAudio;
};

export type MetalRunEvents = {
  onLog?: (line: string) => void;
  /** Called every progress tick parsed from engine stderr. */
  onProgress?: (ratio: number, sourceSecs: number) => void;
  signal?: AbortSignal;
};

export type MetalRunStats = {
  frames: number;
  sourceSecs: number;
  wallSecs: number;
  speed: number;          // realtime ratio
};

/**
 * Resolve the `mve` binary. Defaults to the SPM release build alongside
 * this bridge (`../.build/release/mve`). Override with `MVE_BIN` for CI
 * or productionised installs. The legacy `RECAP_METAL_BIN` env var is
 * still honoured for callers migrating from the original Revver-recap
 * embedding — remove that fallback once the migration is complete.
 */
function mveBinary(): string {
  const env = process.env.MVE_BIN ?? process.env.RECAP_METAL_BIN;
  if (env && env.length > 0) return env;
  return path.resolve(__dirname, '..', '.build', 'release', 'mve');
}

/**
 * Engine stderr emits two kinds of lines we care about:
 *
 *   [engine] frame 3600  src=119.97s  wall=18.41s  speed=6.50x
 *   [done] frames=4080  src=136.49s  wall=20.81s  speed=6.53x
 *
 * The frame line gives us a steady progress signal; the done line is the
 * terminal stats blob. Anything else is informational and passed through
 * onLog unmodified.
 */
const FRAME_RE = /^\[engine\] frame (\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;
const DONE_RE = /^\[done\] frames=(\d+)\s+src=([\d.]+)s\s+wall=([\d.]+)s\s+speed=([\d.]+)x/;

export async function runMetalRender(
  spec: MetalJobSpec,
  events: MetalRunEvents = {},
): Promise<MetalRunStats> {
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
  let finalStats: MetalRunStats | null = null;

  return new Promise<MetalRunStats>((resolve, reject) => {
    const child = spawn(mveBinary(), ['job', specPath], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stderrBuffer = '';
    function ingestStderr(chunk: Buffer): void {
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

    child.stdout.on('data', ingestStderr); // engine logs to stderr but capture both
    child.stderr.on('data', ingestStderr);

    function abort(): void {
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

/**
 * Probe whether the Metal engine binary is present and executable. Cheap
 * stat — used by the alternative-stage gate to fall back to the ffmpeg
 * path silently on hosts that don't have the engine built (CI, Linux,
 * Intel Macs, …).
 */
export async function metalEngineAvailable(): Promise<boolean> {
  const { stat } = await import('node:fs/promises');
  try {
    const s = await stat(mveBinary());
    return s.isFile() && (s.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}
