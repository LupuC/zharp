# Third party notices

Zharp bundles a few files that other people wrote. They are not linked at
runtime or downloaded on first launch, they are copied into the application
bundle and the installer, so every copy of Zharp that anyone downloads
contains them.

Both licences below require the copyright notice and the licence text to
travel with the binary. That is what this file is for. If you build, fork,
repackage or redistribute Zharp in any form, ship this file (or an equivalent
notice screen containing the same text) alongside it.

Zharp's own code is MIT licensed, see [LICENSE](LICENSE). Nothing here changes
that, these are separate grants for the bundled assets.

---

## Tabler Icons

Used as the icon font `tabler-icons.ttf`. Every glyph in the toolbar, the tab
strip, the settings pane and the command blocks comes from this font.

| | |
|---|---|
| Project | Tabler Icons |
| Website | https://tabler.io/icons |
| Licence | MIT |
| Copyright | Copyright (c) 2020-2024 Paweł Kuna |

Bundled at:

- `windows/src/Zharp.App/Assets/Fonts/tabler-icons.ttf`
- `macos/Sources/ZharpApp/Resources/tabler-icons.ttf`

### Licence text

```
MIT License

Copyright (c) 2020-2024 Paweł Kuna

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## DM Mono

Used as `DMMono-Medium.ttf`, the branding typeface. DM Mono is available
through Google Fonts at https://fonts.google.com/specimen/DM+Mono, and the
source repository is https://github.com/googlefonts/dm-mono.

| | |
|---|---|
| Project | DM Mono |
| Licence | SIL Open Font License, Version 1.1 |
| Copyright | Copyright (c) 2014-2017 Colophon Foundry, with Reserved Font Name "DM Mono" |

Bundled at:

- `macos/Sources/ZharpApp/Resources/DMMono-Medium.ttf`
- `windows/src/Zharp.App/Assets/Fonts/DMMono-Medium.ttf`

Two points the OFL asks distributors to keep in mind, and that apply to anyone
forking Zharp: the font may be bundled and redistributed with the application
as long as this notice goes with it, and a modified version of the font may not
keep the name "DM Mono".

### Licence text

```
Copyright (c) 2014-2017 Colophon Foundry, with Reserved Font Name "DM Mono".

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org

-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

---

## Adding something new

If you open a pull request that adds a bundled font, icon set, image, sound or
vendored source file, add a section to this file in the same shape: what it is,
where it lives in the tree, the licence name, the copyright line, and the full
licence text. A link on its own is not enough for MIT or the OFL, both of them
require the text itself to ship with the binary.
