#!/bin/sh
# Fails when the canonical files in shared/ and the copies embedded in the
# platform apps have drifted apart.
#
# Why this exists: the shell integration scripts and the theme palettes live
# twice, once as a readable file in shared/ and once as a string literal or a
# table of hex constants inside each app's source. No compiler can see that the
# two have diverged. In 0.14.0 a stray `fi` left behind during an edit shipped
# inside the zsh template, the generated .zshrc aborted on a parse error, and
# shell integration was silently dead on macOS for the whole release. This
# script is what makes that class of mistake fail loudly instead.
#
# What it checks, in order:
#   1. Every canonical shell script under shared/shell-integration/ parses,
#      using that shell's own syntax checker. Shells that are not installed on
#      this machine are reported as SKIPPED, not as failures.
#   2. Each canonical script matches the copy embedded in the app source, after
#      the language specific string escaping has been undone.
#   3. shared/themes/palettes.json matches the palette tables in both apps.
#
# Requirements: python3, plus zsh and bash for the syntax checks. fish and pwsh
# are optional. Nothing here writes to the tree; it only reads and compares.
#
# Usage, from anywhere:
#   ./scripts/check-shared-drift.sh
# Exits 0 when everything agrees, 1 on the first kind of mismatch it finds
# (it still runs every check, so one run reports every problem).
set -eu

# Every path below is relative to the repository root.
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

status=0

# --------------------------------------------------------------- syntax checks
#
# The canonical files carry a header of comment lines above the sentinel, which
# every one of these shells treats as comments, so each file is checked whole
# exactly as it sits on disk.

check_syntax() {
    file=$1        # path under shared/shell-integration/
    binary=$2      # the checker's executable
    label=$3       # how the check is described in the summary line
    name=$(basename "$file")

    if [ ! -f "$file" ]; then
        printf '==> syntax  %-12s MISSING (%s does not exist)\n' "$name" "$file"
        status=1
        return
    fi

    if ! command -v "$binary" >/dev/null 2>&1; then
        printf '==> syntax  %-12s SKIPPED (%s is not installed on this machine)\n' "$name" "$binary"
        return
    fi

    case $binary in
        pwsh)
            # PowerShell has no -n flag. Ask its own parser instead, which
            # reports syntax errors without running a single statement.
            set +e
            pwsh -NoProfile -NoLogo -File "$work/parse.ps1" "$file" >"$work/err" 2>&1
            rc=$?
            set -e
            ;;
        fish)
            set +e
            fish --no-execute "$file" >"$work/err" 2>&1
            rc=$?
            set -e
            ;;
        *)
            set +e
            "$binary" -n "$file" >"$work/err" 2>&1
            rc=$?
            set -e
            ;;
    esac

    if [ "$rc" -eq 0 ]; then
        printf '==> syntax  %-12s OK (%s)\n' "$name" "$label"
    else
        printf '==> syntax  %-12s FAILED (%s)\n' "$name" "$label"
        sed 's|^|    |' "$work/err"
        status=1
    fi
}

# Written out rather than passed with -Command so that no shell quoting layer
# sits between this file and PowerShell.
cat >"$work/parse.ps1" <<'PS1'
param([Parameter(Mandatory = $true)][string]$Path)
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $Path).Path, [ref]$null, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object { $_.ToString() }
    exit 1
}
exit 0
PS1

check_syntax shared/shell-integration/zharp.zsh  zsh  "zsh -n"
check_syntax shared/shell-integration/zharp.bash bash "bash -n"
check_syntax shared/shell-integration/zharp.fish fish "fish --no-execute"
check_syntax shared/shell-integration/zharp.ps1  pwsh "PowerShell parser"

# ------------------------------------------------------- drift, everything else
#
# Extraction and comparison are one python3 program because both sides need the
# same unescaping rules applied to them. It prints its own summary lines and
# exits non-zero if anything disagrees.

set +e
python3 - <<'PY'
import difflib
import json
import pathlib
import re
import sys
import textwrap

