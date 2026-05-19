/**
 * Example alternative implementation of the `render-final` stage that
 * routes through the Metal engine instead of ffmpeg.
 *
 * This file is NOT wired into the production pipeline — it shows what
 * stages.ts would call if we wanted to make Metal the default render
 * path. The shape mirrors the existing `render-final` blueprint's plan()
 * function: takes a project + jobId + media context, produces final.mp4.
 *
 * To enable in production, you'd:
 *   1. Add a `RECAP_ENGINE` env var (`'ffmpeg'` | `'metal'`, default 'ffmpeg').
 *   2. In stages.ts render-final blueprint, branch on the env var and
 *      call this helper instead of the ffmpeg argv path.
 *   3. The Metal binary needs to be built once via `cd research && swift
 *      build -c release`. The `metalEngineAvailable()` probe in
 *      mve.ts gives a clean fallback when the binary is missing.
 */
import path from 'node:path';
import { runMetalRender, type MetalJobSpec } from './mve';

// These types mirror the production project model — kept duplicated
// here so this example compiles standalone. Real integration would
// import from $lib/project/types.
type BypassSettings = {
  mirror: boolean;
  zoom: number;
  speed: number;
  cropPct: number;
  colorTint: number;
  lut: 'none' | 'cinematic' | 'vintage' | 'punchy';
  noise: number;
  grain: number;
  edgeBlur: number;
  edgeBlurBand: number;
};

type SubtitleStyle = {
  fontFamily: string;
  fontSize: number;
  primaryColor: string;
  outlineColor: string;
  outlineThickness: number;
  shadowDepth: number;
  bold: boolean;
  italic: boolean;
  alignment: 'bottom' | 'middle' | 'top';
  marginV: number;
};

type BrandingSettings = {
  channelName: string;
  channelNamePosition: number;          // numpad 1..9
  channelNameOffsetX: number;
  channelNameOffsetY: number;
  channelNameScale: number;
  channelNameColor: string;
  channelNameShadow: boolean;
  channelNameBgColor: string;
  channelNameBgOpacity: number;
  logoLocalPath: string;
  watermarkCorner: 'tl' | 'tc' | 'tr' | 'bl' | 'bc' | 'br' | 'ml' | 'mc' | 'mr';
  watermarkOpacity: number;
  watermarkScale: number;
};

type RenderContext = {
  jobId: string;
  sourcePath: string;
  narrationPath?: string;
  musicPath?: string;
  logoPath?: string;
  alignedSrtPath?: string;
  bypass: BypassSettings;
  branding: BrandingSettings;
  captionStyle: SubtitleStyle;
  musicVolume: number;
  preset: '720p' | '1080p';
  staticLutDir: string;          // typically <repo>/static/luts
  outputPath: string;
};

/** Map watermark corner code to ASS-style numpad (1..9). */
function cornerToNumpad(c: BrandingSettings['watermarkCorner']): number {
  const map: Record<BrandingSettings['watermarkCorner'], number> = {
    tl: 7, tc: 8, tr: 9,
    ml: 4, mc: 5, mr: 6,
    bl: 1, bc: 2, br: 3,
  };
  return map[c];
}

export async function renderFinalMetal(
  ctx: RenderContext,
  onLog: (line: string) => void,
  onProgress: (ratio: number) => void,
): Promise<{ wallSecs: number; frames: number }> {

  // Build the JobSpec from the project's settings. Most fields are
  // direct passthroughs; the bypass section also flows colorTint and
  // edgeBlur values which the production ffmpeg path would otherwise
  // build into a libavfilter chain.
  const lutPath = ctx.bypass.lut !== 'none'
    ? path.join(ctx.staticLutDir, `${ctx.bypass.lut}.cube`)
    : undefined;

  const overlays: NonNullable<MetalJobSpec['overlays']> = [];
  if (ctx.logoPath) {
    overlays.push({
      imagePath: ctx.logoPath,
      anchor: cornerToNumpad(ctx.branding.watermarkCorner),
      widthFraction: ctx.branding.watermarkScale,
      opacity: ctx.branding.watermarkOpacity,
    });
  }

  const texts: NonNullable<MetalJobSpec['texts']> = [];
  if (ctx.branding.channelName.trim()) {
    texts.push({
      text: ctx.branding.channelName.trim(),
      anchor: ctx.branding.channelNamePosition,
      offsetX: ctx.branding.channelNameOffsetX,
      offsetY: ctx.branding.channelNameOffsetY,
      fontSize: 56 * ctx.branding.channelNameScale,
      colorHex: ctx.branding.channelNameColor,
      shadow: ctx.branding.channelNameShadow,
      bgColorHex: ctx.branding.channelNameBgColor,
      bgOpacity: ctx.branding.channelNameBgOpacity,
    });
  }

  const spec: MetalJobSpec = {
    input: ctx.sourcePath,
    output: ctx.outputPath,
    preset: ctx.preset,
    grade: {
      // The production project model doesn't expose brightness/contrast/
      // saturation knobs — those live inside the per-LUT recipe. We
      // leave them at defaults; LUT carries the look.
      lutMix: lutPath ? 1 : 0,
    },
    bypass: {
      mirror: ctx.bypass.mirror,
      zoom: ctx.bypass.zoom,
      cropPct: ctx.bypass.cropPct,
      colorTintDeg: ctx.bypass.colorTint,
      noise: ctx.bypass.noise,
      grain: ctx.bypass.grain,
      edgeBlur: ctx.bypass.edgeBlur,
      edgeBlurBand: ctx.bypass.edgeBlurBand,
      speed: ctx.bypass.speed,
    },
    lutPath,
    subtitles: ctx.alignedSrtPath
      ? {
          srtPath: ctx.alignedSrtPath,
          fontName: ctx.captionStyle.fontFamily,
          fontSize: ctx.captionStyle.fontSize,
          primaryColorHex: ctx.captionStyle.primaryColor,
          outlineColorHex: ctx.captionStyle.outlineColor,
          outlineThickness: ctx.captionStyle.outlineThickness,
          shadowDepth: ctx.captionStyle.shadowDepth,
          bold: ctx.captionStyle.bold,
          italic: ctx.captionStyle.italic,
          alignment: ctx.captionStyle.alignment,
          marginV: ctx.captionStyle.marginV,
        }
      : undefined,
    overlays: overlays.length > 0 ? overlays : undefined,
    texts: texts.length > 0 ? texts : undefined,
    audio: ctx.narrationPath
      ? {
          narrationPath: ctx.narrationPath,
          musicPath: ctx.musicPath,
          musicVolume: ctx.musicVolume,
        }
      : undefined,
  };

  const stats = await runMetalRender(spec, {
    onLog,
    onProgress: (ratio) => onProgress(ratio),
  });

  return { wallSecs: stats.wallSecs, frames: stats.frames };
}
