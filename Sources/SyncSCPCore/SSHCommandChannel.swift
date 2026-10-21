// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// A raw SSH channel, independent of the SFTP length-prefixed transport.
/// Nonblocking pipes allow cancellation and an inactivity deadline during both reads and writes.
final class SSHCommandChannel {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffered = Data(), diagnostics = Data()
    private var closed = false
    private var lastActivity = Date()
    private var outputEOF = false

    init(arguments: [String], environment: [String: String] = [:]) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        // Close the parent's copies of the child's ends so EOF is observable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        }
    }

    deinit { close() }
    var isRunning: Bool { process.isRunning }
    var errorText: String { drainErrors(); return String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func finishInput() { try? input.fileHandleForWriting.close() }
    /// A long-lived channel may sit idle between commands; the inactivity deadline starts now.
    func markActive() { lastActivity = Date() }
    /// Returns and clears stderr collected so far (one command's diagnostics on a persistent shell).
    func takeErrors() -> String {
        drainErrors()
        let text = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.removeAll(); return text
    }
    /// Reads up to and consumes `pattern`, returning the bytes before it.
    func read(until pattern: Data, limit: Int, token: CancellationToken) throws -> Data {
        var searched = 0
        while true {
            let start = buffered.index(buffered.startIndex, offsetBy: max(0, searched - pattern.count + 1))
            if let range = buffered.range(of: pattern, in: start..<buffered.endIndex) {
                let result = Data(buffered[buffered.startIndex..<range.lowerBound])
                buffered.removeSubrange(buffered.startIndex..<range.upperBound); return result
            }
            searched = buffered.count
            guard buffered.count <= limit else { throw ClientError.protocolError("SSH command output exceeds the size limit.") }
            guard try readMore(token: token) else { throw failure() }
        }
    }

    private func drainErrors() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            diagnostics.append(contentsOf: bytes.prefix(count))
            if diagnostics.count > 32768 { diagnostics = Data(diagnostics.suffix(32768)) }
        }
    }

    private func ready(_ fd: Int32, events: Int16, token: CancellationToken) throws -> Int16 {
        while true {
            try token.check(); drainErrors()
            guard !closed else { throw ClientError.connection("The SSH channel is closed.") }
            guard Date().timeIntervalSince(lastActivity) < 45 else {
                throw ClientError.connection("SSH did not respond for 45 seconds.")
            }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 { return descriptor.revents }
            if result < 0, errno != EINTR { throw failure() }
        }
    }

    func send(_ data: Data, token: CancellationToken) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let events = try ready(input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), token: token)
                guard events & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw failure() }
                let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, raw.baseAddress!.advanced(by: offset), min(raw.count - offset, 65536))
                if count > 0 { offset += count; lastActivity = Date() }
                else if count < 0, errno != EAGAIN, errno != EINTR { throw failure() }
            }
        }
    }

    private func readMore(token: CancellationToken) throws -> Bool {
        if outputEOF { return false }
        _ = try ready(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), token: token)
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count == 0 { outputEOF = true; return false }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return try readMore(token: token) }
            throw failure()
        }
        buffered.append(contentsOf: bytes.prefix(count)); lastActivity = Date(); return true
    }

    func read(_ count: Int, token: CancellationToken) throws -> Data {
        while buffered.count < count { guard try readMore(token: token) else { throw failure() } }
        let value = Data(buffered.prefix(count)); buffered.removeFirst(count); return value
    }

    func line(token: CancellationToken) throws -> Data {
        while true {
            if let index = buffered.firstIndex(of: 10) {
                let length = buffered.distance(from: buffered.startIndex, to: index)
                guard length <= 16384 else { throw ClientError.protocolError("SCP control line is too long.") }
                let result = Data(buffered.prefix(length)); buffered.removeFirst(length + 1); return result
            }
            guard buffered.count <= 16384 else { throw ClientError.protocolError("SCP control line is too long.") }
            guard try readMore(token: token) else { throw failure() }
        }
    }

    func finish(token: CancellationToken = CancellationToken(), limit: Int = 64 * 1024 * 1024) throws -> Data {
        var result = Data()
        repeat {
            guard buffered.count <= limit - result.count else { throw ClientError.protocolError("SSH command output exceeds the size limit.") }
            result.append(buffered); buffered.removeAll(keepingCapacity: true)
        } while try readMore(token: token)
        while process.isRunning {
            try token.check(); drainErrors()
            guard Date().timeIntervalSince(lastActivity) < 45 else { throw ClientError.connection("SSH command did not exit.") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drainErrors()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if process.terminationStatus == 255 || process.terminationReason != .exit { throw failure() }
            throw ClientError.remote("SCP/SSH", Int(process.terminationStatus), errorText.isEmpty ? "The server rejected the operation." : errorText)
        }
        return result
    }

    private func failure() -> ClientError {
        let detail = errorText
        return .connection(detail.isEmpty ? "SSH closed the channel. Check the connection and remote SCP support." : detail)
    }
}

