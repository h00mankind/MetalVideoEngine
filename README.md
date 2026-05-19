# MetalVideoEngine

GPU-resident video render pipeline for Apple Silicon. Decode → grade → LUT
→ subtitle burn → encode, with frames never leaving the GPU.

> **Status:** experimental (`v0.1.0`). API may change between minor versions.

## Premise

The typical ffmpeg path goes VideoToolbox decode → CPU download (nv12) →
CPU filter graph → upload → VideoToolbox encode. Each CPU↔GPU bounce
costs bandwidth and forces a copy. This engine keeps frames on the GPU
the whole way:

```
AVAssetReader  →  CVPixelBuffer (NV12, IOSurface-backed)
              →  CVMetalTextureCache  →  MTLTexture  (zero-copy on UMA)
              →  compute shaders: YCbCr→RGB, scale+pad, grade, LUT, bypass
              →  libass subtitle composite
              →  CVPixelBufferPool (Metal-compatible)
              →  VTCompressionSession  →  AVAssetWriter MP4 / MOV
```

On Apple Silicon, CPU and GPU share physical RAM, so a CVPixelBuffer
backed by an IOSurface is already addressable by Metal with no copy —
`CVMetalTextureCacheCreateTextureFromImage` hands back a texture view of
the same bytes.

## Honest scope

This is NOT a Resolve replacement. It targets a specific render workload:

- single video input
- scale + letterbox to a target resolution (e.g. 1080×1920, 720×1280)
- color grade: brightness, contrast, saturation, tint, 3D LUT (`.cube`)
- bypass effects: mirror, zoom, edge blur, grain, noise, hue rotation
- libass subtitle burn (same renderer ffmpeg uses)
- static logo + CoreText text overlays
- H.264 / HEVC mp4 or ProRes 422 HQ mov, social-media bitrates
- audio passthrough + narration + background music mix

It is faster than the ffmpeg path **for this workload** because it
eliminates copies, not because the algorithms are fundamentally better.

What's NOT in here: multi-track compositing, edit-list trimming, EDL/XML
interchange, scopes, ProRes decoding, color management beyond Rec.709.

## Requirements

- macOS 14+, **Apple Silicon only** (arm64).
- Swift 5.10 / Xcode 15.3+.
- `libass` (Homebrew: `brew install libass`).
- `pkg-config` (Homebrew: `brew install pkg-config`) so SwiftPM can
  resolve libass's headers and link path.

## Install

### As an npm package (Node consumers)

```sh
npm install metal-video-engine
```

The package's `postinstall` script downloads a prebuilt `mve` binary
matching the package version from the [GitHub Release](https://github.com/h00mankind/MetalVideoEngine/releases)
into `node_modules/metal-video-engine/bin/mve`. Use the bridge:

```ts
import { runMetalRender, binaryPath, binaryAvailable } from 'metal-video-engine';

if (await binaryAvailable()) {
  await runMetalRender(spec, { onLog, onProgress });
}
```

Skip the download (e.g. on CI hosts that provide the binary out of
band) with `MVE_SKIP_DOWNLOAD=1`. Override the resolved binary path with
`MVE_BIN=/abs/path`. The package is gated to `darwin-arm64` via npm's
`os` / `cpu` fields — installing on Linux or Intel is a no-op.

### As a SwiftPM dependency

```swift
.package(url: "https://github.com/h00mankind/MetalVideoEngine.git", from: "0.1.0")
```

```swift
.product(name: "MetalVideoEngine", package: "MetalVideoEngine")
```

### Building from source / using the CLI directly

```sh
git clone https://github.com/h00mankind/MetalVideoEngine.git
cd MetalVideoEngine
swift build -c release
./.build/release/mve render --in src.mp4 --out out.mp4 --preset 1080p
```

If libass is installed somewhere `pkg-config` can't find (CI cache,
vendored build), point the build at it:

```sh
MVE_LIBASS_PREFIX=/opt/my-libass swift build -c release
```

## Usage

### Library (Swift)

```swift
import MetalVideoEngine

let ctx = try MetalContext()
let engine = RenderEngine(context: ctx)
try engine.render(.init(
    inputURL: URL(fileURLWithPath: "src.mp4"),
    outputURL: URL(fileURLWithPath: "out.mp4"),
    width: 1080, height: 1920,
    bitrate: 10_000_000
))
```

See `Sources/MetalVideoEngine/Engine.swift` for the full `Request` shape.

### CLI: one-shot

```sh
mve render --in src.mp4 --out out.mp4 --preset 1080p \
           --brightness 0.05 --contrast 1.1 --saturation 1.15
```

### CLI: JSON spec (preferred for non-Swift integrations)

The `job` subcommand takes a JSON spec file. This is the stable
integration surface — see `Sources/MetalVideoEngine/Job.swift` for the
schema. A minimal job:

```json
{
  "input": "/abs/src.mp4",
  "output": "/abs/out.mp4",
  "preset": "1080p",
  "grade": { "saturation": 1.1 },
  "lutPath": "/abs/look.cube",
  "subtitles": { "assPath": "/abs/captions.ass", "fontsDir": "/abs/fonts" },
  "audio": { "narrationPath": "/abs/voice.m4a", "musicPath": "/abs/bed.m4a", "musicVolume": 0.25 }
}
```

```sh
mve job /abs/path/to/spec.json
```

The CLI logs progress to stderr in a stable format:

```
[engine] frame 3600  src=119.97s  wall=18.41s  speed=6.50x
[done] frames=4080  src=136.49s  wall=20.81s  speed=6.53x
```

### Node bridge

`bridge/mve.ts` spawns the CLI and parses the progress/done lines into a
typed event stream. See the file's header comment for usage.

## Constraints / known issues

- **Runtime shader compile**: shaders are compiled via
  `device.makeLibrary(source:)`, not AOT `.metallib`. First render in a
  process pays a ~50–200ms compile cost; in-process subsequent renders
  are cached.
- **arm64 only**: Intel Mac builds would need a separate compute path
  (OpenCL or CPU fallback). Not planned.
- **Single video input**: no multi-track / EDL pipeline.
- **`[done]` line is load-bearing**: the CLI may exit with a non-zero
  signal (AVFoundation audio queue teardown occasionally raises SIGTRAP
  at process exit) even though the mp4 is fully flushed. Consumers
  should treat presence of the `[done]` line as success regardless of
  exit code — the bridge in `bridge/mve.ts` already does this.

## Repo layout

- `Package.swift`                     — SPM manifest
- `Sources/MetalVideoEngine/`         — library
  - `Engine.swift`                    — top-level render entry point
  - `ParallelEngine.swift`            — multi-segment parallel encoder
  - `Decoder.swift`                   — AVAssetReader → CVPixelBuffer
  - `MetalContext.swift`              — MTLDevice, queue, texture cache
  - `FilterGraph.swift`               — compute pipeline chain
  - `Shaders.swift`                   — runtime-compiled .metal source
  - `LibassRenderer.swift`            — libass → MTLTexture
  - `LUT.swift`, `Overlay.swift`,
    `Fonts.swift`, `Job.swift`        — feature modules
  - `Encoder.swift`, `AudioMix.swift` — VT encode + audio mux
- `Sources/mve/main.swift`            — CLI entry point
- `Sources/CLibass/`                  — libass module shim
- `bridge/mve.ts`                     — Node/TS wrapper around the CLI
- `bench.sh`                          — quick wall-time comparison

## License

MIT — see [LICENSE](./LICENSE). Depends on libass (ISC).
