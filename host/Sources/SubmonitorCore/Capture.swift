import Foundation

/// FFmpeg avfoundation은 CGGetActiveDisplayList 순서로 화면 번호를 매긴다.
public func screenDeviceName(for displayID: UInt32, activeDisplays: [UInt32]) -> String? {
    activeDisplays.firstIndex(of: displayID).map { "Capture screen \($0)" }
}

/// 송출은 사용자 전용 디렉터리($TMPDIR, 0700)의 유닉스 소켓으로만 한다. TCP로 열면 화면 기록 권한 없는 로컬 프로세스도 화면을 받아갈 수 있다.
public func ffmpegArguments(screenDevice: String, fps: Int, bitrate: String, socketPath: String) -> [String] {
    [
        "-hide_banner", "-loglevel", "warning",
        "-f", "avfoundation", "-capture_cursor", "0", "-framerate", "\(fps)", "-pixel_format", "nv12",
        "-i", "\(screenDevice):none",
        "-c:v", "hevc_videotoolbox", "-realtime", "1", "-prio_speed", "1", "-bf", "0",
        "-g", "\(fps * 10)", "-b:v", bitrate,
        "-flush_packets", "1", "-f", "flv", "-listen", "1", "unix:\(socketPath)",
    ]
}

public struct RestartDecision: Equatable {
    public let delay: TimeInterval
    /// 빠른 종료가 연속 reportAfter번째일 때 한 번만 true (오류를 사용자에게 보여줄 시점)
    public let reportError: Bool
}

/// 빠른 종료(minHealthyRun 미만)가 이어지면 재시작 간격을 두 배씩 늘린다(최대 maxDelay). 포기하지 않는다:
/// 탭 재접속이 잦은 것도 빠른 종료로 보이기 때문이다. 화면 기록 권한은 시작할 때 따로 확인한다.
public struct RestartPolicy {
    let minHealthyRun: TimeInterval
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let reportAfter: Int
    var fastFailures = 0

    public init(minHealthyRun: TimeInterval = 2, baseDelay: TimeInterval = 0.3, maxDelay: TimeInterval = 5, reportAfter: Int = 3) {
        self.minHealthyRun = minHealthyRun
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.reportAfter = reportAfter
    }

    public mutating func onExit(runDuration: TimeInterval) -> RestartDecision {
        fastFailures = runDuration < minHealthyRun ? fastFailures + 1 : 0
        let delay = fastFailures == 0 ? baseDelay : min(baseDelay * pow(2, Double(fastFailures - 1)), maxDelay)
        return RestartDecision(delay: delay, reportError: fastFailures == reportAfter)
    }
}
