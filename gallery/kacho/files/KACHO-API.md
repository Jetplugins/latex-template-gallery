# kacho API

This is the binding contract between the M1 engine, the M2 motifs, the M3 layouts and the E2E tests.

Status: M1 (engine) is implemented. M2 and M3 extend this document; they do not change sections 0–2 without agreement.

## 0. Conventions

- **Units and angles.** Units are PDF big points (bp, 1/72 in). The origin is the bottom-left corner of the paper. Angles are in radians, counter-clockwise from +x.
- **Shapes.**
  - A *rect* is `{x0=, y0=, x1=, y1=}` with `x0 <= x1` and `y0 <= y1`.
  - A *point* is `{x, y}`.
  - A *colour* is `{r, g, b}` with components in 0..1.
- **TeX globals.** Only `kacho.lua` touches TeX/LuaTeX globals (`tex`, `node`, `pdf`, `token`, `luatexbase`, `status`). Every other module must load under plain `texlua`; the unit tests in `tests/unit/` rely on this.
- **Determinism.**
  - Draw randomness only from `ctx.rng`. Never use `math.random`, `os.time` or `os.clock`.
  - Iterate with `ipairs` or a numeric `for`. Never use `pairs()` where the order affects output.
- **Where Lua lives.** Lua code goes in `.lua` files only. Inside `\directlua` in `.sty`/`.tex` files, `%`, `#` and `~` break.
- **Modules.** Module names are flat in `tex/` and prefixed with `kacho-`.
- **Attribution.** Code adapted from florilegium (MIT, © 2026 Kevin Raymond) carries the MIT notice in a header in that file. This applies to `kacho-rng`, `-palette`, `-pdf`, `-brush` and `-wash`.

## 1. Modules

| Module | Owner | Purpose |
|---|---|---|
| `kacho.sty` | M1 | options, user commands, shipout hook |
| `kacho.lua` | M1 | TeX glue: options and env overrides, markers, page geometry, measured ink, ctx, layout dispatch, built-in `demo`/`none` layouts, debug log |
| `kacho-geom.lua` | M1 | rect ops, page geometry, decoration regions |
| `kacho-rng.lua` | M1 | seeded streams and noise |
| `kacho-palette.lua` | M1 | `sumi` and `hanga` palettes (survey_2 §4.1), Oklab mixing, ink ramp |
| `kacho-pdf.lua` | M1 | content-stream writer: paths, fills, strokes, clips, ExtGState, shadings, soft masks, groups |
| `kacho-brush.lua` | M1 | Bézier utilities, tapered stroke, dry brush, ribbon, outline stroke, offshoot, dot |
| `kacho-wash.lua` | M1 | blob, nijimi, band, soft, bokashi, rim, mokkotsu, tarashikomi, mottle, lift |
| `kacho-flora.lua` / `-fauna` / `-scenery` / `-seal` | M2 | motifs (section 3) |
| `kacho-layout.lua` | M3 | layouts and themes (section 4); optional at runtime |

### 1.1 RNG (`kacho-rng`)

Every stream function is a plain field: call `r.u()`, **not** `r:u()`.

```lua
local rng = require("kacho-rng")
local r = rng.new(seed)      -- 32-bit mulberry32; same seed gives the same stream
r.u()  r.random()            -- [0,1)
r.range(a,b)  r.uniform(a,b) -- [a,b)
r.sym(a)                     -- [-a,a)
r.int(a,b)                   -- integer in [a,b]
r.chance(p)  r.pick(t)  r.normal(mu, sd)  r.next_u32()
r.fork(tag)                  -- child stream; consumes exactly ONE parent draw
r.child(name)                -- order-independent child: depends only on the stream's
                             -- initial seed and name
r.noise(oct)                 -- smooth fbm x -> [-1,1] seeded from this stream
rng.hash(str)                -- FNV-1a 32-bit
rng.page_seed(docseed, page)
```

Convention: the engine gives each page `rng.new(page_seed(seed, index))`.

- Layouts and motifs take sub-streams with `ctx:sub{tag=...}`, which uses `child(tag)`, or with `r.child(name)`. Editing one motif therefore never moves the others.
- `fork` follows florilegium's semantics and fits sequential generation.

