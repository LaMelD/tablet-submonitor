import Foundation
import SubmonitorCore

struct AdbError: Error, CustomStringConvertible {
    let args: [String]
    let output: String
    var description: String { "adb \(args.joined(separator: " ")) 실패: \(output)" }
}

/// `/usr/bin/env adb <args>`를 실행하고 출력을 돌려준다. 종료 코드가 0이 아니면 throw.
@discardableResult
func adb(_ args: String...) throws -> String {
    try adb(args)
}

@discardableResult
func adb(_ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["adb"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try ChildProcesses.shared.run(p)
    defer { ChildProcesses.shared.finished(p) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0 else { throw AdbError(args: args, output: out) }
    return out
}

/// 특정 기기에 adb 명령을 보낸다. 휴대폰 등 다른 기기가 함께 연결돼 있으면 기기를 지정하지 않은 명령은 실패한다.
@discardableResult
func adb(device serial: String, _ args: String...) throws -> String {
    try adb(["-s", serial] + args)
}

let tabletPackage = "dev.submonitor"

private let serialLock = NSLock()
private var currentSerial: String? // 종료 정리용

/// 쓸 태블릿이 연결될 때까지 1초마다 살핀다. 태블릿이 아닌 기기만 있으면 알리고 기다린다.
func waitForTablet(preferred: String?) -> String {
    var characteristics: [String: String] = [:]
    var lastNotice = ""
    while true {
        if let out = try? adb("devices") {
            let serials = parseAdbDevices(out)
            for s in serials where characteristics[s] == nil {
                // 막 연결된 기기는 아직 응답하지 않을 수 있다. 실패는 저장하지 않고 다음에 다시 묻는다
                if let c = try? adb(device: s, "shell", "getprop", "ro.build.characteristics") { characteristics[s] = c }
            }
            if let tablet = chooseTablet(serials: serials, characteristics: characteristics, preferred: preferred) { return tablet }
            let notice = serials.isEmpty ? "" : preferred.map { "--serial \($0) 기기가 연결돼 있지 않습니다" }
                ?? "연결된 기기 \(serials.count)대 중 태블릿이 없습니다(직접 고르려면 --serial)"
            if !notice.isEmpty, notice != lastNotice { print(notice) }
            lastNotice = notice
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

/// 탭이 연결될 때마다 adb reverse·앱 설치·실행을 다시 한다. USB를 다시 꽂으면 reverse 설정이 사라지기 때문이다.
func runDeviceLoop(videoSocket: String, cursorSocket: String, apkPath: String?, serial preferred: String?) {
    var installed: Set<String> = []
    while true {
        do {
            print("탭 연결 대기 중… (USB 디버깅 허용 확인)")
            let s = waitForTablet(preferred: preferred)
            serialLock.withLock { currentSerial = s }
            try adb(device: s, "reverse", "localabstract:submonitor-video", "localfilesystem:\(videoSocket)")
            try adb(device: s, "reverse", "localabstract:submonitor-cursor", "localfilesystem:\(cursorSocket)")
            if let apk = apkPath, !installed.contains(s) {
                print("탭 앱 설치 중…")
                try adb(device: s, "install", "-r", apk)
                installed.insert(s)
            }
            try adb(device: s, "shell", "am", "start", "-n", "\(tabletPackage)/.MainActivity")
            print("탭 연결됨 (\(s))")
            try adb(device: s, "wait-for-disconnect")
            print("탭 연결이 끊어졌습니다")
        } catch {
            if ChildProcesses.shared.terminating { return } // 종료하면서 끈 것
            print("오류: \(error)")
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

/// 종료 시 정리. 탭이 이미 빠졌을 수 있으므로 오류는 무시한다.
func cleanupDevice() {
    ChildProcesses.shared.terminateAll() // 기다리던 adb wait-for-*가 남지 않게
    guard let s = serialLock.withLock({ currentSerial }) else { return }
    _ = try? adb(device: s, "reverse", "--remove", "localabstract:submonitor-video")
    _ = try? adb(device: s, "reverse", "--remove", "localabstract:submonitor-cursor")
    _ = try? adb(device: s, "shell", "am", "force-stop", tabletPackage)
}
