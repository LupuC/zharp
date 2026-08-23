# Icon font

Regenerates `Sources/ZharpApp/Resources/tabler-icons.ttf`: the Tabler glyphs the
app actually draws, redrawn at a 1.25px stroke so they read lighter at 12-19px,
plus the AI agent brand marks. Subsetting takes the file from 2.8MB to ~9KB.

This is the same generator the Windows build uses, pointed at the macOS bundle.
Both apps ship a byte-identical font, so a glyph added here must be added there
too.

## Setup

```bash
npm install @tabler/icons oslllo-svg-fixer simple-icons
pip install fonttools
```

## Build

```bash
python3 Tools/icon-font/build.py
```

`codepoints.json` maps Tabler icon names to their official code points;
`brands.json` maps simple-icons slugs to the private-use points the agent
badges use. A collision between the two is a hard error rather than a silent
overwrite.

Adding a glyph means editing one of those files, rebuilding, and referencing the
new code point from `Icons.swift`. The bundled font is committed, so a
contributor without Node does not need to run this.
