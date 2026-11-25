import Foundation

struct AdbError: Error, CustomStringConvertible {
    let args: [String]
    let output: String
    var description: String { "adb \(args.joined(separator: " ")) 실패: \(output)" }
}

/// `/usr/bin/env adb <args>`를 실행하고 출력을 돌려준다. 종료 코드가 0이 아니면 throw.
@discardableResult
func adb(_ args: String...) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["adb"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0 else { throw AdbError(args: args, output: out) }
    return out
}

let tabletPackage = "dev.submonitor"

/// 탭이 연결될 때마다 adb reverse·앱 설치·실행을 다시 한다. USB를 다시 꽂으면 reverse 설정이 사라지기 때문이다.
func runDeviceLoop(videoSocket: String, cursorSocket: String, apkPath: String?) {
    var installed = false
    while true {
        do {
            print("탭 연결 대기 중… (USB 디버깅 허용 확인)")
            try adb("wait-for-device")
            try adb("reverse", "localabstract:submonitor-video", "localfilesystem:\(videoSocket)")
            try adb("reverse", "localabstract:submonitor-cursor", "localfilesystem:\(cursorSocket)")
            if let apk = apkPath, !installed {
                print("탭 앱 설치 중…")
                try adb("install", "-r", apk)
                installed = true
            }
            try adb("shell", "am", "start", "-n", "\(tabletPackage)/.MainActivity")
            print("탭 연결됨")
            try adb("wait-for-disconnect")
            print("탭 연결이 끊어졌습니다")
        } catch {
            print("오류: \(error)")
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

/// 종료 시 정리. 탭이 이미 빠졌을 수 있으므로 오류는 무시한다.
func cleanupDevice() {
    _ = try? adb("reverse", "--remove", "localabstract:submonitor-video")
    _ = try? adb("reverse", "--remove", "localabstract:submonitor-cursor")
    _ = try? adb("shell", "am", "force-stop", tabletPackage)
}
