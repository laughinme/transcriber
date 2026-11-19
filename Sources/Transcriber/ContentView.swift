import SwiftUI
import TranscriberCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                EmptyStateView()
            } else {
                NavigationSplitView {
                    QueueView()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
                } detail: {
                    DetailView()
                }
            }
        }
        .toolbar { MainToolbar() }
        .overlay { if dropTargeted { DropOverlay() } }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.toolchain.isReady { ToolchainBanner() }
        }
        .onAppear { DebugHooks.openSettings = { openSettings() } }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.openPanel()
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .help("Добавить файлы (⌘O)")
        }
    }
}

/// Switches between installed models; the catalog lives in Settings → Models.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.settingsTab) private var settingsTab = SettingsTab.general.rawValue

    var body: some View {
        Menu {
            if model.toolchain.models.isEmpty {
                Text("Нет скачанных моделей")
            } else {
                Picker("Модель", selection: selection) {
                    ForEach(model.toolchain.models) { m in
                        Text("\(m.name)  ·  \(ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file))")
                            .tag(m.url.path)
                    }
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button("Скачать другие модели…") {
                settingsTab = SettingsTab.models.rawValue
                openSettings()
            }
        } label: {
            Label(model.selectedModel?.name ?? "Нет модели", systemImage: "cpu")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Модель whisper для следующих файлов")
    }

    private var selection: Binding<String> {
        Binding { model.selectedModel?.url.path ?? "" } set: { model.modelPath = $0 }
    }
}

/// Language and output formats for the next files. Lives next to where files are dropped.
struct OptionsBar: View {
    @AppStorage(Pref.language) private var language = Pref.defaultLanguage
    @AppStorage(Pref.formats) private var formatsRaw = Pref.defaultFormats

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Язык речи", selection: $language) {
                    ForEach(Language.all) { Text($0.title).tag($0.code) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(Language.title(for: language), systemImage: "globe")
            }
            .help("Язык речи в файлах")

            Menu {
                Section("Сохранять после расшифровки") {
                    ForEach(OutputFormat.allCases) { format in
                        Toggle(isOn: binding(for: format)) {
                            Text("\(format.title) (.\(format.fileExtension))")
                        }
                    }
                }
            } label: {
                Label(formatsSummary, systemImage: "doc.text")
            }
            .help("Какие файлы сохранять после расшифровки")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    private var formatsSummary: String {
        let f = Pref.formats(from: formatsRaw)
        return f.isEmpty ? "Не сохранять" : f.map { ".\($0.fileExtension)" }.joined(separator: " ")
    }

    private func binding(for format: OutputFormat) -> Binding<Bool> {
        Binding {
            Pref.formats(from: formatsRaw).contains(format)
        } set: { on in
            var set = Pref.formats(from: formatsRaw)
            if on { set.append(format) } else { set.removeAll { $0 == format } }
            formatsRaw = Pref.raw(from: OutputFormat.allCases.filter { set.contains($0) })
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.75))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(14)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Text("Отпустите, чтобы добавить в очередь")
                    .font(.title3.weight(.medium))
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct ToolchainBanner: View {
    @Environment(AppModel.self) private var model

    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.settingsTab) private var settingsTab = SettingsTab.general.rawValue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem).font(.callout.weight(.semibold))
                Text(fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if model.toolchain.whisperCLI != nil && model.toolchain.ffmpeg != nil {
                Button("Скачать модель…") {
                    settingsTab = SettingsTab.models.rawValue
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Проверить снова") { model.refreshToolchain() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.1))
    }

    private var problem: String {
        let t = model.toolchain
        if t.whisperCLI == nil { return "Не найден whisper-cli" }
        if t.ffmpeg == nil { return "Не найден ffmpeg" }
        return "Нет ни одной модели whisper"
    }

    private var fix: String {
        let t = model.toolchain
        if t.whisperCLI == nil || t.ffmpeg == nil { return "Установите в Терминале: brew install whisper-cpp ffmpeg" }
        return "Скачайте модель в настройках (рекомендуется Large v3 Turbo, 1,6 ГБ) или положите свой ggml-*.bin в ~/.whisper"
    }
}
