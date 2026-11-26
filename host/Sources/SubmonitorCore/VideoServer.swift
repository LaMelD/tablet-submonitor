import Foundation

/// 사용자 전용 유닉스 소켓으로 탭(adb reverse)에 영상을 보낸다. 클라이언트는 하나만, 새 연결이 오면 이전 연결을 끊는다.
/// 연결마다 세션 번호가 붙고, 그 번호로 보낸 데이터만 그 연결에 간다(옛 세션 프레임이 새 연결의 헤더보다 먼저 가지 않게).
public final class VideoServer {
    /// macOS 유닉스 소켓 기본 버퍼(8KB)로는 adb 경유 전송이 6MB/s에서 막혔다. 256KB 이상이면 USB 한계(2.0에서 33MB/s)까지 나온다.
    public static let sendBufferBytes: Int32 = 1 << 20

    /// 새 연결마다 서버 큐에서 불린다. 이전 연결은 이미 끊긴 뒤다.
    public var onConnect: ((_ session: Int) -> Void)?

    private let socketPath: String
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "submonitor.video-server")
    private let lock = NSLock()
    private var client: Int32 = -1 // lock. client에서 뺀 쪽이 close 책임을 진다
    private var session = 0        // lock
    private var stopped = false    // lock

    public init(socketPath: String) throws {
        self.socketPath = socketPath
        listenFD = try listenUnixSocket(path: socketPath)
    }

    public func start() { Thread { self.acceptLoop() }.start() }

    /// 블로킹 쓰기(서버 큐). 완료 콜백은 항상 불린다: 보냈으면 true, 세션이 지났거나 끊겼으면 false.
    public func send(_ data: Data, session s: Int, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let fd: Int32 = self.lock.withLock { self.session == s ? self.client : -1 }
            guard fd >= 0 else { completion?(false); return }
            if writeAll(fd, data) { completion?(true); return }
            let mine = self.lock.withLock { () -> Bool in
                guard self.client == fd else { return false }
                self.client = -1
                return true
            }
            if mine { close(fd) }
            completion?(false)
        }
    }

    public func stop() {
        let old: Int32 = lock.withLock {
            stopped = true
            defer { client = -1 }
            return client
        }
        if old >= 0 {
            shutdown(old, SHUT_RDWR) // 막힌 쓰기를 깨운다
            queue.async { close(old) }
        }
        if let fd = try? connectUnixSocket(path: socketPath) { close(fd) } // accept 스레드를 깨워 끝낸다
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var size = Self.sendBufferBytes
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            let (old, s, isStopped): (Int32, Int, Bool) = lock.withLock {
                if stopped { return (-1, 0, true) }
                let old = client
                client = fd
                session += 1
                return (old, session, false)
            }
            if isStopped {
                close(fd)
                close(listenFD)
                return
            }
            if old >= 0 { shutdown(old, SHUT_RDWR) }
            queue.async {
                if old >= 0 { close(old) }
                self.onConnect?(s)
            }
        }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}
