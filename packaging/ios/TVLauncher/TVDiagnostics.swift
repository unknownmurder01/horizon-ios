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
    /// How long the log stays on screen.
    private let visibleFor: TimeInterval = 180

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
        text.isEditable = false
        text.isSelectable = false
        text.isUserInteractionEnabled = false
        text.backgroundColor = UIColor.black.withAlphaComponent(0.80)
        text.textColor = .white
        text.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
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
        let log = folder.appendingPathComponent("logs/latest.log")
        var out = "Horizon on Apple TV: what the game is saying (t+\(Int(elapsed)) s, hides at \(Int(visibleFor)) s)\n"
        out += "\(log.path)\n\n"
        if let tail = Self.tail(of: log, bytes: 5000) {
            out += tail
        } else {
            out += "No log file yet.\n\nIn \(folder.path):\n"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            out += names.isEmpty ? "  (nothing, or the folder does not exist)\n" : names.sorted().map { "  \($0)\n" }.joined()
        }
        text?.text = out
        // Keep the newest lines in view.
        if let text, !out.isEmpty {
            text.scrollRangeToVisible(NSRange(location: (out as NSString).length - 1, length: 1))
        }
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
