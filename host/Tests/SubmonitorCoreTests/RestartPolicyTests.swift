import SubmonitorCore
import XCTest

final class RestartPolicyTests: XCTestCase {
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

    // 오래 돈 뒤의 중단은 바로 다시 시작한다
    func testRestartPolicyResetsAfterHealthyRun() {
        var p = RestartPolicy()
        _ = p.onExit(runDuration: 0.5); _ = p.onExit(runDuration: 0.5)
        XCTAssertEqual(p.onExit(runDuration: 30).delay, 0.3, accuracy: 1e-9)
        XCTAssertEqual(p.onExit(runDuration: 0.5).delay, 0.3, accuracy: 1e-9)
    }
}