### 1.2 Palette (`kacho-palette`)

```lua
local P = require("kacho-palette").get("sumi")   -- or "hanga"; unknown name raises
```

| Function | Returns |
|---|---|
| `P.color(name)` | `{r,g,b}`. Raises on an unknown name, so there is never a silent black. |
| `P.hex(name)` | `"#RRGGBB"` |
| `P.has(name)` | whether `name` is a known colour |
| `P.ink(v)` | colour and alpha-over-paper equivalent along the sumi ramp. `v=0` is sumi-noir (α .95); `v=1` is sumi-wash (α .15). |
| `P.role(r)` | the palette's colour for a role: `branch twig leaf blossom blossom_deep stamen accent seal wash mist rock ground` |
| `P.paper` | the paper colour the preset assumes (`washi` for sumi, `torinoko` for hanga) |

Module-level helpers:

- `mix(c1,c2,t)` (in Oklab)
- `lighten`, `darken`, `lightness`
- `layer_alpha(c, paper)`: the suggested per-layer alpha for washes
- `names()`, `ground(value)`

Colour names are the survey_2 §4.1 names, 35 in all:

- Paper and grounds: `washi kinu-celadon torinoko koson-greige koson-greige-dark`
- Sumi ramp: `sumi-noir sumi-dark sumi-mid sumi-light sumi-wash`
- Pigments: `shu bengara momo sakura-pale beni ume-centre kigaki yamabuki kincha bokashi-sky bokashi-sky-horizon ai gunjo asagi fuji fuji-pale matsuba wakatake moegi koke momiji kuri gofun uguisu tsubame-navy`
- Aliases: `ochre`/`odo` → `kigaki`, `vermilion` → `shu`

### 1.3 PDF writer (`kacho-pdf`), reached as `ctx.pdf`

The page writer `W` collects content into numbered layers and emits them in ascending order. Layer conventions:

| Layer | Content |
|---|---|
| 10 | background washes |
| 20 | trunks and branches |
| 30 | leaves |
| 40 | flowers |
| 50 | birds |
| 60 | seal |
| 70 | overlays |

`W:layer(n)` selects the layer. Changing layer inside an open clip raises an error.

**Path builders** return `{s=ops, bbox=rect}`, or `nil` when the input is degenerate or holds NaN/inf (the whole path is dropped):

- `W:poly(pts, closed)`
- `W:smooth(pts, closed, tension)` (Catmull-Rom → Bézier)
- `W:bezier(segs, closed)`
- `W:ellipse(cx,cy,rx,ry,rot)` and `W:circle(cx,cy,r)`
- `W:rect(x0,y0,x1,y1 | rect)`
- `W:join(p1, p2, ...)`: a compound path. Its subpaths are filled once, so overlaps in one colour do not double-darken under nonzero.

**Painting.** Each call returns the painted bbox.

- `W:fill(path, rgb, alpha, {blend=, evenodd=})`
- `W:stroke(path, rgb, width, alpha, {blend=, cap=, join=})`
- `W:fill_pattern(path, patname, alpha)`

Blend modes are `normal multiply screen darken lighten overlay`.

Alpha is quantized to 1/200. Each (alpha, blend) pair is one ExtGState, registered once per document through pgf's resource list.

**Clips and state.** Each opens a balanced `q … Q`, and the writer refuses to flush with an open clip.

- `W:clip(path[, evenodd])` … `W:unclip()`
- `W:with_gs(name, fn)`

**Shadings.** These are native PDF shadings, so they do not band. They are cached by parameters.

- `W:axial(x0,y0,x1,y1, {{t,rgb},...})` and `W:radial(cx,cy,r0,r1, stops, {sy=})` return a pattern name in page space. More than 2 stops gives a stitching function.

**Soft masks.** Each returns an ExtGState name for `with_gs`.

- `W:fade_axial(x0,y0,x1,y1,g0,g1, rect)`
- `W:fade_radial(cx,cy,rx,ry, inner, power)`: the form BBox is ±1.6 r.
- `W:fade_box(rect, {l,r}, {b,t})`: a rectangular smoothstep feather.

