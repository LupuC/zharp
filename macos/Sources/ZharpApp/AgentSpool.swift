import Darwin
import Foundation

/// The second way an agent can report its state: it drops a small file, and
/// Zharp picks it up.
///
/// Claude Code hands its hook's escape sequence back to the agent, which writes
/// it to the pty for us. That needs no files and routes itself, because
/// whatever comes out of a pty belongs to that pty's tab. Nothing else does
/// that. Codex has no field for returning a terminal sequence, and the
/// /dev/tty macOS does have is not the way round it: a hook inherits the
/// agent's controlling terminal, but the agent is in the middle of painting
/// that screen, so another process writing escape bytes into it is a race and
/// not a transport. For those agents the report travels through the filesystem
/// instead.
///
/// Routing is not guessed. Zharp puts a unique key in the environment of every
/// shell it starts (`ZHARP_SESSION`), the agent's hook inherits it, and the
/// report carries it back. Two Codex sessions in the same repository still land
/// on their own tabs, which matching on the working directory could never
/// manage.
///
/// Each report is a separate file, written under a name the watcher ignores and
/// then renamed into place. A rename within one directory is atomic, so a
/// reader can never see half a report, and there is no read offset to keep in
/// step with a writer.
final class AgentSpool {

    /// The spool the app runs. One per process: the reports are files, and two
    /// watchers on one directory race for every one of them.
    static let shared = AgentSpool()

    /// Where hooks drop their reports, and the value exported to shells as
    /// `ZHARP_SPOOL`.
    ///
    /// `ZHARP_SPOOL_DIR` redirects it, which is how this gets exercised without
    /// fighting a running Zharp: whichever watcher reads a report first deletes
    /// it, so a test sharing the real directory would lose reports to the app
    /// and the app would lose reports to the test.
    static let directory: URL = {
        let custom = ProcessInfo.processInfo.environment["ZHARP_SPOOL_DIR"]
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return AppSettings.supportDirectory.appendingPathComponent("agents", isDirectory: true)
    }()

    /// Reports held for a tab that has not subscribed yet. Bounded because a
    /// key minted by a process that has since exited will never be claimed.
    private static let maxPending = 64

    private let directory: URL
    private let queue = DispatchQueue(label: "app.zharp.agent-spool", qos: .utility)

    /// Main thread only, all three of them. Reports are parsed off the main
    /// thread and hop to it before they touch any of this, which is also where
    /// they have to end up: the only thing that reads a report is the UI.
    private var observers: [String: (AgentReport) -> Void] = [:]
    private var pending: [(key: String, report: AgentReport)] = []
    private var started = false

    private var source: DispatchSourceFileSystemObject?

    /// Serial-queue state: `scan()` and everything it calls run there alone,
    /// so this needs no lock.
    private var scanScheduled = false

    init(directory: URL = AgentSpool.directory) {
        self.directory = directory
    }

    deinit {
        // The event handler holds the source, which is what keeps the
        // descriptor open. Cancelling is the only thing that breaks that.
        source?.cancel()
    }

    // ---------------------------------------------------------------- watching

    /// Starts watching. Safe to call more than once. Main thread.
    func start() {
        if started { return }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            App.log("agent spool: could not create \(directory.path): \(error.localizedDescription)")
            return
        }
        started = true
        queue.async { [weak self] in self?.pruneStale() }

        // Left stopped rather than half started, so calling start() again is
        // still worth something. A watcher that never armed takes every agent's
        // status with it and says nothing.
        guard arm() else {
            started = false
            return
        }

