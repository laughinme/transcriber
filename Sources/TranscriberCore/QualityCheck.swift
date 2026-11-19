import Foundation

/// Structural warnings about a finished transcript. They point at places worth listening to;
/// they do not measure recognition accuracy.
public enum QualityCheck {
    /// One phrase of three or more words repeated this often, and making up this share of all
    /// segments, means whisper got stuck in a loop.
    static let loopCount = 10
    static let loopShare = 0.15

    public static func warnings(raw: [Segment], cleaned: [Segment], duration: Double?) -> [String] {
        var out: [String] = []

        var counts: [String: Int] = [:]
        for s in raw where s.text.split(separator: " ").count >= 3 {
            counts[normalized(s.text), default: 0] += 1
        }
        if let maxRepeat = counts.values.max(), maxRepeat >= loopCount, Double(maxRepeat) / Double(raw.count) >= loopShare {
            out.append("Распознавание зациклилось: одна фраза повторилась \(maxRepeat) раз. Проверьте это место на слух или расшифруйте заново другой моделью.")
        }

        if let duration, duration >= 60, let lastEnd = cleaned.last?.end, lastEnd < duration * 0.5 {
            out.append("Речь заканчивается на \(TimeFormat.clock(lastEnd)) из \(TimeFormat.clock(duration)). Дальше тишина или обрыв, стоит проверить.")
        }
        return out
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }
}
