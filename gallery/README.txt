LaTeX Pro offline gallery

index.txt enumerates all 30 stable catalog IDs. Each directory contains:
- template.properties: display metadata, compiler, source and pinned revision,
  entry file, preview filenames, and optional preview page numbers.
- files.txt: explicit relative paths copied when creating a project.
- files/: editable starter sources, required template assets, and license notices.
- preview*.png: actual rendered pages from the bundled starter.

Template source code must use an explicitly permitted permissive license.
The current catalog contains only MIT and Apache-2.0 templates. GPL, LGPL,
AGPL, share-alike Creative Commons, and LPPL template assets are excluded.
Bundled font binaries are unmodified SIL OFL 1.1 fonts with their notices.
Standard LaTeX packages are external prerequisites supplied by the user's TeX
distribution; their code is not redistributed as part of this gallery.

See LICENSES.md for upstream provenance and template-specific adaptation notes.
New gallery-authored document content is MIT licensed (STARTER-LICENSE.txt).
Keep every upstream copyright and license notice when adapting a template.

To update: verify licenses, retain attribution, update the pinned revision or
content hash, refresh files.txt, and run tools/verify_gallery.py --previews with
listed TeX dependencies installed. Use --audit-only without TeX.
Do not bundle generated TeX build files or substitute mock document previews.
