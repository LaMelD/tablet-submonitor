import SubmonitorCore
import XCTest

final class FrameSchedulerTests: XCTestCase {
    private var submitted: [(frame: String, key: Bool, session: Int)] = []
    private lazy var scheduler = FrameScheduler<String>(maxInflight: 2) { [unowned self] f, key, s in submitted.append((f, key, s)) }

    func testNothingIsEncodedWithoutTablet() {
        scheduler.captured("A")
        XCTAssertTrue(submitted.isEmpty)
    }

    // 화면이 멈춰 있으면 새 프레임이 오지 않는다. 접속하면 마지막 프레임으로 키프레임을 보내야 탭에 화면이 뜬다
    func testConnectOnStaticScreenSendsLastFrameAsKey() {
        scheduler.captured("A")
        scheduler.connected(session: 1)
        XCTAssertEqual(submitted.map(\.frame), ["A"]); XCTAssertEqual(submitted.map(\.key), [true])
    }

    // 버그: 보낸 프레임을 지워 버려 앱 전환 뒤 재접속 때 정지 화면이면 키프레임을 못 보냈다
    func testReconnectAfterStreamingStillGetsKeyFrame() {
        scheduler.connected(session: 1)
        scheduler.captured("A"); scheduler.finished(session: 1)
        scheduler.captured("B"); scheduler.finished(session: 1)
        scheduler.connected(session: 2)
        XCTAssertEqual(submitted.map(\.frame), ["A", "B", "B"])
        XCTAssertEqual(submitted.map(\.key), [true, false, true])
        XCTAssertEqual(submitted.last?.session, 2)
    }

    // 인코딩·전송 중인 프레임이 2장이면 새 프레임은 쌓지 않고, 끝나면 가장 최근 것만 보낸다
    func testKeepsOnlyLatestWhileBusy() {
        scheduler.connected(session: 1)
        scheduler.captured("A"); scheduler.captured("B"); scheduler.captured("C"); scheduler.captured("D")
        XCTAssertEqual(submitted.map(\.frame), ["A", "B"])
        scheduler.finished(session: 1)
        XCTAssertEqual(submitted.map(\.frame), ["A", "B", "D"])
    }

    func testFailedKeyFrameIsRetriedWithLastFrame() {
        scheduler.captured("A")
        scheduler.connected(session: 1)
        scheduler.finished(session: 1, needKeyAgain: true)
        XCTAssertEqual(submitted.map(\.key), [true, true])
        XCTAssertEqual(submitted.map(\.frame), ["A", "A"])
    }

    func testStopsAfterDisconnect() {
        scheduler.connected(session: 1)
        scheduler.disconnected(session: 1)
        scheduler.captured("A")
        XCTAssertTrue(submitted.isEmpty)
    }

    // 옛 세션의 늦은 완료가 새 세션을 끊으면 안 된다
    func testStaleDisconnectIsIgnored() {
        scheduler.connected(session: 1)
        scheduler.connected(session: 2)
        scheduler.disconnected(session: 1)
        scheduler.captured("A")
        XCTAssertEqual(submitted.map(\.session), [2])
    }
}
