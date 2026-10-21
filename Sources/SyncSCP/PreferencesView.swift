// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

/// syncSCP ▸ Settings (⌘,).
struct PreferencesView: View {
    @AppStorage(CommanderModel.externalEditorKey) private var editor = ""
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
        }
        .formStyle(.grouped).frame(width: 560).padding(.vertical, 8)
    }
}
