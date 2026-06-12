# Render-speed optimization — social media video export

**Mode:** trust (synthesized from the 2026-06-12 profiling session; no interview)
**Prime directive:** every speed change ships with proof that output quality is unchanged — bit-identical where the change claims neutrality, explicitly flagged and approved where it isn't.

## Problem

Creators exporting 1080×1920 social videos (TikTok / Reels / Shorts) wait on renders. The Metal engine already beats the ffmpeg path's wall-clock, but: (a) until this session every render *reported failure* (SIGTRAP at exit) so the Node bridge papered over exit codes; (b) the parallel chunked engine crashed mid-run, so the one lever that scales past a single media engine was dead; (c) per-frame CPU and GPU work was being spent on overlays and captions that hadn't changed.

## Measured reality (M1 Pro, 60 s 1080×1920\@30 testsrc2, 8 Mbps H.264 source)

| Scenario | Wall | Note |
|---|---|---|
| Hardware decode only (ffmpeg, VideoToolbox) | 7.9 s | **the floor** — single decode engine saturated |
| ffmpeg full pipeline (decode→scale→VT encode) | 9.35 s | production-path reference |
| `mve job`, plain (grade only) | 9.5 s | at parity with ffmpeg, ~1.6 s above decode floor |
| `mve job`, full social export (captions + logo + text) | 9.6–9.9 s | overlay features cost ~3 % |
| `mve job`, GPU-heavy bypass (edge blur 30 + noise + grain + zoom) | 9.48 s | GPU has headroom; not the bottleneck |
| `mve render --chunks 2/3/4/6` (after crash fix) | 9.6–9.8 s | **no speedup on M1 Pro** — chunks share one media engine |

**Conclusion:** on single-media-engine chips (M1/M2/M3 base and Pro) the engine is already at the hardware ceiling for single-stream rendering. Remaining wins are: removing avoidable per-frame work (helps battery, thermals, and heavy-caption content), making chunked parallelism actually work for multi-media-engine chips (M1/M2 Max = 2 encode engines, Ultra = 4), and shrinking delivered bytes at equal quality (HEVC).

## Already landed this session (working tree, pending commit)

1. **Semaphore-dispose SIGTRAP fix** (`Engine.swift`, `ParallelEngine.swift`) — inflight semaphores are now created at 0 and primed with signals; disposing a drained semaphore no longer traps. Before: *every* render exited 133 after `[done]`; ParallelRenderEngine died mid-run with no output. After: exit 0, parallel renders complete.
2. **Rect-scoped overlay dispatch** (`FilterGraph.composite`, `overlay_composite` kernel) — composite passes launch threads only over the overlay's rect instead of the full 2-megapixel canvas (~99 % thread reduction per logo/text overlay per frame).
3. **libass `detect_change` caching** (`LibassRenderer.renderTexture`) — when libass reports the subtitle frame unchanged (the common case: cues hold for seconds), the CPU blend and ~8 MB texture upload are skipped and the cached texture is returned. Re-uploads rotate through an 8-slot texture ring so in-flight frames never have their texture overwritten (fixes a latent tearing race). Scratch compose buffer is reused instead of an 8 MB alloc/zero per frame.

**Quality proof:** full-job output bit-equivalent to pre-change baseline (ffmpeg PSNR `inf` on all planes, 1800 frames); `mve frame` PNG MD5s identical at t=3.0 s and t=31.2 s. Encoder verified run-to-run deterministic first, so PSNR `inf` is a meaningful equality check.

## Solution

Ship the landed fixes, then execute the slices below. Each slice is independently demoable and carries an explicit quality gate.

## User stories

1. As a creator, I want exports to finish faster on capable hardware, so that iteration loops stay short.
2. As a creator, I want export quality untouched by speed work, so that I never trade crispness for time silently.
3. As the host app, I want `mve` exit codes to mean success/failure, so that fallback logic (ffmpeg path) triggers only on real failures.
4. As the host app, I want chunked parallel rendering for full job specs (captions, overlays, audio), so that Max/Ultra machines cut wall-time proportionally to their media engines.
5. As a creator with caption-heavy projects (karaoke, word-by-word), I want subtitle compositing to cost only what changed, so that heavy caption styles don't slow exports.
6. As a creator uploading to platforms with size limits, I want an HEVC delivery option, so that the same visual quality costs fewer megabytes.
7. As a maintainer, I want a benchmark + parity harness in the repo, so that every future speed PR proves it didn't change pixels.

