import Foundation

protocol SampleProjectFileSystem {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func directoryContents(at url: URL) throws -> [URL]
    func copyItem(at source: URL, to destination: URL) throws
    func writeData(_ data: Data, to url: URL) throws
}

struct LocalSampleProjectFileSystem: SampleProjectFileSystem {
    private let manager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var directory: ObjCBool = false
        let exists = manager.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && directory.boolValue
    }

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func directoryContents(at url: URL) throws -> [URL] {
        try manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try manager.copyItem(at: source, to: destination)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }
}

struct SampleCopyResult: Equatable, Sendable {
    let copied: Bool
    let destination: URL
}

enum SampleProjectError: Error, Equatable {
    case sourceUnavailable
    case destinationConflict
}

final class SampleProjectService {
    static let markerFilename = ".localwrap-sample.json"

    private let fileSystem: any SampleProjectFileSystem
    private let now: () -> String

    init(
        fileSystem: any SampleProjectFileSystem = LocalSampleProjectFileSystem(),
        now: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.fileSystem = fileSystem
        self.now = now
    }

    func copyBundledSample(
        from source: URL,
        to destination: URL
    ) throws -> SampleCopyResult {
        guard fileSystem.isDirectory(at: source) else {
            throw SampleProjectError.sourceUnavailable
        }
        let marker = destination.appendingPathComponent(Self.markerFilename)
        if fileSystem.fileExists(at: destination) {
            guard fileSystem.isDirectory(at: destination), fileSystem.fileExists(at: marker) else {
                throw SampleProjectError.destinationConflict
            }
            return SampleCopyResult(copied: false, destination: destination)
        }

        try fileSystem.createDirectory(at: destination)
        try copyContents(from: source, to: destination)
        let payload: [String: Any] = [
            "createdBy": "LocalWrap",
            "sample": "localwrap-sample-project",
            "markerVersion": 1,
            "createdAt": now(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try fileSystem.writeData(data + Data([0x0A]), to: marker)
        return SampleCopyResult(copied: true, destination: destination)
    }

    func copyBundledSample(
        to destination: URL,
        bundle: Bundle = .main
    ) throws -> SampleCopyResult {
        guard let source = bundle.url(forResource: "sample-project", withExtension: nil) else {
            throw SampleProjectError.sourceUnavailable
        }
        return try copyBundledSample(from: source, to: destination)
    }

    private func copyContents(from source: URL, to destination: URL) throws {
        for item in try fileSystem.directoryContents(at: source) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fileSystem.isDirectory(at: item) {
                try fileSystem.createDirectory(at: target)
                try copyContents(from: item, to: target)
            } else {
                try fileSystem.copyItem(at: item, to: target)
            }
        }
    }
}
