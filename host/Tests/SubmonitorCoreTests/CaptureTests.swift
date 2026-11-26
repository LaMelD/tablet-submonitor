import SubmonitorCore
import XCTest

final class CaptureTests: XCTestCase {
    func testScreenDeviceNameUsesActiveDisplayIndex() {
        XCTAssertEqual(screenDeviceName(for: 7, activeDisplays: [1, 7]), "Capture screen 1")
        XCTAssertNil(screenDeviceName(for: 9, activeDisplays: [1, 7]))
    }

    func testFFmpegArgumentsPinLatencyCriticalOptions() {
        let a = ffmpegArguments(screenDevice: "Capture screen 1", fps: 120, bitrate: "40M")
        assertPair(a, "-f", "avfoundation"); assertPair(a, "-capture_cursor", "0")
        assertPair(a, "-framerate", "120"); assertPair(a, "-i", "Capture screen 1:none")
        assertPair(a, "-c:v", "hevc_videotoolbox"); assertPair(a, "-realtime", "1"); assertPair(a, "-bf", "0")
        assertPair(a, "-b:v", "40M"); assertPair(a, "-flush_packets", "1"); assertPair(a, "-f", "flv")
        // 호스트가 연 사용자 전용 소켓이 표준 출력으로 연결된다. FFmpeg가 직접 포트나 소켓을 열지 않는다
        XCTAssertEqual(a.last, "pipe:1")
        XCTAssertFalse(a.contains("-listen"))
        // 비정상 종료로 남은 FFmpeg를 다음 실행 때 찾아 끄기 위한 표식
        assertPair(a, "-metadata", "comment=\(ffmpegMarker)")
    }

    // 리뷰 Important: 빠른 종료가 이어져도 호스트를 끝내지 않는다(탭 재접속이 잦을 때 권한 문제로 오인했다).
    // 대신 점점 늦게 재시도하고, 연속 3번째에 한 번만 오류를 보여준다. 권한은 시작할 때 따로 확인한다.
    func testRestartPolicyBacksOffOnFastFailures() {
        var p = RestartPolicy()
        let delays = (0..<7).map { _ in p.onExit(runDuration: 0.5).delay }
        for (got, want) in zip(delays, [0.3, 0.6, 1.2, 2.4, 4.8, 5, 5]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
    }

    func testRestartPolicyReportsOncePerStreak() {
        var p = RestartPolicy()
        XCTAssertEqual((0..<5).map { _ in p.onExit(runDuration: 0.5).reportError }, [false, false, true, false, false])
    }

    // 탭 앱이 연결을 끊으면 FFmpeg가 종료된다. 오래 돈 뒤의 종료는 바로 재시작한다
    func testRestartPolicyResetsAfterHealthyRun() {
        var p = RestartPolicy()
        _ = p.onExit(runDuration: 0.5); _ = p.onExit(runDuration: 0.5)
        XCTAssertEqual(p.onExit(runDuration: 30).delay, 0.3, accuracy: 1e-9)
        XCTAssertEqual(p.onExit(runDuration: 0.5).delay, 0.3, accuracy: 1e-9)
    }

    /// args 안 어딘가에 [flag, value]가 연속으로 있는지 확인한다.
    private func assertPair(_ args: [String], _ flag: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = zip(args, args.dropFirst()).contains { $0 == flag && $1 == value }
        XCTAssertTrue(found, "\(flag) \(value) 없음: \(args)", file: file, line: line)
    }
}