## Decisions (assumed — trust mode)

- **Quality bar is bit-identity by default.** A slice that intentionally changes pixels (separable edge blur, sigma-strength fix, logo pre-scale) must say so in its PR and show before/after probes; it cannot ride along inside a "speed" commit.
- **Parallelism scales by media engines, not CPU cores.** Chunk count should derive from the chip's encode-engine count (1 on base/Pro, 2 on Max, 4 on Ultra), defaulting to 1 when unknown. Single-pipeline remains the default path on single-engine chips — chunking there only adds mux overhead and rate-control seams.
- **Chunked output is not bit-identical to single-pipeline output** (each chunk restarts encoder rate control; measured ~33 dB PSNR between the two on synthetic content — both are valid 10 Mbps encodes of identical input pixels). Chunked mode is therefore opt-in per job, not a silent default, until the Open question on acceptability is resolved.
- **The bridge keeps its `[done]`-blob success heuristic** for one release (older binaries still trap at exit), then tightens to exit-code-only once the fixed binary is the published floor.
- **The bench fixture is synthetic** (testsrc2 + generated ASS + generated logo) so it lives in the repo as a script, not as committed media.

## Slices

### S1 — Ship the landed fixes
**Build:** Commit the semaphore fix, rect-scoped dispatch, and libass caching; add CHANGELOG entries (with the bgRadius entry that v0.1.3 missed); bump to v0.1.4; publish the npm package + binary.
**Acceptance:**
- [ ] `mve job` exits 0 on success (was 133)
- [ ] `mve render --chunks 3` completes with a valid output file (was SIGTRAP, no file)
- [ ] Full-job output bit-equivalent to v0.1.3 baseline (PSNR inf)
- [ ] CHANGELOG documents all three changes + bgRadius
**Blocked by:** —

### S2 — Benchmark + parity harness in-repo
**Build:** Replace stale `bench.sh` (still calls a `recap-metal` binary that no longer exists) with a script that generates the synthetic fixture (source clip, ASS captions, logo, job specs), runs baseline vs candidate binaries, reports wall times, and gates on parity (frame-PNG MD5s + full-output PSNR). This is the session's manual workflow, made repeatable.
**Acceptance:**
- [ ] One command produces a speed table and a PASS/FAIL parity verdict
- [ ] Detects encoder nondeterminism before trusting PSNR (baseline-vs-baseline run)
- [ ] Documented in README
**Blocked by:** S1