Rule (poppler seam, explorer_m2_3 P1): **paint must stay inside the mask form's BBox**. Use `W.MASK_MARGIN` = 2 bp for axial and box masks, and 1.6 r for radial masks.

**Transparency group.** `W:group(fn, alpha, blend)` paints `fn(subwriter)` as an isolated group (a LuaTeX box resource carrying the pgf resource dicts) and composites it once.

**Trial fit.** `W:sub()` creates a scratch writer that shares the registry. `W:merge(other)` appends another writer's content; it is used by `ctx:try` (section 2).

### 1.4 Brush (`kacho-brush`), reached as `ctx.brush`

A spine is a chain of cubics `{{p0,p1,p2,p3}, ...}`. A single cubic is also accepted.

**Geometry:**

- `B.bez`, `B.bezd`, `B.bezdd`, `B.split`
- `B.line(p0,p1)`
- `B.chain(pts, tension, t0, t1)`: a C1 Catmull-Rom chain through the points, with collinear handles
- `B.spine(segs) -> S, L`: samples `{x,y,tx,ty,k,s,u}`
- `B.at(S,u) -> x,y,tx,ty` and `B.eval(segs,u)`: evaluate at arc-length fraction `u`, for exact attachment points
- `B.offshoot(S, u, ang, len, flow, bend) -> segs, start, end`: a side branch that starts exactly on the parent and leaves along a blend of the parent's tangent and `ang`, so joints flow instead of looking glued on
- `B.outline(S, wfn, {kmax=.85, jitter=fn, asym=})`: a CCW outline with an inner-side curvature clamp, a monotone filter and de-looping. It has no swallowtails and no winding-0 pinholes.
- `B.deloop(pts)`, `B.area2(pts)`, `B.self_crossings(pts)`

**Painting.** Each call returns a bbox.

- `B.stroke(ctx, segs, o)`. Options:
  - `w`, `profile` (a name or a function), `rgb`, `alpha`, `blend`
  - `jitter` = .05
  - `pressure` (thick-thin amplitude) and `pfreq`
  - `joints={{x,y,r}}`: knot discs in the same fill
  - `cap` (a round start)
- `B.outline_path(ctx, segs, o) -> path, S`: builds the stroke's closed outline path (plus optional `joints` and `cap`) without filling it, so a parent and child branches can be combined with `W:join(...)` and filled once without double-darkening at joints.
- `B.crotch(W, parentS, u, pw, childS, cw, scale) -> path`: builds a smooth concave fillet bridging the parent flank at `u` and the child base, eliminating V-notches at forks.
- `B.fork(ctx, parent, children, o) -> bbox, parentS, childSpines`: paints a parent stroke (`{segs=, w=, profile=, ...}`) and a list of child offshoots (`{{segs=, u=, w=, profile=, ...}, ...}`) together with their crotch fillets as a single compound `W:join` fill.
- `B.dry(ctx, segs, o)`: kasure. A pale unbroken under-silhouette plus bristle runs in one fill. `dryness` is clamped to 0.05..0.6, and it also accepts `pressure`.
- `B.ribbon(ctx, segs, o)`: an orchid leaf.
- `B.outline_stroke(ctx, segs, o)`: a fine kōroku line.
- `B.dot(ctx, x,y,r, o)`

Profiles: `both nail orchid branch twig taper even line` (branch and twig profiles round smoothly to a tip).

### 1.5 Wash (`kacho-wash`), reached as `ctx.wash`

Every call returns a bbox. Washes keep each layer's alpha ≤ 0.12.

- **`Wsh.nijimi(ctx, {x,y,rx,ry,rot}, o)`**: the irregular watercolour blot.
  - The body pigment settles toward `flow`.
  - The bleed fringe is one-sided, with crossing (never nested) edges, so it does not band.
  - Paper-coloured lifts give varied opacity.
  - Pooling (`rim`) uses ribbons on part of the edge.
  - Granulation (`grain`) and optional `bloom` (tarashikomi) are on by default as shown.
- **`Wsh.band(ctx, {x0,x1,y,height,rgb,alpha,...})`**: a layered watercolour band for ground, mist or sky strokes, following explorer_m2_3's `wash_band`.
  - Ends dissolve through `fade_box`.
  - Pooling ribbons run along the upper edge.
  - Granulation stays inside the wash.
  - This is the standalone wash to use. **Do not use soft discs as standalone washes** (P10).
