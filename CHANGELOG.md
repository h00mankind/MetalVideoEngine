# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] — 2026-05-20

### Fixed
- **Image overlays (logos) rendered upside-down.** `Overlay.textureFromCGImage`
  unconditionally Y-flipped the bitmap, which was correct for the text
  rasteriser (whose CGImage rows are bottom-up) but inverted disk-loaded
  logo images (already top-down from ImageIO). The flip is now opt-in via
  a `flipY` parameter: `loadImage` passes `false`, `rasterizeText` passes
  `true`. Logos render upright; text orientation is unchanged. Mirror
  still only affects the source video, never the overlays.
- **Caption / overlay-text edges were not anti-aliased** (jagged, "not
  crisp" vs the ffmpeg/libass reference). The libass alpha-blend in
  `blendASSImage` premultiplied the source colour with `(srcC · a16) / 255`
  where `a16` is `maskByte · colorAlpha` (0..65025). That overshoots by
  255× and clamps every partial-coverage edge pixel to full saturation,
  destroying the anti-aliased gradient. Now divides by 65025 (= 255·255),
  preserving libass's edge coverage. Pixel-matches the ffmpeg burn.
- **CoreText overlay text (logo branding / channel name) was soft / not
  crisp** vs ffmpeg drawtext. Two causes: (1) `anchorRect` returned
  fractional origins for centred anchors, and (2) `overlay_composite`
  sampled at texel *edges* — so a 1:1 text/logo raster was bilinear-
  blended across two neighbours, blurring every glyph edge. Fixed by
  snapping the overlay origin to whole pixels and sampling at texel
  centres (`+0.5`), so an integer-aligned 1:1 overlay reads its texels
  verbatim. Also set explicit AA flags on the text CGContext (antialias
  on, font-smoothing off → clean grayscale coverage like libass).

### Added
- **`mve text` CLI subcommand** — a CoreText rasterisation probe. Renders
  one line through the production `Overlay.rasterizeText` path to a PNG so
  font / size / colour / bold / shadow / pill / corner-radius / AA can be
  eyeballed without a full video render. `--bgfill checker|RRGGBB` paints
  a backdrop so anti-aliased edges are visible. See `mve` usage.

## [0.1.2] — 2026-05-20

### Fixed
- Progress ratio in `runMetalRender`'s `onProgress` callback now reports
  real progress (climbs linearly 0→1) instead of pinning at 1.0 after
  the first frame. The bridge previously used the running max of seen
  PTS as the denominator, which equals the numerator.

### Added
- Engine emits a `[meta] sourceSecs=<float>` line once, before the
  first frame line, so consumers have a real total-duration
  denominator. The bridge prefers this when present and falls back to
  the running-max heuristic for older engine binaries.

## [0.1.1] — 2026-05-20

### Added
- npm package surface — `metal-video-engine` ships `bridge/mve.mjs` +
  `bridge/mve.d.ts` and a postinstall script that downloads the
  matching darwin-arm64 binary from the GitHub Release. Consumers can
  now `npm install github:h00mankind/MetalVideoEngine#v0.1.1` and
  `import { runMetalRender } from 'metal-video-engine'`.
- `MVE_SKIP_DOWNLOAD=1` env var for CI hosts that supply the binary
  out of band.

### Changed
- `bridge/mve.ts` removed; `bridge/mve.mjs` is the source of truth and
  `bridge/mve.d.ts` carries hand-written types. Public API:
  `runMetalRender`, `binaryPath`, `binaryAvailable`.

## [0.1.0] — 2026-05-19

Initial extraction from the Revver-recap research sandbox.

### Added
- `MetalVideoEngine` Swift library — GPU-resident decode → filter → encode
  pipeline for Apple Silicon macOS 14+.
- `mve` CLI executable with `render`, `job`, `frame`, and `libass`
  subcommands. The `job <spec.json>` mode is the supported integration
  surface; its JSON schema lives in `Sources/MetalVideoEngine/Job.swift`.
- `bridge/mve.ts` — TypeScript wrapper that spawns the CLI and streams
  progress/log events through the same callback shape Node renderers use.

### Engine capabilities
- AVAssetReader → CVPixelBuffer → CVMetalTextureCache → MTLTexture
  zero-copy decode on Apple Silicon's unified memory.
- Compute-shader filter graph: YCbCr→RGB, scale+letterbox, grade
  (brightness/contrast/saturation/tint), 3D LUT (`.cube`), bypass effects
  (mirror, zoom, edge blur, grain, noise, hue rotation).
- libass-based subtitle burn (Homebrew libass 0.17.4) — same renderer the
  ffmpeg path uses, so output pixels match.
- Overlay compositing for static logos + CoreText-rasterised text.
- VTCompressionSession encode → AVAssetWriter mp4 (H.264 / HEVC) or
  ProRes 422 HQ .mov.
- Audio passthrough + narration + background music mixing via
  AVAudioEngine offline render.
- Parallel encoder pipelines for multi-segment renders.

### Honest limitations
- macOS 14+, arm64 only. No Intel or Linux build path.
- Metal shaders compile at runtime — first render in a process pays a
  ~50–200ms compile cost.
- Single-input pipeline. No multi-track compositing, EDL/XML
  interchange, or scopes.
