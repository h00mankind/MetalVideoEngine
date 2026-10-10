import XCTest
@testable import MetalVideoEngine

final class EasingTests: XCTestCase {
    func testCubicBezierEaseInMatchesCSS() throws {
        let ease = try XCTUnwrap(Easing.parse("cubicBezier(0.42,0,1,1)"))
        let expected: [(Float, Float)] = [(0.25, 0.093), (0.5, 0.315), (0.75, 0.622)]
        for (u, want) in expected {
            XCTAssertEqual(ease.apply(u), want, accuracy: 0.001, "u=\(u)")
        }
    }

    func testCurrentEasingsKeepTheirValues() throws {
        let us: [Float] = [0.25, 0.5, 0.75]
        let expected: [(String, [Float])] = [
            ("linear",    [0.25, 0.5, 0.75]),
            ("easeIn",    [0.015625, 0.125, 0.421875]),
            ("easeOut",   [0.578125, 0.875, 0.984375]),
            ("easeInOut", [0.0625, 0.5, 0.9375]),
            ("hold",      [0, 0, 0]),
        ]
        for (name, values) in expected {
            let ease = try XCTUnwrap(Easing.parse(name), name)
            for (u, want) in zip(us, values) {
                XCTAssertEqual(ease.apply(u), want, accuracy: 1e-6, "\(name) u=\(u)")
            }
        }
    }

    func testEndpointsIdentityAndParseFailures() throws {
        let identity = try XCTUnwrap(Easing.parse("cubicBezier(0,0,1,1)"))
        for u in stride(from: Float(0), through: 1, by: 0.125) {
            XCTAssertEqual(identity.apply(u), u, accuracy: 1e-5, "u=\(u)")
        }

        let curves = ["linear", "easeIn", "easeOut", "easeInOut",
                      "cubicBezier(0.42,0,1,1)", "cubicBezier(0.34, 1.56, 0.64, 1)",
                      "cubicBezier(2,0,-1,1)"]
        for name in curves {
            let ease = try XCTUnwrap(Easing.parse(name), name)
            XCTAssertEqual(ease.apply(0), 0, name)
            XCTAssertEqual(ease.apply(1), 1, name)
        }

        for bad in ["easeInn", "", "cubicBezier(1,2)", "cubicBezier(a,b,c,d)",
                    "cubicBezier(0,0,1,1,1)", "cubicBezier(0,0,1,nan)", "cubicBezier(0,0,1,1"] {
            XCTAssertNil(Easing.parse(bad), bad)
        }
    }
}
