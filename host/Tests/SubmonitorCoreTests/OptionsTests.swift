import SubmonitorCore
import XCTest

final class OptionsTests: XCTestCase {
    func testDefaults() throws {
        XCTAssertEqual(try Options.parse([]), Options())
        XCTAssertEqual(Options().fps, 120); XCTAssertEqual(Options().bitrate, "40M"); XCTAssertNil(Options().apkPath)
    }

    func testParsesFlags() throws {
        let o = try Options.parse(["--fps", "60", "--bitrate", "30M", "--apk", "a.apk"])
        XCTAssertEqual(o.fps, 60); XCTAssertEqual(o.bitrate, "30M"); XCTAssertEqual(o.apkPath, "a.apk")
    }

    func testRejectsUnknownFlagAndBadFps() {
        XCTAssertThrowsError(try Options.parse(["--nope"]))
        XCTAssertThrowsError(try Options.parse(["--fps", "abc"]))
        XCTAssertThrowsError(try Options.parse(["--fps"])) // 값 없음
        XCTAssertThrowsError(try Options.parse(["--bitrate", "fast"]))
    }

    func testBitrateUnits() {
        XCTAssertEqual(parseBitrate("40M"), 40_000_000)
        XCTAssertEqual(parseBitrate("500k"), 500_000)
        XCTAssertEqual(parseBitrate("8000000"), 8_000_000)
        XCTAssertNil(parseBitrate("0"))
        XCTAssertNil(parseBitrate("M"))
        XCTAssertEqual(Options().bitsPerSecond, 40_000_000)
    }
}
