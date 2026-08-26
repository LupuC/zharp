import Foundation

// ------------------------------------------------------------ SshInvocation

/// The arguments for a second connection to a machine the user reached, and
/// the pieces of the destination worth showing or telling targets apart by.
///
/// Nothing here is ever pasted into a string and handed to a shell. The
/// arguments are an argv, spliced into a child process's argument list
/// verbatim, with every value still sitting immediately behind the flag it
/// belongs to. Rebuilding a command line out of `user`, `host` and `port`
/// would undo the point of having parsed anything: those three are for the
/// panel header and for the connection cache, not for dialling.
///
/// The initialiser is private to this file, so `SshTarget.parse` is the only
/// thing in the program that can produce one. That is what makes the rule in
/// the design enforceable rather than remembered: a machine Zharp merely heard
/// about has no invocation to offer, and whatever opens a connection asks for
/// an invocation rather than for a host name.
public struct SshInvocation: Hashable, Sendable {

    /// Complete and ordered, ending with the destination.
    ///
    /// A caller puts its own options in front of these and never after.
    /// OpenSSH keeps the first value it is given for an option, so a
    /// BatchMode=yes placed ahead of them wins over the BatchMode=no a user
    /// may have typed and this preserved.
    public let arguments: [String]

    /// The destination exactly as typed, which is always `arguments.last`.
    /// The user's own spelling goes on the wire, including a ssh:// scheme or
    /// a trailing :port, because that spelling is what their config matches
    /// against.
    public let destination: String

    /// From user@ in the destination, or from -l when the destination has no
    /// user of its own. Nil when neither said.
    public let user: String?

    /// The host half of the destination, with the scheme, the user and the
    /// port removed. Always a valid host name: `SshTarget.parse` refuses the
    /// command outright rather than producing an invocation whose host is
    /// something else wearing a hostname's clothes.
    public let host: String

    /// From -p, or from the :port of a ssh:// destination. Nil when the
    /// command named no port. A -p that is not a number is not carried and
    /// not tolerated: `SshTarget.parse` refuses the whole command, because a
    /// port is one of the values ssh expands into a ProxyCommand.
    public let port: Int?

    /// The -i value, exactly as typed. Not expanded: ssh does its own ~
    /// handling for an identity file, and expanding it here against this
    /// machine's home would only be right by accident.
    public let identityFile: String?

    /// The -J value, exactly as typed. ssh allows a comma separated chain
    /// there and every hop in it has been checked to be a destination.
    public let jumpHost: String?

    fileprivate init(arguments: [String],
                     destination: String,
                     user: String?,
                     host: String,
                     port: Int?,
                     identityFile: String?,
                     jumpHost: String?) {
        self.arguments = arguments
        self.destination = destination
        self.user = user
        self.host = host
        self.port = port
        self.identityFile = identityFile
        self.jumpHost = jumpHost
    }
}

// ---------------------------------------------------------------- SshTarget

/// Reads the `ssh` command the user typed and works out which machine they are
/// about to be standing on.
///
/// Zharp already captures what was typed at the prompt for history, so noticing
/// that the session has left this computer needs no cooperation from the far
/// end. That matters, because the other two signals are both optional: a remote
/// shell may report its directory, or its hostname in a window title, or
/// neither, and a terminal that can only tell it is elsewhere when the far end
/// volunteers the fact gets it wrong on exactly the plain servers people ssh
/// into most.
///
/// This is also the only place in the program that produces something an ssh
/// command line is built from, so it parses rather than pattern matches, and
/// refuses anything that does not look like the thing it claims to be. The
/// refusals are listed on `parse`.
public enum SshTarget {

