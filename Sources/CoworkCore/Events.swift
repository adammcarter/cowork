import Foundation

/// The lifecycle event stream (ADR 001): one append-only file, one JSON object per
/// line, watchable by any plugin or agent with no API at all — `tail -f` is a
/// first-class client.
///
/// Concurrent writers are safe without coordination because POSIX guarantees
/// `O_APPEND` writes below `PIPE_BUF` (4096 bytes) are atomic. That guarantee is
/// the reason event lines must stay small and bulk worker output goes to a
/// per-dispatch log instead (ADR 003 rule 8).
public enum Events {
    static let schemaVersion = 1
    private static let pipeBuf = 4096

    struct Event: Codable {
        let v: Int
        let ts: String
        let id: String
        let parent: String
        let root: String
        let backend: String
        let event: String
        var detail: String?
        var workspace: String?
    }

//: @use-case:contract.events.every_event_carries_parent_and_root#every_event_carries_pare
    public static func emit(id: String, parent: String, root: String, backend: String,
                     event: String, detail: String? = nil, workspace: String? = nil) {
        let e = Event(v: schemaVersion, ts: ISO8601DateFormatter().string(from: Date()),
                      id: id, parent: parent, root: root, backend: backend,
                      event: event, detail: detail, workspace: workspace)
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)

        // A line over PIPE_BUF loses its atomicity guarantee and could interleave
        // with another writer. Truncating detail is the honest failure: never emit
        // a line that could corrupt another dispatch's record.
        if line.count > pipeBuf, let truncated = try? JSONEncoder().encode(
            Event(v: schemaVersion, ts: e.ts, id: id, parent: parent, root: root,
                  backend: backend, event: event,
                  detail: "<detail omitted: exceeded PIPE_BUF>", workspace: workspace)) {
            line = truncated
            line.append(0x0A)
        }

        try? Store.prepare()

        // O_APPEND is the whole mechanism, and it must be asked for explicitly.
        //
        // `FileHandle(forWritingAtPath:)` opens O_WRONLY, so seek-to-end + write is
        // a race: two writers resolve the same offset and one overwrites the other.
        // That silently loses events — the exact outcome ADR 003 rule 5 forbids —
        // and it will not show up in a single-writer journey. Under O_APPEND the
        // kernel resolves the offset and the write together, atomically for sizes
        // below PIPE_BUF, which is what lets every orchestrator on the machine
        // share one stream with no lock, no writer epoch and no arbitration.
        let fd = open(Store.eventStream.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
    }
}
