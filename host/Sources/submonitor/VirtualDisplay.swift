import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

enum VirtualDisplayError: Error, CustomStringConvertible {
    case createFailed
    case applySettingsFailed
    case hiDPIModeNotFound(available: [String])
    case setModeFailed(CGError)

    var description: String {
        switch self {
        case .createFailed: return "가상 디스플레이를 만들지 못했습니다 (CGVirtualDisplay init 실패)"
        case .applySettingsFailed: return "가상 디스플레이 모드 설정에 실패했습니다 (applySettings)"
        case .hiDPIModeNotFound(let modes): return "HiDPI 모드를 찾지 못했습니다. 사용 가능한 모드: \(modes.joined(separator: ", "))"
        case .setModeFailed(let err): return "디스플레이 모드 적용 실패: CGError \(err.rawValue)"
        }
    }
}

/// 객체가 살아 있는 동안만 존재하는 가상 디스플레이. 해제되면 macOS에서 사라진다.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay

    init(name: String, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        descriptor.sizeInMillimeters = CGSize(width: 315, height: 197) // 14.6인치 16:10
        descriptor.vendorID = 0x5354
        descriptor.productID = 0x0001
        descriptor.serialNum = 1

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { throw VirtualDisplayError.createFailed }
        self.display = display
        self.displayID = display.displayID

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pixelWidth), height: UInt(pixelHeight), refreshRate: refreshRate),
            CGVirtualDisplayMode(width: UInt(pixelWidth / 2), height: UInt(pixelHeight / 2), refreshRate: refreshRate),
        ]
        guard display.apply(settings) else { throw VirtualDisplayError.applySettingsFailed }

        try Self.selectHiDPIMode(displayID, pointWidth: pixelWidth / 2, pixelWidth: pixelWidth, refreshRate: refreshRate)
    }

    private static func selectHiDPIMode(_ id: CGDirectDisplayID, pointWidth: Int, pixelWidth: Int, refreshRate: Double) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        var modes: [CGDisplayMode] = []
        // 디스플레이 등록이 비동기일 수 있어 잠시 기다린다.
        for _ in 0..<30 {
            modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            if !modes.isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let candidates = modes.filter { $0.width == pointWidth && $0.pixelWidth == pixelWidth }
        guard let mode = candidates.min(by: { abs($0.refreshRate - refreshRate) < abs($1.refreshRate - refreshRate) }) else {
            throw VirtualDisplayError.hiDPIModeNotFound(available: modes.map(describe))
        }
        let err = CGDisplaySetDisplayMode(id, mode, nil)
        guard err == .success else { throw VirtualDisplayError.setModeFailed(err) }
    }
}

func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)x\(mode.height) pt / \(mode.pixelWidth)x\(mode.pixelHeight) px @\(Int(mode.refreshRate.rounded()))Hz"
}