- **`Wsh.soft(ctx, cx,cy,rx,ry, o)`**: an airbrush ellipse (a rect fill under a radial mask). Use it inside motifs (breast colour, recesses), not on its own.
- **`Wsh.bokashi(ctx, rect, c0, c1, {dir=, fx=, fy=, fade=})`**: a native gradient through a rectangular feather.
- **`Wsh.rim(ctx, pts, {strength, width, partial})`**, **`Wsh.mokkotsu(ctx, pts, o)`**, **`Wsh.tarashikomi(ctx, pts, o)`**, **`Wsh.mottle(ctx, pts, o)`**, **`Wsh.lift(ctx, segs, o)`**
- **Helpers:** `Wsh.blob(rng, cx,cy,rx,ry, rough, n, rot)` gives a self-intersection-free irregular outline. `Wsh.inside(poly,x,y)` is a point-in-polygon test.

## 2. The drawing context `ctx`

The engine builds `ctx` once per decorated page. Layouts derive sub-contexts from it.

| Field | Meaning |
|---|---|
| `pdf`, `brush`, `wash`, `geom` | drawing API (1.3–1.5) and geometry |
| `under` | secondary `kacho-pdf` writer emitted after the `ground` tint and before the safety-clipped artwork, unclipped, for `*-ground` panels (`kakejiku`, `shikishi`) and `inline-*` sprays inside the type area |
| `rng` | stream for this context |
| `palette` | active palette (1.2) |
| `region` | rect that flowers, leaves, birds and seals must stay inside. At page level this is the whole safe box. |
| `safe` | paper minus the safe zone (5 mm) |
| `exclude` | list of rects: the type area (or the title box) inflated by `buffer` (≥ 4 mm), plus measured ink that sticks out of it (marginpars, overfull lines, glue leaders), also inflated. Nothing may intersect these (except `ground` and `inline` kinds). |
| `bleed` | set of paper edges (`{left=, right=, top=, bottom=}`) that bleed kinds may cross (layouts set it; the demo uses `{}`) |
| `density` | 0..1 |
| `theme`, `season` | `haru`/`natsu`/`aki`/`fuyu` (`shochikubai` maps to the `fuyu` season) |
| `seal`, `birds` | booleans from the options |
| `page`, `opts` | page table (4.1) and effective options, read-only |
| `is_bleed(kind)`, `is_ground(kind)`, `is_inline(kind)` | token classifiers on kind strings |
| `record(kind, rect)` | log one drawn element (section 6) and self-check it against `exclude`, `safe`, and `bleed`. Call it once per visible part (each limb, blossom, bird, seal…) with that part's own bbox. |
| `fits(rect, kind)` | true if rect intersects no `exclude` (unless `inline` or `ground`) and lies inside `region ∩ safe` (or, for bleed kinds, crosses only paper edges listed in `bleed` and never opposite edges) |
| `ctx:try(kind, fn)` | growth limiting: runs `fn(tc)` with a scratch writer and buffers any `tc.record` calls made during the trial. If `tc.record` was called, validates every recorded `(k, r)` with `c.fits(r, k)` (so L-shaped sprays whose union straddles a corner are not falsely rejected); otherwise validates `c.fits(bb, kind)`. On success, merges the scratch writer and replays the buffered records; otherwise discards both and returns `nil`. |
| `ctx:sub(t)` | shallow copy with overrides (`region=`, `bleed=`, `tag=`…). It derives `rng = rng.child(tag)` and rebinds `fits` and `record`. |

**Safety net.** The engine also clips each page's `ctx.pdf` art to the paper minus the exclusions shrunk by `buffer/2`. Paint can therefore never land on the text itself.

- Motifs must not rely on this clip. A clipped shape is still an artifact, and `record` reports the violation as `# WARN` and as a TeX warning.
- The `ground` tint and `ctx.under` are drawn outside this clip.

## 3. Motif API (M2 implements, M3 calls)

```lua
local flora = require("kacho-flora")
local bbox, info = flora.ume(ctx, spec)
```

