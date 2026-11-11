import Foundation

/// Runs a command-line tool and collects what it prints.
///
/// Never use `Process.waitUntilExit()` in this app: it spins the caller's run loop, so on the main thread timers and
/// queued blocks run in the middle of the call. In 1.1.3 a timer re-entered code that held a lock that way and froze
/// the app. This waits on a semaphore instead, which runs nothing else. It reads stdout and stderr while the tool runs,
/// so a tool printing more than a pipe holds (64 KB) can't get stuck, and it can give up and stop a tool that hangs.
///
/// It still blocks the calling thread, so slow tools belong on a background queue, never on the main thread.
enum ProcessRunner {
    struct Result: Sendable {
        /// The exit status; -1 when the tool couldn't be stopped after a timeout.
        var status: Int32
        var output: Data
        /// Only filled with `.capture`.
        var errorOutput: Data
        var timedOut: Bool

        var text: String { String(decoding: output, as: UTF8.self) }
        var errorText: String { String(decoding: errorOutput, as: UTF8.self) }
        var succeeded: Bool { status == 0 && !timedOut }
    }

    enum ErrorOutput: Sendable {
        /// Thrown away.
        case discard
        /// Kept apart in `errorOutput`.
        case capture
        /// Mixed into `output`, as a terminal shows it.
        case merge
    }

    /// Runs `path` and waits for it, at most `timeout` seconds when one is given (nil waits as long as it takes,
    /// for tools like ditto, codesign, or a password prompt). A tool still running then is terminated, and killed a
    /// second later if it ignores that. Returns nil when the tool couldn't be started.
    static func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval? = 10,
                    errorOutput: ErrorOutput = .discard, directory: URL? = nil) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = errorOutput == .capture ? Pipe() : nil
        process.standardOutput = out
        switch errorOutput {
        case .discard: process.standardError = FileHandle.nullDevice
        case .capture: process.standardError = err
        case .merge: process.standardError = out
        }
        let collector = Collector(out, err)
        // Set before run(): a tool that ends at once would otherwise never signal.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            _ = collector.finish()
            return nil
        }
        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 2)
                }
            }
        } else {
            exited.wait()
        }
        // The last output arrives just after the exit. A child the tool left running can hold the pipe open,
        // so that's only waited for briefly.
        _ = collector.ended.wait(timeout: .now() + 1)
        let (output, errors) = collector.finish()
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: status, output: output, errorOutput: errors, timedOut: timedOut)
    }

    /// Gathers each pipe's data on Foundation's background queue as it comes.
    private final class Collector: @unchecked Sendable {
        let ended = DispatchGroup()
        private let lock = NSLock()
        private var data: [Data]
        private var open: [Bool]
        private var finished = false
        private let pipes: [Pipe]

        init(_ pipes: Pipe?...) {
            self.pipes = pipes.compactMap { $0 }
            data = Array(repeating: Data(), count: self.pipes.count)
            open = Array(repeating: true, count: self.pipes.count)
            for (index, pipe) in self.pipes.enumerated() {
                ended.enter()
                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil }
                    self?.received(chunk, at: index)
                }
            }
        }

        private func received(_ chunk: Data, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished, open[index] else { return }
            if chunk.isEmpty {
                open[index] = false
                ended.leave()
            } else {
                data[index].append(chunk)
            }
        }

        /// Stops reading and hands over what came: stdout, then stderr when it was captured.
        func finish() -> (Data, Data) {
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            lock.lock()
            defer { lock.unlock() }
            finished = true
            return (data.first ?? Data(), data.count > 1 ? data[1] : Data())
        }
    }
}
