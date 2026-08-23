#!/bin/sh
# Syntax-checks the shell-integration templates that ShellDiscovery.swift
# writes at session start. They live as Swift string literals, so an editing
# slip can leave an unbalanced block behind without the Swift compiler ever
# noticing - which is exactly how a stray `fi` shipped in 0.14.0 and aborted
# every zsh session's integration.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import re, sys, textwrap, pathlib

work = pathlib.Path(sys.argv[1])
src = pathlib.Path("Sources/ZharpApp/ShellDiscovery.swift").read_text()

# Each template is `let script = """ ... """` inside its shell's factory.
pattern = re.compile(
    r'func (?P<shell>\w+)\([^)]*\)\s*->\s*ShellSpec\s*\{(?:(?!func ).)*?'
    r'let script = """\n(?P<body>.*?)\n\s*"""',
    re.S)

found = 0
for m in pattern.finditer(src):
    shell, body = m.group("shell"), textwrap.dedent(m.group("body"))
    # Undo Swift's literal escaping so the shell sees what it will be handed.
    body = body.replace('\\\\', '\\').replace('\\"', '"')
    (work / shell).write_text(body)
    print(shell)
    found += 1

if found == 0:
    sys.exit("no templates found - has ShellDiscovery.swift been restructured?")
PY

status=0
for shell in zsh bash; do
    [ -f "$work/$shell" ] || continue
    if "$shell" -n "$work/$shell" 2>"$work/err"; then
        echo "==> $shell template OK"
    else
        echo "==> $shell template FAILED"
        sed 's|^|    |' "$work/err"
        status=1
    fi
done

exit $status
