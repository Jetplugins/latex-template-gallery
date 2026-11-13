Floral Beamer Presentation

Compile main.tex with LuaLaTeX (TeX Live 2023 or newer).
The compiler magic comment selects LuaLaTeX in LaTeX Pro unless project
settings override it. latexmkrc sets pdf_mode to LuaLaTeX for command-line
latexmk. Required standard packages: beamer and tikz (PGF). LuaLaTeX's
Latin Modern fonts are enough; no extra font installation is needed.

Theme: https://github.com/krissen/beamer-floral
Pinned revision: 556f2a8964663d92be2aa2008e1b79993fabba78
Author: Kristian Niemi (krissen)
Theme license: MIT; see LICENSE and UPSTREAM-LICENSE.txt.
README.md is the upstream guide, bundled unmodified.

beamer-floral needs Beamer integration hooks that are not in upstream
tikz-flora yet, so this folder also contains the matching engine fork:
https://github.com/krissen/tikz-flora (branch beamer-floral)
Engine revision: ff218774e205828f2d26026110797d4230a46126
That commit is recorded in engine-ref.txt. Engine copyright 2026 the
tikz-flora authors, MIT; see tikz-flora-LICENSE and tikz-flora-README.md.
Keep these files beside main.tex: beamerthemefloral.sty, beamer-floral.sty,
beamer-floral-animation.sty, beamer-floral.lua, beamer-floral-cache.lua,
beamer-floral-pdf.lua, tikzflora.sty, tikzflora-boot.lua, and lua/flora/.

The sample talk is original MIT content; see STARTER-LICENSE.txt.
It follows the upstream smoke test and standalone example: a plain title
frame and one content frame with a block, a list, and an example.
Edit \title, \author, and the slide text. The gallery's Title, Author,
and Language fields work with this starter.

\usetheme{floral} selects the floral margins and colours. Change seed,
density, and layout in \florasetup. \florapalette accepts warm, blue,
green, or green-stems. The title frame uses the theme's fuller left-margin
preset; other frames keep the document settings. Overlay growth and timed
playback are described in README.md. This sample leaves growth off, so it
does not need the animate package, Python, or Poppler.

No shell escape, network access, or external images are required.
The first run writes main.floral-cache beside the output and may request
another pass; latexmk repeats until the measured text block settles.
The development latexmkrc from the theme repository is not included: it
only points latexmk at a separate engine checkout. The bundled engine is
already beside this document.
