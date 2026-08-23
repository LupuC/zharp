import Foundation

/// One executed command, with where and when it ran.
struct HistoryEntry: Codable {
    var command: String = ""
    var directory: String?
    var shell: String = ""
    var when: Date = Date()

    // The Windows build's JSON keys, so a history file moves between platforms.
    private enum CodingKeys: String, CodingKey {
        case command = "cmd"
        case directory = "dir"
        case shell
        case when
    }
}

/// Cross-shell, cross-session command history, fed by the terminal's
/// command-capture pipeline (Enter capture + prompt-mark confirmation) and
/// persisted to ~/Library/Application Support/Zharp/history.json. Thread-safe:
/// commands arrive from pty reader threads and the main thread alike.
final class HistoryStore {
    private static let cap = 5000

    static let shared = HistoryStore()

    private let lock = NSLock()
    private var entries: [HistoryEntry] = [] // oldest first
    private var saveScheduled = false

    static var historyURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("history.json")
    }

    private init() {
        do {
            let data = try Data(contentsOf: Self.historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([HistoryEntry].self, from: data)
            entries = loaded.filter { !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        } catch {
            // Missing or corrupt history starts fresh - never block the terminal on it.
        }
    }

    func add(command: String, directory: String?, shell: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty || command.count > 500 { return }

        lock.lock()
        // One entry per command: reusing a command moves it to the front (with
        // the fresh directory and timestamp) instead of stacking. This also
        // absorbs the double-report per command (Enter capture + the next
        // prompt's confirmation).
        entries.removeAll { $0.command == command }
        entries.append(HistoryEntry(command: command, directory: directory,
                                    shell: shell, when: Date()))
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        lock.unlock()
        scheduleSave()
    }

    /// Newest-first snapshot, deduplicated by command text (the most recent
    /// occurrence wins), optionally scoped to one directory.
    func query(filter: String? = nil, directory: String? = nil, limit: Int = 100) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        var result: [HistoryEntry] = []
        result.reserveCapacity(Swift.min(limit, entries.count))
        for entry in entries.reversed() {
            if result.count >= limit { break }
            if let directory,
               entry.directory?.caseInsensitiveCompare(directory) != .orderedSame {
                continue
            }
            if let filter, !filter.isEmpty,
               entry.command.range(of: filter, options: .caseInsensitive) == nil {
                continue
            }
            if seen.insert(entry.command).inserted {
                result.append(entry)
            }
        }
        return result
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    private func scheduleSave() {
        // Coalesce bursts: one write at most ~2s after the last add.
        lock.lock()
        if saveScheduled {
            lock.unlock()
            return
        }
        saveScheduled = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.saveScheduled = false
            let snapshot = self.entries
            self.lock.unlock()
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try FileManager.default.createDirectory(at: AppSettings.supportDirectory,
                                                        withIntermediateDirectories: true)
                try data.write(to: Self.historyURL, options: .atomic)
            } catch {
                // Non-fatal: history just won't persist this round.
            }
        }
    }
}
