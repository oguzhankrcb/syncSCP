// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

/// syncSCP ▸ Settings (⌘,).
struct PreferencesView: View {
    @ObservedObject var model: CommanderModel
    @AppStorage(CommanderModel.externalEditorKey) private var editor = ""
    @AppStorage(SavedPasswords.requireAuthenticationKey) private var requireAuthentication = false
    @AppStorage(CommanderModel.maxTransfersKey) private var maxTransfers = 2
    @AppStorage(CommanderModel.retriesKey) private var retries = 3
    @AppStorage(TerminalWindowController.fontFamilyKey) private var terminalFont = ""
    @AppStorage(TerminalWindowController.fontSizeKey) private var terminalFontSize = 13.0
    private let monospacedFamilies = Set(NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .compactMap { NSFont(name: $0, size: 12)?.familyName }.reduce(into: Set<String>()) { $0.insert($1) }.sorted()

    var body: some View {
        Form {
            Section {
                LabeledContent("Edit (F4) opens remote files in") {
                    HStack {
                        if editor.isEmpty { Text("Built-in editor") }
                        else { Label(EditorApps.name(URL(fileURLWithPath: editor)), systemImage: "app") }
                        Spacer()
                        Button("Choose Application…") { if let app = EditorApps.chooseApplication() { editor = app.path } }
                        Button("Use Built-in Editor") { editor = "" }.disabled(editor.isEmpty)
                    }
                }
                Text("With an application chosen, the file is downloaded to a private folder and opened there; every save is uploaded if the server copy has not changed since you opened it. Edit With in the context menu always lets you pick another application or the built-in editor.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Editing") }
            Section {
                Picker("Font", selection: $terminalFont) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $terminalFontSize, in: 8...36, step: 1) { LabeledContent("Size", value: "\(Int(terminalFontSize)) pt") }
                Text("Session ▸ Open Terminal (⌘T) logs in again with the site's settings and starts in the remote folder, through the SCP shell (for example sudo su -) when one is set. Prompts that use icon glyphs need a Nerd Font, such as MesloLGS NF.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Terminal") }
            Section {
                Stepper(value: $maxTransfers, in: 1...8) { LabeledContent("Transfers at the same time", value: "\(maxTransfers)") }
                Stepper(value: $retries, in: 0...10) { LabeledContent("Retries after a lost connection", value: retries == 0 ? "Off" : "\(retries)") }
                Text("Transfers run on their own connections to the site, so you can keep browsing. After a lost connection a transfer reconnects and tries again; over SFTP it continues partial files instead of starting over.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Transfers") }
            Section {
                Toggle("Ask for Touch ID or my Mac password before using a saved password", isOn: $requireAuthentication)
                LabeledContent("Saved passwords") {
                    HStack {
                        Text("\(model.sitesWithPasswords.count) site\(model.sitesWithPasswords.count == 1 ? "" : "s")")
                        Spacer()
                        Button("Forget All…") { forgetAll() }.disabled(model.sitesWithPasswords.isEmpty)
                    }
                }
                Text("Login ▸ Save password keeps a password in your macOS Keychain on this Mac only; site files never contain passwords. After an update macOS may ask once whether syncSCP may use them; choose Always Allow.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Passwords") }
        }
        .formStyle(.grouped).frame(width: 560).padding(.vertical, 8)
    }

    private func forgetAll() {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Forget \(model.sitesWithPasswords.count) saved password(s)?"
        alert.informativeText = "They are removed from your Keychain. You will type them at the next login."
        alert.addButton(withTitle: "Forget All"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for site in model.sitesWithPasswords { model.forgetPassword(site) }
    }
}
