import Foundation
import SubmonitorCore
import XCTest

// 탭의 FlvReader(Kotlin)가 읽는 Enhanced FLV. 기존에 FFmpeg가 내보내던 것과 같은 형식이어야 탭 앱을 바꾸지 않아도 된다.
final class FlvTests: XCTestCase {
    func testHeaderIsVideoOnlyFlvWithZeroPreviousTagSize() {
        XCTAssertEqual([UInt8](flvHeader()), [0x46, 0x4C, 0x56, 1, 0x01, 0, 0, 0, 9, 0, 0, 0, 0])
    }

    func testSequenceStartTagCarriesHvcC() {
        let hvcC = Data([1, 2, 3])
        let t = [UInt8](flvSequenceStartTag(hvcC: hvcC))
        let bodySize = 1 + 4 + 3
        XCTAssertEqual(t[0], 9)                                   // 비디오 태그
        XCTAssertEqual(Array(t[1..<4]), [0, 0, UInt8(bodySize)])   // 본문 크기
        XCTAssertEqual(Array(t[4..<11]), [0, 0, 0, 0, 0, 0, 0])   // 시각 0, 스트림 id 0
        XCTAssertEqual(t[11], 0x90)                                // 확장 헤더 | 키프레임 | SequenceStart
        XCTAssertEqual(Array(t[12..<16]), Array("hvc1".utf8))
        XCTAssertEqual(Array(t[16..<19]), [1, 2, 3])
        XCTAssertEqual(Array(t[19...]), [0, 0, 0, UInt8(11 + bodySize)]) // PreviousTagSize
    }

    func testFrameTagsMarkKeyFramesAndUseCodedFramesX() {
        let key = [UInt8](flvFrameTag(Data([0, 0, 0, 1, 0x26]), timestampMs: 0x0102_0304, key: true))
        XCTAssertEqual(Array(key[4..<8]), [0x02, 0x03, 0x04, 0x01]) // 하위 24비트 + 상위 8비트
        XCTAssertEqual(key[11], 0x93)                                 // 키프레임 | CodedFramesX(3)
        XCTAssertEqual(Array(key[16..<21]), [0, 0, 0, 1, 0x26])       // 길이 접두 NAL 그대로
        let inter = [UInt8](flvFrameTag(Data([0, 0, 0, 1, 0x02]), timestampMs: 33, key: false))
        XCTAssertEqual(inter[11], 0xA3)                               // 일반 프레임 | CodedFramesX
        XCTAssertEqual(Array(inter[4..<8]), [0, 0, 33, 0])
    }
}
