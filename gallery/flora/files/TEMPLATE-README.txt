Flora Watercolor Garden

Compile main.tex with LuaLaTeX (TeX Live 2023 or newer).
Uses LuaLaTeX's bundled Latin Modern fonts; no system font installation is needed.
Required standard packages: geometry, microtype, fancyhdr, tikz (PGF), and iftex.

Source and guide: https://flora.alpacasoft.dev/
Package: https://flora.alpacasoft.dev/tikzflora.zip
Downloaded archive SHA-256: 27b61e256b620a14eb2698edbd1f87a402a624a4019c516834ca8b4bf9f70e38
The published LuaLaTeX archive is pinned by its content hash. The linked
wn-mitch/flora GitHub repository contains the separate TypeScript web engine.
All 57 Lua modules, tikzflora.sty, tikzflora-boot.lua, and README.md are
bundled unmodified. Keep lua/flora/ beside the boot file and main.tex.
Upstream copyright 2026 the tikz-flora authors, MIT; see LICENSE and
UPSTREAM-LICENSE.txt. Original sample text is MIT; see STARTER-LICENSE.txt.
The upstream README retains the Florilegium and algorithm acknowledgments.

Edit title, author, date, and the sample prose. The gallery's Title, Author,
and Language fields work with this starter. The first page uses a flanked
botanical frame; the next two put the garden in alternating outer margins.

Change seed for a different repeatable garden; seed=random varies each build.
density controls fullness. colourway selects a seasonal palette; palette and
mix customize inks, flowers, leaves, and visitors. florathispage changes only
one page. See README.md for all keys and layout choices.
The package renders its artwork during compilation without external images,
network access, or shell escape. Its default page cache lives in main-flora/
beside the output PDF. The first render takes longer; later runs reuse it.
Use floraoff/ floraon commands (with a leading backslash) for quick drafting.
