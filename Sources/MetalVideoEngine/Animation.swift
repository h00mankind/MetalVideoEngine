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
public enum Easing: Equatable {
    case hold        // step: previous value until this key's time
    case linear
    case easeIn      // cubic
    case easeOut
    case easeInOut
    /// CSS `cubic-bezier(x1, y1, x2, y2)`. x1/x2 are clamped to 0...1 so
    /// time stays monotonic; y1/y2 are free, so a curve can overshoot.
    case cubicBezier(Float, Float, Float, Float)

    /// Parse a JobSpec ease string: a case name or
    /// `cubicBezier(x1,y1,x2,y2)`. Any other string returns nil.
    public static func parse(_ raw: String) -> Easing? {
        switch raw {
        case "hold":      return .hold
        case "linear":    return .linear
        case "easeIn":    return .easeIn
        case "easeOut":   return .easeOut
        case "easeInOut": return .easeInOut
        default:
            let prefix = "cubicBezier("
            guard raw.hasPrefix(prefix), raw.hasSuffix(")") else { return nil }
            let args = raw.dropFirst(prefix.count).dropLast()
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard args.count == 4,
                  let x1 = args[0], let y1 = args[1],
                  let x2 = args[2], let y2 = args[3],
                  [x1, y1, x2, y2].allSatisfy(\.isFinite)
            else { return nil }
            return .cubicBezier(x1, y1, x2, y2)
        }
    }

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
        case .cubicBezier(let x1, let y1, let x2, let y2):
            if u <= 0 { return 0 }
            if u >= 1 { return 1 }
            return Float(Self.solveBezier(
                Double(u),
                Double(min(max(x1, 0), 1)), Double(y1),
                Double(min(max(x2, 0), 1)), Double(y2)))
        }
    }

    /// y at the point where the bezier's x equals `x` (WebKit UnitBezier:
    /// Newton steps, bisection when Newton stalls).
    private static func solveBezier(
        _ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double
    ) -> Double {
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

        let epsilon = 1e-7
        var t = x
        for _ in 0..<8 {
            let err = sampleX(t) - x
            if abs(err) < epsilon { return sampleY(t) }
            let d = slopeX(t)
            if abs(d) < 1e-6 { break }
            t -= err / d
            if t < 0 || t > 1 { break }
        }

        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let err = sampleX(t) - x
            if abs(err) < epsilon { break }
            if err > 0 { hi = t } else { lo = t }
            let mid = (hi - lo) / 2 + lo
            if mid == t { break }
            t = mid
        }
        return sampleY(t)
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
                     ease: $0.ease.flatMap(Easing.parse) ?? .linear)
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
