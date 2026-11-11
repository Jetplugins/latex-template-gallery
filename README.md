# LaTeX template gallery

Public, independently versioned template content for the JetPlugins LaTeX Pro IntelliJ plugin.
Each template retains its attribution, upstream source, revision, and included license files.
Consult those files for the terms applicable to templates, fonts, and other assets.

Run `python3 validate.py` to check the catalog, and `python3 package.py 1.0.0`
to create reproducible `dist/gallery.zip` and `dist/manifest.json` release assets.
`verify_gallery.py` compiles templates with installed TeX tools and can regenerate previews.
Push a `vMAJOR.MINOR.PATCH` tag to publish a content release. Never replace assets for
an existing version: publish a new version instead. Format version 1 preserves the
index.txt, template.properties, files.txt, and per-template asset layout.

The plugin downloads the complete archive on first gallery use, caches it for offline
use, and checks daily while the gallery is open. Content updates do not modify projects
already created from templates. Lua and LaTeX are executed only by the user's normal
compilation workflow, never by the gallery downloader.