        // Anything already waiting. Queued after the watcher is live so nothing
        // can slip through the gap between the two, and the queue is serial so
        // the prune above has finished by the time this runs.
        queue.async { [weak self] in self?.scan() }
    }

    /// Stops watching. Reports still on disk stay there for the next start.
    /// Observers stay registered: stopping the watcher is not closing the tabs.
    func stop() {
        started = false
        source?.cancel()
        source = nil
    }

    private func arm() -> Bool {
        // O_EVTONLY is the "I only want to hear about it" open: it does not
        // count as a reference that would keep an unmounted volume busy.
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor < 0 {
            App.log("agent spool: cannot watch \(directory.path): \(String(cString: strerror(errno)))")
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.write) {
                self.scheduleScan()
            }
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                // The descriptor follows the inode, not the path. Once the
                // directory it was opened on is unlinked or moved, this source
                // never fires again, even though the path still resolves to
                // whatever took its place. Reopen, or the spool is dead for the
                // rest of the run with nothing to show for it.
                DispatchQueue.main.async { self.rearm() }
            }
        }
        source.setCancelHandler { close(descriptor) }

        self.source = source
        source.resume()
        return true
    }

    private func rearm() {
        guard started else { return }
        source?.cancel()
        source = nil
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            // Nothing left to watch and nothing that would fire to try again,
            // so this is where it ends rather than a retry loop nobody asked
            // for.
            App.log("agent spool: \(directory.path) is gone: \(error.localizedDescription)")
            started = false
            return
        }
        guard arm() else {
            started = false
            return
        }
        queue.async { [weak self] in self?.scan() }
    }

    /// Coalesces the wake-ups. A burst of renames is one rescan, and deleting
    /// the reports we just read writes to the directory too, which would
    /// otherwise buy a scan per report delivered.
    private func scheduleScan() {
        if scanScheduled { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.scan()
        }
    }

    private func scan() {
        guard let entries = list() else {
            // The directory is not there any more. On the plain vanished case
            // the source has already asked for a rearm; this catches the rest.
            DispatchQueue.main.async { [weak self] in self?.rearm() }
            return
        }

        // Oldest first. Readdir order is not arrival order, and these reports
        // are a state machine: a "done" applied after the "permission" that
        // followed it leaves the tab claiming the wrong thing for the rest of
        // the turn. The write time is the only stamp the file carries.
        let reports = entries
            .filter { $0.url.pathExtension == "json" }
            .sorted { $0.written < $1.written }

        for entry in reports {
            deliver(entry.url)
        }
    }

    /// Clears out half written reports abandoned by a hook that died mid write.
    /// Only old ones: a hook running right now owns its temporary file, and a
    /// second Zharp may be running too. Finished reports are not touched here,
    /// those get delivered instead.
    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-3600)
        guard let entries = list() else { return }
        for entry in entries where entry.url.pathExtension == "tmp" {
            if entry.written < cutoff {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    private func list() -> [(url: URL, written: Date)]? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return nil }

        return urls.map { url in
            let written = (try? url.resourceValues(forKeys: Set(keys)))?
                .contentModificationDate ?? Date.distantPast
            return (url, written)
        }
    }

    // ---------------------------------------------------------------- delivery

    private func deliver(_ url: URL) {
        guard let text = readAndRemove(url) else { return }
        guard let report = AgentReport.parse(text) else { return }
        guard let key = report.session, !key.isEmpty else { return } // nothing to route it to
        DispatchQueue.main.async { [weak self] in self?.route(key, report) }
    }

    /// Reads a report and takes it out of the way.
    ///
    /// The rename should mean the content is already whole, but a watcher can
    /// still beat the filesystem to it, so a couple of quick retries cost
    /// nothing and save a dropped report.
    ///
    /// The delete comes before the parse and before the routing, so a report
    /// that is malformed, or addressed to a tab nobody has open, leaves the
    /// disk either way. Keeping it would mean re-reading the same bad file on
    /// every wake for the rest of the run.
    private func readAndRemove(_ url: URL) -> String? {
        guard acceptable(url) else { return nil }

        for _ in 0..<3 {
            do {
                let data = try Data(contentsOf: url)
                try? FileManager.default.removeItem(at: url)

                // Lossy on purpose. Bad bytes become replacement characters and
                // fail the JSON parse, which is the same dropped report as
                // refusing to decode them, minus a second path to get there.
                return String(decoding: data, as: UTF8.self)
            } catch {
                if !FileManager.default.fileExists(atPath: url.path) {
                    return nil // somebody else got there first
                }
                Thread.sleep(forTimeInterval: 0.015) // still being written
            }
        }
        return nil
    }

    /// The most a report is allowed to be. The hooks write a few hundred bytes,
    /// so this is three orders of magnitude of headroom.
    private static let maxReportBytes: off_t = 64 * 1024

    /// Whether this is worth opening at all.
    ///
    /// Everything in here is a plain file a hook renamed into place. Anything
    /// else is not a report, and is worth turning away by name rather than by
    /// reading it and finding out:
    ///
    /// A big one is read whole into memory, twice over, on the way to being
    /// parsed. A 200MB file put here took 400MB of resident memory before it
    /// was dropped for not being JSON, and nothing bounded how much further
    /// that could go.
    ///
    /// A symlink is followed, so it decides what Zharp opens rather than the
    /// spool doing. Nothing crosses a privilege line - Zharp reads as the user
    /// who owns the link either way, and a private key is not going to parse as
    /// a report - but the spool has no reason to read anything it was not
    /// handed, so `lstat` rather than `stat`.
    ///
    /// A FIFO or a directory is neither readable as a report nor removable by
    /// the success path, so before this each one cost three opens and 45ms of
    /// sleeping on this queue on every single scan, forever.
    ///
    /// Rejects are unlinked so they stop coming back. `unlink` rather than
    /// FileManager: it takes a symlink or a FIFO out by name, and it refuses a
    /// directory rather than deleting whatever is inside one somebody put here
    /// by mistake.
    private func acceptable(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }

        let why: String
        if (info.st_mode & S_IFMT) != S_IFREG {
            why = "not a plain file"
        } else if info.st_size > Self.maxReportBytes {
            why = "\(info.st_size) bytes"
        } else {
            return true
        }

        // Logged only when it went away. A directory cannot be unlinked and so
        // comes back every scan; saying so every time would be the noise, not
        // the news.
        if unlink(url.path) == 0 {
            App.log("agent spool: dropped \(url.lastPathComponent), \(why)")
        }
        return false
    }

    private func route(_ key: String, _ report: AgentReport) {
        if let handler = observers[key] {
            handler(report)
            return
        }

        // No tab has claimed this key. Hold the report rather than drop it: a
        // hook can beat its own tab to the subscription, and anything the sweep
        // at startup finds arrived while Zharp was not running. The Windows
        // build reads those files with nobody subscribed yet and loses them,
        // which is the one place its behaviour and docs/agent-protocol.md
        // disagree outright.
        pending.append((key, report))
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
    }

    // ---------------------------------------------------------------- observers

    /// Routes reports carrying `key` to `handler`. Both this and the handler
    /// are main thread.
    ///
    /// One handler per key, because a session key belongs to exactly one tab;
    /// registering a second replaces the first. Anything already held for this
    /// key is delivered right here, in arrival order, so subscribing late costs
    /// nothing.
    func addObserver(session key: String, _ handler: @escaping (AgentReport) -> Void) {
        observers[key] = handler
        let held = pending.filter { $0.key == key }
        if held.isEmpty { return }
        pending.removeAll { $0.key == key }
        for entry in held { handler(entry.report) }
    }

    /// Stops routing to this key. A closing tab must call this: the spool
    /// outlives every tab and would otherwise hold each one it ever saw.
    func removeObserver(session key: String) {
        observers.removeValue(forKey: key)
        pending.removeAll { $0.key == key }
    }
}
