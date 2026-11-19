import SwiftUI
import TranscriberCore

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .contextMenu { JobMenu(job: job) }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let id = model.selection { model.remove(id) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    OptionsBar()
                    Spacer(minLength: 8)
                    if model.jobs.contains(where: { $0.status.isFinished }) {
                        Button("Очистить") { model.clearFinished() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Убрать из списка готовые и отменённые. Файлы на диске останутся.")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .background(.bar)
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: job.isVideo ? "film" : "waveform")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        switch job.status {
        case .queued:
            caption("В очереди")
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                caption("Готовлю звук…")
            }
        case .recognizing:
            HStack(spacing: 8) {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text("\(Int(job.progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        case .done:
            caption(doneLine)
        case .failed:
            Text(job.error ?? "Ошибка")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            caption("Отменено")
        }
    }

    private var doneLine: String {
        var parts: [String] = []
        if let d = job.transcript?.duration { parts.append(TimeFormat.clock(d)) }
        if job.transcript?.isEmpty == true {
            parts.append("речи нет")
        } else if let e = job.elapsed {
            parts.append("готово за \(Self.elapsed(e))")
        } else {
            parts.append("готово")
        }
        return parts.joined(separator: " · ")
    }

    static func elapsed(_ t: TimeInterval) -> String {
        t < 60 ? "\(max(1, Int(t.rounded()))) с" : "\(Int(t) / 60) мин \(Int(t) % 60) с"
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct JobMenu: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
        if job.status == .queued || job.status.isActive {
            Button("Отменить") { model.cancel(job.id) }
        }
        if job.status.isFinished {
            Button("Расшифровать заново") { model.retry(job.id) }
        }
        Divider()
        Button("Убрать из списка") { model.remove(job.id) }
    }
}
