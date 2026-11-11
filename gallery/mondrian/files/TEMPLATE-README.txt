Mondrian Composition

Compile main.tex with lualatex (TeX Live 2023 or newer).
Original MIT implementation and sample text by JetPlugins, inspired by Piet
Mondrian and De Stijl. No artwork, photographs, or external images are bundled.

Keep mondrian.sty and mondrian.lua beside main.tex. Use the package in another
document with \usepackage[seed=17,density=0.65,intensity=1]{mondrian}.

seed: integer 1..2147483646; identical seed and page number give identical art.
density: 0..1; controls the number of rectangular subdivisions.
intensity: 0..1; blends the ink and primary colors toward the paper color.
Each page uses an independent local random stream, without changing Lua's global
random state. The wider physical side margin is used automatically, including
mirrored two-sided pages. Keep that margin at least 35mm wide for useful artwork;
the sample uses 69mm. A 10mm clearance separates the art from the text block.
Narrow margins suppress the panel rather than overlapping your text.

Use \clearpage before \mondriansetup{seed=42,density=0.4,intensity=0.8},
\mondrianOff, or \mondrianOn so changes begin on a fresh page.
The full-page warm paper tint is also disabled by \mondrianOff.
Edit \title and \author, replace the sample prose, and adjust the geometry.
The gallery's Title, Author, and Language fields work with this starter.

Template and sample license: MIT; see UPSTREAM-LICENSE.txt and STARTER-LICENSE.txt.
Standard TeX packages and fonts come from your TeX distribution.
