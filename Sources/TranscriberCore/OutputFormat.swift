import Foundation

public enum OutputFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case txt, md, srt, vtt, json

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .txt: "Текст"
        case .md: "Текст с таймкодами"
        case .srt: "Субтитры SRT"
        case .vtt: "Субтитры WebVTT"
        case .json: "JSON с сегментами"
        }
    }

    public var hint: String {
        switch self {
        case .txt: "сплошной текст по абзацам, удобно отдать в чат или агенту"
        case .md: "абзацы с отметками времени [01:15]"
        case .srt: "для плееров, CapCut, Premiere, YouTube"
        case .vtt: "для веба и HTML5-видео"
        case .json: "сегменты с таймкодами для скриптов"
        }
    }
}

public struct RenderContext: Sendable {
    public var title: String
    public var date: Date

    public init(title: String, date: Date = Date()) {
        self.title = title
        self.date = date
    }
}

public enum Renderer {
    public static func render(_ transcript: Transcript, as format: OutputFormat, context: RenderContext) -> String {
        switch format {
        case .txt: transcript.plainText + "\n"
        case .md: markdown(transcript, context: context)
        case .srt: srt(transcript)
        case .vtt: vtt(transcript)
        case .json: json(transcript, context: context)
        }
    }

    // MARK: Markdown

    static func markdown(_ t: Transcript, context: RenderContext) -> String {
        var meta: [String] = []
        if let d = t.duration { meta.append(TimeFormat.clock(d)) }
        if let l = t.language { meta.append(LanguageName.name(for: l)) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy, HH:mm"
        meta.append("расшифровано \(df.string(from: context.date))")
        if let m = t.model { meta.append("whisper \(m)") }

        var lines = ["# \(context.title)", "", meta.joined(separator: " · "), ""]
        for p in Paragraphs.group(t.segments) {
            lines.append("**[\(TimeFormat.clock(p.start))]** \(p.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Subtitles

    /// Subtitle cues: long whisper segments are split at word boundaries into cues of at most
    /// `maxChars`, time is shared out by character count, text wrapped into two lines.
    public static func cues(_ segments: [Segment], maxChars: Int = 84) -> [Segment] {
        var cues: [Segment] = []
        for s in segments {
            let words = s.text.split(separator: " ").map(String.init)
            var chunks: [String] = []
            var current = ""
            for w in words {
                if !current.isEmpty, current.count + 1 + w.count > maxChars {
                    chunks.append(current)
                    current = w
                } else {
                    current = current.isEmpty ? w : current + " " + w
                }
            }
            if !current.isEmpty { chunks.append(current) }
            let total = Double(chunks.reduce(0) { $0 + $1.count })
            var t = s.start
            for c in chunks {
                let share = total > 0 ? Double(c.count) / total : 1
                let end = c == chunks.last ? s.end : t + (s.end - s.start) * share
                cues.append(Segment(start: t, end: end, text: wrap(c, width: maxChars / 2)))
                t = end
            }
        }
        return cues
    }

    static func wrap(_ text: String, width: Int) -> String {
        guard text.count > width else { return text }
        let words = text.split(separator: " ")
        var best = text, bestDiff = Int.max
        for i in 1..<words.count {
            let a = words[..<i].joined(separator: " "), b = words[i...].joined(separator: " ")
            let diff = abs(a.count - b.count)
            if diff < bestDiff { bestDiff = diff; best = a + "\n" + b }
        }
        return best
    }

    static func srt(_ t: Transcript) -> String {
        cues(t.segments).enumerated().map { i, c in
            "\(i + 1)\n\(TimeFormat.subtitle(c.start, separator: ",")) --> \(TimeFormat.subtitle(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ t: Transcript) -> String {
        "WEBVTT\n\n" + cues(t.segments).map { c in
            "\(TimeFormat.subtitle(c.start, separator: ".")) --> \(TimeFormat.subtitle(c.end, separator: "."))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: JSON

    private struct JSONFile: Encodable {
        let file: String
        let language: String?
        let duration: Double?
        let model: String?
        let segments: [Segment]
    }

    static func json(_ t: Transcript, context: RenderContext) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let rounded = t.segments.map {
            Segment(start: ($0.start * 1000).rounded() / 1000, end: ($0.end * 1000).rounded() / 1000, text: $0.text)
        }
        let file = JSONFile(file: context.title, language: t.language, duration: t.duration, model: t.model, segments: rounded)
        let data = (try? enc.encode(file)) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}

public enum LanguageName {
    static let names = [
        "ru": "русский", "en": "английский", "uk": "украинский", "de": "немецкий", "fr": "французский",
        "es": "испанский", "it": "итальянский", "zh": "китайский", "ja": "японский", "ko": "корейский",
        "tr": "турецкий", "pl": "польский", "kk": "казахский", "be": "белорусский",
    ]

    public static func name(for code: String) -> String {
        names[code] ?? Locale(identifier: "ru_RU").localizedString(forLanguageCode: code) ?? code
    }
}

public enum OutputWriter {
    /// Finder-style free name: `voice.txt`, then `voice 2.txt`, `voice 3.txt`.
    public static func freeURL(in folder: URL, stem: String, ext: String, fileManager: FileManager = .default) -> URL {
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Writes the transcript in each format into `folder` and returns the written files.
    @discardableResult
    public static func write(_ transcript: Transcript, formats: [OutputFormat], source: URL, folder: URL, date: Date = Date()) throws -> [URL] {
        let stem = source.deletingPathExtension().lastPathComponent
        let context = RenderContext(title: source.lastPathComponent, date: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try formats.map { format in
            let url = freeURL(in: folder, stem: stem, ext: format.fileExtension)
            try Renderer.render(transcript, as: format, context: context).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
