import AppKit
import Foundation
import Observation
import TranscriberCore

struct Job: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case queued, preparing, recognizing, done, failed, cancelled
        var isActive: Bool { self == .preparing || self == .recognizing }
        var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
    }

    let id: UUID
    var url: URL
    var status: Status = .queued
    var progress: Double = 0
    var transcript: Transcript?
    var outputs: [URL] = []
    var error: String?
    var note: String?
    var addedAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    /// Segments streamed while recognizing; not persisted.
    var live: [Segment] = []

    enum CodingKeys: String, CodingKey {
        case id, url, status, progress, transcript, outputs, error, note, addedAt, startedAt, finishedAt
    }

    init(url: URL) {
        id = UUID()
        self.url = url
    }

    var name: String { url.lastPathComponent }
    var isVideo: Bool { MediaFiles.isVideo(url) }
    var elapsed: TimeInterval? {
        guard let s = startedAt, let f = finishedAt else { return nil }
        return f.timeIntervalSince(s)
    }
}

/// The queue: files are processed one at a time (whisper already uses the whole GPU),
/// results are written to disk and remembered between launches.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var jobs: [Job] = []
    var selection: Job.ID?
    var toolchain = Toolchain.discover()

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: (id: UUID, task: Task<Transcript, Error>)?
    @ObservationIgnored private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        Pref.register()
        loadHistory()
    }

    var selectedJob: Job? { jobs.first { $0.id == selection } }
    var pendingCount: Int { jobs.filter { $0.status == .queued || $0.status.isActive }.count }

    // MARK: Settings snapshot

    var selectedModel: WhisperModel? {
        let path = UserDefaults.standard.string(forKey: Pref.modelPath) ?? ""
        return toolchain.models.first { $0.url.path == path } ?? toolchain.models.first
    }

    func refreshToolchain() {
        toolchain = Toolchain.discover()
    }

    // MARK: Queue

    func add(_ urls: [URL]) {
        let files = MediaFiles.expand(urls)
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }
        var firstNew: UUID?
        for file in files {
            if jobs.contains(where: { $0.url == file && !$0.status.isFinished }) { continue }
            let job = Job(url: file)
            jobs.append(job)
            firstNew = firstNew ?? job.id
        }
        if selection == nil || selectedJob?.status.isFinished == true, let firstNew {
            selection = firstNew
        }
        startIfNeeded()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Голосовые, аудио или видео. Можно выбрать папку."
        panel.prompt = "Расшифровать"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func cancel(_ id: Job.ID) {
        if current?.id == id {
            current?.task.cancel()
        } else if let i = index(id), jobs[i].status == .queued {
            jobs[i].status = .cancelled
        }
    }

    func retry(_ id: Job.ID) {
        guard let i = index(id), jobs[i].status.isFinished else { return }
        jobs[i].status = .queued
        jobs[i].progress = 0
        jobs[i].error = nil
        jobs[i].note = nil
        jobs[i].live = []
        startIfNeeded()
    }

    func remove(_ id: Job.ID) {
        cancel(id)
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.last?.id }
        saveHistory()
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        if selectedJob == nil { selection = jobs.first?.id }
        saveHistory()
    }

    private func index(_ id: Job.ID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func startIfNeeded() {
        updateDockBadge()
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runQueue()
            self?.worker = nil
        }
    }

    private func runQueue() async {
        var processed = 0
        while let job = jobs.first(where: { $0.status == .queued }) {
            await process(job.id)
            processed += 1
        }
        updateDockBadge()
        if processed > 0, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func process(_ id: Job.ID) async {
        guard let i = index(id) else { return }
        toolchain = Toolchain.discover()
        guard let model = selectedModel else {
            jobs[i].status = .failed
            jobs[i].error = "Не найдена модель whisper. Положите ggml-*.bin в ~/.whisper."
            return
        }
        let defaults = UserDefaults.standard
        let options = TranscriptionOptions(
            language: defaults.string(forKey: Pref.language) ?? Pref.defaultLanguage,
            model: model,
            useVAD: defaults.bool(forKey: Pref.useVAD),
            translateToEnglish: defaults.bool(forKey: Pref.translate),
            punctuationHint: defaults.bool(forKey: Pref.punctuationHint)
        )
        let formats = Pref.formats(from: defaults.string(forKey: Pref.formats) ?? Pref.defaultFormats)
        let url = jobs[i].url

        jobs[i].status = .preparing
        jobs[i].startedAt = Date()
        jobs[i].live = []
        updateDockBadge()

        let runner = WhisperRunner(toolchain: toolchain)
        let task = Task.detached {
            try await runner.transcribe(
                url, options: options,
                onPhase: { phase in Task { @MainActor in AppModel.shared.apply(phase, to: id) } },
                onSegment: { segment in Task { @MainActor in AppModel.shared.appendLive(segment, to: id) } }
            )
        }
        current = (id, task)
        defer { current = nil }

        do {
            let transcript = try await task.value
            guard let i = index(id) else { return }
            jobs[i].transcript = transcript
            jobs[i].finishedAt = Date()
            jobs[i].progress = 1
            jobs[i].live = []
            jobs[i].status = .done
            writeOutputs(for: i, formats: formats)
        } catch {
            guard let i = index(id) else { return }
            jobs[i].finishedAt = Date()
            jobs[i].live = []
            if task.isCancelled || error is CancellationError {
                jobs[i].status = .cancelled
            } else {
                jobs[i].status = .failed
                jobs[i].error = error.localizedDescription
            }
        }
        saveHistory()
    }

    private func apply(_ phase: TranscriptionPhase, to id: Job.ID) {
        guard let i = index(id), jobs[i].status.isActive else { return }
        switch phase {
        case .preparing:
            jobs[i].status = .preparing
        case .recognizing(let fraction):
            jobs[i].status = .recognizing
            jobs[i].progress = max(jobs[i].progress, fraction)
        }
    }

    private func appendLive(_ segment: Segment, to id: Job.ID) {
        guard let i = index(id), jobs[i].status.isActive else { return }
        jobs[i].live.append(segment)
        jobs[i].live.sort { $0.start < $1.start }
    }

    // MARK: Output

    private func writeOutputs(for i: Int, formats: [OutputFormat]) {
        guard let transcript = jobs[i].transcript, !transcript.isEmpty, !formats.isEmpty else { return }
        let source = jobs[i].url
        let defaults = UserDefaults.standard
        let mode = SaveMode(rawValue: defaults.string(forKey: Pref.saveMode) ?? "") ?? .nextToSource
        let chosen = URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder) ?? Pref.defaultFolder)
        let fallback = URL(fileURLWithPath: Pref.defaultFolder)
        let folder = mode == .nextToSource ? source.deletingLastPathComponent() : chosen
        do {
            jobs[i].outputs = try OutputWriter.write(transcript, formats: formats, source: source, folder: folder)
        } catch {
            do {
                jobs[i].outputs = try OutputWriter.write(transcript, formats: formats, source: source, folder: fallback)
                jobs[i].note = "В папку \(folder.lastPathComponent) записать не вышло, файлы в «Документы/Расшифровки»."
            } catch {
                jobs[i].note = "Файлы не сохранены: \(error.localizedDescription)"
            }
        }
    }

    func export(_ id: Job.ID, as format: OutputFormat) {
        guard let job = jobs.first(where: { $0.id == id }), let transcript = job.transcript else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.url.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        panel.directoryURL = job.url.deletingLastPathComponent()
        panel.message = format.title
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Renderer.render(transcript, as: format, context: RenderContext(title: job.name, date: job.finishedAt ?? Date()))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let i = index(id), !jobs[i].outputs.contains(url) { jobs[i].outputs.append(url) }
            saveHistory()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Persistence and Dock

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        jobs = saved.filter { $0.status == .done || $0.status == .failed }
        selection = jobs.last?.id
    }

    private func saveHistory() {
        let finished = jobs.filter { $0.status == .done || $0.status == .failed }
        guard let data = try? JSONEncoder().encode(finished) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func updateDockBadge() {
        let n = pendingCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}
