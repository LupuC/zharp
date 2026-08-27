using System.Text;

namespace Zharp.Core.Remote;

/// <summary>
/// Reads the `ssh` command the user typed and works out which machine they are
/// about to be standing on.
///
/// Zharp knows what was typed at the prompt because it already captures it for
/// history, so no cooperation from the remote end is needed to notice that the
/// session has left this computer. That matters: the alternative signals are
/// all optional. A remote shell may report its directory, or its hostname in
/// the window title, or neither, and a terminal that can only tell it is
/// somewhere else when the far end volunteers the fact will get it wrong on
/// exactly the plain servers people ssh into most.
/// </summary>
public static class SshTarget
{
    /// <summary>
    /// ssh flags that take a separate value. Their argument must be skipped
    /// when looking for the destination, or `ssh -p 2222 host` reads 2222 as
    /// the machine.
    /// </summary>
    private const string TakesValue = "BbcDEeFIiJLlmOoPpQRSWw";

    /// <summary>
    /// Flags worth reusing on a second connection: how to reach the machine
    /// and who to be when we get there.
    /// </summary>
    private const string KeepValue = "BbcFIiJlmop";

    private const string KeepFlag = "46C";

    /// <summary>
    /// Flags that mean this invocation is not a login session at all: a
    /// control command, a tunnel, a subsystem, or a request to background
    /// itself. There is no shell at the far end to be standing in.
    /// </summary>
    private const string NotASession = "OWwNfsGQV";

    /// <summary>
    /// The machine the command connects to, or null when the command is not an
    /// interactive ssh at all.
    /// </summary>
    public static RemoteHost? Parse(string commandLine)
    {
        var tokens = Split(commandLine);
        if (tokens.Count < 2 || !IsSshProgram(tokens[0]))
            return null;

        var keep = new List<string>();
        string? destination = null;

        for (int i = 1; i < tokens.Count; i++)
        {
            string token = tokens[i];

            if (token == "--")
            {
                if (i + 1 < tokens.Count)
                    destination = tokens[i + 1];
                break;
            }

            if (token.Length > 1 && token[0] == '-')
            {
                // Short flags cluster: -46C is three of them, and only the
                // last in a cluster can be the one taking a value.
                for (int c = 1; c < token.Length; c++)
                {
                    char flag = token[c];

                    if (NotASession.IndexOf(flag) >= 0)
                        return null;

                    if (TakesValue.IndexOf(flag) < 0)
                    {
                        if (KeepFlag.IndexOf(flag) >= 0)
                            keep.Add("-" + flag);
                        continue;
                    }

                    // The value is either glued on (-p2222) or the next token.
                    string? value;
                    if (c + 1 < token.Length)
                    {
                        value = token[(c + 1)..];
                        c = token.Length;
                    }
                    else
                    {
                        value = i + 1 < tokens.Count ? tokens[++i] : null;
                    }

                    if (value == null)
                        return null; // malformed, and not ours to guess at

                    if (KeepValue.IndexOf(flag) >= 0)
                    {
                        keep.Add("-" + flag);
                        keep.Add(value);
                    }
                }
                continue;
            }

            // The first bare word is the destination. Anything after it is a
            // command to run there, which is none of our business: we still
            // want the host, because the user is still going to it.
            destination = token;
            break;
        }

        if (string.IsNullOrWhiteSpace(destination))
            return null;

        keep.Add(destination);
        return new RemoteHost(Label(destination), keep);
    }

