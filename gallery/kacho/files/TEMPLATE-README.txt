Kacho Flower and Bird Journal

Compile main.tex with lualatex (TeX Live 2023 or newer).
The starter uses TeX Gyre Pagella only when all four faces are available:
regular, bold, italic, and bold italic. Otherwise it uses Latin Modern Roman,
included with standard TeX installations. Installing just the regular Pagella
font is not enough for the sample's headings and italic text.
Source: https://github.com/AllenJue/kacho
Showcase: https://allenjue.github.io/kacho/
Pinned revision: 73a51dd098dc7d65bfa6f0c53a2a77f75eceff3a
Kacho copyright 2026 Allen Jue, Apache-2.0; all 16 Lua modules and kacho.sty
are bundled unmodified. Keep them together beside main.tex.
See UPSTREAM-LICENSE.txt, LICENSE, and NOTICE.md for the retained upstream and
third-party notices. KACHO-API.md is the upstream API reference.
Original gallery sample text: MIT; see STARTER-LICENSE.txt.

Edit \title, \author, and the sample prose. The two sample pages demonstrate
spring cherry blossoms and autumn maple; two-sided margins alternate naturally.
Use seed, density, theme, palette, layout, birds, and ground options to customize
all pages; \kachoThisPage{...} changes a single page. \kachospray reserves an
inline illustration. No external artwork, download, or shell escape is needed.
The gallery's Title, Author, and Language fields work with this starter.
