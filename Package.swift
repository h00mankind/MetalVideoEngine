// swift-tools-version: 5.10
import PackageDescription
import Foundation

// MetalVideoEngine — GPU-resident video render pipeline for Apple Silicon.
//
// libass discovery strategy:
//   1. pkg-config (the .systemLibrary's `pkgConfig: "libass"`) — works on
//      both Homebrew prefixes (/opt/homebrew, /usr/local) as long as
//      `pkg-config --libs libass` resolves. This is the path 95% of
//      contributors hit.
//   2. Env-var override: set MVE_LIBASS_PREFIX=/path/to/libass-install
//      to force a non-pkg-config install (CI caches, vendored builds).
//      The env var only adds search paths — it never replaces pkg-config.
//
// We intentionally do NOT fall back to a hard-coded /opt/homebrew. An
// opinionated default for one developer's machine doesn't belong in a
// shared package; if pkg-config can't find libass, the build should fail
// loudly with a real diagnostic instead of silently linking the wrong
// copy.
let libassPrefix = ProcessInfo.processInfo.environment["MVE_LIBASS_PREFIX"]

func libassSwiftFlags() -> [SwiftSetting] {
    guard let p = libassPrefix, !p.isEmpty else { return [] }
    return [.unsafeFlags(["-I", "\(p)/include"])]
}

func libassLinkerFlags() -> [LinkerSetting] {
    var s: [LinkerSetting] = [.linkedLibrary("ass")]
    if let p = libassPrefix, !p.isEmpty {
        s.insert(.unsafeFlags(["-L", "\(p)/lib"]), at: 0)
    }
    return s
}

let package = Package(
    name: "MetalVideoEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MetalVideoEngine", targets: ["MetalVideoEngine"]),
        .executable(name: "mve", targets: ["mve"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibass",
            path: "Sources/CLibass",
            pkgConfig: "libass",
            providers: [
                .brew(["libass"]),
            ]
        ),
        .target(
            name: "MetalVideoEngine",
            dependencies: ["CLibass"],
            path: "Sources/MetalVideoEngine",
            swiftSettings: libassSwiftFlags(),
            linkerSettings: libassLinkerFlags()
        ),
        .executableTarget(
            name: "mve",
            dependencies: ["MetalVideoEngine"],
            path: "Sources/mve",
            linkerSettings: libassLinkerFlags()
        ),
    ]
)