root = pathlib.Path(".")
status = 0

SENTINEL = "# zharp-canonical-body-begins-below"

MAC_SHELL = "macos/Sources/ZharpApp/ShellDiscovery.swift"
WIN_SHELL = "windows/src/Zharp.App/ShellDiscovery.cs"
MAC_PALETTE = "macos/Sources/ZharpCore/Terminal/Palette.swift"
WIN_PALETTE = "windows/src/Zharp.Core/Terminal/Palette.cs"


def die(message):
    """A problem with the checker itself, not with the tree it is checking."""
    sys.exit("check-shared-drift: " + message)


def read(path):
    p = root / path
    if not p.is_file():
        die("%s is missing" % path)
    return p.read_text()


# --------------------------------------------------------------- shell scripts

def canonical_body(filename):
    """The part of a canonical file below the sentinel. The header above it is
    documentation and is deliberately not compared against anything."""
    text = read("shared/shell-integration/" + filename)
    parts = text.split(SENTINEL + "\n")
    if len(parts) != 2:
        die("shared/shell-integration/%s must contain the line '%s' exactly once"
            % (filename, SENTINEL))
    return parts[1]


def unescape_swift(literal):
    r"""Undo Swift string escaping. Only \\ and \" occur in these literals; a
    literal that grows an interpolation or a \n would silently decode wrong, so
    refuse rather than guess."""
    for bad in (r"\(", r"\n", r"\t", r"\u{"):
        if bad in literal.replace(r"\\", ""):
            die("a Swift literal now contains %s, which this unescaper does not "
                "handle - teach it that escape before shipping the change" % bad)
    return literal.replace("\\\\", "\\").replace('\\"', '"')


def swift_multiline_templates(source):
    """Templates written as `let script = \"\"\" ... \"\"\"` inside a shell's
    factory function, keyed by the function's name."""
    pattern = re.compile(
        r'func (?P<shell>\w+)\([^)]*\)\s*->\s*ShellSpec\s*\{(?:(?!func ).)*?'
        r'let script = """\n(?P<body>.*?)\n\s*"""',
        re.S)
    return {m.group("shell"): unescape_swift(textwrap.dedent(m.group("body")))
            for m in pattern.finditer(source)}


def concatenated_literal(source, anchor, unescape):
    """One `+`-joined run of double quoted string pieces, starting at `anchor`."""
    m = re.search(re.escape(anchor) + r'\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)',
                  source, re.S)
    if not m:
        return None
    pieces = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
    return unescape("".join(pieces))


def unescape_csharp(literal):
    """C# escaping in these constants is the same subset Swift uses."""
    return literal.replace("\\\\", "\\").replace('\\"', '"')


mac_source = read(MAC_SHELL)
win_source = read(WIN_SHELL)

embedded = {}
for shell, body in swift_multiline_templates(mac_source).items():
    embedded[("macos", shell)] = body
embedded[("macos", "fish")] = concatenated_literal(
    mac_source, "let hook =", unescape_swift)
embedded[("macos", "pwsh")] = concatenated_literal(
    mac_source, "let integration =", unescape_swift)
embedded[("windows", "pwsh")] = concatenated_literal(
    win_source, "const string PowerShellIntegration =", unescape_csharp)

# A restructured source file must fail loudly rather than quietly checking
# nothing, which is the trap a regex based extractor is otherwise prone to.
missing = [key for key, value in embedded.items() if value is None]
if missing:
    die("could not extract %s - have the ShellDiscovery files been "
        "restructured? Update the patterns in this script."
        % ", ".join("%s %s" % (p, s) for p, s in sorted(missing)))

