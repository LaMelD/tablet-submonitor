import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

do {
    let display = try VirtualDisplay(name: "Submonitor", pixelWidth: 2960, pixelHeight: 1848, refreshRate: 120)
    if let mode = CGDisplayCopyDisplayMode(display.displayID) {
        print("가상 디스플레이 \(display.displayID): \(describe(mode))")
    }
    withExtendedLifetime(display) { dispatchMain() }
} catch {
    print("오류: \(error)")
    exit(1)
}
