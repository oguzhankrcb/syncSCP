// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftTerm
import SyncSCPCore

/// One window per SSH terminal, like WinSCP's Open Terminal. Closing the window ends its ssh process.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    static let fontFamilyKey = "TerminalFontFamily", fontSizeKey = "TerminalFontSize"
    private static var openWindows: [TerminalWindowController] = []
    private let terminal: LocalProcessTerminalView
    private let label: String
    private var running = true
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

    static func open(_ launch: SSHTerminalLaunch, title: String) {
        let controller = TerminalWindowController(launch, title: title)
        openWindows.append(controller)
        controller.showWindow(nil)
    }

    /// The number of terminals whose ssh process is still running.
    static var activeCount: Int { openWindows.filter(\.running).count }

    private init(_ launch: SSHTerminalLaunch, title: String) {
        label = title
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 860, height: 540))
        terminal.font = Self.font
        // Option composes characters (@, |, { … on many layouts), as in Terminal.app's default.
        terminal.optionAsMetaKey = false
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = terminal
        window.minSize = NSSize(width: 360, height: 200)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        if let last = Self.openWindows.last?.window { window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY))) }
        else { window.center() }
        super.init(window: window)
        window.delegate = self
        applyColors()
        // Follow light/dark changes and font changes made in Settings while the window is open.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in DispatchQueue.main.async { self?.applyColors() } }
        observations.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.terminal.font != Self.font else { return }
            self.terminal.font = Self.font
        })
        terminal.processDelegate = self
        terminal.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment, execName: "ssh")
        window.makeFirstResponder(terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// SwiftTerm stores fixed colors, so dynamic system colors are resolved for the current appearance.
    private func applyColors() {
        guard let window else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? .black
            let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
            terminal.nativeForegroundColor = foreground
            terminal.nativeBackgroundColor = background
            window.backgroundColor = background
        }
        terminal.needsDisplay = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard running else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.informativeText = "The SSH session to \(label) will end, along with anything running in it."
        alert.addButton(withTitle: "Close"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        if running { running = false; terminal.terminate() }
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        appearanceObservation = nil
        Self.openWindows.removeAll { $0 === self }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            guard running else { return }
            running = false
            let detail = exitCode.map { "exit code \($0)" } ?? "connection lost"
            terminal.feed(text: "\r\n\u{1B}[2m[Session ended: \(detail). Close the window with ⌘W.]\u{1B}[0m\r\n")
            window?.title = label + " — ended"
        }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [self] in window?.subtitle = title }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
