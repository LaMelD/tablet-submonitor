import Foundation
import SubmonitorCore

/// FFmpeg를 하위 프로세스로 돌린다. 종료되면 RestartPolicy에 따라 다시 띄우거나 포기한다.
final class FFmpegRunner {
    private let arguments: [String]
    private let socketPath: String
    private let onGiveUp: (_ stderrTail: String) -> Void
    private let queue = DispatchQueue(label: "submonitor.ffmpeg")
    private var policy = RestartPolicy()
    private var process: Process?
    private var stopping = false
    private var stderrTail: [String] = []

    init(arguments: [String], socketPath: String, onGiveUp: @escaping (_ stderrTail: String) -> Void) {
        self.arguments = arguments
        self.socketPath = socketPath
        self.onGiveUp = onGiveUp
    }

    func start() { queue.async { self.launch() } }

    func stop() {
        queue.sync {
            stopping = true
            process?.terminate()
            process?.waitUntilExit() // 포트 28100을 확실히 놓고 나간다
        }
    }

    private func launch() {
        guard !stopping else { return }
        unlink(socketPath) // FFmpeg가 비정상 종료하면 소켓 파일이 남아 다음 listen이 실패한다
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg", "-nostdin"] + arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let text = String(data: h.availableData, encoding: .utf8), !text.isEmpty else { return }
            FileHandle.standardError.write(Data(text.split(separator: "\n").map { "[ffmpeg] \($0)\n" }.joined().utf8))
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = Array((self.stderrTail + text.split(separator: "\n").map(String.init)).suffix(20))
            }
        }
        let startedAt = Date()
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleExit(runDuration: Date().timeIntervalSince(startedAt)) }
        }
        do {
            try p.run()
            process = p
        } catch {
            stderrTail.append("ffmpeg 실행 실패: \(error)")
            handleExit(runDuration: 0)
        }
    }

    private func handleExit(runDuration: TimeInterval) {
        guard !stopping else { return }
        switch policy.onExit(runDuration: runDuration) {
        case .restart: queue.asyncAfter(deadline: .now() + 0.3) { self.launch() }
        case .giveUp: onGiveUp(stderrTail.joined(separator: "\n"))
        }
    }
}