**Signature.** Every motif is `M.<name>(ctx, spec) -> bbox, info`.

- `spec` keys: `x, y` (anchor or base point), `angle`, `size` (bp), `density`, `variant`, plus motif-specific keys documented above each motif.
- `bbox` is the union of everything painted, or `nil` if nothing fitted.
- `info` may hold:
  - `perch` = `{{x=,y=,angle=,w=,t=},...}`: points on top of a branch, for birds
  - `tips`
  - `kinds`

**Containment.** The debug log is checked by E2E.

1. Non-bleed parts must lie fully inside `ctx.region`. Prefer growth limiting (`ctx:try`, `ctx.fits`, steering headings away from boundaries) over clipping.
2. Bleed kinds (`trunk`, `culm`, `stem`, `vine`, as tokens in the kind string) may cross only paper edges listed in `ctx.bleed`, and only near their base.
3. Nothing may intersect a `ctx.exclude` rect.

**Joins.**

- A child spine starts at `brush.at(parentS, u)`, or use `brush.offshoot` / `brush.fork`.
- The child's start width is at most the parent's width there.
- Blossoms and leaves attach to points on twigs.
- Falling petals are recorded as kind `*-petal`.

**Kinds** (debug log) contain the motif name, for example `ume-twig`, `ume-blossom`, `sakura-petal`, `culm`, `bamboo-leaf`, `orchid-leaf`, `maple-leaf`, `wisteria-raceme`, `vine`, `iris-leaf`, `uguisu`, `sparrow`, `seal`, `rock`, `fuji`, `kasumi`, `bokashi`, `pine-*`, `camellia-*` (see `tests/e2e/api_config.py`).

**Birds and seal.**

- Birds: `fauna.<bird>(ctx, {perch=info.perch[i], size=, facing=})`.
- Seal: `seal.hanko(ctx, {x,y,size,style})`.

**Failure.** A motif must never raise. If nothing fits, it returns nil.

## 4. Layout API (M3 implements; M1 ships `demo` and `none`)

`kacho-layout` is loaded with `pcall(require, "kacho-layout")`. If it is missing, every layout name (except `none` or when `regions=none`) falls back to the built-in `demo` and a single TeX warning is printed for each name.

The module returns a table `L` that has any of these:

- `L.install(kacho)`: call `kacho.register_layout(name, fn)` for each layout.
- `L.layouts = {name = fn, ...}`
- `L.auto(page, ctx) -> name`: used for `layout=auto`. If it returns `"none"`, no layout is drawn; if `L.auto` is absent, the engine uses `demo`.
- `L.user(ctx, page, page.user)`: optional handler called after the page layout when `\kachoSpawn` or `\kachospray` markers are present on the page (even if `layout=none` or `regions=none`).

Each layout function is called as `fn(ctx, page)` once per decorated page.

- Choose regions from `page.regions`, `page.region_list` or `page.bands` (always with `ctx.fits`).
- Derive sub-contexts with `ctx:sub{...}`.
- Call motifs.
- Call `ctx.record` for every part.

Title pages call the layout named by `\kachoTitlePage` (default `kakejiku`). Pages carrying `\kachoThisPage{layout=shikishi}` call `shikishi` (where `page.block` is shrunk to the union of measured ink boxes intersecting `page.text` so the empty lower portion of a chapter-opener page is available for decoration).

### 4.0 The built-in `demo` layout (M1)

`demo` puts one plum tree in the outer margin band. It is the fallback for every layout name until M3 lands.

- **Ground bank.** A grassy bank (user feedback 01:50Z) is centred on the trunk base. Its contour is a low irregular hump.
  - **Fill.** A bokashi from deeper green below to pale above, fading upward into the paper under a feathered `fade_box`, plus a second wash and granulation.
  - **Grass.** Lighter blades behind the trunk, then dense darker blades in several greens in front of the foot and roots.
  - **Details.** Pebbles, a few small flowers and moss tufts.
  - **Rooting.** Tapered buttress roots flare from the trunk base into the bank under the front grass.
  - There is no mist band.
