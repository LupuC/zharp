// Reports one Codex lifecycle event to the Zharp terminal.
//
// Codex runs this from its hooks and hands it the event JSON on stdin. Unlike
// Claude Code there is no way to answer with a terminal escape sequence, and a
// hook process has no controlling terminal of its own to write to, so the
// report is dropped in a directory that Zharp watches instead. It carries the
// session key Zharp put in the environment, which is what lets two Codex
// sessions in the same repository land on their own tabs.
//
// Node rather than PowerShell because Codex ships as an npm package, so node is
// always present where Codex is, and it starts in about a third of the time.
//
// The wire format is documented in docs/agent-protocol.md.
//
// Usage (from hooks.json):
//   node <path>/zharp-agent-codex.js <kind>

'use strict';

const fs = require('fs');
const path = require('path');

const kind = process.argv[2] || '';
const session = process.env.ZHARP_SESSION;
const spool = process.env.ZHARP_SPOOL;

// Anywhere but a Zharp session this does nothing at all, so the hook is safe to
// leave in a config that other terminals also read.
if (!process.env.ZHARP_AGENT_PROTOCOL || !session || !spool) process.exit(0);

// Codex treats anything a hook prints on stdout as extra context for the model,
// so this writes nothing there, ever. Not even on failure.
let stdin = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { stdin += chunk; });
process.stdin.on('end', () => { try { report(); } catch { /* never the reason a turn fails */ } });
process.stdin.on('error', () => process.exit(0));

function short(text, max) {
  if (!text) return '';
  const line = String(text).split(/\r?\n/)[0].trim();
  return line.length > max ? line.slice(0, max - 1) + '…' : line;
}

// mcp__<server>__<tool> is addressing, not a name.
function label(tool) {
  if (!tool) return '';
  const parts = tool.split('__');
  return tool.startsWith('mcp__') && parts.length >= 3
    ? parts[1] + ' ' + parts.slice(2).join(' ')
    : tool;
}

// Codex edits files through apply_patch, whose payload is a patch rather than a
// filename, so the path has to be read out of the patch body.
//
// Only ever a WRITE. The changes panel follows this, and a panel that jumped
// every time the agent read or searched something would be unusable, so a
// path is never taken from a tool that merely names a file it looked at.
function editedFile(tool, input) {
  if (!input || typeof input !== 'object') return null;

  for (const value of Object.values(input)) {
    if (typeof value !== 'string' || value.indexOf('*** ') < 0) continue;
    const found = value.match(/^\*\*\* (?:Update|Add|Delete) File: (.+)$/m);
    if (found) return found[1].trim();
  }

  // No patch body to read, so only a tool that is known to write may name one.
  if (tool !== 'apply_patch') return null;
  if (typeof input.file_path === 'string') return input.file_path;
  if (typeof input.path === 'string') return input.path;
  return null;
}

function report() {
  const hook = stdin ? JSON.parse(stdin) : {};
  const tool = typeof hook.tool_name === 'string' ? hook.tool_name : '';
  const input = hook.tool_input;
  const shown = label(tool);

  let summary = '';
  let file = null;

  // What the tool is acting on, in whichever argument carries it.
  let target = '';
  if (input && typeof input === 'object') {
    if (typeof input.command === 'string') target = short(input.command, 48);
    else if (typeof input.path === 'string') target = path.basename(input.path);
    else if (typeof input.file_path === 'string') target = path.basename(input.file_path);
  }

  switch (kind) {
    case 'start': summary = 'Ready'; break;
    case 'prompt': summary = 'Working'; break;
    case 'done': summary = 'Done'; break;
    case 'end': summary = ''; break;

    case 'permission':
      summary =
        tool === 'apply_patch' ? 'Wants to edit files'
        : tool === 'Bash' || tool === 'shell'
          ? (target ? 'Wants to run ' + target : 'Wants to run a command')
        : shown ? 'Wants to use ' + shown
        : 'Needs your go-ahead';
      break;

    case 'tool': {
      file = editedFile(tool, input);

      // Only a write earns its own line. Codex has no once-per-batch event, so
      // this fires for every tool call, and naming each one turned the tab into
      // a scrolling log of shell commands - a whole cmd.exe line, arguments and
      // all, where the useful answer was "working". Writes are different: the
      // file is what the changes panel is about to show you.
      summary = file ? shown + ' ' + path.basename(file) : 'Working';
      break;
    }

    default: summary = '';
  }

  const payload = {
    v: 1,
    agent: 'codex',
    event: kind,
    session: session,
    summary: short(summary, 100),
  };
  if (tool) payload.tool = tool;
  if (file) payload.path = path.resolve(hook.cwd || process.cwd(), file);

  // Written under a name the watcher ignores, then renamed into place, because
  // a rename is atomic: the watcher can never pick up a half written report.
  // The temp file lives in the spool rather than the system temp directory so
  // the rename is always within one filesystem, which is what makes it atomic.
  const name = process.pid + '-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
  const temp = path.join(spool, name + '.tmp');
  fs.writeFileSync(temp, JSON.stringify(payload));
  fs.renameSync(temp, path.join(spool, name + '.json'));
}
