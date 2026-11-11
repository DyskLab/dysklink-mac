import Darwin
import Foundation

/// A message about a terminal session between the phone and the Mac.
struct TerminalMessage: Codable, Equatable {
    var id: String
    /// Base64 bytes: what was typed on `terminal.input`, what the shell printed on `terminal.output`.
    var data: String?
    var cols: Int?
    var rows: Int?
    var error: String?
    var exitCode: Int?
}

/// A login shell on a pseudo terminal, so colors, Ctrl-C, and full-screen programs like vim and top work.
///
/// Output is gathered for up to `batchDelay` and handed out in one piece. While `maxInFlight` pieces wait for the
/// network (the receiver calls `sent()` for each), reading stops, so the shell itself waits instead of output
/// piling up in memory and holding up the connection.
final class PtyShell: @unchecked Sendable {
    let id: String
    private(set) var pid: pid_t = 0
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private let queue: DispatchQueue
    private var finished = false
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var pendingOutput = Data()
    private var flushScheduled = false
    private var inFlight = 0
    private var readerPaused = false
    static let batchDelay: DispatchTimeInterval = .milliseconds(16)
    static let batchBytes = 32 * 1024
    static let maxInFlight = 4
    /// Called on the shell's queue with each piece of output. Call `sent()` once it went out.
    var onOutput: (Data) -> Void = { _ in }
    var onExit: (Int32) -> Void = { _ in }

    enum Failure: Error { case spawn(Int32) }

    init(id: String) {
        self.id = id
        queue = DispatchQueue(label: "terminal.\(id)")
    }

    deinit {
        // Releasing a suspended dispatch source crashes, so a paused reader is resumed first.
        if readerPaused { reader?.resume() }
        reader?.cancel()
        exitWatch?.cancel()
    }

    /// The user's own shell as a login shell, starting in the home folder.
    static var userShell: String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }), FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    func start(cols: Int, rows: Int, shell: String = PtyShell.userShell, arguments: [String]? = nil) throws {
        let name = (shell as NSString).lastPathComponent
        // A leading dash makes it a login shell, which reads the user's profile like Terminal.app does.
        let argv = [arguments == nil ? "-" + name : name] + (arguments ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["TERM_PROGRAM"] = "DyskLink"
        environment["SHELL"] = shell
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "__CFBundleIdentifier", "XPC_SERVICE_NAME"] { environment[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Everything the child needs is made before fork, because only C calls are safe after it.
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cShell = strdup(shell)
        let cHome = strdup(home)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cShell)
            free(cHome)
        }
        var size = winsize(ws_row: UInt16(clamping: max(rows, 2)), ws_col: UInt16(clamping: max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { throw Failure.spawn(errno) }
        if child == 0 {
            chdir(cHome)
            execve(cShell, cArgs, cEnv)
            _exit(127)
        }
        pid = child
        master = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.resume()
        self.reader = reader

        let watch = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        watch.setEventHandler { [weak self] in self?.reap() }
        watch.resume()
        exitWatch = watch
    }

    /// Returns false when nothing more could be read now.
    @discardableResult
    private func readAvailable() -> Bool {
        guard master >= 0 else { return false }
        let count = read(master, &buffer, buffer.count)
        guard count > 0 else { return false }
        pendingOutput.append(buffer, count: count)
        if pendingOutput.count >= Self.batchBytes {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flush()
            }
        }
        return true
    }

    private func flush() {
        guard !pendingOutput.isEmpty else { return }
        let piece = pendingOutput
        pendingOutput = Data()
        inFlight += 1
        onOutput(piece)
        if inFlight >= Self.maxInFlight, !readerPaused, !finished, let reader {
            readerPaused = true
            reader.suspend()
        }
    }

    /// One piece of output went out (or was dropped); reading goes on when few are left on the way.
    func sent() {
        queue.async { [self] in
            inFlight = max(0, inFlight - 1)
            if readerPaused, inFlight < Self.maxInFlight {
                readerPaused = false
                reader?.resume()
            }
        }
    }

    private func reap() {
        guard !finished else { return }
        // Whatever the shell printed last comes before the exit.
        var reads = 0
        while reads < 64, readAvailable() { reads += 1 }
        flush()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        finished = true
        // A suspended source must be resumed before it can be canceled.
        if readerPaused { readerPaused = false; reader?.resume() }
        reader?.cancel()
        exitWatch?.cancel()
        if master >= 0 { close(master) }
        master = -1
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit(code)
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard master >= 0, !finished else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 {
                        if errno == EAGAIN { usleep(2_000); continue }
                        break
                    }
                    offset += written
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [self] in
            guard master >= 0, !finished else { return }
            var size = winsize(ws_row: UInt16(clamping: max(rows, 2)), ws_col: UInt16(clamping: max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &size)
        }
    }

    /// Hangs up like closing a Terminal window, and kills it if it doesn't go.
    func hangUp() {
        queue.async { [self] in
            guard pid > 0, !finished else { return }
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                if !finished { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
            }
        }
    }
}
extension TerminalMessage: Sendable {}