- **Delegation to M2 (additive, iteration 2).** If `require("kacho-flora")` succeeds and the module has `ume`, the demo draws only the ground wash and the rooting. The tree comes from
  `flora.ume(c, {x=, y=, angle=pi/2, size=, density=, variant="white"|"pink", region=})`, where:
  - `(x, y)` is the trunk base at the wash centre;
  - `c` is a sub-context (`bleed = {}`) whose drawing is trial-fitted with `c:try("ume-trunk", ...)`;
  - every recorded part and the returned bbox must fit inside `col ∩ safe` (clear of exclusions), and the records are replayed only if the trial commits.
- **Fallback.** If `ume` raises, returns nil, records nothing, or paints any part outside `col ∩ safe` / over an exclusion, the built-in tree is drawn and a `# page=<n> demo: kacho-flora.ume ...` line is logged.
- **Forcing the built-in tree.** Set `kacho.demo_flora = false`. Tests use `kacho._set_flora(false | module | nil)`.
- **Built-in tree (spray with depth).** The tree has three kinds of limbs:
  - **Far limbs** use a lighter, greyer ink (`bark` mixed 50% with paper). They are drawn behind the trunk and cross it, and their blossoms are smaller and paler.
  - **Near limbs** are dark, with knots and a dry-brush texture. One sweeps across the crown.
  - **Twigs** steer smoothly away from margin boundaries, zig-zag, and some droop. Long tapered water shoots carry buds.

  Blossoms cluster at twig nodes (joints and tips), and some nodes stay bare. Every flower is trial-fitted. Petals are filled through a radial shading (light centre to deeper edge) with a clipped inner rim and no outline. Every flower also has stamens. Half-open side views and round buds have calyces.
- **Return value.** `kacho.demo_layout(ctx, page)` returns `{base={x,y}, ground=bbox, delegated=bool, blossoms={{x,y,r,node={x,y},kind,far},...}, limbs={{kind,far,bbox},...}}`. The engine ignores it; the tests use it.

### 4.1 Page table

| Field | Meaning |
|---|---|
| `index` | physical page, 1-based (= pdftoppm page number) |
| `folio` | `\count0` |
| `odd`, `twoside` | parity of the folio; whether the document is two-sided |
| `paper`, `paperrect` | `{w=,h=}`, and the same as a rect |
| `text`, `head`, `foot`, `typearea` | geometric boxes. `typearea` is head ∪ body ∪ foot. |
| `block` | the rect kept clear: `typearea` on body pages, the title box on title pages, or the measured text-ink union on `shikishi` pages |
| `ink` | list of all measured ink rects on the page (glyph runs, rules, glue leaders, bounded graphics) in bp |
| `exclude` | the list described for `ctx.exclude` |
| `safe`, `buffer` | the safe box, and the buffer in bp |
| `outer`, `inner` | `"left"`/`"right"`. Two-sided: odd pages have outer = right. One-sided: outer is the wider margin. |
| `regions` | name → largest free rect: `outer inner top bottom left right top_outer top_inner bottom_outer bottom_inner`. Bands thinner than 8 mm are omitted. |
| `region_list` | every free piece, with `.name` |
| `bands` | the same bands before measured-ink subtraction. Use them with `fits`. |
| `opts` | effective options (document < `\kachosetup` < `\kachoThisPage` < title keys) |
| `title` | `nil`, or `{rect=, layout=}` on a `\kachoTitlePage` page |
| `user` | `{spawns = {...}, sprays = {{keys=, rect=}, ...}}` collected from `\kachoSpawn` and `\kachospray` |
| `seed` | page seed |

## 5. TeX user API

### 5.1 Package options and `\kachosetup{<keys>}`

