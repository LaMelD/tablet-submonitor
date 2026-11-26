import Foundation
import ScreenCaptureKit
import SubmonitorCore
import XCTest

final class CaptureStopTests: XCTestCase {
    // 메뉴 막대 "터미널에 공유 중"에서 공유를 멈추면 사용자 뜻이다. 다시 캡처하지 않고 종료한다(전에는 0.4초 만에 다시 시작했다)
    func testUserStopFromMenuBarIsRecognized() {
        XCTAssertTrue(isUserStoppedCapture(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)))
    }

    // 그 밖의 중단(디스플레이 변경 등)은 지금처럼 다시 시도한다
    func testOtherStopsAreRetried() {
        XCTAssertFalse(isUserStoppedCapture(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue)))
        XCTAssertFalse(isUserStoppedCapture(NSError(domain: NSPOSIXErrorDomain, code: SCStreamError.Code.userStopped.rawValue)))
    }
}
