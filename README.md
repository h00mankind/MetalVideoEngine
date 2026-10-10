# MetalVideoEngine

GPU-resident video render pipeline for Apple Silicon. Decode → grade → LUT
→ subtitle burn → encode, with frames never leaving the GPU.

> **Status:** experimental (`v0.1.4`). API may change between minor versions.

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

- single video input, or a playlist of clips joined by transitions
  (cut, crossfade, dip-to-black, wipe, slide)
- scale + letterbox to a target resolution (e.g. 1080×1920, 720×1280)
- color grade: brightness, contrast, saturation, tint, 3D LUT (`.cube`)
- bypass effects: mirror, zoom, edge blur, grain, noise, hue rotation
- keyframe animation over grade/bypass values and overlay
  opacity/position/scale (raw `(t, v, ease)` tracks — the host compiles
  its named animations; the engine only interpolates)
- libass subtitle burn (same renderer ffmpeg uses)
- logo + CoreText text overlays, with visibility windows and Ken Burns
  pan/zoom on images
- whole-frame fade in/out
- H.264 / HEVC mp4 or ProRes 422 HQ mov, social-media bitrates
- audio passthrough + narration + background music mix

It is faster than the ffmpeg path **for this workload** because it
eliminates copies, not because the algorithms are fundamentally better.

What's NOT in here: multi-track compositing, edit-list trimming, EDL/XML
interchange, scopes, ProRes decoding, color management beyond Rec.709,
source-audio crossfades at transitions, animation presets (host-side),
user-supplied transition shaders.

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
.package(url: "https://github.com/h00mankind/MetalVideoEngine.git", from: "0.1.4")
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

Animation is keyframes-first: every animatable value takes a raw
`(t, v, ease)` list (`ease`: `hold` | `linear` | `easeIn` | `easeOut` |
`easeInOut` | `cubicBezier(x1,y1,x2,y2)`, evaluated at output-timeline
seconds). `cubicBezier` matches CSS `cubic-bezier`: `x1`/`x2` clamp to
0..1, `y1`/`y2` may overshoot. An unknown `ease` string logs
`[job] warning` and renders as `linear`. Transition `ease` takes the
same values. Playlists replace
`input` with `inputs`; a transition on a segment describes the boundary
into the next one:

```json
{
  "inputs": [
    { "path": "/abs/a.mp4", "transition": { "type": "crossfade", "duration": 0.75 } },
    { "path": "/abs/b.mp4" }
  ],
  "output": "/abs/out.mp4",
  "preset": "1080p",
  "texts": [ {
    "text": "My Channel", "anchor": 8,
    "startSeconds": 1.0, "endSeconds": 6.0,
    "animate": {
      "opacity": [ {"t":1.0,"v":0}, {"t":1.5,"v":1,"ease":"easeOut"} ],
      "offsetY": [ {"t":1.0,"v":40}, {"t":1.5,"v":0,"ease":"easeOut"} ]
    }
  } ],
  "overlays": [ {
    "imagePath": "/abs/photo.jpg", "anchor": 5, "widthFraction": 0.8,
    "startSeconds": 2, "endSeconds": 7,
    "animate": {
      "srcZoom":    [ {"t":2,"v":1.0}, {"t":7,"v":1.4,"ease":"easeInOut"} ],
      "srcCenterX": [ {"t":2,"v":0.4}, {"t":7,"v":0.6} ]
    }
  } ],
  "animate": {
    "fadeInSeconds": 0.5, "fadeOutSeconds": 0.5,
    "bypass": { "zoom": [ {"t":0,"v":1.0}, {"t":13,"v":1.08} ] }
  }
}
```

Transition types: `cut`, `crossfade`, `dipToBlack`,
`wipeLeft`/`wipeRight`/`wipeUp`/`wipeDown`,
`slideLeft`/`slideRight`/`slideUp`/`slideDown` (directions name the edge
the incoming clip enters from). Overlapping types shorten the output by
their duration; narration/music audio plays through transitions
unaffected.

```sh
mve job /abs/path/to/spec.json
```

The CLI logs progress to stderr in a stable format:

```
[engine] frame 3600  src=119.97s  wall=18.41s  speed=6.50x
[done] frames=4080  src=136.49s  wall=20.81s  speed=6.53x
```

### CLI: contact sheet

```sh
mve strip /abs/path/to/spec.json --from 0 --to 2 --out /tmp/strip.png
mve strip spec.json --from 18 --to 20.5 -n 6 --columns 3 --cell-width 540 --out strip.png
```

`strip` runs the frame probe at `-n` evenly spaced output-timeline times
(default 12), the first at `--from` and the last at `--to`, and draws them
on one PNG with the time under each cell. Use it to read an animation
without a full render. The defaults are 6 columns and a cell width of
270 px; the cell keeps the aspect of the output. The spec needs no `frame`
block. A time with ` T` after it is inside a transition window: the frame
probe shows the incoming segment unblended there. Exit 1 when `--to` is
after the end of the output timeline, 2 for a usage error.

### CLI: pre-flight check

```sh
mve inspect /abs/path/to/spec.json          # one line per finding
mve inspect /abs/path/to/spec.json --json   # one JSON array on stdout
```

