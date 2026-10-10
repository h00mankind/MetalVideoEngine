# Animation & transitions

**Status:** shipped (all slices) · planned 2026-07-03 · implemented 2026-07-06
**Phase 1:** keyframe/timeline layer (text animation, effects-over-time, photo overlays with Ken Burns)
**Phase 2:** multi-input playlist with video A→B transitions

## Problem

Renders look static. An overlay (channel name, logo, photo) appears on frame 0 and sits unchanged until the end; effects are constant for the whole clip; joining two clips with anything but an external editor is impossible. Hosts producing social video want motion: text that fades or slides in, a photo that pans while it's on screen, a clip that fades from black, and clips stitched with a crossfade — without leaving the engine's single GPU pass.

## Solution

One new engine concept — **time-driven parameters** — plus one scope expansion — **multi-input playlists**.

Phase 1: every per-frame parameter the engine already applies (grade, bypass, each overlay's opacity/position/size) becomes animatable via keyframe tracks on the output timeline. Overlays gain visibility windows and animation presets (fade/slide/pop). Photo overlays gain a Ken Burns source window. The host authors all of this declaratively in the JobSpec; the engine evaluates tracks per frame and feeds the existing shaders.

Phase 2: a job may list multiple input segments with a transition at each boundary. During a transition window both decoders run and a new two-source blend kernel mixes the frames.

## User stories

1. As a host, I want an overlay to appear only between `startSeconds` and `endSeconds`, so branding can enter and exit mid-video.
2. As a host, I want text overlays to fade in and out over a chosen duration, so titles don't pop harshly.
3. As a host, I want text overlays to slide in from an edge with easing, so intros feel produced.
4. As a host, I want a pop (scale-up) entrance for text, so emphasis moments land.
5. As a host, I want the same animation presets on logo/image overlays, so all branding animates consistently.
6. As a host, I want to place a photo over the video for a time window with fade in/out, so stills can illustrate narration.
7. As a host, I want Ken Burns pan/zoom on a photo overlay, so stills feel alive.
8. As a host, I want the whole video to fade from black at the start and to black at the end, so clips open and close cleanly.
9. As a host, I want to keyframe grade values over time (e.g. desaturate toward the end), so looks can evolve.
10. As a host, I want to keyframe bypass values over time (e.g. slow zoom ramp, blur pulse), so effects-over-time are possible without per-frame host control.
11. As a host, I want old job specs with none of these fields to render bit-identically, so rollout is safe.
12. As an editor, I want the frame probe to reflect animation state at the probed PTS — including overlays — so preview diffing stays truthful.
13. As a host, I want to list multiple input clips in one job and get them rendered back-to-back (hard cut), so simple stitching doesn't need ffmpeg concat.
14. As a host, I want a crossfade of chosen duration between adjacent clips, so cuts feel intentional.
15. As a host, I want wipe and slide transition types, so different video styles are served.
16. As a host, I want narration and music to continue uninterrupted across segment boundaries, so the audio bed is unaffected by video transitions.
17. As a host, I want progress logs to keep the same stable format with a correct total-duration denominator for playlists, so the bridge progress bar keeps working.

## Decisions

All **assumed** (trust mode) unless marked settled.

- **Engine evaluates, host authors** *(settled in conversation)*. The JobSpec carries declarative timing (windows, presets, keyframes); the engine is the only component that sees per-frame time and computes concrete values. The engine never authors content.
- **One mechanism, not four features.** Text animation, effects-over-time, and photo fades all ride a single keyframe-track evaluator. A track is a sorted list of `(atSeconds, value, easing)`; evaluation is CPU-side per frame; results flow into the existing param structs and composite calls. No shader change for fades, slides, or ramps.
- **Time base is output-timeline seconds**, not frame indices. Frame indices don't survive chunked/parallel rendering or probe mode; PTS does. For single-input jobs output timeline == source PTS.
- **Easing set:** hold, linear, easeIn, easeOut, easeInOut (cubic). With dense keyframes and linear interpolation any curve is representable, so this set is a bandwidth convenience, not a ceiling.
- **Keyframes-first surface; no presets in the engine** *(settled in conversation)*. The JobSpec exposes raw keyframe tracks on animatable overlay properties (opacity, position offset, scale, source window). The host compiles its named animations ("bounce in", "slide up") into tracks. The engine's contract is: these properties are animatable; give me `(t, value, ease)` points; I interpolate. Named presets, curves, and UI vocabulary live host-side.
- **Job-level fade in/out** is implemented as a full-canvas constant-color composite (1×1 black texture stretched) with an animated opacity track. Zero new kernels.
- **Ken Burns is the one Phase-1 shader change.** The composite kernel gains an optional source window (origin/size in normalized image coordinates); animating that window gives pan/zoom. Photos load once at natural resolution. The source window is authored as three tracks — center x, center y, zoom — so aspect stays engine-managed (cover semantics) and can't be skewed by inconsistent keyframes.
- **Transitions: generic mechanism, gallery of kernels.** The structural contract is two decoded sources + a progress value delivered to a blend kernel during the overlap window. Transition *types* (crossfade, wipe, slide) are a gallery of small kernels against that contract; adding a type never touches the decode plumbing. User-supplied shader code is deliberately excluded (validation/support surface), though the runtime-compile architecture would permit it later.
- **Pop/scale animates the destination rect.** During the animation the 1:1 texel mapping (crispness guarantee) is intentionally relaxed; the rect settles on the snapped, crisp position at rest.
- **Parallel engine is out of scope for animation.** It is already a grade-only feature subset; animated jobs run the single-pipeline engine. Revisit only if wall-time demands it.
- **Phase 2 playlist model.** `inputs: [{path, transition?}]` supersedes the single `input` (which remains valid and equivalent to a one-segment playlist). Transitions are declared at boundaries: type (cut, crossfade, wipe, slide, dipToBlack) + duration.
- **Transition windows overlap-decode.** During a transition of duration d, segment A's frame cadence drives output; segment B decodes alongside and contributes its latest frame at-or-before the blend PTS. A new two-source blend kernel mixes into the destination; B's segment PTS re-bases to the output timeline.
- **dipToBlack is not a blend.** It composes from existing pieces: A fades to black, hard cut, B fades from black — no overlap decode needed.
- **Phase 2 audio: video-only transitions.** Narration/music mix continues across boundaries untouched. Source-clip audio crossfade is out of scope (the target workload is voiceover + music bed).
- **Multi-input jobs run the sequential engine.** Chunk-per-segment parallelism is a later optimization, not part of this plan.
- **Backward compatibility is bit-exact.** Every new JobSpec field is optional; a spec without them takes the exact same code paths (no evaluator in the loop, no extra composites).

## Open questions

- Does the live editor preview need to mirror animations (DOM/CSS side), and who owns that parity contract? The frame probe covers spot-checking but not scrubbing.
- Should a photo be allowed as a *playlist segment* (full-frame slideshow slot with transitions), not just an overlay? Natural Phase-2 extension; changes the segment model from "video file" to "video | still".
- Frame-rate mismatch between playlist segments: is nearest-frame-hold during transitions acceptable, or do mixed-fps playlists need explicit fps normalization?
- Is per-word/typewriter text animation wanted? Current position: that's caption territory (libass/karaoke already do it); branding text gets whole-overlay animation only.

## Out of scope

- Multi-track compositing, EDL/XML interchange, edit-list trimming.
- Speed ramps (the reserved `speed` field stays reserved).
- Source-clip audio crossfades during transitions.
- Animated subtitle styling — libass owns caption animation via ASS tags. Per-word/per-character branding text motion is also ASS territory, not the overlay system.
- Animation presets in the engine (fade/slide/pop names) — host-side compilation to keyframe tracks.
- User-supplied transition shader code.
- Animated overlay *sources* (image sequences / alpha video) — the future escape hatch for host-rendered arbitrary motion (stickers, particles); engine stays a compositor when it lands.
- Parallel-engine support for animated or multi-input jobs.
- Preview-side (DOM) animation rendering.

---

## Slices

### Slice 1 — Overlay visibility windows

Overlays and texts accept `startSeconds`/`endSeconds`; the engine skips the composite outside the window. Establishes PTS-driven per-frame overlay evaluation — the plumbing every later slice rides on.

- [x] JobSpec: optional `startSeconds`/`endSeconds` on image and text overlays; absent = always visible (current behavior)
- [x] Engine composites an overlay only when frame PTS is inside its window
- [x] Frame probe applies the same windowing (and gains overlay compositing if it lacks it)
- [x] A spec without windows renders bit-identically to today (parity harness green)
- Blocked by: —

### Slice 2 — Keyframe evaluator + overlay animation tracks

The track evaluator (values + easing) and raw keyframe tracks on overlays/texts: opacity, position offset, scale. No presets — the host compiles its animations into tracks.

- [x] Track type: sorted `(atSeconds, value, easing)` list; hold/linear/easeIn/easeOut/easeInOut; evaluated per frame
- [x] JobSpec: `animate` block on overlays and texts with `opacity`, `offsetX`, `offsetY`, `scale` keyframe lists
- [x] Opacity track animates composite opacity; offset tracks animate rect origin relative to the anchor; scale animates rect size about the rect center
- [x] Frame probe shows the correct mid-animation state at any probed PTS
- [x] Demo: channel name slides up + fades in at 1s, fades out at 8s — authored purely as keyframes
- Blocked by: Slice 1

### Slice 3 — Grade/bypass keyframes + job-level fade

Effects-over-time: optional keyframe lists for grade and bypass scalars, evaluated into the per-frame param structs. Job-level `fadeInSeconds`/`fadeOutSeconds` via the black-overlay trick.

- [x] JobSpec: keyframe lists for grade fields (brightness, contrast, saturation, tint, lutMix) and bypass fields (zoom, colorTintDeg, noise, grain, edgeBlur)
- [x] Scalar field + keyframe list are mutually exclusive per field; keyframes win when present
- [x] Job-level fade from/to black with chosen durations, composited above subtitles and overlays
- [x] Demo: fade-from-black over 0.5s + zoom ramping 1.0→1.08 across the clip
- Blocked by: Slice 2 (evaluator)

### Slice 4 — Photo overlays with Ken Burns

The composite kernel gains a normalized source window; photo overlays get a `kenBurns` block (from-window → to-window over the visibility window) alongside fade in/out.

- [x] Composite kernel samples an optional source sub-window; default (full window) is pixel-identical to today
- [x] JobSpec: `srcCenterX`/`srcCenterY`/`srcZoom` keyframe tracks on image overlays
- [x] Aspect handled: engine computes a cover-semantics source window from center + zoom, so keyframes can't skew the image
- [x] Demo: photo fades in at 2s, pans/zooms for 4s, fades out
- Blocked by: Slice 2

### Slice 5 — Playlist with hard cuts (Phase 2 start)

`inputs` array; segments decode sequentially into one output with re-based PTS. Cut-only — no overlap, no new kernel. Audio spec continues to apply to the whole output timeline.

- [x] JobSpec: `inputs: [{path}]`; single `input` still valid (one-segment playlist)
- [x] Sequential decoders; output PTS = cumulative segment offsets; `[meta] sourceSecs` reports the playlist total
- [x] Segments may differ in resolution (each letterboxes independently); grade/bypass/subtitles/overlays apply on the output timeline
- [x] Demo: two clips rendered back-to-back in one `mve job` run
- Blocked by: — (independent of Slices 1–4; overlays-on-playlist demo depends on Slice 1)

### Slice 6 — Crossfade + dipToBlack transitions

Overlap decode: during the transition window both readers are live; a two-source blend kernel mixes B over A by eased progress. dipToBlack composes from fades + a cut.

- [x] JobSpec: `transition: {type, duration}` per boundary; `cut` default
- [x] Two-source blend kernel; A's cadence drives the window, B holds latest frame at-or-before blend PTS
- [x] dipToBlack implemented via per-segment fade tracks, no overlap decode
- [x] Output duration = sum of segments minus overlaps; progress denominator correct
- [x] Demo: A→B crossfade over 0.75s
- Blocked by: Slice 5 (playlist), Slice 2 (easing)

### Slice 7 — Wipe + slide transition types

Directional variants in the same blend kernel: wipe (soft-edged reveal) and slide (B pushes A out), each in four directions.

- [x] Wipe left/right/up/down with a feathered edge
- [x] Slide left/right/up/down
- [x] Demo reel: one output exercising every transition type
- Blocked by: Slice 6
