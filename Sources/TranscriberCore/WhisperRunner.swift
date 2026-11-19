import Foundation

public struct TranscriptionOptions: Sendable, Hashable {
    /// Whisper language code, or "auto".
    public var language: String
    public var model: WhisperModel
    public var useVAD: Bool
    public var translateToEnglish: Bool
    /// Short punctuated sentence in the target language; nudges whisper to keep punctuation.
    public var punctuationHint: Bool

    public init(language: String, model: WhisperModel, useVAD: Bool = true, translateToEnglish: Bool = false, punctuationHint: Bool = true) {
        self.language = language
        self.model = model
        self.useVAD = useVAD
        self.translateToEnglish = translateToEnglish
        self.punctuationHint = punctuationHint
    }

    static let hints = [
        "ru": "Привет! Это голосовое сообщение, с пунктуацией.",
        "en": "Hello! This is a voice message, with punctuation.",
        "uk": "Привіт! Це голосове повідомлення, з пунктуацією.",
    ]

    /// Arguments for whisper-cli, excluding the input file.
    public func whisperArguments(vadModel: URL?, outputBase: URL) -> [String] {
        var args = ["-m", model.url.path, "-l", language, "-mc", "0", "-oj", "-of", outputBase.path]
        if translateToEnglish { args.append("-tr") }
        if useVAD, let vadModel { args += ["--vad", "-vm", vadModel.path] }
        if punctuationHint, let hint = Self.hints[language] { args += ["--prompt", hint] }
        return args
    }
}

public enum TranscriptionPhase: Sendable, Equatable {
    case preparing
    case recognizing(fraction: Double)
}

public enum TranscriptionError: LocalizedError {
    case toolMissing(String)
    case noAudio(String)
    case whisperFailed(String)
    case unreadableOutput

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool): "Не найден \(tool). Установите: brew install whisper-cpp ffmpeg"
        case .noAudio(let details): "Не удалось достать звук из файла. \(details)"
        case .whisperFailed(let details): "Whisper завершился с ошибкой. \(details)"
        case .unreadableOutput: "Whisper не записал результат."
        }
    }
}

/// Converts any audio or video to 16 kHz mono WAV with ffmpeg, runs whisper-cli on it and
/// returns the cleaned transcript. Cancelling the task terminates the running process.
public struct WhisperRunner: Sendable {
    public var toolchain: Toolchain

    public init(toolchain: Toolchain) {
        self.toolchain = toolchain
    }

    public func transcribe(
        _ file: URL,
        options: TranscriptionOptions,
        onPhase: @escaping @Sendable (TranscriptionPhase) -> Void,
        onSegment: @escaping @Sendable (Segment) -> Void
    ) async throws -> Transcript {
        guard let ffmpeg = toolchain.ffmpeg else { throw TranscriptionError.toolMissing("ffmpeg") }
        guard let whisper = toolchain.whisperCLI else { throw TranscriptionError.toolMissing("whisper-cli") }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        onPhase(.preparing)
        let wav = work.appendingPathComponent("audio.wav")
        let convert = try await ProcessRunner.run(
            ffmpeg,
            ["-nostdin", "-v", "error", "-y", "-i", file.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path],
            logFile: work.appendingPathComponent("ffmpeg.log")
        )
        let wavSize = (try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard convert.status == 0, wavSize > 44 else {
            throw TranscriptionError.noAudio(convert.logTail.isEmpty ? "В файле нет звуковой дорожки." : convert.logTail)
        }
        // 16-bit mono at 16 kHz: 32 000 bytes per second after the 44-byte header.
        let duration = Double(wavSize - 44) / 32_000

        onPhase(.recognizing(fraction: 0))
        let base = work.appendingPathComponent("out")
        let result = try await ProcessRunner.run(
            whisper,
            options.whisperArguments(vadModel: toolchain.vadModel, outputBase: base) + [wav.path],
            logFile: work.appendingPathComponent("whisper.log")
        ) { line in
            guard let segment = WhisperOutput.parseLine(line) else { return }
            onSegment(segment)
            if duration > 0 { onPhase(.recognizing(fraction: min(1, segment.end / duration))) }
        }
        try Task.checkCancellation()
        guard result.status == 0 else { throw TranscriptionError.whisperFailed(result.logTail) }
        guard let data = try? Data(contentsOf: base.appendingPathExtension("json")) else {
            throw TranscriptionError.unreadableOutput
        }
        let parsed = try WhisperOutput.parseJSON(data)
        return Transcript(
            segments: Cleanup.clean(parsed.segments),
            language: options.translateToEnglish ? "en" : (parsed.language ?? (options.language == "auto" ? nil : options.language)),
            duration: duration,
            model: options.model.name
        )
    }
}

/// Runs a process, streams stdout lines to a callback, sends stderr to a log file.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var logTail: String
    }

    static func run(_ executable: URL, _ arguments: [String], logFile: URL, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out

        return try await withTaskCancellationHandler {
            try process.run()
            for try await line in out.fileHandleForReading.bytes.lines {
                onLine?(line)
            }
            process.waitUntilExit()
            try Task.checkCancellation()
            let tail = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            let lines = tail.split(separator: "\n").filter { !$0.hasPrefix("whisper_") && !$0.hasPrefix("ggml_") && !$0.hasPrefix("load_backend") }
            return Result(status: process.terminationStatus, logTail: lines.suffix(3).joined(separator: "\n"))
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
