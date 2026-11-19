import Foundation
import Testing
@testable import TranscriberCore

@Suite struct WhisperOutputTests {
    @Test func parsesStdoutLine() throws {
        let s = try #require(WhisperOutput.parseLine("[00:01:03.790 --> 00:01:07.730]   В целом-то он интересно выглядит."))
        #expect(s.start == 63.79)
        #expect(abs(s.end - 67.73) < 0.0001)
        #expect(s.text == "В целом-то он интересно выглядит.")
    }

    @Test func ignoresNonSegmentLines() {
        #expect(WhisperOutput.parseLine("") == nil)
        #expect(WhisperOutput.parseLine("whisper_print_progress_callback: progress = 100%") == nil)
        #expect(WhisperOutput.parseLine("[BLANK_AUDIO]") == nil)
    }

    @Test func parsesJSONFile() throws {
        let json = """
        {"result": {"language": "ru"}, "transcription": [
          {"timestamps": {"from": "00:00:00,770", "to": "00:00:08,570"}, "offsets": {"from": 770, "to": 8570}, "text": " Привет."},
          {"timestamps": {"from": "00:00:08,570", "to": "00:00:13,290"}, "offsets": {"from": 8570, "to": 13290}, "text": " Как дела?"}
        ]}
        """
        let parsed = try WhisperOutput.parseJSON(Data(json.utf8))
        #expect(parsed.language == "ru")
        #expect(parsed.segments.count == 2)
        #expect(parsed.segments[0].start == 0.77)
        #expect(parsed.segments[1].text == " Как дела?")
    }
}

@Suite struct CleanupTests {
    @Test(arguments: [
        "Спасибо за субтитры Алексею Дубровскому!",
        "Субтитры сделал DimaTorzok",
        "Редактор субтитров А.Синецкая Корректор А.Егорова",
        "Продолжение следует...",
        "[МУЗЫКА]",
        "(музыка)",
        "Thank you for watching!",
    ])
    func dropsKnownHallucinations(_ text: String) {
        #expect(Cleanup.isHallucination(text))
    }

    @Test(arguments: [
        "Надо добавить субтитры к видео для тиктока.",
        "Спасибо за внимание к деталям, это важно.",
        "Включи музыку погромче",
    ])
    func keepsRealSpeech(_ text: String) {
        #expect(!Cleanup.isHallucination(text))
    }

    @Test func mergesRepeatedSegments() {
        let cleaned = Cleanup.clean([
            Segment(start: 0, end: 2, text: " Ну да."),
            Segment(start: 2, end: 4, text: "ну да"),
            Segment(start: 4, end: 6, text: "Ну да!"),
            Segment(start: 6, end: 8, text: " Дальше."),
            Segment(start: 8, end: 9, text: "  "),
        ])
        #expect(cleaned.map(\.text) == ["Ну да.", "Дальше."])
        #expect(cleaned[0].end == 6)
    }
}

@Suite struct FormatTests {
    let transcript = Transcript(
        segments: [
            Segment(start: 0.5, end: 4, text: "Первая фраза."),
            Segment(start: 4.2, end: 7, text: "Вторая фраза."),
            Segment(start: 75, end: 80, text: "После паузы."),
        ],
        language: "ru", duration: 81, model: "large-v3-turbo"
    )

    @Test func clockFormat() {
        #expect(TimeFormat.clock(5) == "0:05")
        #expect(TimeFormat.clock(81.9) == "1:21")
        #expect(TimeFormat.clock(3723) == "1:02:03")
        #expect(TimeFormat.subtitle(63.79, separator: ",") == "00:01:03,790")
    }

    @Test func paragraphsBreakOnPause() {
        let p = Paragraphs.group(transcript.segments)
        #expect(p.count == 2)
        #expect(p[0].text == "Первая фраза. Вторая фраза.")
        #expect(p[1].start == 75)
        #expect(transcript.plainText == "Первая фраза. Вторая фраза.\n\nПосле паузы.")
    }

    @Test func paragraphStartsWithCapital() {
        let p = Paragraphs.group([Segment(start: 0, end: 1, text: "бюджет, да."), Segment(start: 5, end: 6, text: "ёлки.")])
        #expect(p.map(\.text) == ["Бюджет, да.", "Ёлки."])
    }

    @Test func markdownHasTimestampsAndMeta() {
        let md = Renderer.render(transcript, as: .md, context: RenderContext(title: "голос.ogg"))
        #expect(md.hasPrefix("# голос.ogg\n\n1:21 · русский · расшифровано"))
        #expect(md.contains("**[0:00]** Первая фраза. Вторая фраза."))
        #expect(md.contains("**[1:15]** После паузы."))
    }

    @Test func srtNumbersCues() {
        let srt = Renderer.render(transcript, as: .srt, context: RenderContext(title: "x"))
        #expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:04,000\nПервая фраза.\n"))
        #expect(srt.contains("\n3\n00:01:15,000 --> 00:01:20,000\nПосле паузы.\n"))
    }

    @Test func vttHeader() {
        let vtt = Renderer.render(transcript, as: .vtt, context: RenderContext(title: "x"))
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:04.000\n"))
    }

