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

public enum RestartDecision: Equatable { case restart, giveUp }

/// 짧게 죽는 일이 연달아 생기면(권한 없음 등) 포기한다. 오래 돈 뒤의 종료(탭 연결 끊김)는 정상 재시작.
public struct RestartPolicy {
    let minHealthyRun: TimeInterval
    let maxFastFailures: Int
    var fastFailures = 0

    public init(minHealthyRun: TimeInterval = 2, maxFastFailures: Int = 3) {
        self.minHealthyRun = minHealthyRun
        self.maxFastFailures = maxFastFailures
    }

    public mutating func onExit(runDuration: TimeInterval) -> RestartDecision {
        fastFailures = runDuration < minHealthyRun ? fastFailures + 1 : 0
        return fastFailures >= maxFastFailures ? .giveUp : .restart
    }
}
