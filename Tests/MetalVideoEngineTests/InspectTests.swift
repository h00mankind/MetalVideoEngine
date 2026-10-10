import XCTest
@testable import MetalVideoEngine

final class InspectTests: XCTestCase {
    private let missing = "/nonexistent/i1/missing.bin"

    /// A spec whose input does not exist, so no test needs a video file.
    private func spec(_ fields: String = "") throws -> JobSpec {
        let json = "{\"input\":\"\(missing)\",\"output\":\"/tmp/out.mp4\",\"preset\":\"1080p\"\(fields.isEmpty ? "" : "," + fields)}"
        return try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
    }

    private func subjects(_ found: [Diagnostic], _ kind: Diagnostic.Kind) -> [String] {
        found.filter { $0.kind == kind }.map(\.subject)
    }

    func testMissingMediaReportsEveryUnreadablePath() throws {
        let s = try spec("""
        "overlays":[{"imagePath":"\(missing)"}],
        "lutPath":"\(missing)",
        "subtitles":{"assPath":"\(missing)","fontsDir":"\(missing)"},
        "texts":[{"text":"x","fontName":"Helvetica","fontPath":"\(missing)"}],
        "audio":{"narrationPath":"\(missing)","musicPath":"\(missing)"}
        """)
        let found = Inspector.inspect(s)
        XCTAssertEqual(subjects(found, .missingMedia), [
            "input", "overlays[0].imagePath", "lutPath", "subtitles.assPath",
            "subtitles.fontsDir", "texts[0].fontPath",
            "audio.narrationPath", "audio.musicPath",
        ])
        XCTAssertTrue(found.allSatisfy { $0.severity == .error })
    }

    func testMissingMediaIgnoresReadablePathsAndNamesPlaylistSegment() throws {
        let json = """
        {"inputs":[{"path":"\(#filePath)"},{"path":"\(missing)"}],"output":"/tmp/o.mp4",
         "preset":"1080p","lutPath":"\(#filePath)"}
        """
        let s = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        let found = Inspector.inspect(s)
        XCTAssertEqual(subjects(found, .missingMedia), ["inputs[1].path"])
    }

