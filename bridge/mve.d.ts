/**
 * TypeScript declarations for `metal-video-engine` — keep in lockstep
 * with bridge/mve.mjs.
 */

export type MetalGrade = {
  brightness?: number;
  contrast?: number;
  saturation?: number;
  tint?: number;
  lutMix?: number;
};

export type MetalBypass = {
  mirror?: boolean;
  zoom?: number;
  cropPct?: number;
  colorTintDeg?: number;
  noise?: number;
  grain?: number;
  edgeBlur?: number;
  edgeBlurBand?: number;
  /** Reserved; PTS warp not yet implemented. */
  speed?: number;
};

export type MetalSubtitles = {
  /** Path to an SRT file, OR — */
  srtPath?: string;
  /** Path to an ASS document (preferred — same renderer ffmpeg uses). */
  assPath?: string;
  /** Directory of TTFs to register with CoreText before rasterising. */
  fontsDir?: string;
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
  /** 1..9 numpad anchor. */
  anchor?: number;
  offsetX?: number;
  offsetY?: number;
  widthFraction?: number;
  opacity?: number;
};

export type MetalText = {
  text: string;
  /** 1..9 numpad anchor. */
  anchor?: number;
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
  /** "720p", "1080p", or a literal "<W>x<H>". */
  preset?: '720p' | '1080p' | string;
  bitrate?: number;
  /** Peak bitrate cap, bits/sec. Defaults to 1.5x `bitrate`. */
  peakBitrate?: number;
  /** "delivery" (B-frames + peak cap) | "draft" (faster). */
  quality?: 'delivery' | 'draft';
  codec?: 'h264' | 'hevc' | 'prores422hq';
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
  /** Realtime ratio. */
  speed: number;
};

/**
 * Resolve the path the wrapper will spawn. Honours `MVE_BIN` /
 * `RECAP_METAL_BIN` env overrides; otherwise points at the binary
 * installed under this package's `bin/` directory by the postinstall
 * script.
 */
export function binaryPath(): string;

/** True when the resolved binary exists and is executable. */
export function binaryAvailable(): Promise<boolean>;

/** Run a render job. Resolves on the engine's `[done]` line. */
export function runMetalRender(
  spec: MetalJobSpec,
  events?: MetalRunEvents,
): Promise<MetalRunStats>;
