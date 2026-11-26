import CoreGraphics
import Foundation
import SubmonitorCore

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN) // 탭 연결이 끊긴 소켓에 쓸 때 프로세스가 죽지 않게

func activeDisplays() -> [UInt32] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

/// 새 디스플레이가 활성 목록에 나타날 때까지 최대 3초 기다린다.
func waitUntilActive(_ id: CGDirectDisplayID) -> Bool {
    for _ in 0..<30 {
        if activeDisplays().contains(id) { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
}

let permissionHint = "화면 기록 권한을 확인하세요: 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 이 터미널 앱을 허용"

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    print("오류: \(error)\n\(Options.usage)")
    exit(2)
}

let tmp = FileManager.default.temporaryDirectory // 사용자 전용($TMPDIR, 0700)
let videoSocket = tmp.appendingPathComponent("submonitor-video.sock").path
let cursorSocket = tmp.appendingPathComponent("submonitor-cursor.sock").path

// 화면 기록 권한은 시작할 때 확인한다(Review Focus 4)
guard CGPreflightScreenCaptureAccess() else {
    CGRequestScreenCaptureAccess()
    print("오류: 화면 기록 권한이 없습니다.\n\(permissionHint)\n권한을 준 뒤 터미널을 다시 열고 실행하세요.")
    exit(1)
}

do {
    let display = try VirtualDisplay(name: "Submonitor", pixelWidth: 2960, pixelHeight: 1848, refreshRate: 120)
    if let mode = CGDisplayCopyDisplayMode(display.displayID) {
        print("가상 디스플레이 \(display.displayID): \(describe(mode))")
    }
    guard waitUntilActive(display.displayID) else {
        print("오류: 가상 디스플레이가 활성 디스플레이 목록에 나타나지 않습니다")
        exit(1)
    }

    let tracker = CursorTracker(displayID: display.displayID, server: try CursorServer(socketPath: cursorSocket))
    tracker.start()

    let server = try VideoServer(socketPath: videoSocket)
    let screen = try ScreenStream(displayID: display.displayID, width: 2960, height: 1848, fps: options.fps,
                                  bitsPerSecond: options.bitsPerSecond, server: server)
    screen.start()
    server.start()

    Thread { runDeviceLoop(videoSocket: videoSocket, cursorSocket: cursorSocket, apkPath: options.apkPath) }.start()

    func shutdown(_ message: String) {
        print(message)
        screen.stop()
        server.stop()
        cleanupDevice()
        exit(0)
    }
    screen.onUserStopped = { shutdown("메뉴 막대에서 화면 공유가 중지되어 종료합니다.") }

    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { shutdown("종료 중…") }
        source.resume()
        return source
    }
    withExtendedLifetime((display, signals, tracker, screen, server)) { dispatchMain() }
} catch {
    print("오류: \(error)")
    exit(1)
}