    /// Flags that take a separate value. Their argument has to be skipped when
    /// looking for the destination, or `ssh -p 2222 host` reads 2222 as the
    /// machine.
    private static let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// Flags worth carrying to a second connection: how to reach the machine,
    /// and who to be when we get there.
    ///
    /// Two that ssh accepts are deliberately absent, because their value names
    /// something the local machine then runs or loads:
    ///
    ///   * -F, an alternative config file. Every option lives in there,
    ///     ProxyCommand and LocalCommand included, so carrying it is carrying
    ///     whatever that file says. Verified: a -F whose file sets a
    ///     ProxyCommand runs it, under the user's account, on the connection
    ///     Zharp opens by itself.
    ///   * -I, a PKCS#11 provider, which is a shared library ssh dlopens.
    ///
    /// -o is carried, but only for the keywords in `carriableOptions`. The rest
    /// of what is here is safe by construction: every value is consumed by ssh
    /// as the argument of the flag in front of it, so it can never be read as
    /// an option, and none of them names a program.
    private static let keepValue = Set("BbciJlmop")

    private static let keepFlag = Set("46C")

    /// The ssh_config keywords a -o may carry into Zharp's own connection.
    ///
    /// An allowlist, for the same reason `HostName.isValid` is one: the
    /// question worth being able to answer while reading this is not "did we
    /// remember to ban ProxyCommand" but "is there anything in here that runs".
    /// Nothing in this set names a program, a shared library or a file of
    /// further options, and nothing in it decides whether a host key is
    /// trusted.
    ///
    /// Absent on purpose, beyond the obvious ProxyCommand/LocalCommand/
    /// PermitLocalCommand/KnownHostsCommand/PKCS11Provider/Include: HostName,
    /// User and ProxyJump, whose values are expanded into %h, %r and a nested
    /// connection, and StrictHostKeyChecking/UserKnownHostsFile, which decide
    /// whether an unknown key stops the connection. Port and login name have
    /// their own flags here, both checked.
    ///
    /// A keyword that is not here is dropped rather than made a refusal. The
    /// user's own ssh_config still applies to Zharp's connection, so the common
    /// case keeps working; a destination that was only reachable because of the
    /// dropped option simply fails to connect, and the panel says so.
    private static let carriableOptions: Set<String> = [
        "addressfamily", "bindaddress", "bindinterface", "certificatefile",
        "ciphers", "compression", "connectionattempts", "hostkeyalgorithms",
        "identitiesonly", "identityfile", "kexalgorithms", "macs",
        "preferredauthentications", "pubkeyacceptedalgorithms",
        "pubkeyauthentication", "serveralivecountmax", "serveraliveinterval",
    ]

