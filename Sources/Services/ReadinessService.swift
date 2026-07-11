import Foundation

protocol ReadinessProbing: Sendable {
    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool
}

struct ReadinessService: ReadinessProbing {
    private let probe: @Sendable (URL) async -> Bool

    init(probe: @escaping @Sendable (URL) async -> Bool = ReadinessService.probeURL) {
        self.probe = probe
    }

    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled, clock.now <= deadline {
            if await probe(url) { return true }
            try? await clock.sleep(for: interval)
        }
        return false
    }

    private static func probeURL(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return response.statusCode < 500
        } catch {
            return false
        }
    }
}
