import CoreMedia
import CoreVideo
import SubmonitorCore
import XCTest

final class HEVCEncoderTests: XCTestCase {
    // 탭 디코더는 hvcC(Config)를 먼저 받고 키프레임부터 디코딩한다. 접속 직후 강제 키프레임이 hvcC와 함께 나와야 한다
    func testForcedKeyFrameCarriesHvcCAndLengthPrefixedNals() throws {
        let enc = try HEVCEncoder(width: 640, height: 400, fps: 60, bitsPerSecond: 8_000_000)
        let first = try encode(enc, frame: 0, forceKey: true)
        XCTAssertTrue(first.isKey)
        let hvcC = try XCTUnwrap(first.hvcC)
        XCTAssertEqual(hvcC.first, 1, "configurationVersion")
        XCTAssertEqual(hvcC[hvcC.startIndex + 21] & 3, 3, "NAL 길이 필드 4바이트")
        let types = try nalTypes(first.data)
        XCTAssertTrue(types.contains { (16...21).contains($0) }, "IRAP NAL이 있어야 한다: \(types)")
        let second = try encode(enc, frame: 1, forceKey: false)
        XCTAssertFalse(second.isKey)
        XCTAssertNil(second.hvcC)
        _ = try nalTypes(second.data)
    }

    private func encode(_ enc: HEVCEncoder, frame: Int, forceKey: Bool) throws -> EncodedFrame {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), Int32(16 + frame * 40),
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let done = expectation(description: "encoded \(frame)")
        var out: EncodedFrame?
        enc.encode(buffer, pts: CMTime(value: CMTimeValue(frame), timescale: 60), forceKey: forceKey) { out = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(out)
    }

    /// 4바이트 길이 접두 NAL을 끝까지 정확히 나눌 수 있는지 확인하고 NAL 타입 목록을 돌려준다.
    private func nalTypes(_ d: Data) throws -> [Int] {
        let b = [UInt8](d)
        var p = 0, types: [Int] = []
        while p < b.count {
            XCTAssertLessThanOrEqual(p + 4, b.count)
            let len = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4
            guard len > 0, p + len <= b.count else { throw POSIXError(.EBADMSG) }
            types.append(Int(b[p] >> 1) & 0x3F)
            p += len
        }
        return types
    }
}