    /// <summary>
    /// True for `ssh`, `ssh.exe` and a fully qualified path to either, and
    /// false for the rest of the family. ssh-add and ssh-keygen never connect
    /// anywhere, and treating them as a session would leave a tab claiming to
    /// be on a machine that was never contacted.
    /// </summary>
    private static bool IsSshProgram(string token)
    {
        int slash = token.LastIndexOfAny(new[] { '/', '\\' });
        string name = slash < 0 ? token : token[(slash + 1)..];
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            name = name[..^4];
        return string.Equals(name, "ssh", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// What to call the machine on screen. A destination may be a bare alias,
    /// user@host, or a full ssh:// URL; the user@ and the scheme are noise in
    /// a panel header that is already narrow.
    /// </summary>
    private static string Label(string destination)
    {
        string text = destination;
        if (text.StartsWith("ssh://", StringComparison.OrdinalIgnoreCase))
            text = text[6..];
        int at = text.LastIndexOf('@');
        if (at >= 0 && at + 1 < text.Length)
            text = text[(at + 1)..];
        int colon = text.IndexOf(':');
        if (colon > 0)
            text = text[..colon];
        int slash = text.IndexOf('/');
        if (slash > 0)
            text = text[..slash];
        return text.Length == 0 ? destination : text;
    }

    /// <summary>
    /// Splits a typed command into arguments, honouring quotes. A key path
    /// with a space in it is the usual reason this matters: -i "C:\My Keys\id"
    /// is one argument and splitting it on whitespace would silently connect
    /// with the wrong identity.
    /// </summary>
    public static IReadOnlyList<string> Split(string commandLine)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        char quote = '\0';
        bool any = false;

        foreach (char c in commandLine)
        {
            if (quote != '\0')
            {
                if (c == quote)
                    quote = '\0';
                else
                    current.Append(c);
                continue;
            }

            if (c is '"' or '\'')
            {
                quote = c;
                any = true;
                continue;
            }

            if (char.IsWhiteSpace(c))
            {
                if (current.Length > 0 || any)
                    tokens.Add(current.ToString());
                current.Clear();
                any = false;
                continue;
            }

            current.Append(c);
        }

        if (current.Length > 0 || any)
            tokens.Add(current.ToString());

        return tokens;
    }
}

/// <summary>
/// Reads the window title a remote shell sets, which on a great many machines
/// is the only thing that says where the user is standing.
///
/// Debian and Ubuntu ship a .bashrc that puts `\u@\h: \w` in the title of any
/// xterm-like terminal, and zsh's default does the same. That covers most of
/// the servers people ssh into without anyone having configured anything. It
/// is a fallback rather than the primary source: OSC 7 is unambiguous, and a
/// title is a string a program can set to whatever it likes, so this is only
/// consulted once the session is already known to be on another machine.
/// </summary>
public static class PromptTitle
{
    /// <summary>
    /// The host and directory a title claims, or nulls when it is not one of
    /// these. The path must be absolute or start at the home directory: a
    /// title saying "make: *** [all] Error 1" is not a location.
    /// </summary>
    public static (string? Host, string? Path) Parse(string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
            return (null, null);

        int colon = title.IndexOf(':');
        if (colon <= 0 || colon + 1 >= title.Length)
            return (null, null);

        string left = title[..colon].Trim();
        string right = title[(colon + 1)..].Trim();

        if (right.Length == 0 || (right[0] != '/' && right[0] != '~'))
            return (null, null);

        // "user@host" or a bare hostname. Anything with a space in it is a
        // sentence, not a machine.
        int at = left.LastIndexOf('@');
        string host = at >= 0 ? left[(at + 1)..] : left;
        if (host.Length == 0 || host.Any(c => !char.IsLetterOrDigit(c) && c is not ('.' or '-' or '_')))
            return (null, null);

        return (host, right);
    }
}

/// <summary>
/// Quoting for the far end's shell.
/// </summary>
public static class ShellWords
{
    /// <summary>
    /// Wraps a value so that a POSIX shell passes it through untouched. Single
    /// quotes protect everything except a single quote, which is closed,
    /// escaped and reopened. Paths from a remote machine are attacker-adjacent
    /// data in the sense that matters here: they come from a directory listing
    /// on another computer, and a filename is allowed to contain $, ; and a
    /// newline.
    /// </summary>
    public static string Quote(string value) =>
        "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
}
