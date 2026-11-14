import Foundation

/// One session as it sits on disk.
public struct StoredSession: Sendable, Equatable {
    public var manifest: SessionManifest
    public var frames: [FaceFrame]
    public var audio: [Int16]

    public init(manifest: SessionManifest, frames: [FaceFrame], audio: [Int16]) {
        self.manifest = manifest
        self.frames = frames
        self.audio = audio
    }
}

/// Writes and reads session folders:
///
///     <root>/2026-11-07/<sessionId>/{manifest.json, face.bin, audio.wav}
///
/// `ml/silentml/data.py` reads the same folders. `manifest.json` is written last, so a folder
/// with a manifest is a complete session.
public struct SessionStore: Sendable {
    public static let manifestName = "manifest.json"
    public static let faceName = "face.bin"
    public static let audioName = "audio.wav"

    public let root: URL
    /// Decides which day folder a session lands in.
    public let timeZone: TimeZone

    public init(root: URL = SessionStore.defaultRoot, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    /// `~/Library/Application Support/TacitType/sessions`
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "TacitType/sessions", directoryHint: .isDirectory)
    }

    public func folder(for manifest: SessionManifest) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: manifest.createdAt)
        let name = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return root.appending(path: name, directoryHint: .isDirectory)
            .appending(path: manifest.sessionId.uuidString, directoryHint: .isDirectory)
    }

    @discardableResult
    public func write(_ session: StoredSession) throws -> URL {
        let folder = folder(for: session.manifest)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FaceFile.encode(session.frames).write(to: folder.appending(path: Self.faceName))
        try WavFile.encode(session.audio).write(to: folder.appending(path: Self.audioName))
        try Self.encode(session.manifest).write(to: folder.appending(path: Self.manifestName), options: .atomic)
        return folder
    }

    public func read(at folder: URL) throws -> StoredSession {
        let manifest = try readManifest(at: folder)
        let frames = try FaceFile.decode(Data(contentsOf: folder.appending(path: Self.faceName)))
        let wav = try WavFile.decode(Data(contentsOf: folder.appending(path: Self.audioName)))
        guard wav.sampleRate == Int(Constants.audioSampleRate) else {
            throw SessionFileError.unsupportedWav("sample rate \(wav.sampleRate)")
        }
        return StoredSession(manifest: manifest, frames: frames, audio: wav.samples)
    }

    public func readManifest(at folder: URL) throws -> SessionManifest {
        try Self.decoder.decode(SessionManifest.self, from: Data(contentsOf: folder.appending(path: Self.manifestName)))
    }

    /// Every complete session folder under `root`, oldest day first.
    public func sessionFolders() -> [URL] {
        let files = FileManager.default
        let days = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return days.sorted { $0.path < $1.path }.flatMap { day in
            ((try? files.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? [])
                .filter { files.fileExists(atPath: $0.appending(path: Self.manifestName).path) }
                .sorted { $0.path < $1.path }
        }
    }

    public func manifests() -> [SessionManifest] {
        sessionFolders().compactMap { try? readManifest(at: $0) }
    }

    /// Bytes used by everything under `root`.
    public func diskUsage() -> Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Manifest JSON

    /// Sorted keys and ISO 8601 dates, so the same manifest always gives the same bytes.
    public static func encode(_ manifest: SessionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
