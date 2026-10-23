// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SyncSCPCore

/// ⌘K: type to find a site, a bookmark or a command, then press Return.
struct QuickOpenSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let run: () -> Void
    }

    private var items: [Item] {
        var result: [Item] = model.sites.map { site in
            Item(id: "site-" + site.id.uuidString, title: site.displayName, detail: "\(site.transferProtocol.shortTitle) · \(site.username)@\(site.host)",
                 icon: model.sitesWithPasswords.contains(site.id) ? "key.fill" : "server.rack", run: { model.quickConnect(site) })
        }
        if model.connected {
            result += model.remoteBookmarks.map { path in Item(id: "remote-" + path, title: path, detail: "Remote bookmark", icon: "bookmark.fill", run: { model.activeSide = .remote; model.navigateRemote(path) }) }
        }
        result += model.localBookmarks.map { path in Item(id: "local-" + path, title: path, detail: "Local bookmark", icon: "bookmark", run: { model.activeSide = .local; model.navigateLocal(path) }) }
        let commands: [(String, String, Bool, () -> Void)] = [
            ("New Session", "plus", true, { model.showConnection = true }),
            ("Synchronize", "arrow.triangle.2.circlepath", model.connected, { model.previewSynchronization() }),
            (model.keepUpToDate == nil ? "Keep Remote Directory up to Date" : "Stop Keeping Up to Date", "eye", model.connected || model.keepUpToDate != nil, { model.toggleKeepUpToDate() }),
            ("Open Terminal", "terminal", model.canOpenTerminal, { model.openTerminal() }),
            ("Find Files", "doc.text.magnifyingglass", model.connected, { model.showFindFiles = true }),
            ("Port Forwarding", "point.3.connected.trianglepath.dotted", true, { model.showPortForwarding = true }),
            ("Compare Directories", "equal.square", model.connected, { model.compareDirectories.toggle() }),
            ("Directory Tree", "sidebar.left", true, { model.showTree.toggle() }),
            ("Bookmark This Folder", "bookmark", true, { model.bookmarkCurrentFolder() }),
            ("Import Sites from WinSCP or SSH Config", "square.and.arrow.down", true, { model.showImport = true }),
            ("Disconnect", "xmark.circle", model.connected, { model.disconnect() }),
        ]
        result += commands.filter(\.2).map { title, icon, _, run in Item(id: "command-" + title, title: title, detail: "Command", icon: icon, run: run) }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return result }
        return result.filter { item in words.allSatisfy { (item.title + " " + item.detail).lowercased().contains($0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Site, bookmark or command", text: $query).textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .onSubmit { if let first = items.first { run(first) } }
            }.padding(14)
            Divider()
            List(items) { item in
                Button { run(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).foregroundStyle(accent).frame(width: 18)
                        Text(item.id.hasPrefix("command-") ? L(item.title) : item.title).lineLimit(1)
                        Spacer()
                        Text(item.id.hasPrefix("site-") ? item.detail : L(item.detail)).foregroundStyle(.secondary).lineLimit(1)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.listStyle(.plain)
            HStack {
                Text("Return opens the first match · Esc closes").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(10)
        }
        .frame(width: 560, height: 420)
        .onAppear { focused = true }
    }

    private func run(_ item: Item) {
        dismiss()
        DispatchQueue.main.async { item.run() }
    }
}