/// All paths become positional arguments to /bin/sh, never executable shell fragments.
enum SCPShell {
    /// The same script as `command`, but run as a child of a persistent shell instead of replacing it.
    static func inline(_ script: String, arguments: [String] = []) throws -> String {
        try String(command(script, arguments: arguments).dropFirst("exec ".count))
    }
    static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw ClientError.invalid("A remote path cannot contain a null character.") }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func command(_ script: String, arguments: [String] = []) throws -> String {
        let prefix = "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH; LC_ALL=C; export LC_ALL; unset CDPATH; umask 077; "
        return try "exec /bin/sh -c " + quote(prefix + script) + " syncscp " + arguments.map(quote).joined(separator: " ")
    }
}

/// One authenticated master plus independent command/SCP channels on the same connection.
/// ProxyCommand=false makes OpenSSH's normal direct-connection fallback fail closed.
final class SCPSSHSession {
    private let configuration: SSHConfiguration
    private let directory: URL
    private let socket: String
    private var master: SSHCommandChannel?
    /// WinSCP-style persistent shell: started once (with the configured shell, e.g. `sudo su -`)
    /// and reused for every metadata and file-management command.
    private var shell: SSHCommandChannel?

    static func masterArguments(_ configuration: SSHConfiguration, socket: String) throws -> [String] {
        // An idle -N master can outlive an app crash. An initial remote cat instead
        // exits when the owner's stdin pipe closes, including abnormal app exit.
        try configuration.baseArguments() + ["-M", "-S", socket, "-o", "ControlPersist=no", "--", configuration.site.host,
                                             SCPShell.command("exec cat >/dev/null")]
    }