# canonical file, platform, key in `embedded`, source path, known variant.
#
# A known variant is a documented, deliberate difference between one platform's
# copy and the canonical text. It is applied to the canonical side before the
# comparison, so the difference it names is allowed and every other difference
# still fails. Today there is exactly one: Windows reports the working
# directory with OSC 9;9 (the ConEmu convention) where macOS uses OSC 7. Both
# emulators parse both, so this is history, not a requirement, and stage two
# can collapse it.
CHECKS = [
    ("zharp.zsh",  "macos",   "zsh",  MAC_SHELL, None),
    ("zharp.bash", "macos",   "bash", MAC_SHELL, None),
    ("zharp.fish", "macos",   "fish", MAC_SHELL, None),
    ("zharp.ps1",  "macos",   "pwsh", MAC_SHELL, None),
    ("zharp.ps1",  "windows", "pwsh", WIN_SHELL, ("]7;file://", "]9;9;")),
]

for filename, platform, shell, source_path, variant in CHECKS:
    # The embedded literals carry no trailing newline; the canonical files end
    # with one, the way text files should. That difference is not drift.
    want = canonical_body(filename).rstrip("\n")
    note = source_path
    if variant:
        want = want.replace(variant[0], variant[1])
        note += ", through the known %s -> %s variant" % variant
    got = embedded[(platform, shell)].rstrip("\n")

    if want == got:
        print("==> drift   %-12s OK (%s)" % (filename, note))
        continue

    print("==> drift   %-12s FAILED (%s)" % (filename, note))
    diff = difflib.unified_diff(
        want.splitlines(), got.splitlines(),
        fromfile="shared/shell-integration/" + filename,
        tofile="embedded in " + source_path,
        lineterm="")
    for line in diff:
        print("    " + line)
    status = 1


# -------------------------------------------------------------------- palettes

def hexes(text):
    return [h.upper() for h in re.findall(r"0x([0-9A-Fa-f]{6})", text)]


def swift_palettes():
    """Everything from Palette.swift up to the Resolved struct. Cutting there
    keeps the dim mask 0x7F7F7F out, which is arithmetic, not a palette color."""
    source = read(MAC_PALETTE).split("public struct Resolved")[0]

    campbell = re.search(r"func campbell\(\)\s*->\s*Palette\s*\{(.*?)\n    \}",
                         source, re.S)
    shared = re.search(r"gitHubLightAnsi:\s*\[UInt32\]\s*=\s*\[(.*?)\]", source, re.S)
    if not campbell or not shared:
        die("could not parse %s - has it been restructured?" % MAC_PALETTE)

    body = campbell.group(1)
    ansi = re.search(r"let ansi:\s*\[UInt32\]\s*=\s*\[(.*?)\]", body, re.S)

    def field(name):
        return re.search(name + r"\s*=\s*0x([0-9A-Fa-f]{6})", body).group(1).upper()

    themes = [{
        "id": "campbell",
        "foreground": field("defaultForeground"),
        "background": field("defaultBackground"),
        "cursor": field("cursorColor"),
        "selection": field("selectionColor"),
        "ansi16": hexes(ansi.group(1)),
    }]

    pattern = re.compile(
        r"func (\w+)\(\)\s*->\s*Palette\s*\{\s*build\(fg:\s*0x(\w{6}),"
        r"\s*bg:\s*0x(\w{6}),\s*cursor:\s*0x(\w{6}),\s*selection:\s*0x(\w{6}),"
        r"\s*ansi16:\s*(gitHubLightAnsi|\[[^\]]*\])\)", re.S)
    for m in pattern.finditer(source):
        ansi16 = (hexes(shared.group(1)) if m.group(6) == "gitHubLightAnsi"
                  else hexes(m.group(6)))
        themes.append({
            "id": m.group(1),
            "foreground": m.group(2).upper(),
            "background": m.group(3).upper(),
            "cursor": m.group(4).upper(),
            "selection": m.group(5).upper(),
            "ansi16": ansi16,
        })
    return themes


