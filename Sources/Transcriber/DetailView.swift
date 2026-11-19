import SwiftUI
import TranscriberCore

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.selectedJob {
            JobDetail(job: job)
                .id(job.id)
        } else {
            ContentUnavailableView("Выберите файл слева", systemImage: "text.alignleft")
        }
    }
}

struct JobDetail: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.showTimestamps) private var showTimestamps = true
    @State private var copied = false
    let job: Job

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(job.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                actions
            }
            Text(meta)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var meta: String {
        var parts: [String] = []
        if let t = job.transcript {
            if let d = t.duration { parts.append(TimeFormat.clock(d)) }
            if let l = t.language { parts.append(LanguageName.name(for: l)) }
            if let m = t.model { parts.append(m) }
            if let e = job.elapsed { parts.append("расшифровано за \(JobRow.elapsed(e))") }
        } else {
            parts.append(job.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        switch job.status {
        case .done where job.transcript?.isEmpty ?? true:
            Button("Расшифровать заново") { model.retry(job.id) }
        case .done:
            // Full labels when there is room, icons when the window is narrow.
            ViewThatFits(in: .horizontal) {
                doneActions(compact: false)
                doneActions(compact: true)
            }
            .layoutPriority(1)
        case .queued, .preparing, .recognizing:
            Button("Отменить") { model.cancel(job.id) }
        case .failed, .cancelled:
            Button("Расшифровать заново") { model.retry(job.id) }
        }
    }

    private func doneActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("Вид", selection: $showTimestamps) {
                if compact {
                    Image(systemName: "text.alignleft").help("Текст").tag(false)
                    Image(systemName: "clock").help("С таймкодами").tag(true)
                } else {
                    Text("Текст").tag(false)
                    Text("Таймкоды").tag(true)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                copy()
            } label: {
                if compact {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                } else {
                    Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 104)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Скопировать весь текст (⇧⌘C)")

            Menu {
                ForEach(OutputFormat.allCases) { format in
                    Button("\(format.title) (.\(format.fileExtension))…") { model.export(job.id, as: format) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .fixedSize()
            .help("Сохранить в другом формате")
        }
        .fixedSize()
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch job.status {
        case .done:
            if let t = job.transcript, !t.isEmpty {
                ScrollView {
                    TranscriptText(segments: t.segments, timestamps: showTimestamps)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { savedFiles }
            } else {
                ContentUnavailableView("Речи не найдено", systemImage: "speaker.slash",
                                       description: Text("Похоже, в записи тишина или только музыка. Если речь там есть, проверьте язык внизу слева и расшифруйте заново."))
            }
        case .preparing, .recognizing:
            LiveView(job: job)
        case .queued:
            ContentUnavailableView("В очереди", systemImage: "clock",
                                   description: Text("Начну, как только закончу файлы выше."))
        case .failed:
            ContentUnavailableView("Не получилось расшифровать", systemImage: "exclamationmark.triangle",
                                   description: Text(job.error ?? ""))
        case .cancelled:
            ContentUnavailableView("Отменено", systemImage: "xmark.circle")
        }
    }

    @ViewBuilder private var savedFiles: some View {
        if !job.outputs.isEmpty || job.note != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !job.outputs.isEmpty {
                    HStack(spacing: 6) {
                        Text("Сохранено:")
                            .foregroundStyle(.secondary)
                        ForEach(job.outputs, id: \.self) { url in
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Label(url.lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.link)
                            .help("Показать в Finder")
                        }
                    }
                }
                if let note = job.note {
                    Text(note).foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func copy() {
        guard let t = job.transcript else { return }
        let text = showTimestamps
            ? Paragraphs.group(t.segments).map { "[\(TimeFormat.clock($0.start))] \($0.text)" }.joined(separator: "\n\n")
            : t.plainText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

/// The transcript as one selectable text, so a selection can span paragraphs.
struct TranscriptText: View {
    let segments: [Segment]
    let timestamps: Bool

    var body: some View {
        Text(attributed)
            .font(.system(size: 15))
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let paragraphs = Paragraphs.group(segments)
        for (i, p) in paragraphs.enumerated() {
            if timestamps {
                var stamp = AttributedString(TimeFormat.clock(p.start) + "   ")
                stamp.font = .system(size: 12.5, weight: .medium).monospacedDigit()
                stamp.foregroundColor = .secondary
                out += stamp
            }
            out += AttributedString(p.text)
            if i < paragraphs.count - 1 { out += AttributedString("\n\n") }
        }
        return out
    }
}

/// Text appears while whisper is still working.
struct LiveView: View {
    let job: Job

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView(value: job.status == .recognizing ? job.progress : nil)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text(job.status == .preparing ? "Готовлю звук…" : "Распознаю · \(Int(job.progress * 100)) %")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            Divider()
            scroll
        }
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if job.live.isEmpty {
                        Text("Текст появится здесь по ходу распознавания.")
                            .foregroundStyle(.tertiary)
                    } else {
                        TranscriptText(segments: job.live, timestamps: true)
                            .opacity(0.85)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: job.live.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}
