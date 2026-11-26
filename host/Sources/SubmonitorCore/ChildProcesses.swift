import Foundation

/// 실행 중인 자식 프로세스 목록. Foundation의 Process는 자식을 별도 프로세스 그룹으로 띄워 터미널의 Ctrl-C가 닿지 않으므로,
/// 호스트가 끝날 때 여기 있는 것을 한꺼번에 끈다(안 끄면 adb wait-for-disconnect가 실행할 때마다 하나씩 남았다).
public final class ChildProcesses {
    public static let shared = ChildProcesses()

    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]
    private var stopping = false

    public init() {}

    public var count: Int { lock.withLock { running.count } }

    /// terminateAll 뒤에는 true. 이때 끊긴 자식의 실패는 오류가 아니다.
    public var terminating: Bool { lock.withLock { stopping } }

    public func run(_ p: Process) throws {
        try lock.withLock {
            try p.run()
            running[ObjectIdentifier(p)] = p
        }
    }

    public func finished(_ p: Process) {
        lock.withLock { running[ObjectIdentifier(p)] = nil }
    }

    public func terminateAll() {
        lock.withLock {
            stopping = true
            running.values.forEach { $0.terminate() }
        }
    }
}