    /// True when a -o value may be carried. The keyword is everything before
    /// the first `=` or space, since ssh accepts both `-o Key=value` and
    /// `-o "Key value"`, and keywords are case insensitive.
    private static func isCarriableOption(_ value: String) -> Bool {
        let keyword = value.prefix { $0 != "=" && !$0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return carriableOptions.contains(keyword)
    }

    /// Flags that mean this invocation is not a login session at all: a
    /// control command, a tunnel, a subsystem, a request to background itself
    /// or to print something and exit. There is no shell at the far end to be
    /// standing in.
    private static let notASession = Set("OWwNfsGQV")

    /// The machine the command connects to, or nil when the command is not an
    /// interactive ssh to a machine that can be named.
    ///
    /// Nil for, in the order the code decides it:
    ///   * anything whose program is not `ssh`, the rest of the family
    ///     included. ssh-add and ssh-keygen never connect anywhere, and a tab
    ///     claiming to be on a machine that was never contacted is worse than
    ///     one that says nothing. A wrapper (sudo, env, time) is not unwrapped
    ///     either: its own arguments have not been parsed, so its ssh has not
    ///     been either.
    ///   * `ssh` on its own, with nothing to connect to.
    ///   * -O, -W, -w, -N, -f, -s, -G, -Q, -V: not a session.
    ///   * a value taking flag at the end of the line with no value after it.
    ///     Malformed, and not ours to guess at.
    ///   * no bare word anywhere, so no destination.
    ///   * a destination that is not a destination. See `decompose`, which is
    ///     where the argument injection rules live.
    ///   * a -J chain or a -l user that is not one either, checked for the
    ///     same reasons and refused rather than dropped: quietly dropping a
    ///     jump host would send the second connection straight at a machine
    ///     the user only ever reached through a bastion.
    ///   * a -p that is not a port number. ssh expands the port into a
    ///     ProxyCommand as %p and a ProxyCommand runs through /bin/sh, so this
    ///     is the same rule as the destination's, in the one other place a
    ///     value of the user's reaches a shell.
    ///
    /// Everything else that ssh accepts is either carried over or consumed and
    /// dropped. Dropped on purpose: -D, -E, -e, -L, -R and -S set up a tunnel,
    /// a log file, a control socket or an escape character, and opening those
    /// a second time either fails outright or, worse, succeeds and quietly
    /// duplicates the port forwards the user is relying on. -F and -I are
    /// dropped because their values name a file of further options and a
    /// shared library, and a -o outside `carriableOptions` because that is
    /// where ProxyCommand and LocalCommand live: see `keepValue`. The command
    /// after the destination is dropped too. We want the host, not the errand.
    public static func parse(_ commandLine: String) -> RemoteHost? {
        let tokens = split(commandLine)
        guard tokens.count >= 2, isSshProgram(tokens[0]) else { return nil }

        var keep: [String] = []
        var destination: String?
        var identityFile: String?
        var jumpHost: String?
        var portFlag: String?
        var loginUser: String?

        var i = 1
        while i < tokens.count {
            let token = tokens[i]

            if token == "--" {
                if i + 1 < tokens.count { destination = tokens[i + 1] }
                break
            }

            if token.count > 1, token.hasPrefix("-") {
                let chars = Array(token)
                var c = 1
                while c < chars.count {
                    let flag = chars[c]

                    if notASession.contains(flag) { return nil }

                    if !takesValue.contains(flag) {
                        // Short flags cluster: -46C is three of them, and only
                        // the last in a cluster can be the one taking a value.
                        if keepFlag.contains(flag) { keep.append("-\(flag)") }
                        c += 1
                        continue
                    }

                    // The value is either glued on (-p2222) or the next token.
                    let value: String?
                    if c + 1 < chars.count {
                        value = String(chars[(c + 1)...])
                        c = chars.count
                    } else {
                        i += 1
                        value = i < tokens.count ? tokens[i] : nil
                        c += 1
                    }

                    guard let value else { return nil }

                    // Checked BEFORE the value is carried, so a flag whose
                    // value is refused never reaches the argv.
                    var carry = keepValue.contains(flag)
                    switch flag {
                    case "i": identityFile = value
                    case "J":
                        guard isJumpChain(value) else { return nil }
                        jumpHost = value
                    case "p":
                        // Not "left to ssh to reject" any more. The port is one
                        // of the values ssh expands into a ProxyCommand, as %p,
                        // and a ProxyCommand runs through a shell. A -p that is
                        // not a number is a command ssh will refuse anyway, so
                        // refusing it here costs a session that was never going
                        // to open.
                        guard portNumber(value) != nil else { return nil }
                        portFlag = value
                    case "l":
                        guard isUserName(value) else { return nil }
                        loginUser = value
                    case "o":
                        // Everything that turns an ssh command line into a
                        // local command line lives behind -o.
                        carry = isCarriableOption(value)
                    default: break
                    }

                    if carry {
                        keep.append("-\(flag)")
                        keep.append(value)
                    }
                }
                i += 1
                continue
            }

            // The first bare word is the destination. Anything after it is a
            // command to run there, which is none of our business: we still
            // want the host, because the user is still going there.
            destination = token
            break
        }

        guard let destination, let target = decompose(destination) else { return nil }

        keep.append(destination)
        let invocation = SshInvocation(
            arguments: keep,
            destination: destination,
            user: target.user ?? loginUser,
            host: target.host,
            // -p wins over a port in the destination, the way it does for ssh
            // itself. A value that is not a number is left to ssh to reject.
            port: portFlag.flatMap(portNumber) ?? target.port,
            identityFile: identityFile,
            jumpHost: jumpHost)
        return RemoteHost(label: target.host, invocation: invocation)
    }

    // ------------------------------------------------------------ the parts

    /// True for `ssh` and for a path ending in it, and false for the rest of
    /// the family. Only the last segment is compared, and only against that
    /// one word: scp, sftp, ssh-copy-id and mosh all get here eventually and
    /// none of them leaves the user in a shell this can read git through.
    private static func isSshProgram(_ token: String) -> Bool {
        let name = token.split(separator: "/").last.map(String.init) ?? token
        return name.lowercased() == "ssh"
    }

    /// The pieces of an ssh destination, or nil when the token is not one.
    ///
    /// This is the gate. Whatever comes out of here goes onto an ssh command
    /// line, so a token that is not shaped like a destination is refused here
    /// rather than passed along to be someone else's problem:
    ///
    ///   * a leading dash. That is an option, not a machine. It can only be
    ///     reached through `ssh -- -x`, and Zharp does not carry the -- into
    ///     its own argv, so an option would land where a hostname belongs.
    ///   * whitespace or a control character anywhere in the token. No machine
    ///     is named that, and the name is also about to be drawn in a header.
    ///   * a host half that is not a host name (`HostName.isValid`), which is
    ///     an allowlist of letters, digits, dot, dash and underscore, plus the
    ///     IPv6 literal forms. Everything a shell would act on is outside it.
    ///     The destination is one argv element and cannot be split into two,
    ///     but it does not stop there: ssh expands %h and %r into a
    ///     ProxyCommand, and a ProxyCommand runs through /bin/sh.
    ///   * a user half that is not a user name, for the %r half of that.
    ///   * an empty host, which is what `ssh me@` amounts to.
    ///
    /// A refusal means the session stays local, and that is the honest answer:
    /// a string that is not a machine name is not a machine the user arrived
    /// at, because ssh will not resolve it either. What it costs is an ssh
    /// config alias spelled with characters no hostname has, which joins mosh
    /// and container exec on the list of ways to be somewhere Zharp cannot
    /// follow.
    private static func decompose(_ token: String) -> (user: String?, host: String, port: Int?)? {
        guard !token.isEmpty, !token.hasPrefix("-") else { return nil }
        guard token.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }

        var text = Substring(token)
        if let scheme = text.range(of: "ssh://", options: [.anchored, .caseInsensitive]) {
            text = text[scheme.upperBound...]
            // Only a URL may carry a path. Elsewhere a slash is not something
            // a hostname contains, and the host check refuses it.
            if let slash = text.firstIndex(of: "/") { text = text[..<slash] }
        }

        var user: String?
        if let at = text.lastIndex(of: "@") {
            let name = String(text[..<at])
            guard isUserName(name) else { return nil }
            user = name
            text = text[text.index(after: at)...]
        }

        let (host, port) = splitPort(String(text))
        guard HostName.isValid(host) else { return nil }
        return (user, host, port)
    }

