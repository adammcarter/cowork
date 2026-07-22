import Darwin
import Foundation

/// The transport that reaches a **live** worker (ADR 001 `send` / `finish`).
///
/// Everything else cowork stores is a fact written down for a later reader. A
/// message is not: it must arrive at a process that is running *now*, and if no
/// such process exists the caller has to be told so rather than have their message
/// filed somewhere hopeful. That makes this the one place where the filesystem is
/// asked to carry liveness, not just state.
///
/// **Why a FIFO and not a unix socket.** A socket per dispatch is the obvious
/// alternative and it is not available to us: `sockaddr_un.sun_path` holds 104
/// bytes, and a socket bound under the store — whose root is `COWORK_HOME`, a
/// temporary directory in every test — measures 136. The limit is a hard kernel
/// one with no relative-path escape that is portable, so the socket design fails
/// on a path the user chose, in a way no amount of care in this file could fix. A
/// FIFO has no such limit, and it reuses a guarantee this codebase already leans
/// on: `O_APPEND`-style atomicity below `PIPE_BUF` (ADR 003 rule 9).
///
/// FIFO `open` semantics are a genuine trap, and each mitigation below is here
/// because the naive form fails in a way that would make cowork lie:
///
/// - `open(O_WRONLY)` **blocks** until a reader appears — forever, for a dead
///   supervisor. With `O_NONBLOCK` it returns `ENXIO` instead, which is the
///   kernel's own answer to "is anyone listening", and is the honest signal
///   `send` needs.
/// - A receiver holding only the read end sees **EOF** the moment a sender closes,
///   and every later read returns 0 forever. Each `post` is its own open/close, so
///   the mailbox would die after one message, silently. The receiver therefore
///   opens `O_RDWR`, holding a write end of its own so EOF can never arrive.
/// - Writing to a pipe whose reader has gone raises `SIGPIPE`, which by default
///   **kills the orchestrator** — every other dispatch dying because one worker
///   exited. `F_SETNOSIGPIPE` turns that into `EPIPE`, an error the caller can be
///   told about.
public enum Mailbox {
    /// One message to a live worker. `finish` carries no text: it is the caller
    /// saying they are done, not something for the worker to act on.
    public struct Message: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case message, finish }
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String = "") {
            self.kind = kind
            self.text = text
        }
    }

    public enum MailboxError: Error, Equatable, CustomStringConvertible {
        /// No mailbox exists. The dispatch never offered to be messaged.
        case absent
        /// The mailbox exists and nothing is reading it.
        case noLiveWorker
        /// The worker is alive but not draining, and the caller's bounded wait ran
        /// out. Reported rather than waited on forever.
        case full(TimeInterval)
        case io(String)

        public var description: String {
            switch self {
            case .absent: return "mailbox.absent"
            case .noLiveWorker: return "mailbox.no-live-worker"
            case let .full(t): return "mailbox.full,waited=\(t)s"
            case let .io(m): return "mailbox.io,\(m)"
            }
        }
    }

    public static func url(_ id: String) -> URL {
        Store.dispatchDir(id).appendingPathComponent("in.fifo")
    }

    /// Serialises senders. A message is a task and can exceed `PIPE_BUF`, above
    /// which the kernel no longer promises one writer's bytes stay contiguous —
    /// two concurrent sends could interleave into one unparseable line. Cowork
    /// cannot assume a single sender: a worker that dispatches its own work can
    /// itself hold an id and message it.
    private static func lockURL(_ id: String) -> URL {
        Store.dispatchDir(id).appendingPathComponent("in.lock")
    }

    /// Create a dispatch's mailbox. Called **before** the supervisor is spawned, for
    /// the same reason the record is written first (ADR 003 rule 0): a caller holding
    /// an id may `send` immediately, and a mailbox that does not exist yet would
    /// refuse that message as though the worker were dead.
    public static func create(_ id: String) throws {
        let path = url(id)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: path)
        guard mkfifo(path.path, 0o600) == 0 else {
            throw MailboxError.io("mkfifo errno=\(errno)")
        }
    }

    /// Post a message to whoever is reading this dispatch's mailbox.
    ///
    /// `timeout` bounds two distinct waits: for a supervisor that has been spawned
    /// but has not opened its mailbox yet, and for one that is alive but not
    /// draining. Both end in a reported error, never a hang.
    public static func post(_ id: String, _ message: Message, timeout: TimeInterval = 5) throws {
        guard FileManager.default.fileExists(atPath: url(id).path) else { throw MailboxError.absent }
        guard var line = try? JSONEncoder().encode(message) else {
            throw MailboxError.io("unencodable message")
        }
        line.append(0x0A)

        let deadline = Date().addingTimeInterval(timeout)
        let fd = try openForWriting(id, deadline: deadline)
        defer { close(fd) }

        let lock = try takeLock(id)
        defer { flock(lock, LOCK_UN); close(lock) }

        try write(line, to: fd, deadline: deadline, timeout: timeout)
    }

    /// `ENXIO` means the FIFO exists and nobody holds it open for reading. That is
    /// usually a dead worker, but it is also the startup window of a live one, so
    /// the open is retried until the caller's deadline before the harsher of the
    /// two answers is given. Distinguishing them is the caller's job — it holds the
    /// record, and therefore knows whether an owner is alive.
    private static func openForWriting(_ id: String, deadline: Date) throws -> Int32 {
        while true {
            let fd = open(url(id).path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                // Without this a worker that exits between the open and the write
                // takes the orchestrator with it.
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                return fd
            }
            guard errno == ENXIO, Date() < deadline else { throw MailboxError.noLiveWorker }
            usleep(20_000)
        }
    }

    private static func takeLock(_ id: String) throws -> Int32 {
        let fd = open(lockURL(id).path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { throw MailboxError.io("lock errno=\(errno)") }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            throw MailboxError.io("flock errno=\(errno)")
        }
        return fd
    }

    /// A non-blocking write returns `EAGAIN` once the pipe buffer is full, so a
    /// message larger than the buffer needs the reader to drain. Polling for
    /// writability keeps that bounded: a stuck worker costs the caller `timeout`,
    /// not their process.
    private static func write(_ line: Data, to fd: Int32, deadline: Date,
                              timeout: TimeInterval) throws {
        var sent = 0
        try line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let n = Darwin.write(fd, base + sent, buffer.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EAGAIN {
                    guard Date() < deadline else { throw MailboxError.full(timeout) }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                // EPIPE: the reader went away mid-message. The message is not
                // delivered and the caller is told, rather than the signal killing
                // this process or a partial line reaching the worker.
                throw errno == EPIPE ? MailboxError.noLiveWorker
                                     : MailboxError.io("write errno=\(errno)")
            }
        }
    }

    /// Open this dispatch's mailbox for reading. The supervisor's end.
    public static func receive(_ id: String) throws -> Receiver {
        guard FileManager.default.fileExists(atPath: url(id).path) else { throw MailboxError.absent }
        // O_RDWR is the whole reason a mailbox survives its first sender: this end
        // holds a write end too, so the kernel never reports EOF no matter how many
        // senders come and go. O_NONBLOCK is what makes the open itself return —
        // a plain read-open would block until a sender arrived, which for a worker
        // nobody ever messages is forever.
        let fd = open(url(id).path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw MailboxError.io("open errno=\(errno)") }
        return Receiver(fd: fd)
    }

    /// A live mailbox, drained continuously by one supervisor.
    ///
    /// **The kernel buffer is not the queue, and assuming it was is a bug this code
    /// had.** A FIFO holds 8192 bytes on macOS — measured, not the 64 KB folklore —
    /// and a supervisor reads its mailbox only *between* turns. A message larger
    /// than that, sent while the worker was mid-turn, therefore jammed until the
    /// sender's timeout expired: `send` failed at exactly the moment it is most
    /// wanted, since the reason to message a worker is usually that it is busy
    /// doing the wrong thing.
    ///
    /// So a thread drains the pipe the whole time the dispatch lives, and messages
    /// queue in this process instead. The pipe goes back to being a pipe: a
    /// transport, not storage.
    public final class Receiver: @unchecked Sendable {
        private let fd: Int32
        private var pending = Data()
        private var queue: [Message] = []
        private var failure: MailboxError?
        private var closed = false
        private let condition = NSCondition()
        private var drainer: Thread?

        init(fd: Int32) {
            self.fd = fd
            let thread = Thread { [weak self] in self?.drainUntilClosed() }
            thread.stackSize = 512 * 1024
            drainer = thread
            thread.start()
        }

        /// The next message, or `nil` if none arrived before the deadline.
        ///
        /// `nil` is not an error and not an end: it is how an **idle timeout**
        /// becomes expressible at all. A blocking wait here would keep a warm worker
        /// — a live process and its context — alive until the machine was rebooted.
        public func next(timeout: TimeInterval) throws -> Message? {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let failure { throw failure }
                if !queue.isEmpty { return queue.removeFirst() }
                if closed { return nil }
                guard condition.wait(until: deadline) else { return nil }
            }
        }

        private func drainUntilClosed() {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                condition.lock()
                let done = closed
                condition.unlock()
                if done { return }

                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                // A bounded poll rather than an indefinite one, so `close` is noticed
                // promptly without needing a second descriptor to interrupt it.
                _ = poll(&p, 1, 100)

                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    absorb(Data(buffer[0..<n]))
                    continue
                }
                // n == 0 cannot mean end-of-stream here: this receiver holds its own
                // write end (O_RDWR), so there is always at least one writer and the
                // kernel has nobody to report EOF on behalf of. EAGAIN just means
                // "nothing right now", which is the normal case.
                if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    condition.lock()
                    failure = .io("read errno=\(errno)")
                    condition.broadcast()
                    condition.unlock()
                    return
                }
            }
        }

        /// Messages are newline-framed, so a message split across reads waits for
        /// its rest rather than being decoded into a wrong one.
        private func absorb(_ chunk: Data) {
            condition.lock()
            defer { condition.broadcast(); condition.unlock() }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                guard let message = try? JSONDecoder().decode(Message.self, from: line) else {
                    // A line that will not decode is dropped loudly rather than
                    // guessed at: acting on a half-understood message is worse than
                    // reporting that one arrived broken.
                    failure = .io("undecodable message")
                    return
                }
                queue.append(message)
            }
        }

        public func close() {
            condition.lock()
            guard !closed else { return condition.unlock() }
            closed = true
            condition.broadcast()
            condition.unlock()

            // The drainer owns the descriptor while it polls, so it is joined before
            // the close: freeing an fd another thread is polling invites it to be
            // reused and read by the wrong reader.
            let deadline = Date().addingTimeInterval(2)
            while let d = drainer, !d.isFinished, Date() < deadline { usleep(20_000) }
            Darwin.close(fd)
        }

        deinit { if !closed { close() } }
    }
}
