import Darwin
import Foundation

enum PortSuggestionError: Error, Equatable {
    case noAvailablePort
}

final class PortSuggestionService: @unchecked Sendable {
    private let availabilityCheck: (Int) -> Bool

    init(isAvailable: @escaping (Int) -> Bool = PortSuggestionService.checkAvailable) {
        availabilityCheck = isAvailable
    }

    func suggest(preferred: Int, scanLimit: Int = 100) throws -> Int {
        var candidate = (1_000...65_535).contains(preferred) ? preferred : 3_000
        for _ in 0..<max(0, scanLimit) where candidate <= 65_535 {
            if availabilityCheck(candidate) {
                return candidate
            }
            candidate += 1
        }
        throw PortSuggestionError.noAvailablePort
    }

    func isAvailable(_ port: Int) -> Bool {
        availabilityCheck(port)
    }

    private static func checkAvailable(_ port: Int) -> Bool {
        guard (1_000...65_535).contains(port) else {
            return false
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
