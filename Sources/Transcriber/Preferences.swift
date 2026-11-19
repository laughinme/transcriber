import Foundation
import TranscriberCore

/// UserDefaults keys and defaults shared by views (@AppStorage) and the queue.
enum Pref {
    static let language = "language"
    static let formats = "formats"
    static let modelPath = "modelPath"
    static let useVAD = "useVAD"
    static let punctuationHint = "punctuationHint"
    static let translate = "translate"
    static let saveMode = "saveMode"
    static let saveFolder = "saveFolder"
    static let showTimestamps = "showTimestamps"
    static let vocabulary = "vocabulary"
    static let gentle = "gentle"
    static let settingsTab = "settingsTab"

    static let defaultLanguage = "ru"
    static let defaultFormats = "txt,md"
    static var defaultFolder: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Расшифровки").path
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: defaultLanguage,
            formats: defaultFormats,
            modelPath: "",
            useVAD: true,
            punctuationHint: true,
            translate: false,
            saveMode: SaveMode.nextToSource.rawValue,
            saveFolder: defaultFolder,
            showTimestamps: true,
            vocabulary: "",
            gentle: false,
            settingsTab: SettingsTab.general.rawValue,
        ])
    }

    static func formats(from raw: String) -> [OutputFormat] {
        let set = Set(raw.split(separator: ",").map(String.init))
        return OutputFormat.allCases.filter { set.contains($0.rawValue) }
    }

    static func raw(from formats: [OutputFormat]) -> String {
        formats.map(\.rawValue).joined(separator: ",")
    }
}

enum SaveMode: String, CaseIterable, Identifiable {
    case nextToSource, folder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextToSource: "Рядом с исходным файлом"
        case .folder: "В выбранную папку"
        }
    }
}

struct Language: Identifiable, Hashable {
    let code: String
    let title: String
    var id: String { code }

    static let all = [
        Language(code: "ru", title: "Русский"),
        Language(code: "en", title: "Английский"),
        Language(code: "uk", title: "Украинский"),
        Language(code: "auto", title: "Определять автоматически"),
    ]

    static func title(for code: String) -> String {
        all.first { $0.code == code }?.title ?? code
    }
}

enum SettingsTab: String {
    case general, models
}
