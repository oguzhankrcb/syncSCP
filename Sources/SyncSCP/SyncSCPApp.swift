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
                .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1320, height: 840)
        Settings { PreferencesView(model: model) }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.showConnection = true }.keyboardShortcut("n")
                    .disabled(!model.canConnect || model.editor != nil || model.showSync)
                Button("Duplicate Session…") { model.duplicateSession() }.keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(!model.connected || !model.canConnect)
                Button("Disconnect") { model.disconnect() }.disabled(!model.connected || model.operationBusy)
                Divider()
                Button("Import from WinSCP or SSH Config…") { model.showImport = true }.disabled(model.busy)
                Divider()
                Button("Quick Open…") { model.showQuickOpen = true }.keyboardShortcut("k")
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
                    Button("Duplicate on Server…") { model.duplicateRemote() }.keyboardShortcut(FunctionKey.f5, modifiers: .shift).disabled(model.activeSide != .remote || model.activeSelection.isEmpty || model.busy)
                    Button("Move on Server To…") { model.moveRemote() }.keyboardShortcut(FunctionKey.f6, modifiers: .shift).disabled(model.activeSide != .remote || model.activeSelection.isEmpty || model.busy)
                }
                Divider()
                Button("Quick Look") { model.quickLookSelected() }.keyboardShortcut("y").disabled(model.activeSelection.first(where: \.isRegularFile) == nil || model.busy)
                Button("Find Files…") { model.showFindFiles = true }.keyboardShortcut("f", modifiers: [.command, .option]).disabled(!model.connected || model.busy)
                Button("Properties…") { model.promptPermissions() }.keyboardShortcut("i").disabled(model.activeSide != .remote || model.activeSelection.isEmpty || model.busy)
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack(model.activeSide) }.keyboardShortcut("[").disabled(!model.canGoBack(model.activeSide) || model.busy)
                Button("Forward") { model.goForward(model.activeSide) }.keyboardShortcut("]").disabled(!model.canGoForward(model.activeSide) || model.busy)
                Button("Parent Folder") { model.goUp(model.activeSide) }.keyboardShortcut(.upArrow).disabled(model.busy)
                Button("Home Folder") { model.goHome(model.activeSide) }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model.busy)
                Divider()
                Button("Switch Panel") { model.activeSide = model.activeSide == .local ? .remote : .local }.keyboardShortcut(.tab, modifiers: .control)
                Divider()
                Toggle("Directory Tree", isOn: $model.showTree).keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Bookmark This Folder") { model.bookmarkCurrentFolder() }.keyboardShortcut("b", modifiers: [.command, .option])
                Menu("Remote Bookmarks") {
                    ForEach(model.remoteBookmarks, id: \.self) { path in Button(path) { model.activeSide = .remote; model.navigateRemote(path) } }
                }.disabled(model.remoteBookmarks.isEmpty || !model.connected)
                Menu("Local Bookmarks") {
                    ForEach(model.localBookmarks, id: \.self) { path in Button(path) { model.activeSide = .local; model.navigateLocal(path) } }
                }.disabled(model.localBookmarks.isEmpty)
                Toggle("Compare Directories", isOn: $model.compareDirectories).keyboardShortcut("c", modifiers: [.command, .option]).disabled(!model.connected)
            }
            CommandMenu("Session") {
                Button("Synchronize…") { model.previewSynchronization() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.connected)
                Button(model.keepUpToDate == nil ? "Keep Remote Directory up to Date" : "Stop Keeping Remote Directory up to Date") { model.toggleKeepUpToDate() }
                    .keyboardShortcut("u", modifiers: [.command, .option]).disabled(model.keepUpToDate == nil && !model.connected)
                Button("Refresh") { model.refresh() }.keyboardShortcut("r")
                Divider()
                Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Session Log") { model.bottomTab = .log; model.showBottom = true }
                Divider()
                Button("Show Next Session Tab") { model.activateNeighborTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(!model.canSwitchTabs)
                Button("Show Previous Session Tab") { model.activateNeighborTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(!model.canSwitchTabs)
            }
            CommandMenu("Terminal") {
                Button("Open Terminal") { model.openTerminal() }.keyboardShortcut("t").disabled(!model.canOpenTerminal)
                Button("Open in Terminal.app") { model.openTerminal(inTerminalApp: true) }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!model.canOpenTerminal)
                Divider()
                // Sent through the responder chain: they act on the terminal window in front.
                Button("Split Right") { NSApp.sendAction(#selector(TerminalWindowController.splitRight(_:)), to: nil, from: nil) }.keyboardShortcut("d")
                Button("Split Down") { NSApp.sendAction(#selector(TerminalWindowController.splitDown(_:)), to: nil, from: nil) }.keyboardShortcut("d", modifiers: [.command, .control])
                Button("Close Pane") { NSApp.sendAction(#selector(TerminalWindowController.closePane(_:)), to: nil, from: nil) }.keyboardShortcut("w", modifiers: [.command, .option])
                Divider()
                Button("Find…") { findInTerminal(.showFindPanel) }.keyboardShortcut("f")
                Button("Find Next") { findInTerminal(.next) }.keyboardShortcut("g")
                Button("Find Previous") { findInTerminal(.previous) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Menu("Snippets") {
                    ForEach(model.snippets) { snippet in Button(snippet.name.isEmpty ? snippet.command : snippet.name) { TerminalWindowController.send(snippet) } }
                    if !model.snippets.isEmpty { Divider() }
                    Button("Edit Snippets…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                }
                Divider()
                Button("Port Forwarding…") { model.showPortForwarding = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About syncSCP") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "syncSCP",
                        .applicationVersion: "\(appVersion) — " + String(localized: "Development Preview"),
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
    static let f6 = key(NSF6FunctionKey), f7 = key(NSF7FunctionKey), f8 = key(NSF8FunctionKey)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    weak var model: CommanderModel?

    func applicationWillTerminate(_ notification: Notification) { model?.stopAllForwards() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model = model, model.pendingCount > 0 {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = String(localized: "Quit while \(model.pendingCount) transfer(s) are running or waiting?")
            alert.informativeText = String(localized: "They stop now and may leave hidden .syncscp-….filepart files; start them again later.")
            alert.addButton(withTitle: String(localized: "Quit")); alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        // ⌘Q in a terminal usually means "close this terminal"; quitting stays one click away.
        if let terminal = TerminalWindowController.controller(of: NSApp.keyWindow) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Close this terminal, or quit syncSCP?")
            alert.informativeText = String(localized: "Closing the terminal ends only its SSH session. Quitting closes every window and ends all sessions.")
            alert.addButton(withTitle: String(localized: "Close Terminal")); alert.addButton(withTitle: String(localized: "Quit syncSCP")); alert.addButton(withTitle: String(localized: "Cancel"))
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
        alert.informativeText = String(localized: "Their SSH sessions will end, along with anything running in them.")
        alert.addButton(withTitle: String(localized: "Quit")); alert.addButton(withTitle: String(localized: "Cancel"))
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

/// Find in the front terminal: SwiftTerm handles the standard find-panel actions.
private func findInTerminal(_ action: NSFindPanelAction) {
    let sender = NSMenuItem(); sender.tag = Int(action.rawValue)
    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
}