    init(_ configuration: SSHConfiguration) throws {
        self.configuration = configuration
        // Short enough for macOS sockaddr_un; a private unpredictable directory protects the socket.
        directory = URL(fileURLWithPath: "/tmp/syncscp-scp-" + UUID().uuidString)
        socket = directory.appendingPathComponent("s").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            master = try SSHCommandChannel(arguments: Self.masterArguments(configuration, socket: socket), environment: configuration.environment)
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: socket) {
                guard master!.isRunning else { throw ClientError.connection(master!.errorText.isEmpty ? "SSH authentication failed." : master!.errorText) }
                guard Date() < deadline else { throw ClientError.connection("SSH authentication timed out.") }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Also proves that a configured shell (e.g. `sudo su -`) starts without prompting.
            _ = try run("exit 0")
        } catch { close(); throw error }
    }
    var controlPath: String { socket }
    deinit { close() }
    func close() { shell?.close(); shell = nil; master?.close(); master = nil; try? FileManager.default.removeItem(at: directory) }
    func channel(command: String) throws -> SSHCommandChannel {
        guard master?.isRunning == true else { throw ClientError.connection("The SSH session is closed. Connect again.") }
        // OpenSSH keeps the first value of an option, so these must precede the site's own options.
        return try SSHCommandChannel(arguments: ["-S", socket, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false"] + configuration.baseArguments() + ["--", configuration.site.host, command])
    }
    /// Starts `script` either directly or, like WinSCP's SCP/Shell setting, inside the configured
    /// shell: the shell runs as the remote command and receives one line that prints a unique
    /// marker and then execs the quoted script. Output before the marker (banners, motd) is
    /// discarded, and the stream is returned only once the shell has consumed that line, so
    /// later protocol bytes always reach the script rather than the shell.
    func open(_ script: String, arguments: [String] = [], token: CancellationToken = CancellationToken()) throws -> SSHCommandChannel {
        let command = try SCPShell.command(script, arguments: arguments)
        let shell = configuration.site.settings.shell.trimmingCharacters(in: .whitespaces)
        guard !shell.isEmpty else { return try channel(command: command) }
        let stream = try channel(command: shell)
        do {
            let marker = "SYNCSCP-READY-" + UUID().uuidString
            try stream.send(Data("echo \(marker); \(command)\n".utf8), token: token)
            for _ in 0..<1000 {
                var line = try stream.line(token: token)
                if line.last == 13 { line.removeLast() }
                if line == Data(marker.utf8) { return stream }
            }
            throw ClientError.protocolError("The shell printed too much output before starting the command.")
        } catch ClientError.cancelled {
            stream.close(); throw ClientError.cancelled
        } catch {
            let detail = stream.errorText
            stream.close()
            throw ClientError.connection("The SCP shell “\(shell)” did not start the command.\(detail.isEmpty ? "" : " " + detail) A sudo shell must be allowed without a password prompt (NOPASSWD), as in WinSCP.")
        }
    }
    private func persistentShell(token: CancellationToken) throws -> SSHCommandChannel {
        if let shell, shell.isRunning { return shell }
        shell?.close(); shell = nil
        let configured = configuration.site.settings.shell.trimmingCharacters(in: .whitespaces)
        let stream = try channel(command: configured.isEmpty ? "exec /bin/sh" : configured)
        do {
            // Discard login banners and motd once, before the first command.
            let marker = "SYNCSCP-READY-" + UUID().uuidString
            try stream.send(Data("printf '%s\\n' \(marker)\n".utf8), token: token)
            for _ in 0..<1000 {
                var line = try stream.line(token: token)
                if line.last == 13 { line.removeLast() }
                if line == Data(marker.utf8) { _ = stream.takeErrors(); shell = stream; return stream }
            }
            throw ClientError.protocolError("The shell printed too much output before starting.")
        } catch ClientError.cancelled {
            stream.close(); throw ClientError.cancelled
        } catch {
            let detail = stream.errorText
            stream.close()
            if configured.isEmpty { throw error }
            throw ClientError.connection("The SCP shell “\(configured)” did not start the command.\(detail.isEmpty ? "" : " " + detail) A sudo shell must be allowed without a password prompt (NOPASSWD), as in WinSCP.")
        }
    }

    /// Runs one script in the persistent shell: no stdin (it must not consume the shell's
    /// input), output up to a unique end marker, and the script's own exit status.
    func run(_ script: String, arguments: [String] = [], token: CancellationToken = CancellationToken()) throws -> Data {
        try token.check()
        let stream = try persistentShell(token: token)
        let marker = "SYNCSCP-END-" + UUID().uuidString
        do {
            stream.markActive(); _ = stream.takeErrors()
            try stream.send(Data("\(try SCPShell.inline(script, arguments: arguments)) </dev/null; printf '\\n%s %s\\n' \(marker) \"$?\"\n".utf8), token: token)
            let output = try stream.read(until: Data("\n\(marker) ".utf8), limit: 64 * 1024 * 1024, token: token)
            let statusLine = try stream.line(token: token)
            guard let status = Int(String(decoding: statusLine, as: UTF8.self).trimmingCharacters(in: .whitespaces)) else {
                throw ClientError.protocolError("The shell returned an invalid exit status.")
            }
            let errors = stream.takeErrors()
            guard status == 0 else { throw ClientError.remote("SCP/SSH", status, errors.isEmpty ? "The server rejected the operation." : errors) }
            return output
        } catch let error as ClientError {
            // A cancelled or broken command leaves the shell in an unknown state.
            if case .remote = error {} else { shell?.close(); shell = nil }
            throw error
        }
    }
}
