import Foundation

/// 파이프를 끝까지 읽어 텍스트를 넘긴다. EOF(빈 데이터)에서 핸들러를 지운다:
/// 안 지우면 EOF 뒤에도 빈 데이터로 계속 불려 CPU 코어 하나를 100%로 태운다.
public func attachTextReader(_ handle: FileHandle, onText: @escaping (String) -> Void) {
    handle.readabilityHandler = { h in
        let data = h.availableData
        if data.isEmpty {
            h.readabilityHandler = nil
            return
        }
        onText(String(decoding: data, as: UTF8.self))
    }
}

/// 사용자 전용 유닉스 소켓에서 탭(adb reverse)의 접속을 받고, 접속마다 FFmpeg를 띄워 표준 출력을 그 소켓에 바로 잇는다.
/// 새 접속이 오면 이전 FFmpeg는 끈다. 탭이 끊으면 FFmpeg는 쓰기 실패로 끝나고, 탭이 다시 접속하면 새로 띄운다.
/// 인자는 실행할 때마다 다시 만든다(디스플레이 순서가 바뀌면 화면 번호도 바뀐다).
public final class FFmpegRunner {
    /// macOS 유닉스 소켓 기본 버퍼(8KB)로는 adb 경유 전송이 6MB/s에서 막혔다. 256KB 이상이면 USB 한계(2.0에서 33MB/s)까지 나온다.
    public static let sendBufferBytes: Int32 = 1 << 20

    private let executable: String
    private let prefixArguments: [String]
    private let makeArguments: () -> [String]?
    private let socketPath: String
    private let onRepeatedFailure: (_ stderrTail: String) -> Void
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "submonitor.ffmpeg")
    private var policy = RestartPolicy()
    private var process: Process?
    private var notBefore = Date.distantPast
    private var stopping = false
    private var stderrTail: [String] = []

    public init(executable: String = "/usr/bin/env", prefixArguments: [String] = ["ffmpeg", "-nostdin"],
                makeArguments: @escaping () -> [String]?, socketPath: String,
                onRepeatedFailure: @escaping (_ stderrTail: String) -> Void) throws {
        self.executable = executable
        self.prefixArguments = prefixArguments
        self.makeArguments = makeArguments
        self.socketPath = socketPath
        self.onRepeatedFailure = onRepeatedFailure
        listenFD = try listenUnixSocket(path: socketPath)
    }

    public func start() { Thread { self.acceptLoop() }.start() }

    public func stop() {
        queue.sync {
            stopping = true
            terminateCurrent()
        }
        // accept에서 막혀 있는 스레드를 깨워 끝낸다
        if let fd = try? connectUnixSocket(path: socketPath) { close(fd) }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            if queue.sync(execute: { stopping }) {
                close(fd)
                close(listenFD)
                return
            }
            queue.async { self.launch(clientFD: fd) }
        }
    }

    private func launch(clientFD fd: Int32) {
        guard !stopping else { close(fd); return }
        var size = Self.sendBufferBytes
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        terminateCurrent()
        let wait = notBefore.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) } // 빠른 실패가 이어지면 늦춘다
        let socketHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? socketHandle.close() } // 자식만 소켓을 갖게 한다. 우리 사본이 남으면 자식이 끝나도 탭이 EOF를 못 받는다
        guard let arguments = makeArguments() else {
            appendStderr("가상 디스플레이를 화면 목록에서 찾지 못했습니다")
            handleExit(runDuration: 0)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = prefixArguments + arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = socketHandle
        let pipe = Pipe()
        p.standardError = pipe
        attachTextReader(pipe.fileHandleForReading) { [weak self] text in
            FileHandle.standardError.write(Data(text.split(separator: "\n").map { "[ffmpeg] \($0)\n" }.joined().utf8))
            self?.queue.async { self?.appendStderr(text) }
        }
        let startedAt = Date()
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.exited(proc, runDuration: Date().timeIntervalSince(startedAt)) }
        }
        do {
            try p.run()
            process = p
        } catch {
            appendStderr("ffmpeg 실행 실패: \(error)")
            handleExit(runDuration: 0)
        }
    }

    /// TERM에 1초 안에 끝나지 않으면(막힌 쓰기 등) KILL한다. Ctrl-C가 멈추지 않게.
    private func terminateCurrent() {
        guard let p = process else { return }
        process = nil
        p.terminate()
        if !waitForExit(p, seconds: 1) {
            kill(p.processIdentifier, SIGKILL)
            _ = waitForExit(p, seconds: 1)
        }
    }

    private func waitForExit(_ p: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        return !p.isRunning
    }

    private func exited(_ p: Process, runDuration: TimeInterval) {
        guard p === process else { return } // 교체·종료하려고 우리가 끈 것
        process = nil
        handleExit(runDuration: runDuration)
    }

    private func appendStderr(_ text: String) {
        stderrTail = Array((stderrTail + text.split(separator: "\n").map(String.init)).suffix(20))
    }

    private func handleExit(runDuration: TimeInterval) {
        guard !stopping else { return }
        let decision = policy.onExit(runDuration: runDuration)
        if decision.reportError { onRepeatedFailure(stderrTail.joined(separator: "\n")) }
        notBefore = Date().addingTimeInterval(decision.delay)
    }
}
