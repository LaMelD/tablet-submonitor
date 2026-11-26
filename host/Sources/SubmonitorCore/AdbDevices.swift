/// `adb devices` 출력에서 쓸 수 있는(device 상태) 기기의 일련번호. unauthorized·offline은 뺀다.
public func parseAdbDevices(_ output: String) -> [String] {
    output.split(separator: "\n").dropFirst().compactMap { line in
        let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return cols.count >= 2 && cols[1] == "device" ? String(cols[0]) : nil
    }
}

/// 서브모니터로 쓸 기기를 고른다. 휴대폰 같은 다른 기기가 함께 연결돼 있어도 태블릿만 고른다.
/// preferred(--serial)가 있으면 연결돼 있을 때 그것만, 없으면 ro.build.characteristics에 tablet이 있는 기기 중 일련번호 순 첫 번째.
public func chooseTablet(serials: [String], characteristics: [String: String], preferred: String?) -> String? {
    if let preferred { return serials.contains(preferred) ? preferred : nil }
    return serials.sorted().first { characteristics[$0]?.split(separator: ",").contains("tablet") == true }
}
