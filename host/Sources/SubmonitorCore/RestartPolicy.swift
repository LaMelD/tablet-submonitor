import Foundation

public struct RestartDecision: Equatable {
    public let delay: TimeInterval
    /// 빠른 종료가 연속 reportAfter번째일 때 한 번만 true (오류를 사용자에게 보여줄 시점)
    public let reportError: Bool
}

/// 화면 캡처가 빨리(minHealthyRun 미만) 멈추는 일이 이어지면 다시 시작을 두 배씩 늦춘다(최대 maxDelay). 포기하지 않는다.
/// 화면 기록 권한은 시작할 때 따로 확인한다.
public struct RestartPolicy {
    let minHealthyRun: TimeInterval
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let reportAfter: Int
    var fastFailures = 0

    public init(minHealthyRun: TimeInterval = 2, baseDelay: TimeInterval = 0.3, maxDelay: TimeInterval = 5, reportAfter: Int = 3) {
        self.minHealthyRun = minHealthyRun
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.reportAfter = reportAfter
    }

    public mutating func onExit(runDuration: TimeInterval) -> RestartDecision {
        fastFailures = runDuration < minHealthyRun ? fastFailures + 1 : 0
        let delay = fastFailures == 0 ? baseDelay : min(baseDelay * pow(2, Double(fastFailures - 1)), maxDelay)
        return RestartDecision(delay: delay, reportError: fastFailures == reportAfter)
    }
}
