// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftTerm
import SyncSCPCore

/// Prepares one terminal login (a saved password may need Touch ID first) and hands over the
/// launch plus a release action that runs when that login's ssh process ends.
typealias TerminalLauncher = (@escaping (SSHTerminalLaunch, (() -> Void)?) -> Void) -> Void

/// A saved command for Terminal ▸ Snippets.
struct TerminalSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    /// Press Return after inserting the command.
    var run = false

    static let storageKey = "TerminalSnippets"
    static func load() -> [TerminalSnippet] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([TerminalSnippet].self, from: data)) ?? []
    }
    static func save(_ snippets: [TerminalSnippet]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(snippets), forKey: storageKey)
    }
}

/// One SSH login inside a terminal window.
private final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    var running = true
    private var release: (() -> Void)?
    var ended: (() -> Void)?
    var titleChanged: ((String) -> Void)?

    init(frame: NSRect) {
        view = LocalProcessTerminalView(frame: frame)
        super.init()
        view.font = TerminalWindowController.font
        // Option composes characters (@, |, { … on many layouts), as in Terminal.app's default.
        view.optionAsMetaKey = false
        view.processDelegate = self
    }

    func start(_ launch: SSHTerminalLaunch, release: (() -> Void)?) {
        self.release = release
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment, execName: "ssh")
    }

    /// Ends the ssh process (if still running) and lets go of a temporary credential.
    func stop() {
        if running { running = false; view.terminate() }
        release?(); release = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            release?(); release = nil
            guard running else { return }
            running = false
            let detail = exitCode.map { "exit code \($0)" } ?? "connection lost"
            view.feed(text: "\r\n\u{1B}[2m[Session ended: \(detail). Close the pane with ⌥⌘W or the window with ⌘W.]\u{1B}[0m\r\n")
            ended?()
        }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [self] in titleChanged?(title) }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Terminal windows, like WinSCP's Open Terminal. They group as native macOS tabs; each window
