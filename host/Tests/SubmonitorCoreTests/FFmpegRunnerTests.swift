import Foundation
import SubmonitorCore
import XCTest

final class FFmpegRunnerTests: XCTestCase {
    // 리뷰 Critical: EOF 뒤에도 readabilityHandler가 빈 데이터로 계속 불려 CPU 코어를 태웠다
    func testTextReaderStopsAtEOF() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "echo boom >&2"]
        let pipe = Pipe()
        p.standardError = pipe
        let got = expectation(description: "text")
        attachTextReader(pipe.fileHandleForReading) { if $0.contains("boom") { got.fulfill() } }
        try p.run()
        p.waitUntilExit()
        wait(for: [got], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while pipe.fileHandleForReading.readabilityHandler != nil, Date() < deadline { usleep(10_000) }
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "EOF 뒤에는 핸들러가 지워져야 한다")
    }

    // 리뷰 Important: 재시작 때마다 화면 번호를 다시 계산해야 한다(디스플레이 순서가 바뀔 수 있음)
    func testRunnerRecomputesArgumentsOnEveryLaunch() {
        let launched = expectation(description: "3 launches")
        launched.expectedFulfillmentCount = 3
        launched.assertForOverFulfill = false
        let runner = FFmpegRunner(executable: "/bin/sh", prefixArguments: [],
                                  makeArguments: { launched.fulfill(); return ["-c", "exit 1"] },
                                  socketPath: NSTemporaryDirectory() + "runner-test-1.sock",
                                  onRepeatedFailure: { _ in })
        runner.start()
        wait(for: [launched], timeout: 5)
        runner.stop()
    }

    func testRunnerReportsStderrAfterRepeatedFastFailures() {
        let reported = expectation(description: "report")
        var tail = ""
        let runner = FFmpegRunner(executable: "/bin/sh", prefixArguments: [],
                                  makeArguments: { ["-c", "echo boom >&2; exit 1"] },
                                  socketPath: NSTemporaryDirectory() + "runner-test-2.sock",
                                  onRepeatedFailure: { tail = $0; reported.fulfill() })
        runner.start()
        wait(for: [reported], timeout: 5)
        runner.stop()
        XCTAssertTrue(tail.contains("boom"), tail)
    }
}
