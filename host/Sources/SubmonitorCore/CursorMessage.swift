import CoreGraphics
import Foundation

/// 호스트 → 탭 커서 채널 메시지. 형식: type u8, length u32, payload (모두 big-endian). 좌표·크기는 가상 디스플레이 pt 단위.
public enum CursorMessage: Equatable {
    case display(width: Float, height: Float)
    case position(x: Float, y: Float, visible: Bool)
    case shape(hotX: Float, hotY: Float, width: Float, height: Float, png: Data)

    public func encoded() -> Data {
        var payload = Data()
        func float(_ v: Float) { withUnsafeBytes(of: v.bitPattern.bigEndian) { payload.append(contentsOf: $0) } }
        let type: UInt8
        switch self {
        case let .display(width, height):
            type = 1; float(width); float(height)
        case let .position(x, y, visible):
            type = 2; float(x); float(y); payload.append(visible ? 1 : 0)
        case let .shape(hotX, hotY, width, height, png):
            type = 3; float(hotX); float(hotY); float(width); float(height); payload.append(png)
        }
        var out = Data([type])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        return out + payload
    }
}

/// 전역 좌표(pt)를 가상 디스플레이 기준 좌표로 바꾼다. 디스플레이 밖이면 visible = false.
public func cursorPosition(global: CGPoint, displayBounds: CGRect) -> (x: Float, y: Float, visible: Bool) {
    (Float(global.x - displayBounds.minX), Float(global.y - displayBounds.minY), displayBounds.contains(global))
}
