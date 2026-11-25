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
func waitForScreenDevice(_ id: CGDirectDisplayID) -> String? {
    for _ in 0..<30 {
        if let name = screenDeviceName(for: id, activeDisplays: activeDisplays()) { return name }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return nil
}

/// 이전 실행이 비정상 종료되어 남은 FFmpeg를 정리한다.
func killStaleFFmpeg(socketPath: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-f", "unix:\(socketPath)"]
    try? p.run()
    p.waitUntilExit()
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
killStaleFFmpeg(socketPath: videoSocket)

do {
    let display = try VirtualDisplay(name: "Submonitor", pixelWidth: 2960, pixelHeight: 1848, refreshRate: 120)
    if let mode = CGDisplayCopyDisplayMode(display.displayID) {
        print("가상 디스플레이 \(display.displayID): \(describe(mode))")
    }
    guard let device = waitForScreenDevice(display.displayID) else {
        print("오류: 가상 디스플레이가 활성 디스플레이 목록에 나타나지 않습니다")
        exit(1)
    }

    let tracker = CursorTracker(displayID: display.displayID, server: try CursorServer(socketPath: cursorSocket))
    tracker.start()

    let runner = FFmpegRunner(
        arguments: ffmpegArguments(screenDevice: device, fps: options.fps, bitrate: options.bitrate, socketPath: videoSocket),
        socketPath: videoSocket
    ) { tail in
        print("오류: FFmpeg가 연달아 바로 종료되었습니다.\n\(tail)\n\(permissionHint)")
        exit(1)
    }
    runner.start()

    Thread { runDeviceLoop(videoSocket: videoSocket, cursorSocket: cursorSocket, apkPath: options.apkPath) }.start()

    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            print("종료 중…")
            runner.stop()
            cleanupDevice()
            exit(0)
        }
        source.resume()
        return source
    }
    withExtendedLifetime((display, signals, tracker)) { dispatchMain() }
} catch {
    print("오류: \(error)")
    exit(1)
}
