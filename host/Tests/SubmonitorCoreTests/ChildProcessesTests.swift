import Foundation
import SubmonitorCore
import XCTest

final class ChildProcessesTests: XCTestCase {
    // 버그: adb wait-for-disconnect는 별도 프로세스 그룹이라 Ctrl-C가 닿지 않고, 호스트가 끝나도 남아 실행할 때마다 쌓였다
    func testTerminateAllStopsRunningChildren() throws {
        let children = ChildProcesses()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try children.run(p)
        children.terminateAll()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        XCTAssertFalse(p.isRunning)
        XCTAssertTrue(children.terminating, "종료 중에 끊긴 adb를 오류로 출력하지 않게 알 수 있어야 한다")
    }

    func testFinishedChildIsForgotten() throws {
        let children = ChildProcesses()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try children.run(p)
        p.waitUntilExit()
        children.finished(p)
        XCTAssertEqual(children.count, 0)
    }
}
