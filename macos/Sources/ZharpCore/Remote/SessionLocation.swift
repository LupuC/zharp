import Foundation

// ------------------------------------------------------------- RemoteHost

/// A machine the session is on, together with what Zharp is allowed to do
/// about it.
///
/// `label` is the user's own word for the machine: an alias out of their ssh
/// config, or the host half of user@host. It is deliberately not the hostname
/// the far end reports, because the panel header is narrow and the name they
/// typed is the one they will recognise.
///
/// `reach` is the security boundary of the whole feature, which is why it is a
/// case with a payload rather than a flag next to one. A machine Zharp watched
/// the user reach carries the arguments to make the same trip again. A machine
/// that merely announced itself carries nothing at all: that name arrived over
/// the wire from a program on another computer, and turning a name from the
/// wire into an outbound connection would let the far end choose where Zharp
/// connects next. There is no boolean anyone can forget to check, because a
/// reported host has no argument list to hand to the thing that connects.
public struct RemoteHost: Hashable, Sendable, CustomStringConvertible {

    /// How Zharp came to know about this machine, and with it, whether it may
    /// be dialled.
    public enum Reach: Hashable, Sendable {
        /// Zharp read the command line at a local prompt, before it was sent,
        /// so it knows the flags as well as the destination. Only this case
        /// carries anything a connection can be built from.
        case watched(SshInvocation)

        /// The machine named itself, through OSC 7 or a window title. Knowing
        /// it is worth having on its own: it is the difference between showing
        /// nothing and showing another machine's repository as though it were
        /// this one's. It is never enough to connect on.
        case reported
    }

    public let label: String
    public let reach: Reach

    /// A machine the user reached with a command Zharp watched them type. The
    /// invocation can only have come from `SshTarget.parse`, which is the
    /// point: there is no way to build one of these around a name that arrived
    /// over the wire.
    public init(label: String, invocation: SshInvocation) {
        self.label = label
        self.reach = .watched(invocation)
    }

    private init(reportedLabel: String) {
        self.label = reportedLabel
        self.reach = .reported
    }

    /// A machine that announced itself.
    ///
    /// Nil when the name is not a machine name, which for a value that came
    /// off the wire is a real possibility rather than a formality. A caller
    /// that gets nil must drop the whole report: falling back to treating the
    /// directory as local is the exact bug this type exists to prevent, since
    /// a remote POSIX path is a syntactically perfect local one on macOS.
    public static func reported(_ label: String) -> RemoteHost? {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostName.isValid(name) else { return nil }
        return RemoteHost(reportedLabel: name)
    }

    /// The arguments for a second connection, or nil when this machine was
    /// only named to us. Whatever opens connections takes one of these, so a
    /// reported host has nothing it could pass.
    public var invocation: SshInvocation? {
        if case .watched(let invocation) = reach { return invocation }
        return nil
    }

    /// For the panel, which names the machine either way but says something
    /// different depending on whether it can go and look. Reading this is not
    /// permission to connect: only `invocation` carries that.
    public var canConnect: Bool { invocation != nil }

    /// A stable text form for logs and for anything that has to key a
    /// dictionary by a string. Equality does not go through it: the value
    /// hashes on its own parts, so two different targets cannot collide by
    /// having their arguments join into the same text. The separator is
    /// U+0001 for the same reason.
    public var key: String {
        switch reach {
        case .watched(let invocation):
            return ([label] + invocation.arguments).joined(separator: "\u{1}")
        case .reported:
            return label + "\u{1}"
        }
    }

    public var description: String { label }
}

// -------------------------------------------------------- SessionLocation

/// Where a session is standing: a directory, and the machine it is on.
///
/// Zharp used to track only the directory, which is correct exactly until the
/// user types `ssh`. From that moment the recorded path belongs to a machine
/// the shell is no longer on, and every question asked of it (is this a git
/// repository, what has changed in it) is answered by the wrong computer with
/// nothing to show that anything is wrong. That is worse here than it is on
/// Windows: there a lost host produces a path in the wrong notation and fails
/// loudly, while /home/me/work off a Linux box is a perfectly ordinary local
/// path on a Mac and quietly reads whatever happens to be there.
///
/// So the host travels inside the value, not in a second variable beside it.
/// A path that has been separated from its machine is a state this type cannot
/// represent.
public struct SessionLocation: Hashable, Sendable, CustomStringConvertible {

    /// Nil when this is the machine Zharp is running on.
    public let remote: RemoteHost?

    /// The directory, in the far end's own notation when remote. Empty means
    /// the session is somewhere Zharp cannot name, which is a real and common
    /// state over ssh: a remote shell need not report its directory at all.
    public let path: String

    private init(remote: RemoteHost?, path: String) {
        self.remote = remote
        self.path = path
    }

    public var isRemote: Bool { remote != nil }

    public var hasPath: Bool { !path.isEmpty }