| Key | Values (default) | Meaning |
|---|---|---|
| `seed` | integer (1) | document seed |
| `palette` | `sumi`, `hanga` (sumi) | colour preset |
| `theme` | `haru`, `natsu`, `aki`, `fuyu`, `shochikubai` (haru) | motif set / season (used by M3) |
| `layout` | `auto`, `none`, `demo`, M3 names (`corner-spray`, `margin-column`, `header-garland`, `footer-ground`, `scattered-petals`, `kakejiku`, `shikishi`, `hashira`, `fukinuki`, `sote`) (auto) | page layout; an unknown name falls back to `demo` with one warning |
| `motif` | `auto` or motif name(s) (`auto`) | explicit motif override for layouts and `\kachoTitlePage` |
| `regions` | `auto`, `none`, or comma-separated region list (`auto`) | restrict which margin regions may be decorated |
| `spawn` | spawn spec string (`""`) | per-page margin spawn specification |
| `density` | 0..1 (0.5) | amount of decoration |
| `ground` | `none`, `washi`, `kinu`, `torinoko`, `koson` (none) | subtle full-page paper tone (kind `ground`) |
| `seal`, `birds` | true/false (true) | allow a hanko or birds (M2/M3) |
| `safe` | dimen (5mm, minimum 5mm) | paper-edge safe zone |
| `buffer` | dimen (4mm, minimum 4mm) | gap around the type area |
| `debug` | flag | write `<jobname>.kacho.log` (section 6) |
| `off` | flag | draw nothing at all |

- An unknown key is an error: `Unknown option 'x' for package kacho`. A bad value (including in `\usepackage[...]{kacho}`) is a `Package kacho Error`.
- Environment overrides beat document options:
  - `KACHO_SEED=<n>`
  - `KACHO_DEBUG=1`
  - `KACHO_OFF=1`
- `\kachosetup` in the preamble applies immediately. After `\begin{document}` it inserts a marker and applies **from the page that contains it onward**. Allowed keys there are the per-page keys: `seed palette theme layout motif regions spawn density ground seal birds off`.

### 5.2 Page and placement commands

These are whatsit markers, resolved at shipout.

- `\kachoOff`: disables all kacho output (including the `ground` paper tint) on the page that contains it and on any following page until `\kachoOn`, leaving the page completely untouched.
- `\kachoOn`: decoration resumes on the page that contains it. If both are on one page, the last one wins.
- `\kachoThisPage{<keys>}`: overrides for this page only. It takes the per-page keys, including bare `off`. Example: `\kachoThisPage{layout=shikishi, motif=ume, seed=11}`.
- `\kachoSpawn{<keys>}`: requests an explicit margin motif spawn on the current page (passed to `kacho-layout.user` in `page.user.spawns`).
- `\kachospray[<keys>]`: typesets a reserved vertical box (`width` default `\linewidth`, `height` default `38mm`) carrying a `spray:` marker so `kacho-layout.user` can paint an inline spray inside a `figure` (e.g. above a `\caption`) without overlapping surrounding text.
- Tip: place page marker commands inside a paragraph or right after `\clearpage`. In vertical mode between paragraphs, a marker adds a legal break point.

### 5.3 `\kachoTitlePage[<keys>]{<keys | plain title>}`

`\kachoTitlePage` starts a new page with `\thispagestyle{empty}` and typesets the title block at the top-left of the text area.

- **Title keys:** `title`, `subtitle`, `author`, `date`, `width` (0.62\textwidth), `pos` (`tl` | `tr` | `c`).
- **Per-page keys:** `layout` (default `kakejiku`), `motif`, `seed`, `palette`, `theme`, `density`, `ground`.
- **Plain argument:** if the argument contains no `=`, it is taken as the title text.
- **Measurement and clearance:** the title box is measured at shipout through a marker inside it. On that page `exclude` is the title box (plus measured ink) inflated by the buffer, so the rest of the page is free for art. The log's `textblock=` is the title box.
- **End:** the command finishes with `\clearpage`.
- **Status:** M1 ships the typesetting and geometry stub, and falls back to `demo` until M3 registers `kakejiku`.

## 6. Debug log (`debug` option or `KACHO_DEBUG=1`)

The file is `<output-directory>/<jobname>.kacho.log`, using `status.output_directory`. It is truncated at start, line-buffered, and closed in `enddocument/afterlastpage`. Numbers are `%.2f` bp.

```
# kacho <version> job=<jobname> seed=<s> palette=<p> theme=<t> layout=<l> density=<d> off=<bool>
# page=<n> folio=<f> layout=<name> outer=<left|right> safe=<x0> <y0> <x1> <y1> ground=<g> seed=<s>
# page=<n> region=<name> rect=<x0> <y0> <x1> <y1>
page=<n> elem=<kind> bbox=<x0> <y0> <x1> <y1> textblock=<x0> <y0> <x1> <y1>
# WARN page=<n> elem=<kind> <reason>
# ERROR page=<n> layout=<name> <message>
# page=<n> off            (or: # page=<n> off (option))
# done pages=<n> decorated=<n>
```

