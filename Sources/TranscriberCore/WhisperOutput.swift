import Foundation

/// Parsers for what whisper-cli writes: the `-oj` JSON file and the live segment lines on stdout.
public enum WhisperOutput {
    private struct File: Decodable {
        struct Result: Decodable { let language: String? }
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let result: Result?
        let transcription: [Item]
    }

    /// Parses the JSON written by `whisper-cli -oj`.
    public static func parseJSON(_ data: Data) throws -> (segments: [Segment], language: String?) {
        let file = try JSONDecoder().decode(File.self, from: data)
        let segments = file.transcription.map {
            Segment(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000, text: $0.text)
        }
        return (segments, file.result?.language)
    }

    /// Parses a stdout line like `[00:00:03.790 --> 00:00:07.730]   Текст`.
    public static func parseLine(_ line: String) -> Segment? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let stamps = line[line.index(after: line.startIndex)..<close].components(separatedBy: " --> ")
        guard stamps.count == 2, let start = seconds(stamps[0]), let end = seconds(stamps[1]) else { return nil }
        let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return Segment(start: start, end: end, text: text)
    }

    /// `hh:mm:ss.mmm` → seconds.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

/// Removes what whisper invents on silence and noise: credit lines from the subtitle corpora it
/// was trained on, bracketed sound tags, and loops of the same phrase.
public enum Cleanup {
    static let hallucinations: [NSRegularExpression] = [
        #"спасибо за субтитры"#,
        #"субтитры (сделал|сделала|делал|делала|подготовил|подготовила|создавал|создавала|создал)"#,
        #"(редактор|корректор)(ы)? субтитров"#,
        #"^субтитры( от| by)?\b"#,
        #"продолжение следует\.*$"#,
        #"спасибо за (просмотр|внимание)[.!]*$"#,
        #"подписывайтесь на (наш )?канал"#,
        #"^ставьте лайки"#,
        #"thank(s| you) for watching"#,
        #"amara\.org"#,
        #"dimatorzok"#,
        #"^[\[\(](музыка|music|аплодисменты|applause|смех|laughter|тишина|silence|blank_audio)[\]\)]\.?$"#,
        #"^[\[\(]\s*(музыка|music)[^\]\)]*[\]\)]$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func isHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(t.startIndex..., in: t)
        return hallucinations.contains { $0.firstMatch(in: t, range: range) != nil }
    }

    public static func clean(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for var segment in segments {
            segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segment.text.isEmpty || isHallucination(segment.text) { continue }
            if let last = out.last, normalized(last.text) == normalized(segment.text) {
                out[out.count - 1].end = segment.end
                continue
            }
            out.append(segment)
        }
        return out
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
