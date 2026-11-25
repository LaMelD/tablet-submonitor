import AppKit
import CoreGraphics
import Foundation
import SubmonitorCore

enum CursorServerError: Error, CustomStringConvertible {
    case socket(String)
    var description: String {
        if case let .socket(m) = self { return "커서 소켓 오류: \(m) (errno \(errno))" }
        return ""
    }
}

/// 사용자 전용 유닉스 소켓($TMPDIR)으로 커서 메시지를 보낸다. 클라이언트는 하나만, 새 연결이 오면 이전 연결을 닫는다.
final class CursorServer {
    var onConnect: (() -> Void)?
    private let listenFD: Int32
    private var client: Int32 = -1
    private let queue = DispatchQueue(label: "submonitor.cursor")

    init(socketPath: String) throws {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw CursorServerError.socket("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw CursorServerError.socket("경로가 너무 김") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else { throw CursorServerError.socket("bind/listen") }
        chmod(socketPath, 0o600)
        Thread { [weak self] in self?.acceptLoop() }.start()
    }

    func send(_ message: CursorMessage) {
        let data = message.encoded()
        queue.async {
            guard self.client >= 0 else { return }
            // ponytail: 블로킹 쓰기. 탭이 읽기를 멈추면 이 큐가 밀린다. 커서 메시지는 작아서 소켓 버퍼로 충분하다.
            let ok = data.withUnsafeBytes { buf -> Bool in
                var off = 0
                while off < buf.count {
                    let n = write(self.client, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            if !ok { close(self.client); self.client = -1 }
        }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { continue }
            queue.async {
                if self.client >= 0 { close(self.client) }
                self.client = fd
                self.onConnect?()
            }
        }
    }
}

/// 커서 좌표(4ms마다)와 모양(50ms마다)을 살펴 바뀐 것만 보낸다. 메인 큐에서 돈다.
final class CursorTracker {
    private let displayID: CGDirectDisplayID
    private let server: CursorServer
    private var timers: [DispatchSourceTimer] = []
    private var lastPosition: (x: Float, y: Float, visible: Bool)?
    private var lastShape: CursorMessage?

    init(displayID: CGDirectDisplayID, server: CursorServer) {
        self.displayID = displayID
        self.server = server
    }

    func start() {
        server.onConnect = { [weak self] in DispatchQueue.main.async { self?.sendInitialState() } }
        timers = [every(.milliseconds(4)) { [weak self] in self?.pollPosition() },
                  every(.milliseconds(50)) { [weak self] in self?.pollShape() }]
    }

    private func every(_ interval: DispatchTimeInterval, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler(handler: handler)
        t.resume()
        return t
    }

    private func sendInitialState() {
        let b = CGDisplayBounds(displayID)
        server.send(.display(width: Float(b.width), height: Float(b.height)))
        if let shape = lastShape { server.send(shape) }
        if let p = lastPosition { server.send(.position(x: p.x, y: p.y, visible: p.visible)) }
    }

    private func pollPosition() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let p = cursorPosition(global: location, displayBounds: CGDisplayBounds(displayID))
        if let last = lastPosition, last == p { return }
        lastPosition = p
        server.send(.position(x: p.x, y: p.y, visible: p.visible))
    }

    private func pollShape() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        guard let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let size = cursor.image.size
        let shape = CursorMessage.shape(hotX: Float(cursor.hotSpot.x), hotY: Float(cursor.hotSpot.y),
                                        width: Float(size.width), height: Float(size.height), png: png)
        if shape == lastShape { return }
        lastShape = shape
        server.send(shape)
    }
}
