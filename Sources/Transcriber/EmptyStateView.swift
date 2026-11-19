import SwiftUI
import TranscriberCore

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.saveMode) private var saveMode = SaveMode.nextToSource.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, options: .speed(0.4))
                VStack(spacing: 6) {
                    Text("Перетащите голосовые или видео")
                        .font(.title2.weight(.semibold))
                    Text("OGG из Telegram, M4A, MP3, WAV, MP4, MOV и другие.\nМожно сразу несколько файлов или целую папку.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    model.openPanel()
                } label: {
                    Text("Выбрать файлы…").padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    ModelMenu()
                    OptionsBar()
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 20)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var summary: String {
        let place = SaveMode(rawValue: saveMode) == .folder ? "в выбранную папку" : "рядом с исходным файлом"
        return "Расшифровки сохраняются \(place) · ⌘, настройки"
    }
}
