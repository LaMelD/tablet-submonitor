import CoreGraphics
import Foundation
import SubmonitorCore
import XCTest

/// 이 바이트 배열 셋은 Android CursorProtocolTest에도 똑같이 들어간다. 두 언어 사이의 계약이다.
let displayBytes: [UInt8] = [0x01, 0, 0, 0, 8, 0x44, 0xB9, 0, 0, 0x44, 0x67, 0, 0]
let positionBytes: [UInt8] = [0x02, 0, 0, 0, 9, 0x3F, 0xC0, 0, 0, 0x40, 0x00, 0, 0, 0x01]
let shapeBytes: [UInt8] = [0x03, 0, 0, 0, 0x12, 0x40, 0x80, 0, 0, 0x40, 0x80, 0, 0, 0x41, 0x80, 0, 0, 0x41, 0x80, 0, 0, 0xAA, 0xBB]

final class CursorMessageTests: XCTestCase {
    func testEncodesGoldenBytes() {
        XCTAssertEqual([UInt8](CursorMessage.display(width: 1480, height: 924).encoded()), displayBytes)
        XCTAssertEqual([UInt8](CursorMessage.position(x: 1.5, y: 2, visible: true).encoded()), positionBytes)
        XCTAssertEqual([UInt8](CursorMessage.shape(hotX: 4, hotY: 4, width: 16, height: 16, png: Data([0xAA, 0xBB])).encoded()), shapeBytes)
    }

    // Review Focus 3: 경계
    func testCursorPositionRelativeToDisplayAndHiddenOutside() {
        let b = CGRect(x: 1512, y: 0, width: 1480, height: 924) // 메인 화면 오른쪽에 붙은 가상 디스플레이
        let inside = cursorPosition(global: CGPoint(x: 1512 + 10, y: 20), displayBounds: b)
        XCTAssertEqual(inside.x, 10); XCTAssertEqual(inside.y, 20); XCTAssertTrue(inside.visible)
        XCTAssertTrue(cursorPosition(global: CGPoint(x: 1512, y: 0), displayBounds: b).visible) // 왼쪽 위 모서리는 안
        XCTAssertFalse(cursorPosition(global: CGPoint(x: 1511.5, y: 20), displayBounds: b).visible) // 메인 화면 쪽
        XCTAssertFalse(cursorPosition(global: CGPoint(x: 1512 + 1480, y: 20), displayBounds: b).visible) // 오른쪽 끝은 밖
    }
}
