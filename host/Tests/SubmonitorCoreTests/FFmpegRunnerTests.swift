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

    // 리뷰 Important: 실행할 때마다 화면 번호를 다시 계산해야 한다(디스플레이 순서가 바뀔 수 있음)
    func testLaunchesPerConnectionWithFreshArguments() throws {
        var launches = 0
        let runner = try makeRunner("fresh") { launches += 1; return ["-c", "printf launch\(launches)"] }
        defer { runner.stop() }
        XCTAssertEqual(launches, 0, "탭이 접속하기 전에는 캡처하지 않는다")
        XCTAssertEqual(readAll(try connectClient("fresh")), "launch1")
        XCTAssertEqual(readAll(try connectClient("fresh")), "launch2")
    }

    // 버벅임의 원인: macOS 유닉스 소켓 기본 버퍼(8KB)로는 adb 경유 전송이 6MB/s에서 막혔다(256KB면 33MB/s).
    // 탭이 읽지 않아도 큰 프레임 하나(200KB)는 막히지 않고 써져야 한다.
    func testSocketBufferHoldsLargeFrame() throws {
        let marker = NSTemporaryDirectory() + "submonitor-test-marker-\(getpid())"
        unlink(marker)
        let runner = try makeRunner("buffer") { ["-c", "head -c 200000 /dev/zero && touch '\(marker)'; sleep 5"] }
        defer { runner.stop(); unlink(marker) }
        let fd = try connectClient("buffer")
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "200KB 쓰기가 소켓 버퍼에서 막혔다")
    }

    func testNewConnectionReplacesOldOne() throws {
        let runner = try makeRunner("replace") { ["-c", "printf x; exec sleep 30"] }
        defer { runner.stop() }
        let old = try connectClient("replace")
        var byte: UInt8 = 0
        XCTAssertEqual(read(old, &byte, 1), 1)
        let new = try connectClient("replace")
        defer { close(new) }
        XCTAssertEqual(readAll(old), "", "옛 연결은 끊겨야 한다")
        XCTAssertEqual(read(new, &byte, 1), 1)
    }

    // 탭이 읽기를 멈춘 채 빠지면 FFmpeg가 쓰기에서 막혀 TERM에 응답하지 않을 수 있다. Ctrl-C가 멈추면 안 된다
    func testStopKillsChildIgnoringTerm() throws {
        let runner = try makeRunner("stubborn") { ["-c", "trap '' TERM; printf x; while :; do sleep 1; done"] }
        let fd = try connectClient("stubborn")
        defer { close(fd) }
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 1)
        let started = Date()
        runner.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // 보안: 다른 사용자가 화면을 받아가지 못하게
    func testSocketIsUserOnly() throws {
        let runner = try makeRunner("perm") { nil }
        defer { runner.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path("perm"))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testReportsStderrAfterRepeatedFastFailures() throws {
        let reported = expectation(description: "report")
        var tail = ""
        let runner = try FFmpegRunner(executable: "/bin/sh", prefixArguments: [],
                                      makeArguments: { ["-c", "echo boom >&2; exit 1"] }, socketPath: path("report"),
                                      onRepeatedFailure: { tail = $0; reported.fulfill() })
        defer { runner.stop() }
        runner.start()
        for _ in 0..<3 { _ = readAll(try connectClient("report")) }
        wait(for: [reported], timeout: 5)
        XCTAssertTrue(tail.contains("boom"), tail)
    }

    // --- 헬퍼 ---

    private func path(_ name: String) -> String { NSTemporaryDirectory() + "smt-\(name)-\(getpid()).sock" }

    private func makeRunner(_ name: String, _ args: @escaping () -> [String]?) throws -> FFmpegRunner {
        let r = try FFmpegRunner(executable: "/bin/sh", prefixArguments: [], makeArguments: args,
                                 socketPath: path(name), onRepeatedFailure: { _ in })
        r.start()
        return r
    }

    private func connectClient(_ name: String) throws -> Int32 {
        let fd = try connectUnixSocket(path: path(name))
        var tv = timeval(tv_sec: 5, tv_usec: 0) // 실패할 때 영원히 기다리지 않게
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func readAll(_ fd: Int32) -> String {
        defer { close(fd) }
        var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { return "읽기 실패(시간 초과)" }
            if n == 0 { return String(decoding: out, as: UTF8.self) }
            out.append(contentsOf: buf[0..<n])
        }
    }
}