`inspect` checks a spec before you render it. It decodes no video frame
and creates no Metal texture. Each finding prints as
`<severity> <kind> <subject>: <message>`, errors first, with a summary
line on stderr. `--json` prints only the array of
`{kind, severity, subject, message, atSeconds?}` objects (`[]` when clean).
`inspectJob(spec, { signal })` in the Node bridge runs the same check. Aborting `signal` kills the child.

| Kind | Severity | Meaning |
| --- | --- | --- |
| `missingMedia` | error | A path the render reads is unreadable: `input`, `inputs[].path`, `overlays[].imagePath`, `lutPath`, `subtitles.assPath`, `subtitles.fontsDir`, `texts[].fontPath`, `audio.narrationPath`, and `audio.musicPath` when the render opens it (`musicVolume` is not 0). A file path must be a readable regular file, and `subtitles.fontsDir` must be a directory. Also: no `input` or `inputs`, an image that ImageIO cannot open, an input with no video track. |
| `fontFallback` | warning | CoreText resolves a text `fontName` to a different font. Fonts from `subtitles.fontsDir` and `fontPath` count as installed. |
| `textClipped` | warning | The rest rect of a text or image overlay is larger than the canvas and crosses an edge. The rest rect uses the anchor, offsets, and size with no animation. The engine clamps the origin into the canvas, so an offset alone never causes this. |
| `unknownEase` | error | An `ease` string that the engine does not parse, on a keyframe (one finding per track) or on a transition that the render reads. |
| `unknownTransition` | error | A transition `type` that is not in the gallery. The engine reads the transition of segment `i` for the boundary into `i + 1` and ignores the last one, so `inspect` does too. A `cut` never reads its `ease`. |
| `emptyWindow` | error | `endSeconds` is not after `startSeconds`. A missing `startSeconds` counts as 0. |
| `windowOutsideTimeline` | warning | A window starts at or after the end of the output timeline. |
| `keyframeOutsideTimeline` | warning | A track has a keyframe after the end of the output timeline (one finding per track). |

The two timeline checks read the input durations with AVFoundation. They
count the overlap of crossfade, wipe, and slide transitions, and they are
skipped when an input is unreadable.

Exit codes: `0` when no error is found (warnings alone exit 0), `3` when
one or more errors are found, `2` for a usage error (including an unknown
`--` option) or a spec file that cannot be read or decoded, `1` when the
`--json` output cannot be encoded.

### Node bridge

`bridge/mve.mjs` spawns the CLI and parses the progress/done lines into a
typed event stream. See the file's header comment for usage.

## Benchmark / parity harness

`bench.sh` generates a synthetic vertical-video fixture, ASS captions, and
a logo PNG, then renders baseline-vs-baseline and baseline-vs-candidate
jobs. It reports wall times, checks that the encoder is deterministic
before trusting PSNR, compares full-output PSNR, and compares PNG frame
probe MD5s. The full-output PSNR covers the generated logo and text
overlays; the frame probes cover the pre-encode render path.

```sh
MVE_BASELINE_BIN=/path/to/v0.1.3/mve ./bench.sh
```

If `MVE_BASELINE_BIN` is not set, the script uses the current release
binary for both baseline and candidate, building `.build/release/mve` if
needed. That mode is useful as a local smoke test. The default fixture is
60 s at 1080x1920. For a quick harness check, override
`MVE_BENCH_DURATION`, `MVE_BENCH_WIDTH`, `MVE_BENCH_HEIGHT`, and
`MVE_BENCH_PROBES`.

## Constraints / known issues

- **Runtime shader compile**: shaders are compiled via
  `device.makeLibrary(source:)`, not AOT `.metallib`. First render in a
  process pays a ~50–200ms compile cost; in-process subsequent renders
  are cached.
- **arm64 only**: Intel Mac builds would need a separate compute path
  (OpenCL or CPU fallback). Not planned.
- **Sequential playlist, not an NLE**: segments play back-to-back with
  boundary transitions; no multi-track / EDL pipeline. Playlist and
  animated jobs run the single-pipeline engine (the parallel chunk
  engine remains grade-only).
- **Frame probes don't blend transitions**: `mve frame` inside an
  overlap window returns the incoming segment unblended — probing needs
  one frame, transitions need two.
- **Bridge compatibility**: v0.1.4 fixes the semaphore-dispose trap that
  made older binaries exit non-zero after `[done]`. The Node bridge still
  treats a captured `[done]` line as success for one release so hosts can
  run against older binaries during rollout.

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
  - `Animation.swift`                 — keyframe tracks + easing evaluator
  - `LUT.swift`, `Overlay.swift`,
    `Fonts.swift`, `Job.swift`        — feature modules
  - `Inspect.swift`                   — `mve inspect` pre-flight check
  - `Sheet.swift`                     — `mve strip` contact sheet
  - `Encoder.swift`, `AudioMix.swift` — VT encode + audio mux
- `Sources/mve/main.swift`            — CLI entry point
- `Sources/CLibass/`                  — libass module shim
- `bridge/mve.mjs`, `bridge/mve.d.ts` — Node wrapper around the CLI
- `bench.sh`                          — benchmark + parity harness

## License

MIT — see [LICENSE](./LICENSE). Depends on libass (ISC).