def csharp_palettes():
    source = read(WIN_PALETTE).split("public void Resolve")[0]

    campbell = re.search(r"Palette Campbell\(\)\s*\{(.*?)\n        return p;",
                         source, re.S)
    shared = re.search(r"GitHubLightAnsi\s*=\s*\{(.*?)\};", source, re.S)
    if not campbell or not shared:
        die("could not parse %s - has it been restructured?" % WIN_PALETTE)

    body = campbell.group(1)
    ansi = re.search(r"uint\[\] ansi\s*=\s*\{(.*?)\};", body, re.S)

    def field(name):
        return re.search(name + r"\s*=\s*0x([0-9A-Fa-f]{6})", body).group(1).upper()

    themes = [{
        "id": "campbell",
        "foreground": field("DefaultForeground"),
        "background": field("DefaultBackground"),
        "cursor": field("CursorColor"),
        "selection": field("SelectionColor"),
        "ansi16": hexes(ansi.group(1)),
    }]

    pattern = re.compile(
        r"Palette (\w+)\(\)\s*=>\s*Build\(0x(\w{6}),\s*0x(\w{6}),\s*0x(\w{6}),"
        r"\s*0x(\w{6}),\s*(GitHubLightAnsi|new uint\[\]\s*\{[^}]*\})\)", re.S)
    for m in pattern.finditer(source):
        ansi16 = (hexes(shared.group(1)) if m.group(6) == "GitHubLightAnsi"
                  else hexes(m.group(6)))
        themes.append({
            "id": m.group(1).lower(),
            "foreground": m.group(2).upper(),
            "background": m.group(3).upper(),
            "cursor": m.group(4).upper(),
            "selection": m.group(5).upper(),
            "ansi16": ansi16,
        })
    return themes


def json_palettes():
    doc = json.loads(read("shared/themes/palettes.json"))
    shared = {k: v for k, v in doc["sharedAnsi16"].items() if not k.startswith("_")}
    themes = []
    for t in doc["themes"]:
        if "ansi16Ref" in t:
            ref = t["ansi16Ref"]
            if ref not in shared:
                die("theme '%s' refers to sharedAnsi16 '%s', which is not defined"
                    % (t["id"], ref))
            ansi16 = shared[ref]
        else:
            ansi16 = t["ansi16"]
        themes.append({
            "id": t["id"],
            "foreground": t["foreground"].upper(),
            "background": t["background"].upper(),
            "cursor": t["cursor"].upper(),
            "selection": t["selection"].upper(),
            "ansi16": [c.upper() for c in ansi16],
        })
    return themes


def render(themes):
    """A flat, diffable form: one line per theme, values in a fixed order."""
    lines = []
    for t in themes:
        lines.append("%-12s fg=%s bg=%s cursor=%s selection=%s"
                     % (t["id"], t["foreground"], t["background"],
                        t["cursor"], t["selection"]))
        lines.append("%-12s ansi16=%s" % (t["id"], " ".join(t["ansi16"])))
    return lines


canonical_themes = json_palettes()
if not canonical_themes:
    die("shared/themes/palettes.json defines no themes")

for label, path, extracted in (("macos", MAC_PALETTE, swift_palettes()),
                               ("windows", WIN_PALETTE, csharp_palettes())):
    if not extracted:
        die("extracted no themes from %s - has it been restructured?" % path)

    want, got = render(canonical_themes), render(extracted)
    if want == got:
        print("==> themes  %-12s OK (%d themes, %s)"
              % ("palettes.json", len(canonical_themes), path))
        continue

    print("==> themes  %-12s FAILED (%s)" % ("palettes.json", path))
    for line in difflib.unified_diff(want, got,
                                     fromfile="shared/themes/palettes.json",
                                     tofile="embedded in " + path,
                                     lineterm=""):
        print("    " + line)
    status = 1

    ids_want = [t["id"] for t in canonical_themes]
    ids_got = [t["id"] for t in extracted]
    if ids_want != ids_got:
        print("    theme ids differ: %s vs %s" % (ids_want, ids_got))

sys.exit(status)
PY
python_status=$?
set -e
[ "$python_status" -eq 0 ] || status=1

if [ "$status" -eq 0 ]; then
    echo "==> shared/ is in sync with both apps"
else
    echo "==> shared/ has drifted, see the failures above"
fi

exit $status
