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

/// FFmpeg를 하위 프로세스로 돌린다. 종료되면 RestartPolicy가 정한 간격 뒤 다시 띄운다.
/// 인자는 실행할 때마다 다시 만든다(디스플레이 순서가 바뀌면 화면 번호도 바뀐다).
public final class FFmpegRunner {
    private let executable: String
    private let prefixArguments: [String]
    private let makeArguments: () -> [String]?
    private let socketPath: String
    private let onRepeatedFailure: (_ stderrTail: String) -> Void
    private let queue = DispatchQueue(label: "submonitor.ffmpeg")
    private var policy = RestartPolicy()
    private var process: Process?
    private var stopping = false
    private var stderrTail: [String] = []

    public init(executable: String = "/usr/bin/env", prefixArguments: [String] = ["ffmpeg", "-nostdin"],
                makeArguments: @escaping () -> [String]?, socketPath: String,
                onRepeatedFailure: @escaping (_ stderrTail: String) -> Void) {
        self.executable = executable
        self.prefixArguments = prefixArguments
        self.makeArguments = makeArguments
        self.socketPath = socketPath
        self.onRepeatedFailure = onRepeatedFailure
    }

    public func start() { queue.async { self.launch() } }

    public func stop() {
        queue.sync {
            stopping = true
            process?.terminate()
            process?.waitUntilExit() // 소켓을 확실히 놓고 나간다
        }
    }

    private func launch() {
        guard !stopping else { return }
        unlink(socketPath) // FFmpeg가 비정상 종료하면 소켓 파일이 남아 다음 listen이 실패한다
        guard let arguments = makeArguments() else {
            appendStderr("가상 디스플레이를 화면 목록에서 찾지 못했습니다")
            handleExit(runDuration: 0)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = prefixArguments + arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardError = pipe
        attachTextReader(pipe.fileHandleForReading) { [weak self] text in
            FileHandle.standardError.write(Data(text.split(separator: "\n").map { "[ffmpeg] \($0)\n" }.joined().utf8))
            self?.queue.async { self?.appendStderr(text) }
        }
        let startedAt = Date()
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleExit(runDuration: Date().timeIntervalSince(startedAt)) }
        }
        do {
            try p.run()
            process = p
        } catch {
            appendStderr("ffmpeg 실행 실패: \(error)")
            handleExit(runDuration: 0)
        }
    }

    private func appendStderr(_ text: String) {
        stderrTail = Array((stderrTail + text.split(separator: "\n").map(String.init)).suffix(20))
    }

    private func handleExit(runDuration: TimeInterval) {
        guard !stopping else { return }
        let decision = policy.onExit(runDuration: runDuration)
        if decision.reportError { onRepeatedFailure(stderrTail.joined(separator: "\n")) }
        queue.asyncAfter(deadline: .now() + decision.delay) { self.launch() }
    }
}
