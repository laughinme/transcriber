import Foundation

public struct TranscriptionOptions: Sendable, Hashable {
    /// Whisper language code, or "auto".
    public var language: String
    public var model: WhisperModel
    public var useVAD: Bool
    public var translateToEnglish: Bool
    /// Short punctuated sentence in the target language; nudges whisper to keep punctuation.
    public var punctuationHint: Bool
    /// Names and terms that occur in the recordings; whisper spells them as given.
    public var vocabulary: String
    /// Two threads at utility priority: slower, but the Mac stays responsive.
    public var gentle: Bool

    public init(language: String, model: WhisperModel, useVAD: Bool = true, translateToEnglish: Bool = false,
                punctuationHint: Bool = true, vocabulary: String = "", gentle: Bool = false) {
        self.language = language
        self.model = model
        self.useVAD = useVAD
        self.translateToEnglish = translateToEnglish
        self.punctuationHint = punctuationHint
        self.vocabulary = vocabulary
        self.gentle = gentle
    }

    /// whisper accepts up to half of its 448-token text context as a prompt.
    static let vocabularyLimit = 400

    public var prompt: String? {
        var parts: [String] = []
        if punctuationHint, let hint = Self.hints[language] { parts.append(hint) }
        let words = vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !words.isEmpty { parts.append(String(words.prefix(Self.vocabularyLimit))) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
        if gentle { args += ["-t", "2"] }
        // The prompt must reach every 30-second window, not only the first one.
        if let prompt { args += ["--prompt", prompt, "--carry-initial-prompt"] }
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
        let qos: QualityOfService = options.gentle ? .utility : .userInitiated
        let convert = try await ProcessRunner.run(
            ffmpeg, qos: qos,
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
            whisper, qos: qos,
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
        let segments = Cleanup.clean(parsed.segments)
        let warnings = QualityCheck.warnings(raw: parsed.segments, cleaned: segments, duration: duration)
        // With no speech whisper still reports its default "en"; that would be misleading.
        let language: String? = segments.isEmpty ? nil
            : options.translateToEnglish ? "en"
            : parsed.language ?? (options.language == "auto" ? nil : options.language)
        return Transcript(
            segments: segments,
            language: language,
            duration: duration,
            model: options.model.name,
            warnings: warnings
        )
    }
}

/// Runs a process, streams stdout lines to a callback, sends stderr to a log file.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var logTail: String
    }

    static func run(_ executable: URL, qos: QualityOfService = .userInitiated, _ arguments: [String], logFile: URL,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = qos
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
