# Zharp shell integration for fish - CANONICAL COPY.
#
# What it does: registers an on-event fish_prompt hook that emits OSC 133;A
# (prompt start) and OSC 7 (working directory), then copies fish_prompt aside
# and wraps it so OSC 133;B lands after the prompt's own output.
#
# How the app uses it: this is passed whole as the argument to `fish -i -C`.
# It is never written to disk, and fish runs -C after its own config, so
# nothing of the user's setup is bypassed. That is why the body is a single
# line: it has to survive being one command line argument. Keep it one line.
#
# This file is the canonical copy. The applications do NOT read it at runtime:
# each app embeds its own generated copy of the body below, as a string literal
# in its source. Editing this file alone changes nothing that ships.
#
# If you edit the body below, you MUST update every embedded copy to match:
#   macOS:   macos/Sources/ZharpApp/ShellDiscovery.swift
# Then run scripts/check-shared-drift.sh, which fails the build when this file
# and the embedded copies disagree.
#
# Everything above the sentinel line is header and is ignored by the drift
# check. Everything below it is compared byte for byte against the embedded
# copies, after the language specific string escaping has been undone.
# zharp-canonical-body-begins-below
function __zharp_report --on-event fish_prompt; printf '\e]133;A\a'; printf '\e]7;file://%s%s\e\\' (hostname) "$PWD"; end; if not functions -q __zharp_orig_prompt; functions --copy fish_prompt __zharp_orig_prompt; function fish_prompt; __zharp_orig_prompt; printf '\e]133;B\a'; end; end