    func testDirectoryIsNotAFileAndFileIsNotADirectory() throws {
        let file = #filePath
        let dir = (file as NSString).deletingLastPathComponent
        let bad = try spec("""
        "lutPath":"\(dir)",
        "subtitles":{"assPath":"\(dir)","fontsDir":"\(file)"}
        """)
        XCTAssertEqual(subjects(Inspector.inspect(bad), .missingMedia),
                       ["input", "lutPath", "subtitles.assPath", "subtitles.fontsDir"])
        let good = try spec(#""lutPath":"\#(file)","subtitles":{"assPath":"\#(file)","fontsDir":"\#(dir)"}"#)
        XCTAssertEqual(subjects(Inspector.inspect(good), .missingMedia), ["input"])
    }

    func testMusicPathIsReportedOnlyWhenTheRenderOpensIt() throws {
        func missing(_ audio: String) throws -> [String] {
            subjects(Inspector.inspect(try spec("\"audio\":{\"narrationPath\":\"\(#filePath)\"\(audio)}")), .missingMedia)
        }
        XCTAssertEqual(try missing(#","musicPath":"\#(self.missing)","musicVolume":0"#), ["input"])
        XCTAssertEqual(try missing(#","musicVolume":0.5"#), ["input"])
        XCTAssertEqual(try missing(#","musicPath":"\#(self.missing)""#), ["input", "audio.musicPath"])
        XCTAssertEqual(try missing(#","musicPath":"\#(self.missing)","musicVolume":0.5"#), ["input", "audio.musicPath"])
    }

    func testSpecWithoutAnyInputIsAMissingMediaError() throws {
        let json = #"{"output":"/tmp/o.mp4","preset":"1080p"}"#
        let s = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        let found = Inspector.inspect(s)
        XCTAssertEqual(found.map(\.kind), [.missingMedia])
        XCTAssertEqual(found.first?.severity, .error)
        XCTAssertEqual(found.first?.subject, "input")
    }

    func testFontFallbackWarnsOnlyForAnUnresolvableName() throws {
        let s = try spec("""
        "texts":[{"text":"a","fontName":"NoSuchFontXYZ"},
                 {"text":"b","fontName":"Helvetica"},
                 {"text":"c"}]
        """)
        let found = Inspector.inspect(s).filter { $0.kind == .fontFallback }
        XCTAssertEqual(found.map(\.subject), ["texts[0].fontName"])
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testTextWiderThanCanvasIsClipped() throws {
        let s = try spec("""
        "texts":[{"text":"THIS IS A VERY LONG HEADLINE","fontName":"Helvetica","fontSize":160,"anchor":5},
                 {"text":"Hi","fontName":"Helvetica","anchor":5}]
        """)
        let found = Inspector.inspect(s).filter { $0.kind == .textClipped }
        XCTAssertEqual(found.map(\.subject), ["texts[0]"])
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testRectEdgeClassification() {
        let canvas = SIMD2<Float>(1080, 1920)
        func kinds(_ origin: SIMD2<Float>, _ size: SIMD2<Float>) -> [Diagnostic.Kind] {
            Inspector.rectDiagnostics(subject: "overlays[0]", what: "image",
                                      origin: origin, size: size, canvas: canvas).map(\.kind)
        }
        XCTAssertEqual(kinds(SIMD2(1000, 100), SIMD2(200, 100)), [.textClipped])
        XCTAssertEqual(kinds(SIMD2(980, 100), SIMD2(100, 100)), [])
        XCTAssertEqual(kinds(SIMD2(980.5, 100), SIMD2(100, 100)), [])
    }

    func testOffsetPastTheCanvasIsClampedAndNotReported() throws {
        let s = try spec(#""texts":[{"text":"Hi","fontName":"Helvetica","anchor":5,"offsetX":99999,"offsetY":-99999}]"#)
        XCTAssertEqual(Inspector.inspect(s).filter { $0.kind == .textClipped }, [])
    }

    func testUnknownEaseIsReportedOncePerTrack() throws {
        let s = try spec("""
        "texts":[{"text":"a","fontName":"Helvetica","animate":{
            "opacity":[{"t":0,"v":0},{"t":1,"v":1,"ease":"easeInn"},{"t":2,"v":0,"ease":"easeInn"}],
            "offsetY":[{"t":0,"v":0},{"t":1,"v":1,"ease":"easeInn"}]}}],
        "animate":{"grade":{"contrast":[{"t":0,"v":1,"ease":"easeInn"}]}}
        """)
        let found = Inspector.specDiagnostics(s).filter { $0.kind == .unknownEase }
        XCTAssertEqual(found.map(\.subject), ["texts[0].animate.opacity", "texts[0].animate.offsetY",
                                              "animate.grade.contrast"])
        XCTAssertEqual(found.first?.atSeconds, 1)
        XCTAssertTrue(found.allSatisfy { $0.severity == .error })
    }

    func testTransitionFieldsAreCheckedOnlyWhereTheEngineReadsThem() throws {
        func found(_ inputs: String) throws -> [Diagnostic] {
            let json = #"{"inputs":\#(inputs),"output":"/tmp/o.mp4","preset":"1080p"}"#
            return Inspector.specDiagnostics(try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8)))
        }
        let m = missing
        let first = try found(#"[{"path":"\#(m)","transition":{"type":"spin","ease":"wobble"}},{"path":"\#(m)"}]"#)
        XCTAssertEqual(first.map(\.kind), [.unknownTransition])
        XCTAssertEqual(first.map(\.subject), ["inputs[0].transition.type"])

        let last = try found(#"[{"path":"\#(m)"},{"path":"\#(m)","transition":{"type":"spin","ease":"wobble"}}]"#)
        XCTAssertEqual(last, [])

        let cut = try found(#"[{"path":"\#(m)","transition":{"type":"cut","ease":"wobble"}},{"path":"\#(m)"}]"#)
        XCTAssertEqual(cut, [])

        let ease = try found(#"[{"path":"\#(m)","transition":{"type":"crossfade","ease":"wobble"}},{"path":"\#(m)"}]"#)
        XCTAssertEqual(ease.map(\.kind), [.unknownEase])
        XCTAssertEqual(ease.map(\.subject), ["inputs[0].transition.ease"])
        XCTAssertTrue(ease.allSatisfy { $0.severity == .error })
    }

    func testWindowStartingAtOrAfterTheEndIsAWarning() throws {
        let s = try spec("""
        "texts":[{"text":"a","fontName":"Helvetica","startSeconds":20,"endSeconds":30},
                 {"text":"b","fontName":"Helvetica","startSeconds":19.9}],
        "overlays":[{"imagePath":"\(missing)","startSeconds":500}]
        """)
        let found = Inspector.timelineDiagnostics(s, outputSeconds: 20)
        XCTAssertEqual(subjects(found, .windowOutsideTimeline),
                       ["overlays[0].startSeconds", "texts[0].startSeconds"])
        XCTAssertTrue(found.allSatisfy { $0.severity == .warning })
    }

    func testKeyframeAfterTheEndIsOneWarningPerTrack() throws {
        let s = try spec("""
        "texts":[{"text":"a","fontName":"Helvetica","animate":{
            "opacity":[{"t":0,"v":0},{"t":25,"v":1},{"t":30,"v":0}],
            "offsetY":[{"t":0,"v":0},{"t":20,"v":10}]}}]
        """)
        let found = Inspector.timelineDiagnostics(s, outputSeconds: 20)
        XCTAssertEqual(found.map(\.kind), [.keyframeOutsideTimeline])
        XCTAssertEqual(found.first?.subject, "texts[0].animate.opacity")
        XCTAssertEqual(found.first?.atSeconds, 25)
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testEmptyWindowIsAnError() throws {
        let s = try spec("""
        "texts":[{"text":"a","fontName":"Helvetica","startSeconds":5,"endSeconds":5},
                 {"text":"b","fontName":"Helvetica","startSeconds":5,"endSeconds":6},
                 {"text":"c","fontName":"Helvetica","endSeconds":0},
                 {"text":"d","fontName":"Helvetica","endSeconds":0.5},
                 {"text":"e","fontName":"Helvetica","startSeconds":-5,"endSeconds":-2}],
        "overlays":[{"imagePath":"\(missing)","startSeconds":9,"endSeconds":2}]
        """)
        let found = Inspector.specDiagnostics(s).filter { $0.kind == .emptyWindow }
        XCTAssertEqual(found.map(\.subject), ["overlays[0]", "texts[0]", "texts[2]", "texts[4]"])
        XCTAssertTrue(found.allSatisfy { $0.severity == .error })
    }

    func testOverlappingTransitionShortensTheOutputTimeline() throws {
        let json = """
        {"inputs":[{"path":"a","transition":{"type":"crossfade","duration":0.5}},
                   {"path":"b","transition":{"type":"dipToBlack","duration":0.5}},{"path":"c"}],
         "output":"/tmp/o.mp4","preset":"1080p"}
        """
        let s = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        XCTAssertEqual(Inspector.outputSeconds(of: s, segmentSeconds: [10, 10, 10]), 29.5, accuracy: 1e-9)
    }

    func testUnknownTransitionTypeIsAHardCutOnTheTimeline() throws {
        let json = """
        {"inputs":[{"path":"a","transition":{"type":"spin","duration":0.5}},{"path":"b"}],
         "output":"/tmp/o.mp4","preset":"1080p"}
        """
        let s = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        XCTAssertEqual(Inspector.outputSeconds(of: s, segmentSeconds: [10, 10]), 20, accuracy: 1e-9)
    }

    func testRangeFaultsAreErrors() throws {
        let json = """
        {"inputs":[{"path":"a"},{"path":"b"}],"range":{"startSeconds":1,"endSeconds":2},
         "output":"/tmp/o.mp4","preset":"1080p"}
        """
        let playlist = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        XCTAssertEqual(Inspector.specDiagnostics(playlist).map(\.message),
                       ["range is not supported with inputs"])

        let backward = try spec("\"range\":{\"startSeconds\":5,\"endSeconds\":3}")
        XCTAssertEqual(subjects(Inspector.specDiagnostics(backward), .invalidRange), ["range"])

        let late = try spec("\"range\":{\"startSeconds\":25,\"endSeconds\":30}")
        XCTAssertEqual(Inspector.specDiagnostics(late), [])
        let found = Inspector.timelineDiagnostics(late, outputSeconds: 20)
        XCTAssertEqual(subjects(found, .invalidRange), ["range.startSeconds"])
        XCTAssertEqual(found.first?.severity, .error)

        let good = try spec("\"range\":{\"startSeconds\":8,\"endSeconds\":10}")
        XCTAssertEqual(Inspector.specDiagnostics(good) + Inspector.timelineDiagnostics(good, outputSeconds: 20), [])
    }

    func testSpecWithNoFaultHasNoPureDiagnostics() throws {
        let s = try spec("""
        "texts":[{"text":"Hello","fontName":"Helvetica","startSeconds":1,"endSeconds":6,"animate":{
            "opacity":[{"t":1,"v":0},{"t":2,"v":1,"ease":"cubicBezier(0.42,0,1,1)"}]}}]
        """)
        XCTAssertEqual(Inspector.specDiagnostics(s), [])
        XCTAssertEqual(Inspector.timelineDiagnostics(s, outputSeconds: 20), [])
    }

    func testDiagnosticEncodesAsJSONWithoutNilTime() throws {
        let d = Diagnostic(.fontFallback, .warning, subject: "texts[0].fontName", message: "m")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: String]
        XCTAssertEqual(json, ["kind": "fontFallback", "severity": "warning",
                              "subject": "texts[0].fontName", "message": "m"])
    }
}
