Calculus Course Notes

Compile main.tex with lualatex. Keep calculus-notes.sty and chapters/ with it.
This is an original MIT implementation of the visual style in the local
Calculus1 project (course notes credited there to Ludwig Claude Lelis): navy
cover stripe, sky-blue rule, circular cover motifs, chapter divider, blue
headings, and four semantic teaching boxes. The source course material is not
redistributed. Sample explanations, exercises, and solutions are new.

Edit \title, \author, \date, and \coursesubtitle in main.tex.
\coursecover draws a cover from those fields. In the report class,
\sectionpage{Topic} begins a numbered chapter with a full-page divider.
Add course sections through \input{chapters/your-topic}.
Available environments, each taking a title in braces:
  definitionbox (blue), theorembox (green), examplebox (gray), remarkbox (orange).
All four boxes may break across pages. Adjust colors and typography in the style.

IBM Plex Serif, Sans, Mono, and Math are used when installed; each has an
independent TeX Live font fallback (TeX Gyre / Latin Modern). Incomplete Serif
or Sans families also fall back, preserving bold headings and italic text. No font binaries
or machine-specific paths are required. The gallery's Title, Author, and
Language fields work with this starter.

Template and sample license: MIT; see UPSTREAM-LICENSE.txt and STARTER-LICENSE.txt.
Standard TeX packages and fonts come from your TeX distribution.