### S3 — ParallelRenderEngine: full JobSpec parity
**Build:** Extend `renderChunk` to the full feature set the single engine has — bypass params, LUT, libass (one `LibassRenderer` per chunk, seeded to the chunk's start time), static overlays, `[meta]`/progress log lines, and audio (mix once, mux after concat). Auto-derive chunk count from the chip's encode-engine count; fall through to single-pipeline when it is 1. Wire `mve job` to accept `"chunks"`/auto.
**Acceptance:**
- [ ] Full social-export job (captions + logo + text + audio) renders correctly chunked
- [ ] Frame probes at chunk boundaries match single-pipeline pixels (pre-encode)
- [ ] On a multi-media-engine machine: measured wall-time reduction reported; on M1 Pro: auto mode selects single-pipeline
- [ ] Progress ratio still monotonic 0→1 across chunks in the bridge
**Blocked by:** S1, S2

### S4 — Pre-scale logo textures at job start
**Build:** `Overlay.loadImage` gains a target-size parameter; logos are resampled once on the CPU (CGContext, high-quality interpolation, EXIF orientation applied) to the integer rect the composite uses, making every static overlay a true 1:1 composite. Fixes the per-frame single-tap bilinear downscale (aliased logos) and the stale file-header comment.
**Quality note:** changes pixels *for the better* (proper downsampling vs aliased single-tap); needs before/after screenshots, not PSNR.
**Acceptance:**
- [ ] Logo overlay rect sizes are integer; composite is 1:1
- [ ] Large source logos show no shimmer/aliasing vs v0.1.3 (eyeball probe at 4× zoom)
- [ ] JPEG logos with EXIF rotation render upright
**Blocked by:** S2

### S5 — Dirty-rect subtitle compose + upload
**Build:** Track the union bounding box of ASS_Image rects per changed frame; zero, blend, and `replace()` only that region of the scratch buffer/texture (plus the previous frame's box, so stale glyphs clear). Pass the box to `graph.composite` as the rect so the GPU pass also shrinks from full-canvas to caption-sized.
**Acceptance:**
- [ ] Pixel parity vs S1 output on the bench fixture and on a karaoke ASS (per-frame changes)
- [ ] Measured reduction in subtitle-path CPU time on a karaoke-heavy job (report numbers)
**Blocked by:** S2 (parity gate), pairs well after S3

### S6 — Edge-blur: fix strength, then make it separable
**Build:** Two ordered changes. First the correctness fix from the 2026-06-12 audit: tap stride must be `sigma / EFF_SIGMA` (σ/3), not `sigma / KERNEL_R` (σ/6) — the current kernel renders at *half* the requested Gaussian sigma, so the render is visibly weaker than the CSS/ffmpeg preview. Second, replace the 169-tap 2D grid with a two-pass separable Gaussian (or a band-limited intermediate texture), cutting band-pixel cost ~6×.
**Quality note:** the strength fix intentionally changes pixels (to match the preview's intent); the separable rewrite must then match the fixed 2D kernel within float tolerance (PSNR > 55 dB on band regions).
**Acceptance:**
- [ ] Rendered edge-blur strength matches CSS `backdrop-filter: blur(σ)` preview side-by-side
- [ ] Separable pass ≈ 2D reference (PSNR > 55 dB, no banding at σ ∈ {5, 30, 100})
- [ ] GPU time of the band pass reported before/after
**Blocked by:** S2

### S7 — HEVC delivery preset
**Build:** Surface the existing HEVC codec path as a first-class job option with tuned bitrate defaults (~60–70 % of H.264 for equal quality), verify platform ingest (TikTok/Reels/Shorts all accept HEVC mp4), and document the trade-off (encode speed parity on the ASIC, smaller uploads).
**Acceptance:**
- [ ] `"codec": "hevc"` job renders at equal visual quality (SSIM vs H.264 within noise) at reduced size
- [ ] Bridge type definitions document the option
**Blocked by:** S1

### S8 — Bridge: honest exit codes
**Build:** Once v0.1.4 is the published floor, drop the bridge's "treat any exit as success if a `[done]` blob was seen" workaround (its comment misattributes the SIGTRAP to AVFoundation teardown — the real cause was the semaphore trap, now fixed). Reject on nonzero exit; keep the `[done]` parse for stats only.
**Acceptance:**
- [ ] Nonzero exit from the engine rejects the bridge promise with the exit code
- [ ] Forced failure (bad input path) surfaces a real error to the host
**Blocked by:** S1 (published)

## Open questions

1. **Chunked-encode acceptability:** chunk boundaries restart rate control, so chunked and single outputs differ (both valid encodes of identical pixels). Is that acceptable for delivery renders, or should chunked mode stay draft/preview-only? Needs a decision from the product owner before S3 makes chunking automatic anywhere.
2. **Multi-media-engine test hardware:** S3's speedup claim needs a Max/Ultra machine (or CI runner) to validate; none was available this session.
3. **Decode-engine count detection:** there is no public API for media-engine count; likely needs a chip-name lookup table. Acceptable?

## Out of scope

- Software encoders (x264/x265) — different quality/speed regime, breaks the GPU-resident design.
- Lowering encode quality for speed (draft profile already exists for that).
- Preview/scrub performance in the editor (separate surface; this plan is export only).
- The audit's non-speed findings other than those folded into S4/S6.
