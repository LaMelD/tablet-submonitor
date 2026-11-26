import Foundation

// 탭의 FlvReader가 읽는 Enhanced FLV(HEVC, fourcc hvc1). 태그마다 크기가 붙어 있어 탭이 프레임 경계를 바로 안다.
// 본문 첫 바이트 = 0x80(확장 헤더) | 프레임 종류<<4 (1 키, 2 일반) | 패킷 종류 (0 SequenceStart, 3 CodedFramesX)

/// FLV 헤더(비디오만) + PreviousTagSize0
public func flvHeader() -> Data {
    Data([0x46, 0x4C, 0x56, 1, 0x01, 0, 0, 0, 9, 0, 0, 0, 0])
}

/// 디코더 설정(hvcC). 탭은 이걸 받으면 디코더를 새로 만든다.
public func flvSequenceStartTag(hvcC: Data) -> Data {
    flvVideoTag(Data([0x90]) + Data("hvc1".utf8) + hvcC, timestampMs: 0)
}

/// 프레임 하나. data는 VideoToolbox 출력 그대로(4바이트 길이 접두 NAL). B프레임이 없으니 CTS 없는 CodedFramesX를 쓴다.
public func flvFrameTag(_ data: Data, timestampMs: UInt32, key: Bool) -> Data {
    flvVideoTag(Data([key ? 0x93 : 0xA3]) + Data("hvc1".utf8) + data, timestampMs: timestampMs)
}

private func flvVideoTag(_ body: Data, timestampMs ts: UInt32) -> Data {
    let n = UInt32(body.count)
    var tag = Data([9, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF),
                    UInt8(ts >> 16 & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts & 0xFF), UInt8(ts >> 24), 0, 0, 0])
    tag.reserveCapacity(tag.count + body.count + 4)
    tag += body
    let prev = 11 + n
    tag += Data([UInt8(prev >> 24), UInt8(prev >> 16 & 0xFF), UInt8(prev >> 8 & 0xFF), UInt8(prev & 0xFF)])
    return tag
}
