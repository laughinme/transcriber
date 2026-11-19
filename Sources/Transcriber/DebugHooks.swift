import AppKit
import SwiftUI

/// Lets scripts drive the app and capture its windows without Screen Recording permission.
/// Enabled only when launched with TRANSCRIBER_DEBUG=1. Commands arrive as distributed
/// notifications named `local.transcriber.debug` with the command in `object`:
/// `snapshot:<dir>`, `select:<index>`, `settings`, `appearance:dark|light|system`, `timestamps:on|off`.
@MainActor
enum DebugHooks {
    /// Set by ContentView: SwiftUI opens the Settings scene only through its environment action.
    static var openSettings: (() -> Void)?

    static var enabled: Bool { ProcessInfo.processInfo.environment["TRANSCRIBER_DEBUG"] == "1" }

    static func install() {
        guard enabled else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.transcriber.debug"), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(command) }
        }
    }

    private static func handle(_ command: String) {
        let (name, arg) = command.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        let model = AppModel.shared
        switch name {
        case "snapshot":
            snapshot(into: URL(fileURLWithPath: arg))
        case "select":
            if let i = Int(arg), model.jobs.indices.contains(i) { model.selection = model.jobs[i].id }
        case "settings":
            NSApp.activate()
            openSettings?()
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Расшифровка" }) {
                w.setContentSize(NSSize(width: wh[0], height: wh[1]))
            }
        case "dump":
            dump(into: URL(fileURLWithPath: arg))
        case "timestamps":
            UserDefaults.standard.set(arg == "on", forKey: Pref.showTimestamps)
        default:
            break
        }
    }

    private static func dump(into file: URL) {
        var lines = AppModel.shared.jobs.map { "job \($0.name) \($0.status.rawValue) \(Int($0.progress * 100))%" }
        func walk(_ v: NSView, _ depth: Int) {
            if let t = v as? NSTableView {
                lines.append("table \(type(of: t)) rows=\(t.numberOfRows) frame=\(t.frame.integral) visible=\(!t.isHiddenOrHasHiddenAncestor)")
            }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        for w in NSApp.windows where w.isVisible {
            lines.append("window \(w.title) \(w.frame.integral)")
            if let root = w.contentView?.superview { walk(root, 0) }
        }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func windowServerImage(_ windowNumber: Int) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // .null rect = window bounds; optionIncludingWindow = 8; boundsIgnoreFraming = 1, bestResolution = 8.
        return create(.null, 8, UInt32(windowNumber), 1 | 8)?.takeRetainedValue()
    }

    private static func snapshot(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let frameView = window.contentView?.superview else { continue }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            frameView.cacheDisplay(in: bounds, to: rep)
            let title = window.title.isEmpty ? "window" : window.title
            let url = dir.appendingPathComponent("\(i)-\(title).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            // Window server capture of our own window: the real pixels, including sidebar glass
            // that cacheDisplay skips. The API is hidden from the SDK, so it is looked up at runtime.
            if let image = windowServerImage(window.windowNumber) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("\(i)-\(title)-ws.png"))
            }
        }
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
