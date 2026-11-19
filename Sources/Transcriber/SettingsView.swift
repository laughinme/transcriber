import AppKit
import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @AppStorage(Pref.settingsTab) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Основное", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            ModelsSettings()
                .tabItem { Label("Модели", systemImage: "cpu") }
                .tag(SettingsTab.models.rawValue)
        }
        .frame(width: 560, height: 660)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.language) private var language = Pref.defaultLanguage
    @AppStorage(Pref.useVAD) private var useVAD = true
    @AppStorage(Pref.punctuationHint) private var punctuationHint = true
    @AppStorage(Pref.translate) private var translate = false
    @AppStorage(Pref.gentle) private var gentle = false
    @AppStorage(Pref.vocabulary) private var vocabulary = ""
    @AppStorage(Pref.formats) private var formatsRaw = Pref.defaultFormats
    @AppStorage(Pref.saveMode) private var saveMode = SaveMode.nextToSource.rawValue
    @AppStorage(Pref.saveFolder) private var saveFolder = Pref.defaultFolder

    var body: some View {
        Form {
            Section("Распознавание") {
                Picker("Язык речи", selection: $language) {
                    ForEach(Language.all) { Text($0.title).tag($0.code) }
                }
                Toggle(isOn: $useVAD) {
                    Text("Пропускать тишину")
                    Text(model.toolchain.vadModel == nil
                         ? "Нужен детектор речи: скачайте его на вкладке «Модели»"
                         : "Детектор речи Silero: меньше выдуманных фраз на паузах").font(.caption)
                }
                .disabled(model.toolchain.vadModel == nil)
                Toggle(isOn: $punctuationHint) {
                    Text("Подсказка для пунктуации")
                    Text("Без неё whisper иногда пишет без точек и запятых").font(.caption)
                }
                Toggle(isOn: $gentle) {
                    Text("Щадящий режим")
                    Text("Два потока и низкий приоритет: медленнее, зато Mac не тормозит").font(.caption)
                }
                Toggle(isOn: $translate) {
                    Text("Переводить на английский")
                    Text("Whisper сразу выдаёт перевод вместо исходного текста").font(.caption)
                }
            }

            Section {
                TextEditor(text: $vocabulary)
                    .font(.body)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Имена и термины")
            } footer: {
                Text("Через запятую или с новой строки: Иван Петров, Kubernetes, FastAPI. Whisper будет писать их так. Длинный список мешает, хватит 10–20 слов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сохранение") {
                ForEach(OutputFormat.allCases) { format in
                    Toggle(isOn: formatBinding(format)) {
                        Text("\(format.title) (.\(format.fileExtension))")
                        Text(format.hint).font(.caption)
                    }
                }
                Picker("Куда", selection: $saveMode) {
                    ForEach(SaveMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if saveMode == SaveMode.folder.rawValue {
                    LabeledContent("Папка") {
                        HStack {
                            Text(saveFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Выбрать…", action: chooseFolder)
                        }
                    }
                }
            }

            Section("Инструменты") {
                LabeledContent("whisper-cli", value: model.toolchain.whisperCLI?.path ?? "не найден, brew install whisper-cpp")
                LabeledContent("ffmpeg", value: model.toolchain.ffmpeg?.path ?? "не найден, brew install ffmpeg")
                Button("Проверить снова") { model.refreshToolchain() }
            }
        }
        .formStyle(.grouped)
    }

    private func formatBinding(_ format: OutputFormat) -> Binding<Bool> {
        Binding {
            Pref.formats(from: formatsRaw).contains(format)
        } set: { on in
            var set = Pref.formats(from: formatsRaw)
            if on { set.append(format) } else { set.removeAll { $0 == format } }
            formatsRaw = Pref.raw(from: OutputFormat.allCases.filter { set.contains($0) })
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }
}

struct ModelsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var store = ModelStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.whisper) { entry in
                    CatalogRow(entry: entry, store: store)
                }
                ForEach(store.customModels) { m in
                    InstalledRow(model: m, store: store)
                }
            } header: {
                Text("Модели распознавания")
            } footer: {
                Text("Скачиваются с HuggingFace (\(ModelCatalog.whisperRepo)) в ~/.whisper и проверяются по SHA-256. Свои ggml-файлы можно просто положить в ту же папку.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Детектор речи") {
                if let vad = model.toolchain.vadModel {
                    LabeledContent("Silero") {
                        Label(vad.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    CatalogRow(entry: ModelCatalog.vad, store: store)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshToolchain() }
    }
}

private struct CatalogRow: View {
    let entry: CatalogEntry
    let store: ModelStore

    var body: some View {
        let installed = store.installedModel(for: entry)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                    if entry.recommended {
                        Text("рекомендуется")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let download = store.downloads[entry.file] {
                    DownloadProgress(download: download)
                } else if let error = store.errors[entry.file] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            trailing(installed: installed)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func trailing(installed: WhisperModel?) -> some View {
        if store.downloads[entry.file] != nil {
            Button("Отменить") { store.cancel(entry) }
        } else if let installed {
            ModelActions(model: installed, store: store)
        } else {
            Button {
                store.download(entry)
            } label: {
                Text("Скачать · \(ByteCountFormatter.string(fromByteCount: entry.approxBytes, countStyle: .file))")
                    .monospacedDigit()
            }
        }
    }
}

private struct InstalledRow: View {
    let model: WhisperModel
    let store: ModelStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                Text(model.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ModelActions(model: model, store: store)
        }
    }
}

private struct ModelActions: View {
    let model: WhisperModel
    let store: ModelStore

    var body: some View {
        HStack(spacing: 8) {
            if store.current == model {
                Label("Используется", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                Button("Использовать") { store.use(model) }
            }
            Button {
                store.delete(model)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Переместить файл модели в Корзину")
        }
    }
}

private struct DownloadProgress: View {
    let download: ModelStore.Download

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: download.verifying ? nil : download.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 200)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var label: String {
        if download.verifying { return "Проверяю файл…" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: download.received)) из \(f.string(fromByteCount: download.total))"
    }
}
