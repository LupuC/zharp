# Reports one Claude Code lifecycle event to the Zharp terminal.
#
# Claude Code runs this from its hooks and hands it the event JSON on stdin. It
# answers with {"terminalSequence": "..."}, which Claude Code writes to the
# terminal for us. That indirection is the point: a hook process has no
# controlling terminal of its own to write to. macOS does have a /dev/tty, but
# a hook inherits the agent's, which is not necessarily the tab Zharp is
# showing, and an agent running over ssh or inside a multiplexer has none worth
# borrowing. The field works everywhere, so there is no second path.
#
# The Windows build ships this as PowerShell. A stock Mac has no PowerShell, so
# this is /bin/sh plus two binaries every macOS install carries: plutil parses
# the JSON on the way in, awk builds the report on the way out. node was the
# obvious alternative and was turned down: Claude Code ships as a native binary
# now, so having Claude Code no longer implies having node the way having Codex
# does, and a hook that quietly does nothing on a machine without node is worse
# than a longer script.
#
# The wire format is documented in docs/agent-protocol.md.
#
# Usage (from settings.json):
#   /bin/sh <path>/zharp-agent-claude.sh <kind>

# Zharp announces the protocol it speaks in the environment of every shell it
# starts. Anywhere else this exits immediately and prints nothing, so the hook
# is safe to leave in a config that other terminals also read.
[ -n "${ZHARP_AGENT_PROTOCOL:-}" ] || exit 0

kind=$1

# Bytes, not characters, for everything below. awk's length() and substr()
# follow the locale, and a hook inherits whatever locale the agent happened to
# start with, so leaving this alone would mean clipping at 100 characters on
# one machine and 100 bytes on the next. Pinned, the arithmetic is the same
# everywhere and the clip is made UTF-8 aware by hand instead, which is the
# part that actually matters: half a UTF-8 sequence inside an OSC string is a
# corrupt string.
LC_ALL=C
export LC_ALL

# Full paths for both tools. A hook inherits the agent's PATH and there is no
# reason to depend on what somebody put in it.
#
# Captured rather than piped straight into awk, because plutil prints its parse
# errors on stdout rather than stderr: piped, a malformed body would arrive at
# the parser looking like input. On failure the report still goes out, saying
# whatever the event kind alone can say.
xml=$(/usr/bin/plutil -convert xml1 -o - -- - 2>/dev/null) || xml=""

# One awk pass does the rest: read the plist, pick the summary, escape it, emit
# the sequence. Three processes for the whole hook (sh, plutil, awk) against
# the single PowerShell host Windows pays for, and a PowerShell host is the
# slower of the two on its own.
printf '%s\n' "$xml" | /usr/bin/awk -v kind="$kind" '
function ord(c) { return ORD[c] }

# Undo the entities plutil escapes inside a <string>. The ampersand goes last,
# so that a literal &amp;lt; in a command line comes back as &lt; rather than
# as a less-than sign.
function unxml(s) {
    gsub(/&lt;/, "<", s)
    gsub(/&gt;/, ">", s)
    gsub(/&quot;/, "\"", s)
    gsub(/&apos;/, sprintf("%c", 39), s)
    gsub(/&amp;/, "\\&", s)
    return s
}

# Control bytes become spaces rather than escapes. Zharp drops everything below
# 0x20 out of an OSC string anyway, so a tab that survived encoding would only
# arrive having run two words together.
function clean(s) {
    gsub(/[[:cntrl:]]/, " ", s)
    return s
}

function trim(s) {
    gsub(/^ +/, "", s)
    gsub(/ +$/, "", s)
    return s
}

# Give back a byte-clipped string with any half written UTF-8 sequence at the
# end removed.
function whole(s,   n, i, k, lead) {
    n = length(s)
    i = n
    k = 0
    while (i > 0 && ord(substr(s, i, 1)) >= 128 && ord(substr(s, i, 1)) < 192) {
        i--
        k++
    }
    if (i == 0) return ""
    lead = ord(substr(s, i, 1))
    if (lead < 192) return s
    if (lead < 224) return k == 1 ? s : substr(s, 1, i - 1)
    if (lead < 240) return k == 2 ? s : substr(s, 1, i - 1)
    return k == 3 ? s : substr(s, 1, i - 1)
}

# First line only, clipped: a status line has one line of room and a Bash
# command can be a paragraph. The parser above has already reduced a multi-line
# value to its first line, so trimming is all that is left.
function short(text, max,   line) {
    if (text == "") return ""
    line = trim(text)
    if (length(line) > max) return whole(substr(line, 1, max - 1)) ELLIPSIS
    return line
}

