# Zharp shell integration for PowerShell - CANONICAL COPY.
#
# What it does: saves the existing `prompt` function, then replaces it with a
# wrapper that emits OSC 133;A (prompt start) and a working directory report,
# calls the original prompt, and appends OSC 133;B (input starts here).
#
# How the app uses it: this is passed whole as the argument to `-Command`.
# That is why the body is a single line with no double quotes in it: the call
# site wraps it in double quotes, and ESC and BEL are built in PowerShell with
# ([char]27) and ([char]7) so it still runs on Windows PowerShell 5.1.
#
# KNOWN PLATFORM VARIANT: Windows emits the working directory as OSC 9;9
# instead of OSC 7. It is the same script otherwise, byte for byte. The drift
# check knows about this one substitution ("]7;file://" becomes "]9;9;") and
# checks the Windows copy through it, so any OTHER difference still fails.
# Both emulators already parse both sequences, so this split is historical.
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
$global:__zharpPrompt = $function:prompt; function global:prompt { [Console]::Write(([char]27)+']133;A'+([char]7)+([char]27)+']7;file://'+$PWD.Path+([char]7)); (( & $global:__zharpPrompt ) -join '') + ([char]27)+']133;B'+([char]7) }
