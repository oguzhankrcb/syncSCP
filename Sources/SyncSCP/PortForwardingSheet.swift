// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SyncSCPCore

/// Terminal ▸ Port Forwarding: the current site's saved SSH local forwards, and every running one.
struct PortForwardingSheet: View {
    @ObservedObject var model: CommanderModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var localPort = ""
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = ""

    private var site: Site? { model.currentSite?.transferProtocol.usesSSH == true ? model.currentSite : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 20)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Port Forwarding").font(.system(size: 17, weight: .semibold))
                    Text(site.map { "Forwards through \($0.displayName) (\($0.username)@\($0.host))" } ?? "Connect with SFTP or SCP to add forwards for a site")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            List {
                if let site {
                    Section {
                        ForEach(site.settings.portForwards) { forward in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(forward.name.isEmpty ? forward.summary : forward.name).font(.system(size: 12.5, weight: .medium))
                                    if !forward.name.isEmpty { Text(forward.summary).font(.system(size: 11)).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if let running = model.activeForwards.first(where: { $0.forward.id == forward.id && $0.isRunning }) {
                                    Button("Stop") { model.stopForward(running.id) }
                                } else {
                                    Button("Start") { model.startForward(forward, site: site) }
                                }
                                Button { model.setPortForwards(site.settings.portForwards.filter { $0.id != forward.id }, for: site.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Delete this forward")
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("Name (optional)", text: $name).frame(width: 140)
                            TextField("Local port", text: $localPort).frame(width: 80)
                            Text("→")
                            TextField("Host as seen from the server", text: $remoteHost)
                            TextField("Port", text: $remotePort).frame(width: 60)
                            Button("Add") { add(to: site) }.disabled(Int(localPort) == nil || Int(remotePort) == nil || remoteHost.isEmpty)
                        }.textFieldStyle(.roundedBorder).font(.system(size: 12))
                    } header: { Text("Saved for this site") } footer: {
                        Text("Example: local port 5433 → 127.0.0.1 : 5432 reaches the server's PostgreSQL at localhost:5433 on this Mac. Forwards listen on this Mac's loopback address only.")
                            .font(.system(size: 11))
                    }
                }
                Section("Running") {
                    if model.activeForwards.isEmpty { Text("No port forwards are running.").foregroundStyle(.secondary) }
                    ForEach(model.activeForwards) { active in
                        HStack {
                            Image(systemName: "circle.fill").font(.system(size: 7))
                                .foregroundStyle(active.isRunning ? (active.state == "Active" ? Color.green : Color.orange) : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(active.forward.summary).font(.system(size: 12.5))
                                Text("\(active.site.displayName) · \(active.state)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            if active.isRunning { Button("Stop") { model.stopForward(active.id) } }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Clear Ended") { model.clearEndedForwards() }.disabled(!model.activeForwards.contains { !$0.isRunning })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .frame(width: 720, height: 520)
    }

    private func add(to site: Site) {
        let forward = PortForward(name: name.trimmingCharacters(in: .whitespaces), localPort: Int(localPort) ?? 0,
                                  remoteHost: remoteHost.trimmingCharacters(in: .whitespaces), remotePort: Int(remotePort) ?? 0)
        do { try forward.validate() } catch { model.report(error); return }
        model.setPortForwards(site.settings.portForwards + [forward], for: site.id)
        name = ""; localPort = ""; remotePort = ""
    }
}
