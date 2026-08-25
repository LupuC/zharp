# Reports one Claude Code lifecycle event to the Zharp terminal.
#
# Claude Code runs this from its hooks and hands it the event JSON on stdin.
# It answers with {"terminalSequence": "..."}, which Claude Code writes to the
# terminal for us. That indirection is the point: a hook has no controlling
# terminal of its own to write to, and Windows has no /dev/tty to borrow.
#
# The wire format is documented in docs/agent-protocol.md.
#
# Usage (from hooks.json):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File zharp-agent.ps1 <kind>

param([Parameter(Position = 0)][string] $Kind)

# Zharp announces the protocol it speaks in the environment of every shell it
# starts. Anywhere else this exits immediately and prints nothing, so the hook
# is safe to leave in a config that other terminals also read.
if (-not $env:ZHARP_AGENT_PROTOCOL) { exit 0 }

# Nothing below is worth failing a turn over. Any surprise, and this hook goes
# quiet rather than putting an error notice in front of the user.
try {
    $raw = [Console]::In.ReadToEnd()
    $hook = if ($raw) { $raw | ConvertFrom-Json } else { $null }

    # First line only, clipped: a status line has one line's worth of room and
    # a Bash command can be a paragraph.
    function Short([string] $text, [int] $max) {
        if (-not $text) { return '' }
        $line = ($text -split "`r?`n")[0].Trim()
        if ($line.Length -gt $max) { return $line.Substring(0, $max - 1) + [char]0x2026 }
        return $line
    }

    $tool = [string] $hook.tool_name
    $toolInput = $hook.tool_input

    # MCP tools arrive as mcp__<server>__<tool>, which is addressing, not a
    # name. "todoist add-tasks" is the same information without the plumbing.
    $toolLabel = $tool
    if ($tool -like 'mcp__*') {
        $parts = $tool -split '__', 3
        if ($parts.Count -ge 3) { $toolLabel = "$($parts[1]) $($parts[2])" }
    }
    $path = $null
    $summary = ''

    # What the tool is acting on, in the words of whichever argument carries it.
    $target = ''
    if ($toolInput) {
        if ($toolInput.file_path)      { $target = Split-Path -Leaf $toolInput.file_path }
        elseif ($toolInput.command)    { $target = Short $toolInput.command 48 }
        elseif ($toolInput.pattern)    { $target = Short $toolInput.pattern 48 }
        elseif ($toolInput.url)        { $target = Short $toolInput.url 48 }
        elseif ($toolInput.notebook_path) { $target = Split-Path -Leaf $toolInput.notebook_path }
    }

    switch ($Kind) {
        'start'  { $summary = 'Ready' }
        'prompt' { $summary = 'Working' }
        'done'   { $summary = 'Done' }
        'end'    { $summary = '' }

        'idle' {
            $summary = Short ([string] $hook.message) 100
            if (-not $summary) { $summary = 'Waiting for you' }
        }

        'error' {
            $why = Short ([string] $hook.error_message) 80
            if (-not $why) { $why = [string] $hook.error_type }
            $summary = if ($why) { "Stopped: $why" } else { 'Stopped' }
        }

        # A batch of tool calls finished, so the agent is running again. Used
        # only to clear a stale "waiting for you": there is no event for a
        # permission having been answered, and without this the tab kept
        # claiming to be blocked for the rest of the turn. The body is
        # deliberately ignored, so this does not depend on the shape of
        # tool_calls.
        'working' { $summary = 'Working' }

        'permission' {
            # Plain English, not tool names. "AskUserQuestion" is Claude's
            # vocabulary and means nothing to somebody glancing at a tab.
            $summary = switch ($tool) {
                'AskUserQuestion' { 'Has a question for you' }
                'ExitPlanMode'    { 'Wants you to approve a plan' }
                'Task'            { 'Wants to start a subagent' }
                'Bash'            { if ($target) { "Wants to run $target" }   else { 'Wants to run a command' } }
                'Edit'            { if ($target) { "Wants to edit $target" }  else { 'Wants to edit a file' } }
                'NotebookEdit'    { if ($target) { "Wants to edit $target" }  else { 'Wants to edit a notebook' } }
                'Write'           { if ($target) { "Wants to write $target" } else { 'Wants to write a file' } }
                'WebFetch'        { if ($target) { "Wants to fetch $target" } else { 'Wants to fetch a page' } }
                default           { if ($tool)   { "Wants to use $toolLabel" } else { 'Needs your go-ahead' } }
            }
        }

        'tool' {
            $summary = if ($target) { "$toolLabel $target" } else { $toolLabel }

            # Only the tools that WRITE hand back a path. The changes panel
            # follows this, and a panel that jumped every time the agent read
            # or grepped something would be unusable.
            if ($tool -in @('Edit', 'Write', 'NotebookEdit')) {
                $path = [string] $toolInput.file_path
                if (-not $path) { $path = [string] $toolInput.notebook_path }
            }
        }

        default { $summary = '' }
    }

    $payload = [ordered] @{
        v       = 1
        agent   = 'claude'
        event   = $Kind
        summary = Short $summary 100
    }
    if ($tool) { $payload['tool'] = $tool }
    if ($path) { $payload['path'] = $path }

    $body = $payload | ConvertTo-Json -Compress -Depth 3

    # The sequence travels inside a 4096-byte OSC string. A path long enough to
    # threaten that is a path the panel can find on its own.
    if ($body.Length -gt 3000 -and $payload.Contains('path')) {
        $payload.Remove('path')
        $body = $payload | ConvertTo-Json -Compress -Depth 3
    }

    $sequence = "$([char]27)]777;notify;zharp://agent;$body$([char]7)"
    [pscustomobject] @{ terminalSequence = $sequence } | ConvertTo-Json -Compress
}
catch {
    # Deliberately silent. Claude Code surfaces anything on stderr to the user,
    # and a broken status line is not worth interrupting them for.
}

exit 0
