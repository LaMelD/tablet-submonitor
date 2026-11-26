public enum OptionsError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case invalidValue(flag: String)

    public var description: String {
        switch self {
        case .unknownFlag(let f): return "알 수 없는 옵션: \(f)"
        case .invalidValue(let f): return "\(f) 값이 없거나 잘못되었습니다"
        }
    }
}

public struct Options: Equatable {
    public var fps = 120
    public var bitrate = "40M"
    public var apkPath: String? = nil

    public init() {}

    public var bitsPerSecond: Int { parseBitrate(bitrate) ?? 40_000_000 }

    public static let usage = "사용법: submonitor [--fps 120|60] [--bitrate 40M] [--apk <app-debug.apk>]"

    public static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var it = args.makeIterator()
        while let flag = it.next() {
            let value = it.next()
            switch flag {
            case "--fps":
                guard let v = value.flatMap(Int.init), v > 0 else { throw OptionsError.invalidValue(flag: flag) }
                o.fps = v
            case "--bitrate":
                guard let v = value, parseBitrate(v) != nil else { throw OptionsError.invalidValue(flag: flag) }
                o.bitrate = v
            case "--apk":
                guard let v = value else { throw OptionsError.invalidValue(flag: flag) }
                o.apkPath = v
            default:
                throw OptionsError.unknownFlag(flag)
            }
        }
        return o
    }
}

/// "40M", "500k", "8000000" → 초당 비트. 0 이하나 해석 못 하면 nil.
public func parseBitrate(_ s: String) -> Int? {
    let unit: Int
    switch s.last {
    case "M", "m": unit = 1_000_000
    case "K", "k": unit = 1_000
    default: unit = 1
    }
    guard let n = Int(unit == 1 ? s : String(s.dropLast())), n > 0 else { return nil }
    return n * unit
}