/// can be split into panes, every pane its own SSH login. Closing a window ends its logins.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static let fontFamilyKey = "TerminalFontFamily", fontSizeKey = "TerminalFontSize"
    private static let tabbingIdentifier = "io.github.oguzhankrcb.syncscp.terminal"
    private static var openWindows: [TerminalWindowController] = []
    private let label: String
    private let launcher: TerminalLauncher
    /// Holds the pane tree: a pane, or nested split views when the window is split.
    private let container = NSView()
    private var panes: [TerminalPane] = []
    private var observations: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    /// Settings ▸ Terminal: a monospaced family (empty: the system font) and size.
    static var font: NSFont {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.double(forKey: fontSizeKey) == 0 ? 13 : min(max(defaults.double(forKey: fontSizeKey), 8), 36))
        let family = defaults.string(forKey: fontFamilyKey) ?? ""
        if !family.isEmpty, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Opens a terminal window, as a new tab when a terminal window is in front.
    static func open(title: String, launcher: @escaping TerminalLauncher) {
        let front = controller(of: NSApp.keyWindow)?.window
        let controller = TerminalWindowController(title: title, launcher: launcher)
        openWindows.append(controller)
        if let front, let window = controller.window { front.addTabbedWindow(window, ordered: .above) }
        controller.showWindow(nil)
        controller.addPane()
    }

    /// The number of terminal logins whose ssh process is still running.
    static var activeCount: Int { openWindows.reduce(0) { $0 + $1.panes.filter(\.running).count } }

    /// The terminal shown in `window`, if it is one.
    static func controller(of window: NSWindow?) -> TerminalWindowController? { openWindows.first { $0.window === window } }

    /// Types a snippet into the focused pane of the front terminal window.
    static func send(_ snippet: TerminalSnippet) {
        guard let controller = controller(of: NSApp.keyWindow) ?? openWindows.last, let pane = controller.focusedPane, pane.running else { NSSound.beep(); return }
        pane.view.send(txt: snippet.command + (snippet.run ? "\r" : ""))
        controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(pane.view)
    }

    /// Closes without asking again; `close()` skips windowShouldClose, and windowWillClose ends ssh.
    func closeWithoutConfirmation() { window?.close() }

    private init(title: String, launcher: @escaping TerminalLauncher) {
        label = title; self.launcher = launcher
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = container
        window.minSize = NSSize(width: 360, height: 200)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        if let last = Self.openWindows.last?.window { window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY))) }
        else { window.center() }
        super.init(window: window)
        window.delegate = self
        // Follow light/dark changes and font changes made in Settings while the window is open.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in DispatchQueue.main.async { self?.applyColors() } }
        observations.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for pane in self.panes where pane.view.font != Self.font { pane.view.font = Self.font }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var focusedPane: TerminalPane? {
        let responder = window?.firstResponder as? NSView
        return panes.first { responder?.isDescendant(of: $0.view) == true } ?? panes.last
    }

    /// The first pane fills the window; later ones split the focused pane in two.
    private func addPane(vertical: Bool = true) {
        guard let window else { return }
        let pane = TerminalPane(frame: container.bounds)
        pane.ended = { [weak self] in self?.updateTitle() }
        pane.titleChanged = { [weak self] title in self?.window?.subtitle = title }
        if let target = focusedPane?.view {
            let split = NSSplitView(frame: target.frame)
            split.isVertical = vertical; split.dividerStyle = .thin
            replace(target, with: split)
            split.addArrangedSubview(target); split.addArrangedSubview(pane.view)
            split.adjustSubviews()
            split.setPosition((vertical ? split.bounds.width : split.bounds.height) / 2, ofDividerAt: 0)
        } else {
            pane.view.frame = container.bounds; pane.view.autoresizingMask = [.width, .height]
            container.addSubview(pane.view)
        }
        panes.append(pane)
        applyColors()
        window.makeFirstResponder(pane.view)
        launcher { [weak self, weak pane] launch, release in
            guard let self, let pane, self.panes.contains(where: { $0 === pane }) else { release?(); return }
            pane.start(launch, release: release)
        }
    }

    /// Puts `new` where `old` is: in its split view, or directly in the window.
    private func replace(_ old: NSView, with new: NSView) {
        if let parent = old.superview as? NSSplitView, let index = parent.arrangedSubviews.firstIndex(of: old) {
            parent.insertArrangedSubview(new, at: index)
            parent.removeArrangedSubview(old); old.removeFromSuperview()
        } else {
            new.frame = old.frame; new.autoresizingMask = [.width, .height]
            container.replaceSubview(old, with: new)
        }
    }

    private func updateTitle() {
        window?.title = panes.contains(where: \.running) ? label : label + " — ended"
    }

    /// SwiftTerm stores fixed colors, so dynamic system colors are resolved for the current appearance.
    private func applyColors() {
        guard let window else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? .black
            let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
            for pane in panes { pane.view.nativeForegroundColor = foreground; pane.view.nativeBackgroundColor = background; pane.view.needsDisplay = true }
            window.backgroundColor = background
        }
    }

    // MARK: Menu actions (found through the responder chain)

    @objc func splitRight(_ sender: Any?) { addPane(vertical: true) }
    @objc func splitDown(_ sender: Any?) { addPane(vertical: false) }

    @objc func closePane(_ sender: Any?) {
        guard panes.count > 1, let pane = focusedPane else { window?.performClose(sender); return }
        if pane.running {
            let alert = NSAlert()
            alert.messageText = "Close this pane?"
            alert.informativeText = "Its SSH session to \(label) will end."
            alert.addButton(withTitle: "Close"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pane.stop()
        panes.removeAll { $0 === pane }
        let parent = pane.view.superview as? NSSplitView
        pane.view.removeFromSuperview()
        // A split left with one side collapses into that side.
        if let parent, parent.arrangedSubviews.count == 1, let remaining = parent.arrangedSubviews.first {
            parent.removeArrangedSubview(remaining); remaining.removeFromSuperview()
            replace(parent, with: remaining)
        }
        if let next = panes.last { window?.makeFirstResponder(next.view) }
        updateTitle()
    }

    /// The tab bar's + button: another login to the same site.
    override func newWindowForTab(_ sender: Any?) {
        Self.open(title: label, launcher: launcher)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = panes.filter(\.running).count
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "Close this terminal?" : "Close \(running) terminal sessions?"
        alert.informativeText = "The SSH session to \(label) will end, along with anything running in it."
        alert.addButton(withTitle: "Close"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.stop() }
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        appearanceObservation = nil
        Self.openWindows.removeAll { $0 === self }
    }
}
