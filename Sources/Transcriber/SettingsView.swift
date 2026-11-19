import AppKit
import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.modelPath) private var modelPath = ""
    @AppStorage(Pref.language) private var language = Pref.defaultLanguage
    @AppStorage(Pref.useVAD) private var useVAD = true
    @AppStorage(Pref.punctuationHint) private var punctuationHint = true
    @AppStorage(Pref.translate) private var translate = false
    @AppStorage(Pref.formats) private var formatsRaw = Pref.defaultFormats
    @AppStorage(Pref.saveMode) private var saveMode = SaveMode.nextToSource.rawValue
    @AppStorage(Pref.saveFolder) private var saveFolder = Pref.defaultFolder

    var body: some View {
        Form {
            Section("Распознавание") {
                Picker("Модель", selection: modelSelection) {
                    ForEach(model.toolchain.models) { m in
                        Text("\(m.name)  ·  \(ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file))")
                            .tag(m.url.path)
                    }
                }
                Picker("Язык речи", selection: $language) {
                    ForEach(Language.all) { Text($0.title).tag($0.code) }
                }
                Toggle(isOn: $useVAD) {
                    Text("Пропускать тишину")
                    Text("Детектор речи silero: меньше выдуманных фраз на паузах").font(.caption)
                }
                .disabled(model.toolchain.vadModel == nil)
                Toggle(isOn: $punctuationHint) {
                    Text("Подсказка для пунктуации")
                    Text("Без неё whisper иногда пишет без точек и запятых").font(.caption)
                }
                Toggle(isOn: $translate) {
                    Text("Переводить на английский")
                    Text("Whisper сразу выдаёт перевод вместо исходного текста").font(.caption)
                }
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
                LabeledContent("whisper-cli", value: model.toolchain.whisperCLI?.path ?? "не найден")
                LabeledContent("ffmpeg", value: model.toolchain.ffmpeg?.path ?? "не найден")
                LabeledContent("Детектор речи", value: model.toolchain.vadModel?.lastPathComponent ?? "не найден")
                LabeledContent("Модели ищу в") {
                    Text("~/.whisper, ~/.cache/whisper.cpp")
                        .foregroundStyle(.secondary)
                }
                Button("Проверить снова") { model.refreshToolchain() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private var modelSelection: Binding<String> {
        Binding {
            model.selectedModel?.url.path ?? ""
        } set: { modelPath = $0 }
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
