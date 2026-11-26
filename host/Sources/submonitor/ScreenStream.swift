import CoreMedia
import Foundation
import ScreenCaptureKit
import SubmonitorCore

/// 가상 디스플레이를 ScreenCaptureKit으로 캡처 → HEVC 인코딩 → FLV로 탭에 보낸다.
/// FFmpeg(avfoundation)는 macOS가 레거시 캡처로 다뤄 30초마다 캡처 표시를 지웠다 다시 띄웠다("터미널이 화면을 캡처하는 중").
/// 화면이 바뀔 때만 프레임이 온다. 언제 인코딩할지는 FrameScheduler가 정한다.
///
/// 설정은 탭에서 화면 전체를 계속 움직이는 시험으로 골랐다(같은 시험에서 FFmpeg: 71~79fps, 밀림 평균 36~58ms):
/// - 인코딩+전송 중 최대 2장: 약 70fps, 밀림 평균 25~27ms. 4장이면 98fps지만 밀림 평균 36ms, 최악 228ms.
/// - 화면이 바뀐 뒤 1초 동안은 마지막 프레임을 계속 다시 넣는다. 바뀔 때만 넣으면 인코더가 멈춘 동안 쌓인
///   비트 예산을 한 장에 몰아 2MB대 프레임을 만들어 8fps까지 떨어졌다. 움직임이 멈춘 뒤 화질도 다시 올라온다.
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let refreshWindow = 1.0
    private static let maxInflight = 2

    /// 사용자가 메뉴 막대에서 화면 공유를 멈췄을 때(메인 큐)
    var onUserStopped: (() -> Void)?

    private let displayID: CGDirectDisplayID
    private let width: Int, height: Int, fps: Int
    private let encoder: HEVCEncoder
    private let server: VideoServer
    private let queue = DispatchQueue(label: "submonitor.stream", qos: .userInteractive)
    private var policy = RestartPolicy()
    private var stream: SCStream?
    private var startedAt = Date()

    // 아래는 queue에서만
    private lazy var scheduler = FrameScheduler<(buffer: CVPixelBuffer, pts: CMTime)>(maxInflight: Self.maxInflight) { [unowned self] f, key, s in
        submit(f.buffer, captured: f.pts, forceKey: key, session: s)
    }
    private var lastSubmitted = CMTime.negativeInfinity
    private var session = 0
    private var sentHvcC: Data?
    private var basePts: Double?
    private var latest: CVPixelBuffer?
    private var latestAt = -Double.infinity
    private lazy var refreshTimer: DispatchSourceTimer = {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [unowned self] in refresh() }
        return t
    }()

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, bitsPerSecond: Int, server: VideoServer) throws {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.server = server
        encoder = try HEVCEncoder(width: width, height: height, fps: fps, bitsPerSecond: bitsPerSecond)
        super.init()
        server.onConnect = { [weak self] s in self?.queue.async { self?.connected(s) } }
        queue.async { self.refreshTimer.resume() } // 한 번만(캡처 재시작 때 다시 resume하면 죽는다)
    }

    func start() { Task { await startCapture() } }

    /// 화면이 바뀐 뒤 refreshWindow 동안은 새 프레임이 없어도 마지막 프레임을 지금 시각으로 다시 넣는다.
    private func refresh() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let buffer = latest, now.seconds - latestAt < Self.refreshWindow else { return }
        scheduler.captured((buffer, now))
    }

    /// 종료 시 캡처를 멈춘다(최대 1초 기다림).
    func stop() {
        guard let s = stream else { return }
        let done = DispatchSemaphore(value: 0)
        s.stopCapture { _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NSError(domain: "submonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "가상 디스플레이를 캡처 목록에서 찾지 못했습니다"])
            }
            let cfg = SCStreamConfiguration()
            cfg.width = width
            cfg.height = height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2 // 인코더 색 정보(BT.709)와 맞춘다
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.showsCursor = false // 커서는 탭이 따로 그린다
            cfg.queueDepth = 5      // 인코딩 2장 + 보관 1장 + 여유
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            startedAt = Date()
        } catch {
            restartLater(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if isUserStoppedCapture(error) {
            DispatchQueue.main.async { self.onUserStopped?() }
            return
        }
        restartLater(error)
    }

    private func restartLater(_ error: Error) {
        let decision = policy.onExit(runDuration: Date().timeIntervalSince(startedAt))
        if decision.reportError { print("화면 캡처가 연달아 멈춥니다. 계속 재시도합니다: \(error.localizedDescription)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + decision.delay) { self.start() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        latest = buffer
        latestAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        scheduler.captured((buffer, CMSampleBufferGetPresentationTimeStamp(sample)))
    }

    private func connected(_ s: Int) {
        session = s
        sentHvcC = nil
        basePts = nil
        server.send(flvHeader(), session: s)
        scheduler.connected(session: s)
    }

    private func submit(_ buffer: CVPixelBuffer, captured: CMTime, forceKey: Bool, session s: Int) {
        // 같은 프레임을 다시 인코딩할 때(재접속 키프레임)도 시각은 늘어나야 한다
        let pts = CMTimeMaximum(captured, CMTimeAdd(lastSubmitted, CMTime(value: 1, timescale: 1000)))
        lastSubmitted = pts
        encoder.encode(buffer, pts: pts, forceKey: forceKey) { [weak self] frame in
            self?.queue.async { self?.encoded(frame, session: s) }
        }
    }

    private func encoded(_ frame: EncodedFrame?, session s: Int) {
        guard s == session else { scheduler.finished(session: s); return }
        guard let frame else { scheduler.finished(session: s, needKeyAgain: true); return } // 인코딩 실패
        var out = Data()
        if let h = frame.hvcC, h != sentHvcC {
            out += flvSequenceStartTag(hvcC: h)
            sentHvcC = h
        }
        guard sentHvcC != nil else { scheduler.finished(session: s, needKeyAgain: true); return } // 설정보다 일반 프레임이 먼저 가지 않게
        let base = basePts ?? frame.ptsSeconds
        basePts = base
        out += flvFrameTag(frame.data, timestampMs: UInt32(max(0, (frame.ptsSeconds - base) * 1000)), key: frame.isKey)
        server.send(out, session: s) { [weak self] ok in
            self?.queue.async {
                if !ok { self?.scheduler.disconnected(session: s) } // 끊긴 연결에는 더 인코딩하지 않는다
                self?.scheduler.finished(session: s)
            }
        }
    }
}
