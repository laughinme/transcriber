import Foundation
import UniformTypeIdentifiers

/// A ggml whisper model file on disk.
public struct WhisperModel: Hashable, Identifiable, Sendable {
    public var url: URL
    public var id: String { url.path }
    /// `ggml-large-v3-turbo.bin` → `large-v3-turbo`.
    public var name: String {
        var n = url.deletingPathExtension().lastPathComponent
        if n.hasPrefix("ggml-") { n.removeFirst(5) }
        return n
    }
    public var size: Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
    }
}

/// Finds the external programs and models the app relies on. Apps launched from Finder do not
/// get the shell PATH, so Homebrew locations are searched explicitly.
public struct Toolchain: Sendable {
    public var whisperCLI: URL?
    public var ffmpeg: URL?
    public var models: [WhisperModel]
    public var vadModel: URL?

    public var isReady: Bool { whisperCLI != nil && ffmpeg != nil && !models.isEmpty }

    public static let binaryDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public static func modelDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appendingPathComponent(".whisper"),
            home.appendingPathComponent(".cache/whisper.cpp"),
            home.appendingPathComponent("Library/Application Support/Transcriber/Models"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"),
        ]
    }

    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Toolchain {
        let fm = FileManager.default
        func binary(_ name: String) -> URL? {
            (binaryDirectories + [home.appendingPathComponent(".local/bin").path])
                .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { fm.isExecutableFile(atPath: $0.path) }
        }
        var models: [WhisperModel] = []
        var vad: URL?
        for dir in modelDirectories(home: home) {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for f in files where f.pathExtension == "bin" && f.lastPathComponent.hasPrefix("ggml-") {
                let name = f.lastPathComponent.lowercased()
                if name.contains("silero") || name.contains("vad") {
                    if vad == nil { vad = f }
                } else if !name.contains("for-tests") && !models.contains(where: { $0.name == WhisperModel(url: f).name }) {
                    models.append(WhisperModel(url: f))
                }
            }
        }
        models.sort { rank($0) == rank($1) ? $0.size > $1.size : rank($0) < rank($1) }
        return Toolchain(whisperCLI: binary("whisper-cli"), ffmpeg: binary("ffmpeg"), models: models, vadModel: vad)
    }

    /// Preferred default: full large-v3, then turbo, then the biggest other model.
    static func rank(_ m: WhisperModel) -> Int {
        switch m.name {
        case "large-v3": 0
        case "large-v3-turbo": 1
        default: m.name.hasPrefix("large") ? 2 : 3
        }
    }
}

public enum MediaFiles {
    public static let extensions: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac", "aiff", "aif", "caf", "amr", "wma", "weba",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "mpg", "mpeg", "ts", "wmv", "flv",
    ]

    public static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    public static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "mpg", "mpeg", "ts", "wmv", "flv"].contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
    }

    /// Expands dropped items: files are kept if they look like media, folders are searched recursively.
    public static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = walker?.nextObject() as? URL {
                    if isMedia(f) { out.append(f) }
                }
            } else if isMedia(url) {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
