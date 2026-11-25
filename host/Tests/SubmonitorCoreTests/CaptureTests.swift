import SubmonitorCore
import XCTest

final class CaptureTests: XCTestCase {
    func testScreenDeviceNameUsesActiveDisplayIndex() {
        XCTAssertEqual(screenDeviceName(for: 7, activeDisplays: [1, 7]), "Capture screen 1")
        XCTAssertNil(screenDeviceName(for: 9, activeDisplays: [1, 7]))
    }

    func testFFmpegArgumentsPinLatencyCriticalOptions() {
        let a = ffmpegArguments(screenDevice: "Capture screen 1", fps: 120, bitrate: "40M", socketPath: "/tmp/u/video.sock")
        assertPair(a, "-f", "avfoundation"); assertPair(a, "-capture_cursor", "0")
        assertPair(a, "-framerate", "120"); assertPair(a, "-i", "Capture screen 1:none")
        assertPair(a, "-c:v", "hevc_videotoolbox"); assertPair(a, "-realtime", "1"); assertPair(a, "-bf", "0")
        assertPair(a, "-b:v", "40M"); assertPair(a, "-flush_packets", "1"); assertPair(a, "-f", "flv")
        // 보안: 다른 프로세스가 화면을 받아가지 못하게 사용자 전용 디렉터리의 유닉스 소켓으로만 송출한다
        assertPair(a, "-listen", "1")
        XCTAssertEqual(a.last, "unix:/tmp/u/video.sock")
    }

    // Review Focus 4: 권한이 없어 FFmpeg가 바로 죽으면 무한 재시작하지 않는다
    func testRestartPolicyGivesUpAfterThreeFastFailures() {
        var p = RestartPolicy()
        XCTAssertEqual(p.onExit(runDuration: 0.5), .restart)
        XCTAssertEqual(p.onExit(runDuration: 0.5), .restart)
        XCTAssertEqual(p.onExit(runDuration: 0.5), .giveUp)
    }

    // 탭 앱이 연결을 끊으면 FFmpeg가 종료된다. 오래 돈 뒤의 종료는 정상 재시작이다
    func testRestartPolicyResetsAfterHealthyRun() {
        var p = RestartPolicy()
        _ = p.onExit(runDuration: 0.5); _ = p.onExit(runDuration: 0.5)
        XCTAssertEqual(p.onExit(runDuration: 30), .restart)
        XCTAssertEqual(p.onExit(runDuration: 0.5), .restart)
    }

    /// args 안 어딘가에 [flag, value]가 연속으로 있는지 확인한다.
    private func assertPair(_ args: [String], _ flag: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
        XCTAssertTrue(found, "\(flag) \(value) 없음: \(args)", file: file, line: line)
    }
}
