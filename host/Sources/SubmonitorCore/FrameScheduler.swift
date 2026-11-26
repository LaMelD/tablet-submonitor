/// 캡처한 프레임을 언제 인코더에 넣을지 정한다. 직렬 큐 하나에서만 부른다.
/// - 탭이 없으면 인코딩하지 않는다.
/// - 인코딩·전송 중인 프레임이 maxInflight 이상이면 쌓지 않고 가장 최근 프레임만 남긴다(지연이 쌓이지 않게).
/// - 새 연결에는 키프레임부터. 화면이 멈춰 새 프레임이 없어도 마지막 프레임으로 보낸다.
public final class FrameScheduler<Frame> {
    private let maxInflight: Int
    private let submit: (_ frame: Frame, _ forceKey: Bool, _ session: Int) -> Void
    private var pending: Frame? // 아직 넣지 않은 가장 최근 프레임
    private var last: Frame?    // 마지막으로 캡처한 프레임(재접속 키프레임용)
    private var session = 0     // 0이면 연결 없음
    private var needsKey = true
    public private(set) var inflight = 0

    public init(maxInflight: Int, submit: @escaping (_ frame: Frame, _ forceKey: Bool, _ session: Int) -> Void) {
        self.maxInflight = maxInflight
        self.submit = submit
    }

    public func captured(_ frame: Frame) {
        last = frame
        pending = frame
        pump()
    }

    public func connected(session s: Int) {
        session = s
        needsKey = true
        if pending == nil { pending = last }
        pump()
    }

    public func disconnected(session s: Int) {
        if s == session { session = 0 }
    }

    /// 넣은 프레임 하나가 끝났을 때(보냈든 버렸든) 한 번 부른다. needKeyAgain: 키프레임을 못 보냈다.
    public func finished(session s: Int, needKeyAgain: Bool = false) {
        inflight -= 1
        if needKeyAgain, s == session {
            needsKey = true
            if pending == nil { pending = last }
        }
        pump()
    }

    private func pump() {
        guard session != 0, inflight < maxInflight, let frame = pending else { return }
        pending = nil
        let key = needsKey
        needsKey = false
        inflight += 1
        submit(frame, key, session)
    }
}
