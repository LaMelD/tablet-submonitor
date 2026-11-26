import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct EncodedFrame {
    /// 4바이트 길이 접두 NAL들(VideoToolbox 출력 그대로)
    public let data: Data
    /// 키프레임일 때 디코더 설정(hvcC 레코드)
    public let hvcC: Data?
    public let ptsSeconds: Double
    public let isKey: Bool
}

public struct EncoderError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "HEVC 인코더를 만들지 못했습니다 (OSStatus \(status))" }
}

/// VideoToolbox 하드웨어 HEVC 인코더. 2960x1848 실측(M3 Pro): 저지연 전용 모드(LowLatencyRateControl)는 43fps에서
/// 막혔고, 일반 실시간 모드 + 속도 우선이 빨랐다. 동시 처리 수 제한은 호출하는 쪽(ScreenStream)이 한다.
public final class HEVCEncoder {
    private let session: VTCompressionSession

    public init(width: Int, height: Int, fps: Int, bitsPerSecond: Int) throws {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw EncoderError(status: st) }
        session = s
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // B프레임 없음
        set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue) // FFmpeg -prio_speed 1과 같다
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber) // 출력 전에 프레임을 붙잡지 않는다
        // 주기적 키프레임은 큰 프레임을 만들어 순간 끊김이 된다. 접속할 때만 강제로 넣는다(전송은 손실 없는 소켓).
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600 as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// 완료는 VideoToolbox 스레드에서 불린다. 실패하면 nil.
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKey: Bool, completion: @escaping (EncodedFrame?) -> Void) {
        let props = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                 duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let frame = Self.frame(from: sample) else { completion(nil); return }
            completion(frame)
        }
        if st != noErr { completion(nil) }
    }

    private static func frame(from sample: CMSampleBuffer) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        let data = Data(bytes: pointer, count: length) // 블록이 여러 조각이면 아래에서 다시 복사
        let full = data.count == CMBlockBufferGetDataLength(block) ? data : copyAll(block)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        var hvcC: Data?
        if !notSync, let fd = CMSampleBufferGetFormatDescription(sample),
           let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
            hvcC = atoms["hvcC"] as? Data
        }
        return EncodedFrame(data: full, hvcC: hvcC, ptsSeconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds, isKey: !notSync)
    }

    private static func copyAll(_ block: CMBlockBuffer) -> Data {
        var d = Data(count: CMBlockBufferGetDataLength(block))
        d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        return d
    }
}