    /// A directory on this machine, or nil when there isn't one.
    public static func local(_ path: String?) -> SessionLocation? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SessionLocation(remote: nil, path: path)
    }

    /// A place on another machine. The path may be empty: knowing the user is
    /// on another host is worth recording before, or without ever, learning
    /// where they are standing on it.
    public static func on(_ remote: RemoteHost, path: String?) -> SessionLocation {
        SessionLocation(remote: remote,
                        path: path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// The same machine, a different directory. The host cannot be changed
    /// this way, which is deliberate: a shell that reports a new directory has
    /// not told us it moved to a new computer.
    public func withPath(_ path: String) -> SessionLocation {
        SessionLocation(remote: remote,
                        path: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The last segment, for a header that has room for one word.
    ///
    /// POSIX arithmetic serves both cases here because macOS paths are POSIX
    /// too. That coincidence is the hazard, not the convenience: it is why the
    /// machine has to be read off `remote` and can never be inferred from the
    /// shape of the path.
    public var displayName: String { PosixPath.fileName(path) }

    /// Stable text form, used as a dictionary key and in logs.
    public var description: String {
        guard let remote else { return path }
        return remote.key + "\u{1}" + path
    }

    /// Case sensitive when remote, insensitive when local. The far end is
    /// case sensitive even though the volume this is running on usually is
    /// not, and treating /A and /a over there as one directory would show the
    /// wrong one without saying so.
    public static func == (lhs: SessionLocation, rhs: SessionLocation) -> Bool {
        guard lhs.remote == rhs.remote else { return false }
        if lhs.isRemote { return lhs.path == rhs.path }
        return lhs.path.lowercased() == rhs.path.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(remote)
        hasher.combine(isRemote ? path : path.lowercased())
    }
}

// ---------------------------------------------------------------- HostName

/// What may be a machine name.
///
/// One definition, used by everything that accepts a name from anywhere: the
/// ssh command the user typed, an OSC 7 host, a window title. The rule is an
/// allowlist rather than a list of banned characters, so the interesting
/// question when reading it is not "did we remember to exclude a backtick" but
/// "is there any string here that is not a name".
public enum HostName {

    /// True when `name` could be a host: a DNS name, an IPv4 address, or an
    /// IPv6 literal with or without its brackets.
    ///
    /// A leading dash is refused explicitly. A hostname beginning with a dash
    /// is an option, and a value that reads as an option in a place a hostname
    /// was expected is how argument injection starts.
    public static func isValid(_ name: String) -> Bool {
        // 255 is the longest a DNS name can be. Past that it is not a name,
        // and it is about to be drawn into a panel header.
        guard !name.isEmpty, name.count <= 255 else { return false }

        if name.hasPrefix("[") {
            guard name.hasSuffix("]") else { return false }
            return isAddressLiteral(String(name.dropFirst().dropLast()))
        }
        if name.contains(":") {
            return isAddressLiteral(name)
        }
        guard !name.hasPrefix("-") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// An IPv6 literal, optionally with a zone (fe80::1%en0).
    ///
    /// This is a filter for characters that mean something to a shell, not an
    /// address parser. getaddrinfo will refuse anything that is not really an
    /// address, and being stricter here would only mean rejecting forms a
    /// later ssh accepts. What matters is that nothing in this set can end a
    /// word, start a command or expand into one.
    private static func isAddressLiteral(_ text: String) -> Bool {
        guard !text.isEmpty, text.contains(":") else { return false }
        return text.allSatisfy {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == ":" || $0 == "." || $0 == "%"
        }
    }
}

// --------------------------------------------------------------- PosixPath

/// Path arithmetic for directories on the far end.
///
/// Foundation's path helpers answer as the machine they are running on, which
/// is close enough to right for a Linux server that the differences only show
/// up in the cases that matter: NSString.standardizingPath resolves symlinks
/// and tildes against this machine's filesystem, and a remote path standardised
/// against local disk is a made-up answer. These are the same few operations,
/// done the way the far end would do them, and nothing here touches disk.
public enum PosixPath {

    /// The last segment. The root keeps its slash, because a header reading
    /// nothing at all is worse than one reading "/".
    public static func fileName(_ path: String) -> String {
        var text = path
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        if text == "/" { return "/" }
        guard let slash = text.lastIndex(of: "/") else { return text }
        return String(text[text.index(after: slash)...])
    }

    public static func combine(_ directory: String, _ relative: String) -> String {
        var dir = Substring(directory)
        while dir.hasSuffix("/") { dir = dir.dropLast() }
        var rest = Substring(relative)
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        return "\(dir)/\(rest)"
    }

    /// The part of `path` below `root`, or nil when it is not inside it. Case
    /// sensitive, because the far end is.
    public static func relative(_ path: String, under root: String) -> String? {
        var prefix = Substring(root)
        while prefix.hasSuffix("/") { prefix = prefix.dropLast() }
        guard !prefix.isEmpty else { return nil }
        // Literal rather than canonical: macOS hands out decomposed file
        // names, and a match that quietly equated the two forms would hand
        // back an index into a string of a different length.
        guard let match = path.range(of: prefix + "/", options: [.anchored, .literal]) else {
            return nil
        }
        let rest = String(path[match.upperBound...])
        return rest.isEmpty ? nil : rest
    }

    /// Replaces a leading ~ with the home directory read from the far end.
    ///
    /// A shell would do this before the command ran. Nothing here goes through
    /// a shell that would, and git treats ~ as an ordinary directory name, so
    /// it has to happen before the path is sent. ~other is left alone: another
    /// user's home is not ours to guess at.
    public static func expandHome(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, path.hasPrefix("~") else { return path }
        if path == "~" { return home }
        let rest = path.dropFirst()
        guard rest.hasPrefix("/") else { return path }
        var base = Substring(home)
        while base.hasSuffix("/") { base = base.dropLast() }
        return "\(base)\(rest)"
    }
}
