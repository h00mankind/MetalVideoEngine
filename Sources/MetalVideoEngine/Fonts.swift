import Foundation
import CoreText
import CoreGraphics

/// Font registration helper.
///
/// libass with the CoreText font provider looks fonts up against the
/// **system font registry** — which doesn't include this project's
/// `static/fonts/` directory by default. Without registering the TTFs
/// explicitly, libass would fall back to Helvetica for anything that
/// isn't already system-installed, and the Metal render would drift
/// from the ffmpeg/preview burn (which finds the project font fine).
///
/// This helper registers a TTF/OTF with the **process-scoped** CTFont
/// manager so it's visible to CoreText (and therefore libass) for the
/// lifetime of the engine process. Registering process-scoped (not
/// user-scoped) means we don't touch the user's font library —
/// registrations evaporate when the engine exits, and the same path
/// can be re-registered cheaply because we cache per-path.
public enum Fonts {

    /// Set of font paths already registered in this process. Repeated
    /// calls with the same path are short-circuited so the caller
    /// doesn't have to dedupe (preview thumbnails, frame mode, and
    /// job mode all register the same font set).
    private static var registered: Set<String> = []
    private static let lock = NSLock()

    /// Register one font file with the process-scoped CTFont manager.
    /// No-op + true when the same path was registered earlier in this
    /// process. Returns false only on a genuinely unreadable file or
    /// CoreText refusal.
    @discardableResult
    public static func register(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if registered.contains(path) { return true }
        let url = URL(fileURLWithPath: path)
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if ok {
            registered.insert(path)
            return true
        }
        // "AlreadyRegistered" is a benign error code returned when the
        // same TTF was registered earlier (often via a different code
        // path, e.g. the libass probe CLI). Treat the font as available
        // either way. Other failures (file missing, bad format) bubble
        // up as false so callers can decide to fall back.
        if let e = error?.takeRetainedValue() {
            let code = CFErrorGetCode(e)
            if code == CTFontManagerError.alreadyRegistered.rawValue {
                registered.insert(path)
                return true
            }
        }
        return false
    }

    /// Register every `.ttf`/`.otf` file inside `dir`. Skips silently on
    /// per-file failure — used by the Node bridge which hands us the
    /// project's static/fonts/ directory and expects best-effort
    /// registration of whatever's there.
    public static func registerDirectory(_ dir: String) {
        let url = URL(fileURLWithPath: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return }
        for f in files {
            let ext = f.pathExtension.lowercased()
            if ext == "ttf" || ext == "otf" {
                _ = register(path: f.path)
            }
        }
    }
}
