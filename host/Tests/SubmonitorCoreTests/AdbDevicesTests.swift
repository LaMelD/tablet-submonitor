import SubmonitorCore
import XCTest

final class AdbDevicesTests: XCTestCase {
    func testParsesOnlyReadyDevices() {
        let out = """
        List of devices attached
        R3CY70F8MGP            device usb:1048576X product:b7sksx model:SM_F766N device:b7s transport_id:17
        R54T502EJ0L            device usb:17825792X product:gts8ukxx model:SM_X906N device:gts8u transport_id:15
        ABC123                 unauthorized usb:1 transport_id:18
        XYZ                    offline transport_id:19

        """
        XCTAssertEqual(parseAdbDevices(out), ["R3CY70F8MGP", "R54T502EJ0L"])
    }

    // 버그: 휴대폰을 같이 연결하면 기기를 지정하지 않은 adb 명령이 "more than one device"로 실패했다
    func testPicksTabletOverPhone() {
        let c = ["R3CY70F8MGP": "phone", "R54T502EJ0L": "tablet"]
        XCTAssertEqual(chooseTablet(serials: ["R3CY70F8MGP", "R54T502EJ0L"], characteristics: c, preferred: nil), "R54T502EJ0L")
    }

    // 휴대폰만 있으면 고르지 않는다(휴대폰에 앱을 설치하고 띄우면 안 된다)
    func testDoesNotPickPhoneAlone() {
        XCTAssertNil(chooseTablet(serials: ["R3CY70F8MGP"], characteristics: ["R3CY70F8MGP": "phone"], preferred: nil))
    }

    func testPreferredSerialWinsOnlyWhenConnected() {
        let c = ["A": "tablet", "B": "phone"]
        XCTAssertEqual(chooseTablet(serials: ["A", "B"], characteristics: c, preferred: "B"), "B")
        XCTAssertNil(chooseTablet(serials: ["A"], characteristics: c, preferred: "B"))
    }

    func testTwoTabletsPickFirstBySerial() {
        XCTAssertEqual(chooseTablet(serials: ["T2", "T1"], characteristics: ["T1": "tablet", "T2": "tablet,nosdcard"], preferred: nil), "T1")
    }
}
