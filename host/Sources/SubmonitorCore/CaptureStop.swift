import Foundation
import ScreenCaptureKit

/// 사용자가 메뉴 막대의 화면 공유 표시("터미널에 공유 중")에서 공유를 멈췄는가. 그렇다면 다시 캡처하지 않는다.
public func isUserStoppedCapture(_ error: Error) -> Bool {
    let e = error as NSError
    return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userStopped.rawValue
}
