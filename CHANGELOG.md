# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
