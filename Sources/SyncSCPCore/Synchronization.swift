// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// WinSCP's Synchronize directions.
public enum SyncDirection: String, CaseIterable, Identifiable, Sendable {
    case upload = "Local → Remote", download = "Remote → Local", both = "Both"
    public var id: String { rawValue }
}

public enum SyncAction: String, Sendable {
    case createDirectory = "Create remote folder", upload = "Upload"
    case createLocalDirectory = "Create local folder", download = "Download"
    case deleteRemote = "Delete remote", deleteLocal = "Move local to Trash"
    case conflict = "Conflict"
}

public struct SyncItem: Identifiable, Sendable {
    public var id: String { relativePath + "|" + action.rawValue }
    public let relativePath: String
    public let action: SyncAction
    public let size: UInt64
    public let replacesFile: Bool
    /// Why a conflict could not be decided.
    public let reason: String
    public init(relativePath: String, action: SyncAction, size: UInt64 = 0, replacesFile: Bool = false, reason: String = "") {
        self.relativePath = relativePath; self.action = action; self.size = size; self.replacesFile = replacesFile; self.reason = reason
    }
}

public struct SyncOptions: Sendable {
    public var direction: SyncDirection
    /// One-way only: copy a file only when the source is newer than the target.
    public var newerOnly: Bool
    /// Compare files by size alone (for servers whose times cannot be trusted).
    public var sizeOnly: Bool
    /// One-way only (WinSCP's "Delete files"): remove target items that the source does not have.
    public var deleteExtras: Bool
    public init(direction: SyncDirection = .upload, newerOnly: Bool = false, sizeOnly: Bool = false, deleteExtras: Bool = false) {
        self.direction = direction; self.newerOnly = newerOnly; self.sizeOnly = sizeOnly; self.deleteExtras = deleteExtras
    }
}

public enum SyncPlanner {
    /// One-way, additive synchronization. Never deletes files or follows symlinks.
    public static func compare(local: [String: FileEntry], remote: [String: FileEntry]) -> [SyncItem] {
        compare(local: local, remote: remote, options: SyncOptions())
    }

    /// Plans a synchronization; symbolic links and special files are never copied, and
    /// deletions happen only for one-way synchronization with `deleteExtras`.
    public static func compare(local: [String: FileEntry], remote: [String: FileEntry], options: SyncOptions) -> [SyncItem] {
        let usable: (FileEntry) -> Bool = { $0.isDirectory || $0.isRegularFile }
        var items: [SyncItem] = []
        for path in Set(local.keys).union(remote.keys).sorted() {
            let left = local[path].flatMap { usable($0) ? $0 : nil }, right = remote[path].flatMap { usable($0) ? $0 : nil }
            // A symlink on either side blocks a copy over it.
            if (local[path] != nil && left == nil && right != nil) || (remote[path] != nil && right == nil && left != nil) {
                items.append(SyncItem(relativePath: path, action: .conflict, reason: "A symbolic link or special file is in the way")); continue
            }
            switch (left, right) {
            case let (source?, nil):
                if options.direction != .download { items.append(SyncItem(relativePath: path, action: source.isDirectory ? .createDirectory : .upload, size: source.size)) }
                else if options.deleteExtras { items.append(SyncItem(relativePath: path, action: .deleteLocal)) }
            case let (nil, target?):
                if options.direction != .upload { items.append(SyncItem(relativePath: path, action: target.isDirectory ? .createLocalDirectory : .download, size: target.size)) }
                else if options.deleteExtras { items.append(SyncItem(relativePath: path, action: .deleteRemote)) }
            case let (source?, target?):
                if source.isDirectory != target.isDirectory { items.append(SyncItem(relativePath: path, action: .conflict, reason: "A file on one side is a folder on the other")); continue }
                if source.isDirectory { continue }
                let differs = source.size != target.size || (!options.sizeOnly && !sameTime(source.modified, target.modified))
                guard differs else { continue }
                let newer = newerSide(source.modified, target.modified)
                switch options.direction {
                case .upload:
                    if options.newerOnly, newer != .local { continue }
                    items.append(SyncItem(relativePath: path, action: .upload, size: source.size, replacesFile: true))
                case .download:
                    if options.newerOnly, newer != .remote { continue }
                    items.append(SyncItem(relativePath: path, action: .download, size: target.size, replacesFile: true))
                case .both:
                    switch newer {
                    case .local?: items.append(SyncItem(relativePath: path, action: .upload, size: source.size, replacesFile: true))
                    case .remote?: items.append(SyncItem(relativePath: path, action: .download, size: target.size, replacesFile: true))
                    case nil: items.append(SyncItem(relativePath: path, action: .conflict, reason: "Both changed and neither is clearly newer"))
                    }
                }
            case (nil, nil): continue
            }
        }
        return prune(items)
    }

    private enum Side { case local, remote }

    private static func sameTime(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else { return false }
        return abs(left.timeIntervalSince(right)) < 2
    }
    private static func newerSide(_ local: Date?, _ remote: Date?) -> Side? {
        guard let local, let remote, abs(local.timeIntervalSince(remote)) >= 2 else { return nil }
        return local > remote ? .local : .remote
    }

    /// A deleted folder covers everything inside it.
    private static func prune(_ items: [SyncItem]) -> [SyncItem] {
        let deleted = items.filter { $0.action == .deleteRemote || $0.action == .deleteLocal }.map(\.relativePath)
        return items.filter { item in
            guard item.action == .deleteRemote || item.action == .deleteLocal else { return true }
            return !deleted.contains { item.relativePath.hasPrefix($0 + "/") }
        }
    }
}
