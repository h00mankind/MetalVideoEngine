import Foundation

/// Keyframe animation primitives — the engine's *only* animation
/// mechanism. The JobSpec carries raw `(t, v, ease)` keyframe lists on
/// animatable properties; the host compiles whatever named animations
/// its UI offers ("bounce in", "slide up") down to these tracks. The
/// engine never knows a preset name — it interpolates.
///
/// Time base is OUTPUT-TIMELINE SECONDS (== source PTS for a
/// single-input job), never frame indices: PTS survives seek-based
/// probe mode (`mve frame`) and any future chunked rendering, frame
/// counters don't.
///
/// With dense keyframes and linear interpolation any curve is
/// representable, so the easing set below is a bandwidth convenience,
/// not a ceiling — a host that lets users draw custom curves samples
/// them into keyframes.

/// Interpolation shape *into* a keyframe from the previous one.
public enum Easing: String {
    case hold        // step: previous value until this key's time
    case linear
    case easeIn      // cubic
    case easeOut
    case easeInOut

    /// Map linear progress u ∈ [0,1] to eased progress.
    func apply(_ u: Float) -> Float {
        switch self {
        case .hold:      return 0
        case .linear:    return u
        case .easeIn:    return u * u * u
        case .easeOut:   let v = 1 - u; return 1 - v * v * v
        case .easeInOut:
            return u < 0.5
                ? 4 * u * u * u
                : 1 - pow(-2 * u + 2, 3) / 2
        }
    }
}

public struct Keyframe {
    public var t: Double     // output-timeline seconds
    public var v: Float
    public var ease: Easing  // interpolation from the previous key into this one

    public init(t: Double, v: Float, ease: Easing = .linear) {
        self.t = t; self.v = v; self.ease = ease
    }
}

/// A sorted keyframe list for one scalar property. Evaluation is a
/// linear scan — tracks are authored by hosts and stay small (a dense
/// hand-sampled curve is ~60 keys); per-frame cost is nanoseconds
/// against a multi-millisecond frame budget.
public struct Track {
    public let keys: [Keyframe]

    public init(_ keys: [Keyframe]) {
        self.keys = keys.sorted { $0.t < $1.t }
    }

    /// Value at time `t`. Clamps to the first/last key outside the
    /// keyed range — an overlay that fades in stays at its final
    /// opacity after the last key, matching every animation system's
    /// convention.
    public func value(at t: Double) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        // Find the segment [i, i+1] containing t.
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if t < b.t {
                let span = b.t - a.t
                if span <= 0 { return b.v }
                let u = Float((t - a.t) / span)
                return a.v + (b.v - a.v) * b.ease.apply(u)
            }
        }
        return last.v
    }
}

// ── JobSpec → Track conversion ─────────────────────────────────────────

extension Track {
    /// Build a Track from the JobSpec's raw keyframe list. `nil` or
    /// empty lists produce no track (property stays static). `map`
    /// converts spec-space values to engine-space (e.g. degrees →
    /// radians, percent → fraction) so tracks always hold the unit the
    /// shader consumes.
    public static func from(
        _ specs: [JobSpec.KeyframeSpec]?,
        map: (Float) -> Float = { $0 }
    ) -> Track? {
        guard let specs, !specs.isEmpty else { return nil }
        return Track(specs.map {
            Keyframe(t: $0.t, v: map($0.v),
                     ease: Easing(rawValue: $0.ease ?? "linear") ?? .linear)
        })
    }
}

// ── Grade / bypass track bundles ───────────────────────────────────────

/// Optional per-field tracks over the grade params. Fields without a
/// track keep the request's static value — evaluation copies the base
/// struct and overrides only what's keyed.
public struct GradeTracks {
    public var brightness: Track?
    public var contrast: Track?
    public var saturation: Track?
    public var tint: Track?
    public var lutMix: Track?

    public init(brightness: Track? = nil, contrast: Track? = nil,
                saturation: Track? = nil, tint: Track? = nil,
                lutMix: Track? = nil) {
        self.brightness = brightness; self.contrast = contrast
        self.saturation = saturation; self.tint = tint; self.lutMix = lutMix
    }

    public var isEmpty: Bool {
        brightness == nil && contrast == nil && saturation == nil
            && tint == nil && lutMix == nil
    }

    public func apply(to grade: inout FilterGraph.GradeParams, at t: Double) {
        if let tr = brightness { grade.brightness = tr.value(at: t) }
        if let tr = contrast   { grade.contrast = tr.value(at: t) }
        if let tr = saturation { grade.saturation = tr.value(at: t) }
        if let tr = tint       { grade.tint = tr.value(at: t) }
        if let tr = lutMix     { grade.lutMix = tr.value(at: t) }
    }
}

/// Optional per-field tracks over the bypass params. Track values are
/// already in engine units (radians, fractions) — the JobSpec builder
/// converts via `Track.from(_:map:)`.
public struct BypassTracks {
    public var zoom: Track?
    public var colorTintRad: Track?
    public var noise: Track?
    public var grain: Track?
    public var edgeBlurSigma: Track?

    public init(zoom: Track? = nil, colorTintRad: Track? = nil,
                noise: Track? = nil, grain: Track? = nil,
                edgeBlurSigma: Track? = nil) {
        self.zoom = zoom; self.colorTintRad = colorTintRad
        self.noise = noise; self.grain = grain
        self.edgeBlurSigma = edgeBlurSigma
    }

    public var isEmpty: Bool {
        zoom == nil && colorTintRad == nil && noise == nil
            && grain == nil && edgeBlurSigma == nil
    }

    public func apply(to bypass: inout FilterGraph.BypassParams, at t: Double) {
        if let tr = zoom          { bypass.zoom = tr.value(at: t) }
        if let tr = colorTintRad  { bypass.colorTintRad = tr.value(at: t) }
        if let tr = noise         { bypass.noise = tr.value(at: t) }
        if let tr = grain         { bypass.grain = tr.value(at: t) }
        if let tr = edgeBlurSigma { bypass.edgeBlurSigma = tr.value(at: t) }
    }
}
