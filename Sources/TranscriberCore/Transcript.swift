import Foundation

/// One recognized piece of speech with its position in the recording, in seconds.
public struct Segment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Result of transcribing one file. Every output format is rendered from this.
public struct Transcript: Codable, Hashable, Sendable {
    public var segments: [Segment]
    /// Language code reported by whisper, e.g. "ru".
    public var language: String?
    /// Recording length in seconds.
    public var duration: Double?
    /// Model name, e.g. "large-v3-turbo".
    public var model: String?

    public init(segments: [Segment], language: String? = nil, duration: Double? = nil, model: String? = nil) {
        self.segments = segments
        self.language = language
        self.duration = duration
        self.model = model
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Plain text without timestamps, paragraphs separated by a blank line.
    public var plainText: String {
        Paragraphs.group(segments).map(\.text).joined(separator: "\n\n")
    }
}

public enum TimeFormat {
    /// `1:05`, `12:30`, `1:02:03`: for reading.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `00:01:05,250` (SRT) or `00:01:05.250` (VTT).
    public static func subtitle(_ seconds: Double, separator: Character) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        let h = ms / 3_600_000, m = (ms % 3_600_000) / 60_000, s = (ms % 60_000) / 1000, f = ms % 1000
        return String(format: "%02d:%02d:%02d\(separator)%03d", h, m, s, f)
    }
}

/// Groups segments into readable paragraphs: a new paragraph starts after a pause or once
/// the current one is long and ends on a sentence boundary.
public enum Paragraphs {
    public struct Paragraph: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public static let pauseThreshold = 2.0
    public static let softLimit = 450

    public static func group(_ segments: [Segment]) -> [Paragraph] {
        var result: [Paragraph] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = result.last {
                let pause = segment.start - last.end
                let endsSentence = last.text.last.map { ".!?…".contains($0) } ?? false
                let breakHere = pause >= pauseThreshold || (last.text.count >= softLimit && endsSentence)
                if !breakHere {
                    last.text += " " + text
                    last.end = segment.end
                    result[result.count - 1] = last
                    continue
                }
            }
            result.append(Paragraph(start: segment.start, end: segment.end, text: text))
        }
        return result
    }
}