    /// Separates a trailing :port from a host, without mistaking an IPv6
    /// literal's own colons for one. A bracketed literal keeps its brackets
    /// off the host: they are URL syntax, not part of the name.
    private static func splitPort(_ text: String) -> (host: String, port: Int?) {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let inner = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let port = portNumber(String(rest.dropFirst())) {
                return (inner, port)
            }
            return (rest.isEmpty ? inner : text, nil)
        }

        guard let colon = text.lastIndex(of: ":") else { return (text, nil) }
        let head = String(text[..<colon])
        // More than one colon means an unbracketed IPv6 literal, where the
        // last group is not a port however much it looks like one.
        guard !head.contains(":"), let port = portNumber(String(text[text.index(after: colon)...]))
        else {
            return (text, nil)
        }
        return (head, port)
    }

    /// A ProxyJump value: one or more destinations, comma separated.
    private static func isJumpChain(_ value: String) -> Bool {
        let hops = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !hops.isEmpty else { return false }
        return hops.allSatisfy { decompose(String($0)) != nil }
    }

    /// What may be a login name. Wider than a hostname, because @ and + are
    /// both real conventions (an Azure style user@domain@host, a user+route@
    /// on a proxying bastion) and neither means anything to a shell.
    private static func isUserName(_ user: String) -> Bool {
        guard !user.isEmpty, user.count <= 64, !user.hasPrefix("-") else { return false }
        return user.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
                || $0 == "+" || $0 == "@"
        }
    }

    private static func portNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let port = Int(text), port > 0, port <= 65535 else { return nil }
        return port
    }

    private static let forbidden =
        CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// Splits a typed command into arguments the way the shell that ran it
    /// did: quotes hold a word together, and outside quotes a backslash
    /// escapes the next character.
    ///
    /// The escape half is not decoration. `ssh -i ~/my\ keys/id srv1` is what a
    /// POSIX user types and what tab completion writes, and splitting it on
    /// whitespace would connect with the wrong identity and then read
    /// `keys/id` as the machine.
    ///
    /// Inside quotes a backslash stays a literal character, which is POSIX for
    /// single quotes and a simplification for double ones. The direction is
    /// deliberate: a path is preserved as typed rather than having a character
    /// invented out of it.
    public static func split(_ commandLine: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        // A token that was written as an empty quoted string still exists.
        var any = false

        for ch in commandLine {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }

            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
                continue
            }

            if ch == "\\" {
                escaped = true
                any = true
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                any = true
                continue
            }

            if ch.isWhitespace {
                if !current.isEmpty || any { tokens.append(current) }
                current = ""
                any = false
                continue
            }

            current.append(ch)
        }

        // A trailing lone backslash is a line continuation with nothing after
        // it, so there is nothing it could be escaping.
        if !current.isEmpty || any { tokens.append(current) }
        return tokens
    }
}

