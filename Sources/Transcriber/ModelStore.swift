import AppKit
import Foundation
import Observation
import TranscriberCore

/// Downloads, removes and switches whisper models. Installed models come from `Toolchain`,
/// so files the user put in ~/.whisper by hand show up here too.
@MainActor
@Observable
final class ModelStore {
    static let shared = ModelStore()

    struct Download: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var verifying = false
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }

    var downloads: [String: Download] = [:]
    var errors: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private var app: AppModel { AppModel.shared }

    var installed: [WhisperModel] { app.toolchain.models }
    var current: WhisperModel? { app.selectedModel }

    func installedModel(for entry: CatalogEntry) -> WhisperModel? {
        installed.first { $0.name == entry.name }
    }

    /// Installed models that are not in the catalog (for example a custom fine-tune).
    var customModels: [WhisperModel] {
        installed.filter { m in !ModelCatalog.whisper.contains { $0.name == m.name } }
    }

    func use(_ model: WhisperModel) {
        app.modelPath = model.url.path
    }

    func download(_ entry: CatalogEntry) {
        guard tasks[entry.file] == nil else { return }
        errors[entry.file] = nil
        downloads[entry.file] = Download(total: entry.approxBytes)
        let file = entry.file
        tasks[file] = Task {
            do {
                let url = try await ModelDownloader().download(entry, into: Toolchain.downloadDirectory()) { phase in
                    Task { @MainActor in ModelStore.shared.update(file, phase) }
                }
                finish(file)
                let hadModel = !installed.isEmpty
                app.refreshToolchain()
                // The first model becomes the current one; later ones wait for an explicit choice.
                if !hadModel, let m = installed.first(where: { $0.url == url }) { use(m) }
            } catch is CancellationError {
                finish(file)
            } catch {
                finish(file)
                if !Task.isCancelled { errors[file] = error.localizedDescription }
            }
        }
    }

    func cancel(_ entry: CatalogEntry) {
        tasks[entry.file]?.cancel()
        finish(entry.file)
    }

    func delete(_ model: WhisperModel) {
        let alert = NSAlert()
        alert.messageText = "Удалить модель \(model.name)?"
        alert.informativeText = "Файл \(model.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))) будет перемещён в Корзину."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: model.url, resultingItemURL: nil)
            if app.modelPath == model.url.path { app.modelPath = "" }
            app.refreshToolchain()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func update(_ file: String, _ phase: ModelDownloader.Phase) {
        guard downloads[file] != nil else { return }
        switch phase {
        case .downloading(let received, let total):
            downloads[file]?.received = received
            if total > 0 { downloads[file]?.total = total }
        case .verifying:
            downloads[file]?.verifying = true
        }
    }

    private func finish(_ file: String) {
        tasks[file] = nil
        downloads[file] = nil
    }
}
