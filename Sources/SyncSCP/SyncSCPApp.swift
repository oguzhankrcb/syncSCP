// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Security
import SyncSCPCore

@main
enum EntryPoint {
    static func main() {
        if let id = ProcessInfo.processInfo.environment["SYNCSCP_ASKPASS_ID"] {
            // OpenSSH invokes this same executable as SSH_ASKPASS, before any UI starts.
            if let secret = SessionCredential.read(id) { FileHandle.standardOutput.write(Data((secret + "\n").utf8)) }
            return
        }
        SyncSCPApp.main()
    }
}

struct SyncSCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CommanderModel()

    var body: some Scene {
        Window("syncSCP", id: "commander") {
            CommanderView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1320, height: 840)
        Settings { PreferencesView() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.showConnection = true }.keyboardShortcut("n")
                    .disabled(model.busy || model.editor != nil || model.showSync)
                Button("Disconnect") { model.disconnect() }.disabled(!model.connected)
                Divider()
                Button("Import from WinSCP…") { model.showImport = true }.disabled(model.busy)
            }
            CommandMenu("Files") {
                Button("Upload Selected") { model.transfer(.upload) }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!model.canUpload)
                Button("Download Selected") { model.transfer(.download) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!model.canDownload)
                Divider()
                Button("Edit") { model.editSelected() }.keyboardShortcut("e").disabled(model.activeSelection.count != 1)
                Button("Rename…") { model.promptRename() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.activeSelection.count != 1)
                Button("New Directory…") { model.promptMkdir() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New File…") { model.promptNewFile() }.keyboardShortcut("n", modifiers: [.command, .option]).disabled(model.busy)
                Button("Delete…") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: .command).disabled(model.activeSelection.isEmpty)
                Divider()
                // WinSCP's Commander function keys (fn+F-key on Mac keyboards).
                Menu("Commander Keys") {
                    Button("Rename…") { model.promptRename() }.keyboardShortcut(FunctionKey.f2, modifiers: []).disabled(model.activeSelection.count != 1 || model.busy)
                    Button("Edit") { model.editSelected() }.keyboardShortcut(FunctionKey.f4, modifiers: []).disabled(model.activeSelection.count != 1 || model.busy)
                    Button("Copy to Other Panel") { model.copyToOtherPanel() }.keyboardShortcut(FunctionKey.f5, modifiers: []).disabled(!model.canCopyToOtherPanel)
                    Button("New File…") { model.promptNewFile() }.keyboardShortcut(FunctionKey.f4, modifiers: .shift).disabled(model.busy)
                    Button("New Folder…") { model.promptMkdir() }.keyboardShortcut(FunctionKey.f7, modifiers: []).disabled(model.busy)
                    Button("Delete…") { model.deleteSelected() }.keyboardShortcut(FunctionKey.f8, modifiers: []).disabled(model.activeSelection.isEmpty || model.busy)
                }
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack(model.activeSide) }.keyboardShortcut("[").disabled(!model.canGoBack(model.activeSide) || model.busy)
                Button("Forward") { model.goForward(model.activeSide) }.keyboardShortcut("]").disabled(!model.canGoForward(model.activeSide) || model.busy)
                Button("Parent Folder") { model.goUp(model.activeSide) }.keyboardShortcut(.upArrow).disabled(model.busy)
                Button("Home Folder") { model.goHome(model.activeSide) }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model.busy)
                Divider()
                Button("Switch Panel") { model.activeSide = model.activeSide == .local ? .remote : .local }.keyboardShortcut(.tab, modifiers: .control)
            }
            CommandMenu("Session") {
                Button("Synchronize…") { model.previewSynchronization() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.connected)
                Button("Refresh") { model.refresh() }.keyboardShortcut("r")
                Divider()
                Button("Open Terminal") { model.openTerminal() }.keyboardShortcut("t").disabled(!model.canOpenTerminal)
                Button("Open in Terminal.app") { model.openTerminal(inTerminalApp: true) }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!model.canOpenTerminal)
                Divider()
                Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Session Log") { model.bottomTab = .log; model.showBottom = true }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About syncSCP") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "syncSCP",
                        .applicationVersion: "0.14.0 — Development Preview",
                        .credits: NSAttributedString(string: "An independent macOS file manager inspired by WinSCP's workflows; not affiliated with the WinSCP project.\nWinSCP is by Martin Prikryl and contributors.\nGPL v3 or later. No warranty. See bundled LICENSE.txt and README.md.")
                    ])
                }
            }
        }
    }
}

enum FunctionKey {
    private static func key(_ code: Int) -> KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(UInt32(code))!)) }
    static let f2 = key(NSF2FunctionKey), f4 = key(NSF4FunctionKey), f5 = key(NSF5FunctionKey)
    static let f7 = key(NSF7FunctionKey), f8 = key(NSF8FunctionKey)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ⌘Q in a terminal usually means "close this terminal"; quitting stays one click away.
        if let terminal = TerminalWindowController.controller(of: NSApp.keyWindow) {
            let alert = NSAlert()
            alert.messageText = "Close this terminal, or quit syncSCP?"
            alert.informativeText = "Closing the terminal ends only its SSH session. Quitting closes every window and ends all sessions."
            alert.addButton(withTitle: "Close Terminal"); alert.addButton(withTitle: "Quit syncSCP"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: terminal.closeWithoutConfirmation(); return .terminateCancel
            case .alertSecondButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        }
        let count = TerminalWindowController.activeCount
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Quit with an open terminal?" : "Quit with \(count) open terminals?"
        alert.informativeText = "Their SSH sessions will end, along with anything running in them."
        alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

enum SessionCredential {
    private static let service = "io.github.oguzhankrcb.syncscp.session"
    static func store(_ secret: String) throws -> String {
        let id = UUID().uuidString
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                kSecAttrAccount: id, kSecValueData: Data(secret.utf8),
                                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClientError.invalid("Could not temporarily store the SSH credential in Keychain (\(status)).") }
        return id
    }
    static func read(_ id: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                         kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(_ id: String) -> Bool {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
