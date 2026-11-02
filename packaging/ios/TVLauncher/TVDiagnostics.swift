import UIKit

// The Apple TV's stand-in for the launcher framework, for now: no menu, only a way to see what the game is doing.
//
// An Apple TV has no Files app and no Console without a Mac, and the game's own window can sit grey for reasons
// that are only in `logs/latest.log`. The game loads this framework by name (`Frameworks/HorizonLauncherKit.
// framework`, crates/horizon-ios-launcher) and calls `horizon_launcher_present`; this one puts the tail of that
// log on screen, in plain UIKit over the game's window, for the first three minutes, and answers false: "no
// launcher to show", which makes the game start by itself rather than wait for a Play button nobody can press.

public typealias TVDone = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
public typealias TVSubmit = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?, TVDone) -> Void

@_cdecl("horizon_launcher_present")
public func horizonLauncherPresent(_ submit: TVSubmit?) -> Bool {
    DispatchQueue.main.async { TVDiagnostics.shared.start() }
    return false
}

final class TVDiagnostics {
    static let shared = TVDiagnostics()

    private var window: UIWindow?
    private var text: UITextView?
    private var timer: Timer?
    private let opened = Date()
    /// How long the viewer stays on screen, and how much of that is the full report.
    private let visibleFor: TimeInterval = 600
    private let fullFor: TimeInterval = 30

    func start() {
        guard window == nil else { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.windowLevel = UIWindow.Level.alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        let text = UITextView(frame: controller.view.bounds.insetBy(dx: 48, dy: 32))
        text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // No isEditable or isSelectable: tvOS has neither (a text view there is read-only, and that is all this is).
        text.isUserInteractionEnabled = false
        text.backgroundColor = UIColor.black.withAlphaComponent(0.80)
        text.textColor = .white
        text.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        text.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        controller.view.addSubview(text)
        window.rootViewController = controller
        // Visible but never key: the game's window stays the one that hears the remote.
        window.isHidden = false
        self.window = window
        self.text = text
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let elapsed = Date().timeIntervalSince(opened)
        guard elapsed < visibleFor else {
            timer?.invalidate()
            window?.isHidden = true
            window = nil
            return
        }
        let folder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/Horizon", isDirectory: true)
        // The full report for the first half minute, long enough to read what ended the last run; after that a
        // two-line strip across the top, so the game can be played with the newest log lines still in view.
        if elapsed >= fullFor, let text, let host = text.superview {
            text.autoresizingMask = [.flexibleWidth]
            text.frame = CGRect(x: 48, y: 12, width: host.bounds.width - 96, height: 62)
            let lines = (Self.tail(of: folder.appendingPathComponent("logs/latest.log"), bytes: 700) ?? "")
                .split(separator: "\n").suffix(2).joined(separator: "\n")
            text.text = lines.isEmpty ? "Horizon: no log yet" : lines
            return
        }
        var out = "Horizon on Apple TV (t+\(Int(elapsed)) s, shrinks at \(Int(fullFor)) s)  \(folder.path)\n"

        // What ended the last run: Rust's crash report, if the game wrote one, and the end of that run's log (rolled
        // into logs/<date>-<n>.log.gz when this run started). A crash the system causes, such as running out of
        // memory, writes no report, but the last lines of that log still say what the game was doing.
        let crash = Self.newest(in: folder.appendingPathComponent("crash-reports"), suffix: ".txt")
        if let crash, let text = Self.tail(of: crash, bytes: 2400) {
            out += "\n=== LAST CRASH REPORT  \(crash.lastPathComponent) ===\n\(text)\n"
        }
        let archive = Self.newest(in: folder.appendingPathComponent("logs"), suffix: ".log.gz")
        if let archive, let text = Self.gunzipTail(of: archive, bytes: 2400) {
            out += "\n=== END OF THE PREVIOUS RUN  \(archive.lastPathComponent) ===\n\(text)\n"
        }

        let log = folder.appendingPathComponent("logs/latest.log")
        out += "\n=== THIS RUN ===\n"
        if let tail = Self.tail(of: log, bytes: 3000) {
            out += tail
        } else {
            out += "No log file yet.\n"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            out += names.isEmpty ? "  (nothing, or the folder does not exist)\n" : names.sorted().map { "  \($0)\n" }.joined()
        }
        text?.text = out
        // Keep the newest lines in view.
        if let text, !out.isEmpty {
            text.scrollRangeToVisible(NSRange(location: (out as NSString).length - 1, length: 1))
        }
    }

    /// The most recently written file in `folder` whose name ends with `suffix`.
    private static func newest(in folder: URL, suffix: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    /// The last `bytes` of a gzip file's text. The game's log archives are plain gzip (a 10-byte header, a deflate
    /// stream, an 8-byte trailer); Apple's zlib codec reads the stream between them.
    private static func gunzipTail(of url: URL, bytes: Int) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else {
            return nil
        }
        let flags = data[3]
        var offset = 10
        if flags & 4 != 0, data.count > offset + 2 { offset += 2 + Int(data[offset]) + Int(data[offset + 1]) << 8 }
        for bit in [UInt8(8), UInt8(16)] where flags & bit != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 2 != 0 { offset += 2 }
        guard offset < data.count - 8 else { return nil }
        let body = data.subdata(in: offset..<(data.count - 8))
        guard let raw = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        var text = String(decoding: raw.suffix(bytes), as: UTF8.self)
        if raw.count > bytes, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text.isEmpty ? nil : text
    }

    /// The last `bytes` of `url` as text, from the start of a whole line; nil when it can't be read.
    private static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text.isEmpty ? "(the log is empty)\n" : text
    }
}