- Element lines match exactly `^page=(\d+) elem=(\S+) bbox=(\S+) (\S+) (\S+) (\S+) textblock=(\S+) (\S+) (\S+) (\S+)$`. All other lines start with `#`.
- `page` is the physical index. `textblock` is the type area on body pages, the title box on title pages, and the measured text-ink union on `shikishi` pages.
- **Kinds:**
  - `trunk`, `culm`, `stem`, `vine` (tokens) are bleed kinds.
  - `ground` (any kind containing the token `ground`, e.g. `ground`, `kakejiku-ground`, `shikishi-ground`) is exempt from overlap and edge checks.
  - `inline` (any kind containing the token `inline`) is exempt from the page text-block exclusion check (it is checked against neighbouring text lines/captions by `kacho-layout.user`).
  - The M1 demo uses `demo-earth`, `demo-trunk`, `demo-branch`, `demo-twig`, `demo-blossom` and `demo-bud`. `demo-mist` was removed in iteration 2. When the demo delegates to `kacho-flora`, the motif's own kinds (`ume-*`) appear instead of the tree kinds.
- **Checks:** the engine checks each `record` against the exclusions, the safe box, and `bleed`. It writes `# WARN` lines and a TeX warning.

## 7. `off`

`\usepackage[off]{kacho}` (or `KACHO_OFF=1`) still parses every option and still runs every command, but the shipout hook draws nothing and registers no PDF resources.

Typesetting is identical to the decorated build, because decoration never takes up space.

## 8. Build

- `make` builds `examples/*.tex` into `build/` with plain `lualatex`, up to 3 passes. latexmk is not used because it misses edits to `require`d Lua modules.
- The Makefile:
  - prepends `~/.TinyTeX/bin/x86_64-linux` to `PATH` when that directory exists;
  - exports `TEXINPUTS` and `LUAINPUTS` as `$(CURDIR)/tex//:`;
  - sets `SOURCE_DATE_EPOCH` and `FORCE_SOURCE_DATE=1` so PDFs are reproducible.
- Other targets:

  | Target | Action |
  |---|---|
  | `make view` | opens the PDF with `$VIEWER`, macOS `open`, or `xdg-open` (after an `xdpyinfo` probe); when headless, renders PNGs and prints their paths |
  | `make render` | renders every page to `build/png/` (`DPI=110`) |
  | `make test` | `unit` (texlua) + `e2e` |
  | `make e2e-quick` | runs the quick E2E subset |
  | `make clean` | removes the build output |

## 9. Design decisions (reconciling the explorer designs)

| Topic | Choice | Why |
|---|---|---|
| Hook and literal | kernel `shipout/background` + `\put(0,0)` + one `pdf_literal` **mode 1 (page)** per piece | m1_2 verified page-absolute bp. m1_1/m1_3 used `\put(0,-\paperheight)` + origin mode; both work, but mode 1 does not depend on the hook's current point. |
| RNG API | m1_1's closures (`u/range/sym/…`, `child`) + m1_3's names (`random/uniform/fork(tag)/next_u32`) | both explorer APIs are honoured; `child` gives order independence |
| Rects | named fields `{x0,y0,x1,y1}` | m1_3 / PROJECT.md. m1_2's positional prototype was converted. |
| Writer purity | `kacho-pdf` takes an injected backend | only `kacho.lua` touches TeX, so the writer is unit-testable with a fake backend |
| Paths | `{s, bbox}` objects | every primitive returns an honest bbox for the log and fit checks |
| Unknown option | error (kernel default) | m1_3/E2E. m1_2's prototype only warned. |
| Partial-page "tail" region | not offered | it lies inside the type area, which the log contract forbids |
| Washes | `band` + reworked `nijimi`; `soft` = rect under mask | user feedback 00:24:48Z, explorer_m2_3 P1/P2/P10–P12 |
| Safety clip | page art clipped to paper − (exclusions shrunk by buffer/2) | defence in depth; motifs are still growth-limited |