// -------------------------------------------------------------- PromptTitle

/// Reads the window title a remote shell sets, which on a great many machines
/// is the only thing that says where the user is standing.
///
/// Debian and Ubuntu ship a .bashrc that puts `\u@\h: \w` in the title of any
/// xterm-like terminal, and zsh's default does the same, which covers most of
/// the servers people ssh into without anyone having configured anything.
///
/// It is a fallback and never a promotion. A title is a string any program can
/// set to anything, so this is only consulted once the session is known to be
/// elsewhere, and the host it returns is there so the shape can be checked at
/// all. The caller reads the path and throws the name away: nothing builds a
/// machine out of a window title.
public enum PromptTitle {

    /// The host and directory a title claims, or nil when it is not one of
    /// those. The path has to be absolute or start at a home directory: a
    /// title reading "make: *** [all] Error 1" is not a location.
    public static func parse(_ title: String?) -> (host: String, path: String)? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let colon = title.firstIndex(of: ":"), colon != title.startIndex else { return nil }

        let left = title[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let right = title[title.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard right.hasPrefix("/") || right.hasPrefix("~") else { return nil }

        // "user@host" or a bare hostname. Anything with a space in it is a
        // sentence, not a machine.
        let host = left.lastIndex(of: "@").map { String(left[left.index(after: $0)...]) } ?? left
        guard HostName.isValid(host) else { return nil }

        return (host, right)
    }
}

// --------------------------------------------------------------- ShellWords

/// Quoting for the far end's shell.
public enum ShellWords {

    /// Wraps a value so a POSIX shell passes it through untouched. Single
    /// quotes protect everything except a single quote, which is closed,
    /// escaped and reopened.
    ///
    /// Paths from a remote machine are attacker adjacent in the sense that
    /// matters here: they come out of a directory listing on another computer,
    /// and a filename is allowed to contain $, ; and a newline.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''", options: .literal) + "'"
    }
}
