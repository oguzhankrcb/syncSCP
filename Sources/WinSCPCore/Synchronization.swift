// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SyncAction: String, Sendable { case createDirectory = "Create directory", upload = "Upload", conflict = "Type conflict" }
public struct SyncItem: Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let action: SyncAction
    public let size: UInt64
    public let replacesFile: Bool
    public init(relativePath: String, action: SyncAction, size: UInt64 = 0, replacesFile: Bool = false) {
        self.relativePath = relativePath; self.action = action; self.size = size; self.replacesFile = replacesFile
    }
}

public enum SyncPlanner {
    /// One-way, additive synchronization. Never deletes files or follows symlinks.
    public static func compare(local: [String: FileEntry], remote: [String: FileEntry]) -> [SyncItem] {
        local.keys.sorted().compactMap { path in
            guard let source = local[path], source.isDirectory || source.isRegularFile else { return nil }
            guard let target = remote[path] else {
                return SyncItem(relativePath: path, action: source.isDirectory ? .createDirectory : .upload, size: source.size)
            }
            if source.isDirectory != target.isDirectory || target.isSymbolicLink {
                return SyncItem(relativePath: path, action: .conflict)
            }
            if source.isDirectory { return nil }
            let sameTime: Bool
            if let left = source.modified, let right = target.modified {
                sameTime = abs(left.timeIntervalSince(right)) < 2
            } else { sameTime = false }
            if source.size != target.size || !sameTime {
                return SyncItem(relativePath: path, action: .upload, size: source.size, replacesFile: true)
            }
            return nil
        }
    }
}