function base(p,   leaf) {
    sub(/\/+$/, "", p)
    leaf = p
    sub(/^.*\//, "", leaf)
    return leaf == "" ? p : leaf
}

# Escapes a value for a JSON string. Two characters need it and no more,
# because clean() has already taken every control byte out. Backslashes first:
# doing the quotes first would double the backslash this adds in front of them.
function esc(s) {
    gsub(/\\/, "&&", s)
    gsub(/"/, "\\\\&", s)
    return s
}

BEGIN {
    for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
    # U+2026, spelled out in bytes because LC_ALL=C means the characters in
    # this file are bytes too.
    ELLIPSIS = sprintf("%c%c%c", 226, 128, 166)
}

# The remainder of a string that ran over more than one line. Keeping the first
# line and dropping the rest is what short() would have done with it anyway.
spilling { if ($0 ~ /<\/string>/) spilling = 0; next }

# Nesting is tracked rather than assumed, so that an array of edits or a nested
# object inside tool_input cannot be mistaken for the fields being looked for.
# Reading tags line by line is safe here: plutil escapes every angle bracket
# that came from the data, so a tag in a string value cannot be seen as one.
/<dict>|<array>/ { depth++; next }
/<\/dict>|<\/array>/ { depth--; next }

/<key>/ {
    line = $0
    sub(/^[^<]*<key>/, "", line)
    sub(/<\/key>.*$/, "", line)
    key[depth] = unxml(line)
    next
}

/<string>/ {
    line = $0
    sub(/^[^<]*<string>/, "", line)
    if (line ~ /<\/string>/) sub(/<\/string>.*$/, "", line)
    else spilling = 1
    value = clean(unxml(line))

    if (depth == 1) top[key[1]] = value
    else if (depth == 2 && key[1] == "tool_input") input[key[2]] = value
    next
}

END {
    tool = top["tool_name"]

    # MCP tools arrive as mcp__<server>__<tool>, which is addressing, not a
    # name. "todoist add-tasks" is the same information without the plumbing.
    label = tool
    if (tool ~ /^mcp__/) {
        rest = substr(tool, 6)
        cut = index(rest, "__")
        if (cut > 0) label = substr(rest, 1, cut - 1) " " substr(rest, cut + 2)
    }

    # What the tool is acting on, in the words of whichever argument carries it.
    target = ""
    if (input["file_path"] != "") target = base(input["file_path"])
    else if (input["command"] != "") target = short(input["command"], 48)
    else if (input["pattern"] != "") target = short(input["pattern"], 48)
    else if (input["url"] != "") target = short(input["url"], 48)
    else if (input["notebook_path"] != "") target = base(input["notebook_path"])

    summary = ""
    path = ""

    if (kind == "start") summary = "Ready"
    else if (kind == "prompt") summary = "Working"
    else if (kind == "done") summary = "Done"
    else if (kind == "end") summary = ""

    # A batch of tool calls finished, so the agent is running again. Used only
    # to clear a stale "waiting for you": there is no event for a permission
    # having been answered, and without this the tab went on claiming to be
    # blocked for the rest of the turn. The body is deliberately ignored, so
    # this does not depend on the shape of tool_calls.
    else if (kind == "working") summary = "Working"

    else if (kind == "idle") {
        summary = short(top["message"], 100)
        if (summary == "") summary = "Waiting for you"
    }

    else if (kind == "error") {
        why = short(top["error_message"], 80)
        if (why == "") why = top["error_type"]
        summary = why == "" ? "Stopped" : "Stopped: " why
    }

    # Plain English, not tool names. "AskUserQuestion" is the agent vocabulary
    # and means nothing to somebody glancing at a tab.
    else if (kind == "permission") {
        if (tool == "AskUserQuestion") summary = "Has a question for you"
        else if (tool == "ExitPlanMode") summary = "Wants you to approve a plan"
        else if (tool == "Task") summary = "Wants to start a subagent"
        else if (tool == "Bash") summary = target != "" ? "Wants to run " target : "Wants to run a command"
        else if (tool == "Edit") summary = target != "" ? "Wants to edit " target : "Wants to edit a file"
        else if (tool == "NotebookEdit") summary = target != "" ? "Wants to edit " target : "Wants to edit a notebook"
        else if (tool == "Write") summary = target != "" ? "Wants to write " target : "Wants to write a file"
        else if (tool == "WebFetch") summary = target != "" ? "Wants to fetch " target : "Wants to fetch a page"
        else summary = tool != "" ? "Wants to use " label : "Needs your go-ahead"
    }

    else if (kind == "tool") {
        summary = target != "" ? label " " target : label

        # Only the tools that WRITE hand back a path. The changes panel follows
        # this, and a panel that jumped every time the agent read or grepped
        # something would be unusable.
        if (tool == "Edit" || tool == "Write" || tool == "NotebookEdit") {
            path = input["file_path"]
            if (path == "") path = input["notebook_path"]
        }
    }

    body = "{\"v\":1,\"agent\":\"claude\",\"event\":\"" esc(kind) "\""
    body = body ",\"summary\":\"" esc(short(summary, 100)) "\""
    if (tool != "") body = body ",\"tool\":\"" esc(tool) "\""
    tail = path != "" ? ",\"path\":\"" esc(path) "\"}" : "}"

    # The sequence travels inside a 4096-byte OSC string. A path long enough to
    # threaten that is a path the panel can find on its own.
    if (length(body tail) > 3000) tail = "}"

    # ESC and BEL are spelled as \u escapes because that is what they have to
    # be inside a JSON string, and they are the only two control bytes left:
    # esc() has taken care of the quotes and backslashes the body carries.
    printf "{\"terminalSequence\":\"\\u001b]777;notify;zharp://agent;%s\\u0007\"}\n", esc(body tail)
}
'

# Deliberately silent about its own failures. Claude Code surfaces anything on
# stderr to the user, and a broken status line is not worth interrupting them
# for.
exit 0
