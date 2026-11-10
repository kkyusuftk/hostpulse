import CryptoKit
import Foundation

struct RemoteError: Error {
    var message: String
}

/// Runs /usr/bin/ssh with the user's own config, keys and agent.
enum SSH {
    /// Connections are multiplexed so each poll reuses one authenticated session.
    /// Re-created on every call because macOS periodically cleans /tmp.
    static var controlDirectory: String {
        let dir = "/tmp/hostpulse-\(getuid())"
        if mkdir(dir, 0o700) != 0 && errno != EEXIST { return NSTemporaryDirectory() }
        return dir
    }

    static func arguments(for host: HostConfig, command: String, timeout: Int = 8) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(timeout)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory)/%C",
            "-o", "ControlPersist=120",
        ]
        if let port = host.port { args += ["-p", String(port)] }
        let identity = host.identityFile.trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty { args += ["-i", (identity as NSString).expandingTildeInPath] }
        args += splitArguments(host.extraArguments)
        args += ["--", host.target.trimmingCharacters(in: .whitespaces), command]
        return args
    }

    static func run(_ host: HostConfig, command: String, input: Data?, timeout: TimeInterval) async -> ProcessResult {
        await ProcessRunner.run("/usr/bin/ssh", arguments(for: host, command: command), input: input, timeout: timeout)
    }

    /// Closes the shared connection, e.g. after waking from sleep or editing a host.
    static func closeMaster(_ host: HostConfig) async {
        var args = arguments(for: host, command: "true")
        args.insert(contentsOf: ["-O", "exit"], at: 0)
        _ = await ProcessRunner.run("/usr/bin/ssh", args, input: nil, timeout: 5)
    }

    /// Splits extra arguments on whitespace, honoring simple quotes.
    static func splitArguments(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var inToken = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inToken = true
            } else if ch.isWhitespace {
                if inToken { result.append(current); current = ""; inToken = false }
            } else {
                current.append(ch)
                inToken = true
            }
        }
        if inToken { result.append(current) }
        return result
    }

    /// Turns ssh's stderr into something a person can act on.
    static func describe(_ r: ProcessResult, target: String) -> String {
        if r.timedOut { return "Timed out talking to \(target)" }
        let err = String(decoding: r.stderr, as: UTF8.self)
        let lower = err.lowercased()
        if lower.contains("permission denied") {
            return "Login refused. Set up key auth: ssh-copy-id \(target)"
        }
        if lower.contains("could not resolve hostname") { return "Unknown host name “\(target)”" }
        if lower.contains("connection refused") { return "SSH refused. Is Remote Login on?" }
        if lower.contains("no route to host") || lower.contains("network is unreachable") { return "No route to host (offline?)" }
        if lower.contains("timed out") { return "Connection timed out" }
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            return "Host key changed. Check ~/.ssh/known_hosts"
        }
        let line = err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        if let line { return line }
        return r.status == 0 ? "Unexpected output from \(target)" : "ssh exited with status \(r.status)"
    }
}

/// The collector script and the sensor helper that HostPulse sends to remote machines.
enum RemoteCollector {
    static let script: Data = {
        guard let url = Bundle.main.url(forResource: "collect", withExtension: "sh"),
              let data = try? Data(contentsOf: url) else { return Data("echo error=collector script missing\n".utf8) }
        return data
    }()

    /// The helper binary and the versioned path it lives at on remote Macs (relative to $HOME).
    static let probe: (data: Data, path: String)? = {
        guard let url = Bundle.main.url(forResource: "hostpulse-probe", withExtension: nil),
              let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12)
        return (data, ".cache/hostpulse/probe-\(hash)")
    }()

    static func collect(_ host: HostConfig, full: Bool) async -> Result<Metrics, RemoteError> {
        let probePath = host.installHelper ? (probe?.path ?? "-") : "-"
        let command = "sh -s -- \(probePath) \(full ? 1 : 0)"
        let r = await SSH.run(host, command: command, input: script, timeout: full ? 40 : 25)
        let out = String(decoding: r.stdout, as: UTF8.self)
        guard !r.timedOut, out.contains("@@HOSTPULSE") else {
            return .failure(RemoteError(message: SSH.describe(r, target: host.target)))
        }
        var m = CollectorParser.parse(out)
        if !host.installHelper && m.os == "Darwin" { m.helper = .disabled }
        return .success(m)
    }

    /// Copies the helper to ~/.cache/hostpulse on a remote Mac and checks it runs.
    static func installProbe(_ host: HostConfig) async -> Result<Void, RemoteError> {
        guard let probe else { return .failure(RemoteError(message: "Helper is missing from the app bundle")) }
        let name = (probe.path as NSString).lastPathComponent
        let script = """
        d="$HOME/.cache/hostpulse"; mkdir -p "$d" && rm -f "$d"/probe-* "$d/.probe.tmp" && \
        cat > "$d/.probe.tmp" && chmod 755 "$d/.probe.tmp" && mv -f "$d/.probe.tmp" "$d/\(name)" && \
        "$d/\(name)" --interval 0 > /dev/null && echo HOSTPULSE_OK
        """
        let r = await SSH.run(host, command: "sh -c '\(script)'", input: probe.data, timeout: 60)
        if String(decoding: r.stdout, as: UTF8.self).contains("HOSTPULSE_OK") { return .success(()) }
        return .failure(RemoteError(message: SSH.describe(r, target: host.target)))
    }
}

struct ProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

enum ProcessRunner {
    /// Runs a process off the main thread, feeding `input` to stdin and killing it after `timeout`.
    static func run(_ path: String, _ args: [String], input: Data?, timeout: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path, args, input: input, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ path: String, _ args: [String], input: Data?, timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8), timedOut: false)
        }

        if let input {
            DispatchQueue.global(qos: .utility).async {
                // Throws (instead of crashing) if ssh exits early; SIGPIPE is ignored app-wide.
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let timedOut = Flag()
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()
        return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData, timedOut: timedOut.isSet)
    }

    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
