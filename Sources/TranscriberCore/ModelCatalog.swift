import CryptoKit
import Foundation

/// A model the app can download from HuggingFace.
public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public let file: String
    public let repo: String
    public let title: String
    public let summary: String
    public let approxBytes: Int64
    public let recommended: Bool

    public var id: String { file }
    /// `ggml-large-v3-turbo.bin` → `large-v3-turbo`, same as `WhisperModel.name`.
    public var name: String { WhisperModel(url: URL(fileURLWithPath: file)).name }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")!
    }
}

public enum ModelCatalog {
    public static let whisperRepo = "ggerganov/whisper.cpp"
    public static let vadRepo = "ggml-org/whisper-vad"

    /// Multilingual models only: English-only (.en) variants cannot transcribe Russian.
    public static let whisper: [CatalogEntry] = [
        entry("ggml-large-v3-turbo.bin", "Large v3 Turbo",
              "Быстрая и точная, хороша для русского. Час записи примерно за 5 минут на M-серии.",
              1_624_555_275, recommended: true),
        entry("ggml-large-v3-turbo-q8_0.bin", "Large v3 Turbo, сжатая 8 бит",
              "Почти та же точность, вдвое меньше места.", 874_188_075),
        entry("ggml-large-v3-turbo-q5_0.bin", "Large v3 Turbo, сжатая 5 бит",
              "Для небольшого диска. Чуть чаще ошибается в редких словах.", 574_041_195),
        entry("ggml-large-v3.bin", "Large v3",
              "Самая точная, но в 3–4 раза медленнее Turbo. Для трудных записей.", 3_095_033_483),
        entry("ggml-large-v3-q5_0.bin", "Large v3, сжатая 5 бит",
              "Точность Large v3 при трети размера.", 1_081_140_203),
        entry("ggml-medium.bin", "Medium",
              "Предыдущее поколение: заметно хуже Turbo при похожем размере.", 1_533_763_059),
        entry("ggml-small.bin", "Small",
              "Быстрая, для черновой расшифровки чистой речи.", 487_601_967),
        entry("ggml-base.bin", "Base",
              "Очень быстрая, много ошибок в русском.", 147_951_465),
        entry("ggml-tiny.bin", "Tiny",
              "Для проверки, что всё работает.", 77_691_713),
    ]

    public static let vad = CatalogEntry(
        file: "ggml-silero-v6.2.0.bin", repo: vadRepo, title: "Детектор речи Silero",
        summary: "Вырезает тишину, чтобы whisper не выдумывал фразы на паузах.",
        approxBytes: 885_098, recommended: true)

    private static func entry(_ file: String, _ title: String, _ summary: String, _ bytes: Int64, recommended: Bool = false) -> CatalogEntry {
        CatalogEntry(file: file, repo: whisperRepo, title: title, summary: summary, approxBytes: bytes, recommended: recommended)
    }
}

/// Size and SHA-256 published by HuggingFace for a file in a repo.
public struct RemoteFileInfo: Sendable, Equatable {
    public let size: Int64
    public let sha256: String
}

public enum HuggingFace {
    private struct TreeItem: Decodable {
        struct LFS: Decodable { let oid: String; let size: Int64 }
        let path: String
        let size: Int64
        let lfs: LFS?
    }

    public static func info(for entry: CatalogEntry, session: URLSession = .shared) async throws -> RemoteFileInfo {
        let url = URL(string: "https://huggingface.co/api/models/\(entry.repo)/tree/main?limit=200")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.metadataUnavailable }
        return try parseInfo(data, file: entry.file)
    }

    static func parseInfo(_ data: Data, file: String) throws -> RemoteFileInfo {
        let items = try JSONDecoder().decode([TreeItem].self, from: data)
        guard let item = items.first(where: { $0.path == file }), let lfs = item.lfs else {
            throw DownloadError.metadataUnavailable
        }
        return RemoteFileInfo(size: lfs.size, sha256: lfs.oid)
    }
}

public enum DownloadError: LocalizedError, Equatable {
    case metadataUnavailable
    case badStatus(Int)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .metadataUnavailable: "Не удалось получить описание модели с HuggingFace. Проверьте интернет."
        case .badStatus(let code): "HuggingFace ответил ошибкой \(code)."
        case .checksumMismatch: "Файл скачался с ошибкой (не совпала контрольная сумма). Попробуйте ещё раз."
        }
    }
}

public enum Checksum {
    /// SHA-256 of a file, read in 8 MB chunks so multi-gigabyte models do not fill memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads a model into `folder`: resumes after network errors, verifies size and SHA-256,
/// and only then moves the file into place, so a half-downloaded model never looks installed.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public enum Phase: Sendable, Equatable {
        case downloading(received: Int64, total: Int64)
        case verifying
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onPhase: (@Sendable (Phase) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var keptFile: URL?

    public override init() {}

    public func download(
        _ entry: CatalogEntry,
        into folder: URL,
        maxRetries: Int = 3,
        onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws -> URL {
        let info = try await HuggingFace.info(for: entry)
        self.onPhase = onPhase
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }
        defer { session.finishTasksAndInvalidate() }

        var resumeData: Data?
        var attempt = 0
        var downloaded: URL
        while true {
            do {
                downloaded = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                        lock.withLock {
                            continuation = c
                            let t = resumeData.map { session.downloadTask(withResumeData: $0) }
                                ?? session.downloadTask(with: entry.downloadURL)
                            task = t
                            t.resume()
                        }
                    }
                } onCancel: {
                    lock.withLock { task?.cancel() }
                }
                break
            } catch {
                try Task.checkCancellation()
                let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                attempt += 1
                guard attempt <= maxRetries, (error as? DownloadError) == nil else { throw error }
                resumeData = data
                try await Task.sleep(for: .seconds(Double(attempt * 2)))
            }
        }

        onPhase(.verifying)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == info.size, try Checksum.sha256(of: downloaded) == info.sha256 else {
            throw DownloadError.checksumMismatch
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // URLSession keeps downloads owner-only; models are ordinary shared files.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: downloaded.path)
        let target = folder.appendingPathComponent(entry.file)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: downloaded)
        } else {
            try FileManager.default.moveItem(at: downloaded, to: target)
        }
        return target
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onPhase?(.downloading(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns: keep the file first.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            finish(.failure(DownloadError.badStatus(status)))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            lock.withLock { keptFile = kept }
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let kept = lock.withLock({ keptFile }) {
            finish(.success(kept))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let c: CheckedContinuation<URL, Error>? = lock.withLock {
            defer { continuation = nil; keptFile = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
