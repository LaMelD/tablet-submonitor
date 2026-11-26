import Foundation
import SubmonitorCore
import XCTest

final class VideoServerTests: XCTestCase {
    // 새 연결이 오면 이전 연결은 끊고, 세션 번호가 맞는 데이터만 보낸다.
    // 옛 세션용으로 인코딩된 프레임이 새 연결의 FLV 헤더보다 먼저 가면 탭이 스트림을 못 읽는다.
    func testDeliversOnlyCurrentSessionData() throws {
        let (server, sessions) = try makeServer("session")
        defer { server.stop() }
        let a = try connectClient("session")
        let s1 = try sessions.next()
        server.send(Data("a".utf8), session: s1)
        XCTAssertEqual(readExactly(a, 1), "a")
        let b = try connectClient("session")
        let s2 = try sessions.next()
        XCTAssertNotEqual(s1, s2)
        XCTAssertEqual(readAll(a), "", "옛 연결은 끊겨야 한다")
        server.send(Data("old".utf8), session: s1)
        server.send(Data("b".utf8), session: s2)
        XCTAssertEqual(readExactly(b, 1), "b")
        close(b)
    }

    // 버벅임 원인: macOS 유닉스 소켓 기본 버퍼(8KB)로는 adb 경유 전송이 6MB/s에서 막혔다(256KB 이상이면 33MB/s).
    // 탭이 아직 읽지 않아도 큰 프레임 하나(200KB)는 막히지 않고 써져야 한다.
    func testSocketBufferHoldsLargeFrame() throws {
        let (server, sessions) = try makeServer("buffer")
        defer { server.stop() }
        let fd = try connectClient("buffer")
        defer { close(fd) }
        let s = try sessions.next()
        let sent = expectation(description: "sent")
        server.send(Data(count: 200_000), session: s) { ok in XCTAssertTrue(ok); sent.fulfill() }
        wait(for: [sent], timeout: 3)
    }

    // 파이프라인은 완료 콜백으로 진행 중 프레임 수를 센다. 보내지 않은 경우에도 반드시 불려야 한다
    func testCompletionReportsFailureForStaleSession() throws {
        let (server, _) = try makeServer("stale")
        defer { server.stop() }
        let done = expectation(description: "done")
        server.send(Data("x".utf8), session: 999) { ok in XCTAssertFalse(ok); done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // 보안: 다른 사용자가 화면을 받아가지 못하게
    func testSocketIsUserOnly() throws {
        let (server, _) = try makeServer("perm")
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path("perm"))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // --- 헬퍼 ---

    final class Sessions {
        private let lock = NSLock()
        private var items: [Int] = []
        private let sem = DispatchSemaphore(value: 0)
        func push(_ s: Int) { lock.withLock { items.append(s) }; sem.signal() }
        func next() throws -> Int {
            guard sem.wait(timeout: .now() + 3) == .success else { throw POSIXError(.ETIMEDOUT) }
            return lock.withLock { items.removeFirst() }
        }
    }

    private func path(_ name: String) -> String { NSTemporaryDirectory() + "smv-\(name)-\(getpid()).sock" }

    private func makeServer(_ name: String) throws -> (VideoServer, Sessions) {
        let server = try VideoServer(socketPath: path(name))
        let sessions = Sessions()
        server.onConnect = { sessions.push($0) }
        server.start()
        return (server, sessions)
    }

    private func connectClient(_ name: String) throws -> Int32 {
        let fd = try connectUnixSocket(path: path(name))
        var tv = timeval(tv_sec: 5, tv_usec: 0) // 실패할 때 영원히 기다리지 않게
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func readExactly(_ fd: Int32, _ n: Int) -> String {
        var buf = [UInt8](repeating: 0, count: n), got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { break }
            got += r
        }
        return String(decoding: buf[0..<got], as: UTF8.self)
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