    @Test func longSegmentsSplitIntoShortCues() {
        let long = String(repeating: "слово ", count: 40).trimmingCharacters(in: .whitespaces)
        let cues = Renderer.cues([Segment(start: 10, end: 30, text: long)])
        #expect(cues.count > 1)
        #expect(cues.allSatisfy { $0.text.replacingOccurrences(of: "\n", with: " ").count <= 84 })
        #expect(cues.first?.start == 10)
        #expect(cues.last?.end == 30)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func jsonRoundTrips() throws {
        let json = Renderer.render(transcript, as: .json, context: RenderContext(title: "голос.ogg"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["file"] as? String == "голос.ogg")
        #expect((obj["segments"] as? [[String: Any]])?.count == 3)
    }
}

@Suite struct OutputWriterTests {
    @Test func writesNextToSourceWithoutOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("голос 1.ogg")
        try "моё".write(to: dir.appendingPathComponent("голос 1.txt"), atomically: true, encoding: .utf8)

        let t = Transcript(segments: [Segment(start: 0, end: 1, text: "Текст.")])
        let urls = try OutputWriter.write(t, formats: [.txt, .md], source: source, folder: dir)

        #expect(urls.map(\.lastPathComponent) == ["голос 1 2.txt", "голос 1.md"])
        #expect(try String(contentsOf: dir.appendingPathComponent("голос 1.txt"), encoding: .utf8) == "моё")
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "Текст.\n")
    }
}

@Suite struct MediaFilesTests {
    @Test func recognizesMedia() {
        #expect(MediaFiles.isMedia(URL(fileURLWithPath: "/a/2026-11-19 6.40.56 PM.ogg")))
        #expect(MediaFiles.isMedia(URL(fileURLWithPath: "/a/clip.MOV")))
        #expect(!MediaFiles.isMedia(URL(fileURLWithPath: "/a/notes.pdf")))
        #expect(MediaFiles.isVideo(URL(fileURLWithPath: "/a/clip.mp4")))
        #expect(!MediaFiles.isVideo(URL(fileURLWithPath: "/a/voice.m4a")))
    }

    @Test func expandsFoldersRecursively() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "b.ogg", "sub/c.mp4", "sub/d.pdf", "sub/e.m4a"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        #expect(MediaFiles.expand([dir]).map(\.lastPathComponent) == ["b.ogg", "c.mp4", "e.m4a"])
    }
}

@Suite struct OptionsTests {
    let model = WhisperModel(url: URL(fileURLWithPath: "/m/ggml-large-v3-turbo.bin"))

    @Test func modelName() {
        #expect(model.name == "large-v3-turbo")
    }

    @Test func russianGetsPunctuationHintAndVAD() {
        let args = TranscriptionOptions(language: "ru", model: model)
            .whisperArguments(vadModel: URL(fileURLWithPath: "/m/ggml-silero.bin"), outputBase: URL(fileURLWithPath: "/tmp/out"))
        #expect(args.contains("--vad"))
        #expect(args.contains("--prompt"))
        #expect(args.contains("--carry-initial-prompt"))
        #expect(!args.contains("-tr"))
    }

    @Test func autoLanguageHasNoHint() {
        let args = TranscriptionOptions(language: "auto", model: model, useVAD: false, translateToEnglish: true)
            .whisperArguments(vadModel: nil, outputBase: URL(fileURLWithPath: "/tmp/out"))
        #expect(!args.contains("--prompt"))
        #expect(!args.contains("--vad"))
        #expect(args.contains("-tr"))
    }
}

/// End-to-end run on the real whisper-cli. Slow (model load), so opt-in:
/// `TRANSCRIBER_E2E=1 make test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIBER_E2E"] == "1"))
struct EndToEndTests {
    @Test func transcribesSynthesizedRussianSpeech() async throws {
        let toolchain = Toolchain.discover()
        let model = try #require(toolchain.models.first)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("speech.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Milena", "-o", audio.path, "--data-format=aac", "Привет! Это проверка расшифровки. Сегодня хорошая погода."]
        try say.run()
        say.waitUntilExit()

        let phases = Locked<[TranscriptionPhase]>([])
        let transcript = try await WhisperRunner(toolchain: toolchain).transcribe(
            audio, options: TranscriptionOptions(language: "ru", model: model),
            onPhase: { p in phases.mutate { $0.append(p) } }, onSegment: { _ in }
        )
        let text = transcript.plainText.lowercased()
        #expect(text.contains("привет"))
        #expect(text.contains("погода"))
        #expect(transcript.language == "ru")
        #expect((transcript.duration ?? 0) > 2)
        #expect(phases.value.first == .preparing)
    }

    @Test func reportsFileWithoutAudio() async throws {
        let toolchain = Toolchain.discover()
        let model = try #require(toolchain.models.first)
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        await #expect(throws: TranscriptionError.self) {
            _ = try await WhisperRunner(toolchain: toolchain).transcribe(
                bogus, options: TranscriptionOptions(language: "ru", model: model), onPhase: { _ in }, onSegment: { _ in }
            )
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
