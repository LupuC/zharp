// Reports OpenCode's state to the Zharp terminal.
//
// OpenCode loads plugins into its own process, so unlike Codex there is no
// shell and no process to spawn: a hook here is a function call. That is why
// this subscribes to rather more than the Codex integration dares to, and why
// it can afford to say which file was just written.
//
// Reports are dropped in a directory Zharp watches, carrying the session key
// Zharp put in the environment. Writing terminal escape sequences to stdout
// from inside a running TUI would fight with its own renderer.
//
// The wire format is documented in docs/agent-protocol.md.

import { writeFileSync, renameSync } from "node:fs"
import { join, basename, isAbsolute, resolve } from "node:path"

export const ZharpStatus = async ({ directory }) => {
  const session = process.env.ZHARP_SESSION
  const spool = process.env.ZHARP_SPOOL

  // Outside a Zharp session this plugin does nothing at all, so it is safe to
  // leave installed for whatever terminal the user opens next.
  if (!process.env.ZHARP_AGENT_PROTOCOL || !session || !spool) return {}

  const clip = (text, max) => {
    if (!text) return ""
    const line = String(text).split(/\r?\n/)[0].trim()
    return line.length > max ? line.slice(0, max - 1) + "…" : line
  }

  let counter = 0
  const report = (event, summary, path) => {
    try {
      const payload = { v: 1, agent: "opencode", event, session, summary: clip(summary, 100) }
      if (path) payload.path = isAbsolute(path) ? path : resolve(directory ?? process.cwd(), path)

      // Written under a name the watcher ignores, then renamed into place: a
      // rename within one directory is atomic, so a half written report can
      // never be picked up.
      const name = `${process.pid}-${counter++}-${Math.random().toString(36).slice(2, 8)}`
      const temp = join(spool, name + ".tmp")
      writeFileSync(temp, JSON.stringify(payload))
      renameSync(temp, join(spool, name + ".json"))
    } catch {
      // Never the reason a turn fails.
    }
  }

  return {
    // A prompt was submitted, so the turn has started.
    "chat.message": async () => report("prompt", "Working"),

    // Blocked, and OpenCode has already written the sentence a human would:
    // Permission.title is what its own dialog shows.
    "permission.ask": async (permission) =>
      report("permission", permission?.title || "Needs your go-ahead"),

    event: async ({ event }) => {
      const type = event?.type
      const props = event?.properties ?? {}

      if (type === "permission.replied") {
        // You answered it. OpenCode is the only one of the three agents that
        // says so; the others have to be inferred from you typing.
        report("working", "Working")
      } else if (type === "session.idle") {
        report("done", "Done")
      } else if (type === "file.edited" && props.file) {
        // The whole reason the changes panel can follow along, handed over as
        // a path rather than a patch to be parsed.
        report("tool", `Edited ${basename(props.file)}`, props.file)
      }
    },
  }
}
