# Third-Party Notices and Attributions

`kacho` is Copyright 2026 Allen Jue and is licensed under
the Apache License, Version 2.0 (see [LICENSE](LICENSE)). Portions of `kacho`
are adapted from third-party open-source work or implement published algorithms
from the computer graphics and botany literature. This file records those parts,
their authors, and their license terms.

## 1. florilegium (MIT License — adapted code)

- **Project**: `florilegium`, procedurally generated Delft-blue and watercolour
  floral page margins for LuaLaTeX
- **Author**: Kevin Raymond
- **Source**: <https://github.com/kevinraymond/florilegium>
- **License**: MIT License (reproduced verbatim below)

The following `kacho` files contain code adapted from `florilegium`
(`florilegium.sty`, `florilegium-ink.lua`, `florilegium-flora.lua`,
`florilegium-growth.lua`, and `florilegium-layout.lua`). Each file carries an
explicit header notice crediting Kevin Raymond and pointing to this file:

| `kacho` file | Adapted from (`florilegium`) |
|---|---|
| `tex/kacho.sty` | LaTeX package keyval interface, shipout background hook, and whatsit marker wiring (`florilegium.sty`) |
| `tex/kacho-rng.lua` | `mulberry32` stream, string hashing (`hash32`), named child streams, and 1-D value noise (`florilegium-ink.lua`) |
| `tex/kacho-palette.lua` | Linear sRGB ↔ Oklab conversions and perceptual pigment mixing (`florilegium-ink.lua`) |
| `tex/kacho-pdf.lua` | Layered PDF path builder, ExtGState opacity registry, and transparency group emission (`florilegium-ink.lua`) |
| `tex/kacho-brush.lua` | Catmull-Rom spline discretization, arc-length spine sampling, and variable-width tapered stroke/ribbon outlines (`florilegium-ink.lua`, `florilegium-flora.lua`) |
| `tex/kacho-wash.lua` | Layered radial/axial watercolour wash flood, multiply mottle, pooled rim, and lifted streaks (`florilegium-ink.lua`) |
| `tex/kacho-ink.lua` | High-level botanical watercolour primitives: `wash_fill` (multi-glaze wet-on-wet body, back-run rim, dry-brush streaks, stipple), `vein_fan`, `petal`, `leaf_shape`, and `branch_stroke` (`florilegium-ink.lua`) |
| `tex/kacho-flora.lua` | Multi-layer cupped petals, filament/anther stamen crowns, serrated compound leaves, and drooping raceme construction (`florilegium-flora.lua`) |
| `tex/kacho-layout.lua` | Transactional `Plan` sub-context (`try`/`commit`), safe-zone/text-block collision avoidance, and 4-sided border frame composition (`florilegium-layout.lua`, `florilegium-growth.lua`) |

```text
MIT License

Copyright (c) 2026 Kevin Raymond

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

## 2. Public-Domain Algorithms (courtesy attribution)

- **mulberry32** 32-bit state-mixing pseudo-random number generator by
  **Tommy Ettinger**, dedicated to the public domain (`CC0`):
  <https://gist.github.com/tommyettinger/46a874533244883189143505d203312c>.
  Adapted in `tex/kacho-rng.lua`.
- **Oklab** perceptual colour space by **Björn Ottosson** (2020), released into
  the public domain (`CC0`): <https://bottosson.github.io/posts/oklab/>.
  Adapted in `tex/kacho-palette.lua` and `tex/kacho-ink.lua`.

## 3. Academic Literature and Inspiration (no code copied)

- **Adam Runions, Brendan Lane, and Przemyslaw Prusinkiewicz**, *"Modeling Trees
  with a Space Colonization Algorithm"*, Eurographics Workshop on Natural
  Phenomena (EGWNP), pp. 63–70, 2007. Inspired the 2-D attractor-cloud space
  colonization solver in `tex/kacho-growth.lua` (`M.colonize`, `M.tree`,
  `M.garland`).
- **Kichiro Shinozaki, Kyoji Yoda, Kazuo Hozumi, and Tatuo Kira**, *"A
  Quantitative Analysis of Plant Form — The Pipe Model Theory"*, Japanese
  Journal of Ecology, 14(3):97–105, 1964. Inspired the Da Vinci / pipe-model
  area-preserving branch cross-section law ($r^2 = \sum r_i^2$) in
  `tex/kacho-growth.lua`, `tex/kacho-flora.lua`, and `tex/kacho.lua`.
- **Przemyslaw Prusinkiewicz and Aristid Lindenmayer**, *The Algorithmic Beauty
  of Plants*, Springer-Verlag, 1990. Inspired the phyllotactic divergence angles,
  monopodial/sympodial branching rules, and botanical organ placement in
  `tex/kacho-flora.lua` and `tex/kacho-growth.lua`.
- **Michael T. Wong, Douglas E. Zongker, and David H. Salesin**,
  *"Computer-Generated Floral Ornament"*, Proceedings of SIGGRAPH 1998,
  pp. 423–434, <https://doi.org/10.1145/280814.280948>. Inspired the adaptive
  ornament planning in free margin regions around typeset text in
  `tex/kacho-geom.lua`, `tex/kacho-layout.lua`, and `tex/kacho.lua`.
- ** Cassidy J. Curtis, Sean E. Anderson, Joshua E. Seims, Kurt W. Fleischer,
  and David H. Salesin**, *"Computer-Generated Watercolor"*, Proceedings of
  SIGGRAPH 1997, pp. 421–430, <https://doi.org/10.1145/258734.258896>. Inspired
  the edge-darkening pigment-migration (`nijimi`), back-run, and wet-in-wet
  (`tarashikomi`) wash layering in `tex/kacho-wash.lua` and `tex/kacho-ink.lua`.
- **tikz-flora** (<https://github.com/wn-mitch/tikz-flora>, MIT License). Its
  progressive botanical growth concept inspired the optional animated growth
  sheet (`examples/kacho-animated.tex`). All animation code in `kacho` is
  written from scratch in Lua; no `tikz-flora` code is included.
