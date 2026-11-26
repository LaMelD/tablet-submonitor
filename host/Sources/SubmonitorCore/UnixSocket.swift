import Foundation

public struct UnixSocketError: Error, CustomStringConvertible {
    public let step: String
    public let code: Int32
    public var description: String { "유닉스 소켓 \(step) 실패: \(String(cString: strerror(code)))" }
}

/// 사용자 전용 유닉스 소켓을 열고 listen 상태의 fd를 돌려준다. $TMPDIR(0700) 안에 두고 소켓 자체도 0600으로 막는다.
public func listenUnixSocket(path: String) throws -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw UnixSocketError(step: "socket", code: errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        throw UnixSocketError(step: "경로 길이 확인", code: ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
        let e = errno
        close(fd)
        throw UnixSocketError(step: "bind/listen", code: e)
    }
    chmod(path, 0o600)
    return fd
}

/// 유닉스 소켓에 접속한다(종료 시 accept 깨우기, 테스트용).
public func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw UnixSocketError(step: "socket", code: errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8).prefix($0.count - 1)) }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard r == 0 else {
        let e = errno
        close(fd)
        throw UnixSocketError(step: "connect", code: e)
    }
    return fd
}
