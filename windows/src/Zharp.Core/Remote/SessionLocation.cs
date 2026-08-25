namespace Zharp.Core.Remote;

/// <summary>
/// A machine reached over ssh, together with the arguments needed to reach it
/// a second time.
///
/// <see cref="Label"/> is what the user typed after `ssh`: an alias from their
/// own config, or user@host. It is deliberately their word for the machine
/// rather than the hostname it reports, because that is what they will
/// recognise in a panel header.
///
/// <see cref="Args"/> are the flags Zharp may safely reuse. The user's -p, -i,
/// -J, -F and -o all carry over, so a host that only works through a jump box
/// or a named key keeps working. Anything that sets up a tunnel, a control
/// socket or a background process is dropped: opening those a second time
/// either fails outright or, worse, succeeds and quietly duplicates the port
/// forwards the user is relying on.
/// </summary>
public sealed class RemoteHost : IEquatable<RemoteHost>
{
    public RemoteHost(string label, IReadOnlyList<string> args)
    {
        Label = label;
        Args = args;
        // The label is part of the identity so that two machines Zharp only
        // heard about, which carry no arguments at all, stay distinct.
        Key = label + " " + string.Join(" ", args);
    }

    /// <summary>
    /// A machine that announced itself, through OSC 7 or its window title,
    /// without Zharp having seen the command that got there.
    ///
    /// It carries no arguments on purpose. The name comes from a shell on
    /// another computer, and turning a name that arrived over the wire into an
    /// outbound connection would let the far end choose where Zharp connects
    /// next. Knowing the session has left this machine is worth having on its
    /// own: it is the difference between showing nothing and showing another
    /// machine's repository as though it were this one's.
    /// </summary>
    public static RemoteHost Reported(string label) => new(label, Array.Empty<string>());

    /// <summary>False when this host was only reported, never dialled.</summary>
    public bool CanConnect => Args.Count > 0;

    /// <summary>How the user named this machine, for showing back to them.</summary>
    public string Label { get; }

    /// <summary>ssh arguments ending in the destination, with the user's own
    /// connection flags preserved.</summary>
    public IReadOnlyList<string> Args { get; }

    /// <summary>Identity for caching one connection per distinct target. Two
    /// tabs on the same host with the same flags share a channel; the same
    /// host on a different port does not, because it is a different machine as
    /// far as anything here is concerned.</summary>
    public string Key { get; }

    public bool Equals(RemoteHost? other) =>
        other != null && string.Equals(Key, other.Key, StringComparison.Ordinal);

    public override bool Equals(object? obj) => Equals(obj as RemoteHost);

    public override int GetHashCode() => Key.GetHashCode(StringComparison.Ordinal);

    public override string ToString() => Label;
}

/// <summary>
/// Where a session is standing: a directory, and the machine it is on.
///
/// Zharp used to track only the directory, which is correct exactly until the
/// user types `ssh`. From that moment the recorded path belongs to a machine
/// the shell is no longer on, and every question asked of it (is this a git
/// repository, what has changed in it) is answered by the wrong computer with
/// no sign that anything is wrong. Carrying the host alongside the path makes
/// that state impossible to represent by accident.
/// </summary>
public sealed class SessionLocation : IEquatable<SessionLocation>
{
    private SessionLocation(RemoteHost? remote, string path)
    {
        Remote = remote;
        Path = path;
    }

    /// <summary>Null when this is the machine Zharp is running on.</summary>
    public RemoteHost? Remote { get; }

    /// <summary>
    /// The directory, in the remote's own notation when remote. Empty means
    /// the session is somewhere Zharp cannot name, which is a real and common
    /// state over ssh: a remote shell need not report its directory at all.
    /// </summary>
    public string Path { get; }

    public bool IsRemote => Remote != null;

    public bool HasPath => Path.Length > 0;

    /// <summary>A directory on this machine, or null when there isn't one.</summary>
    public static SessionLocation? Local(string? path) =>
        string.IsNullOrWhiteSpace(path) ? null : new SessionLocation(null, path);

    /// <summary>
    /// A place on another machine. The path may be empty: knowing the user is
    /// on another host is worth recording even before, or without ever,
    /// learning where they are standing on it.
    /// </summary>
    public static SessionLocation On(RemoteHost remote, string? path) =>
        new(remote, path?.Trim() ?? "");

    /// <summary>The same place, on the same host, at a different directory.</summary>
    public SessionLocation WithPath(string path) => new(Remote, path);

    public bool Equals(SessionLocation? other) =>
        other != null
        && Equals(Remote, other.Remote)
        && string.Equals(Path, other.Path,
            IsRemote ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase);

    public override bool Equals(object? obj) => Equals(obj as SessionLocation);

    public override int GetHashCode() =>
        HashCode.Combine(Remote?.Key, IsRemote ? Path : Path.ToLowerInvariant());

    /// <summary>Stable text form, used as a dictionary key and in logs.</summary>
    public override string ToString() => IsRemote ? $"{Remote!.Key}\u0001{Path}" : Path;

    /// <summary>The last segment of the path, in whichever notation applies.</summary>
    public string DisplayName => IsRemote
        ? PosixPath.GetFileName(Path)
        : System.IO.Path.GetFileName(Path.TrimEnd(System.IO.Path.DirectorySeparatorChar));
}

/// <summary>
/// Path arithmetic for remote directories.
///
/// System.IO.Path answers as the machine it is running on, which is the wrong
/// machine for anything reached over ssh: it would turn /home/me/work into
/// \home\me\work and then report that C:\home\me\work does not exist. These
/// are the same few operations, done the way the far end would do them.
/// </summary>
public static class PosixPath
{
    public static string GetFileName(string path)
    {
        path = path.TrimEnd('/');
        int slash = path.LastIndexOf('/');
        return slash < 0 ? path : path[(slash + 1)..];
    }

    public static string Combine(string directory, string relative) =>
        directory.TrimEnd('/') + "/" + relative.TrimStart('/');

    /// <summary>
    /// True when <paramref name="full"/> is inside <paramref name="root"/>,
    /// with the part below it. Case sensitive, because the far end is.
    /// </summary>
    public static bool IsUnder(string root, string full, out string relative)
    {
        relative = "";
        root = root.TrimEnd('/');
        if (root.Length == 0 || !full.StartsWith(root + "/", StringComparison.Ordinal))
            return false;
        relative = full[(root.Length + 1)..];
        return relative.Length > 0;
    }

    /// <summary>
    /// Replaces a leading ~ with the home directory that was read from the far
    /// end. A shell would do this before the command ran; nothing here goes
    /// through a shell that would, and git treats ~ as a literal directory
    /// name, so it has to happen before the path is sent.
    /// </summary>
    public static string ExpandHome(string path, string? home)
    {
        if (string.IsNullOrEmpty(home) || path.Length == 0 || path[0] != '~')
            return path;
        if (path.Length == 1)
            return home;
        return path[1] == '/' ? home.TrimEnd('/') + path[1..] : path;
    }
}
