// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Security
import WinSCPCore

@main
enum EntryPoint {
    static func main() {
        if let id = ProcessInfo.processInfo.environment["WINSCP_ASKPASS_ID"] {
            // OpenSSH invokes this same executable as SSH_ASKPASS, before any UI starts.
            if let secret = SessionCredential.read(id) { FileHandle.standardOutput.write(Data((secret + "\n").utf8)) }
            return
        }
        WinSCPMacApp.main()
    }
}

struct WinSCPMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CommanderModel()

    var body: some Scene {
        Window("WinSCP for macOS", id: "commander") {
            CommanderView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.showConnection = true }.keyboardShortcut("n")
                    .disabled(model.busy || model.editor != nil || model.showSync)
                Button("Disconnect") { model.disconnect() }.disabled(!model.connected)
            }
            CommandMenu("Files") {
                Button("Upload Selected") { model.transfer(.upload) }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!model.canUpload)
                Button("Download Selected") { model.transfer(.download) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!model.canDownload)
                Divider()
                Button("Edit") { model.editSelected() }.keyboardShortcut("e").disabled(model.activeSelection.count != 1)
                Button("Rename…") { model.promptRename() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.activeSelection.count != 1)
                Button("New Directory…") { model.promptMkdir() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Delete…") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: .command).disabled(model.activeSelection.isEmpty)
            }
            CommandMenu("Session") {
                Button("Synchronize…") { model.previewSynchronization() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.connected)
                Button("Refresh") { model.refresh() }.keyboardShortcut("r")
                Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Session Log") { model.bottomTab = .log; model.showBottom = true }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About WinSCP for macOS") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "WinSCP for macOS · Community Port",
                        .applicationVersion: "0.4.0 — Development Preview",
                        .credits: NSAttributedString(string: "Independent community implementation of WinSCP workflows.\nOriginal WinSCP: Martin Prikryl and contributors.\nGPL v3 or later. No warranty. See bundled LICENSE.txt and README.md.")
                    ])
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SessionCredential {
    private static let service = "org.winscp.community.mac.session"
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
