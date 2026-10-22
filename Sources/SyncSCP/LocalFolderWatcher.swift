// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreServices

/// Reports changed files under a local folder (FSEvents, file-level, recursive), batched on the main queue.
final class LocalFolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(root: String, latency: TimeInterval = 0.6, handler: @escaping ([String]) -> Void) throws {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LocalFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handler(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root])
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root]) }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
