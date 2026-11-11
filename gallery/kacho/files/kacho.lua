-- Copyright 2026 Allen Jue
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- ALGORITHMS & REFERENCES:
--   * LuaTeX node-list traversal (hlist/vlist/glyph/rule/glue-leaders/whatsit)
--     per the LuaTeX Reference Manual, ch. 8 ("Nodes") and ch. 10 ("PDF backend").
--   * Transparency group XObject packaging via tex.saveboxresource /
--     tex.useboxresource with /Group << /S /Transparency /I true /K false >>
--     (Adobe PDF Reference 1.7, sec. 7.5.5).
--   * Da Vinci's pipe model (sum of child cross-sections ~ parent cross-section,
--     Richter 1970, note 394) and boundary-deflected growth limiting for the
--     built-in fallback plum tree.
--
-- kacho.lua: entry point and TeX glue of the kacho package (LuaLaTeX only).
--
-- Responsibilities (the only kacho module that touches TeX/LuaTeX globals):
--   * options (package keys, \kachosetup, environment overrides KACHO_SEED /
--     KACHO_DEBUG / KACHO_OFF) and their validation;
--   * per-page markers (\kachoOff, \kachoOn, \kachoThisPage, post-preamble
--     \kachosetup, \kachoTitlePage, \kachoSpawn, \kachospray) carried as
--     user_defined whatsits;
--   * page geometry from TeX dimensions + measured ink from a walk of the
--     shipout box -> decoration regions (kacho-geom);
--   * the drawing context `ctx`, layout dispatch (optional kacho-layout module,
--     built-in "demo" and "none"), and emission of the page's PDF literal;
--   * the debug log <jobname>.kacho.log (see tex/API.md section 6).
--
-- All drawing modules (kacho-pdf, -brush, -wash, -palette, -rng, -geom) are pure
-- Lua; this file requires nothing from TeX at load time, so it can also be loaded
-- under texlua for unit tests of the pure parts (option parsing, demo layout).
local M = {}

M.VERSION = "0.1.0"

local rng_mod = require("kacho-rng")
local geom = require("kacho-geom")
local palette_mod = require("kacho-palette")
local pdfw = require("kacho-pdf")
local brush = require("kacho-brush")
local wash = require("kacho-wash")

local fmt, min, max, pi = string.format, math.min, math.max, math.pi

---------------------------------------------------------------- options
M.THEMES = { haru = true, natsu = true, aki = true, fuyu = true, shochikubai = true }
M.BLEED_KINDS = { trunk = true, culm = true, stem = true, vine = true }

M.defaults = {
  seed = 1, palette = "sumi", theme = "haru", layout = "auto", density = 0.5,
  ground = "none", seal = true, birds = true, safe = 5, buffer = 4,
  motif = "auto", regions = "auto", spawn = "",
  debug = false, off = false,
}
M.opts = {}
for k, v in pairs(M.defaults) do M.opts[k] = v end
M.env_lock = {}      -- keys fixed by environment variables

local function warn(msg)
  if texio and texio.write_nl then
    texio.write_nl("term and log", "Package kacho Warning: " .. msg)
    texio.write_nl("term and log", "")
  else
    io.stderr:write("kacho warning: " .. msg .. "\n")
  end
end
M.warn = warn

local function err(msg)
  if tex and tex.error and M.in_tex then tex.error("Package kacho Error: " .. msg)
  else error("kacho: " .. msg, 0) end
end

local function to_bool(v)
  if v == true or v == "true" or v == "" or v == nil then return true end
  if v == false or v == "false" then return false end
  return nil
end

--- Validate and convert one option value. Returns the converted value or raises.
--- `unit` = "sp" means safe/buffer were given as TeX dimensions in sp.
function M.check(key, value, unit)
  if key == "seed" then
    local n = tonumber(value)
    if not n or n ~= n then err("seed must be an integer, got '" .. tostring(value) .. "'"); return nil end
    return math.floor(n)
  elseif key == "palette" then
    value = tostring(value)
    if value ~= "sumi" and value ~= "hanga" then err("palette must be sumi or hanga, got '" .. value .. "'"); return nil end
    return value
  elseif key == "theme" then
    value = tostring(value)
    if not M.THEMES[value] then err("theme must be haru, natsu, aki, fuyu or shochikubai, got '" .. value .. "'"); return nil end
    return value
  elseif key == "layout" then
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" or not value:match("^[%w%-_]+$") then err("bad layout name '" .. value .. "'"); return nil end
    return value
  elseif key == "density" then
    local n = tonumber(value)
    if not n then err("density must be a number in 0..1, got '" .. tostring(value) .. "'"); return nil end
    return max(0, min(1, n))
  elseif key == "ground" then
    value = tostring(value)
    local ok = pcall(palette_mod.ground, value)
    if not ok then err("ground must be none, washi, kinu, torinoko or koson, got '" .. value .. "'"); return nil end
    return value
  elseif key == "seal" or key == "birds" or key == "debug" or key == "off" then
    local b = to_bool(value)
    if b == nil then err(key .. " must be true or false, got '" .. tostring(value) .. "'"); return nil end
    return b
  elseif key == "safe" or key == "buffer" then
    local n = tonumber(value)
    if not n then err(key .. " must be a dimension, got '" .. tostring(value) .. "'"); return nil end
    if unit == "sp" then n = geom.bp(n) / geom.MM end     -- -> mm
    if key == "buffer" and n < 4 then warn("buffer below 4mm raised to 4mm"); n = 4 end
    if key == "safe" and n < 5 then warn("safe below 5mm raised to 5mm"); n = 5 end
    return n
  elseif key == "motif" then
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" or not value:match("^[%w%-_,%s/+]+$") then err("bad motif spec '" .. value .. "'"); return nil end
    return value
  elseif key == "regions" then
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" or not value:match("^[%w%-_,%s]+$") then err("bad regions spec '" .. value .. "'"); return nil end
    return value
  elseif key == "spawn" then
    return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
  end
  err("unknown option '" .. tostring(key) .. "'")
  return nil
end

--- Set an option (from package options or \kachosetup in the preamble).
function M.set(key, value, unit)
  if M.env_lock[key] then return end
  local v = M.check(key, value, unit)
  if v ~= nil then M.opts[key] = v end
end

--- Apply environment overrides; they beat document options.
function M.apply_env(getenv)
  getenv = getenv or os.getenv
  local s = getenv("KACHO_SEED")
  if s and s ~= "" then
    local n = tonumber(s)
    if n then M.opts.seed = math.floor(n); M.env_lock.seed = true
    else warn("ignoring non-numeric KACHO_SEED='" .. s .. "'") end
  end
  if getenv("KACHO_DEBUG") == "1" then M.opts.debug = true; M.env_lock.debug = true end
  if getenv("KACHO_OFF") == "1" then M.opts.off = true; M.env_lock.off = true end
end

--- Parse "k=v, k2={v 2}, flag" into an ordered list of {key, value}.
function M.parse_keyvals(s)
  local out = {}
  s = s or ""
  local depth, cur, items = 0, {}, {}
  for ch in s:gmatch(".") do
    if ch == "{" then depth = depth + 1; cur[#cur + 1] = ch
    elseif ch == "}" then depth = depth - 1; cur[#cur + 1] = ch
    elseif ch == "," and depth == 0 then items[#items + 1] = table.concat(cur); cur = {}
    else cur[#cur + 1] = ch end
  end
  items[#items + 1] = table.concat(cur)
  local function strip(x)
    x = x:gsub("^%s+", ""):gsub("%s+$", "")
    local inner = x:match("^{(.*)}$")
    if inner then x = inner end
    return x
  end
  for _, it in ipairs(items) do
    local k, v = it:match("^%s*([^=]-)%s*=(.*)$")
    if k then out[#out + 1] = { strip(k), strip(v) }
    else
      local f = strip(it)
      if f ~= "" then out[#out + 1] = { f, "" } end
    end
  end
  return out
end

M.PAGE_KEYS = { seed = true, palette = true, theme = true, layout = true, density = true,
                ground = true, seal = true, birds = true, motif = true, regions = true,
                spawn = true, off = true }

--- Apply a key list to an options table (per-page or persistent setup).
function M.apply_keys(target, list, allowed)
  for _, kv in ipairs(list) do
    local k, v = kv[1], kv[2]
    if allowed and not allowed[k] then err("option '" .. k .. "' not allowed here")
    elseif not M.env_lock[k] then
      local cv = M.check(k, v)
      if cv ~= nil then target[k] = cv end
    end
  end
  return target
end

---------------------------------------------------------------- layouts
M.layouts = {}           -- name -> function(ctx, page)
M.layout_module = nil

function M.register_layout(name, fn) M.layouts[name] = fn end

local warned_layout = {}

--- Load the optional kacho-layout module (M3). Missing module -> demo fallback.
function M.load_layouts()
  if M.layout_module ~= nil then return M.layout_module end
  local ok, mod = pcall(require, "kacho-layout")
  if ok and type(mod) == "table" then
    M.layout_module = mod
    if type(mod.install) == "function" then mod.install(M) end
    if type(mod.layouts) == "table" then
      local names = {}
      for k in pairs(mod.layouts) do names[#names + 1] = k end
      table.sort(names)
      for _, k in ipairs(names) do if not M.layouts[k] then M.layouts[k] = mod.layouts[k] end end
    end
  else
    M.layout_module = false
    if not ok and not tostring(mod):find("module 'kacho%-layout' not found") then
      warn("kacho-layout failed to load: " .. tostring(mod))
    end
  end
  return M.layout_module
end

--- Resolve the layout function for a page. Returns name, fn (fn nil = none).
function M.resolve_layout(name, page, ctx)
  local mod = M.load_layouts()
  if (page and page.opts and page.opts.regions == "none") or name == "none" then return "none", nil end
  if name == "auto" then
    local chosen
    if mod and type(mod.auto) == "function" then chosen = mod.auto(page, ctx) end
    if chosen == "none" then return "none", nil end
    name = chosen or "demo"
  end
  local fn = M.layouts[name] or (type(mod) == "table" and ((mod.layouts and mod.layouts[name]) or (type(mod[name]) == "function" and mod[name])))
  if fn then return name, fn end
  if not warned_layout[name] then
    warned_layout[name] = true
    warn("layout '" .. name .. "' is not available yet; using the built-in demo layout")
  end
  return "demo", M.layouts.demo
end

---------------------------------------------------------------- context
-- Build the page-level drawing context.
function M.make_context(page, popts, writer, log)
  local P = palette_mod.get(popts.palette)
  local seed = rng_mod.page_seed(popts.seed, page.index)
  local under = pdfw.new(writer and writer.R or M.registry)
  local ctx = {
    pdf = writer, under = under, rng = rng_mod.new(seed), palette = P, brush = brush, wash = wash, geom = geom,
    region = geom.copy(page.safe), safe = page.safe, exclude = page.exclude,
    bleed = { left = true, right = true, top = true, bottom = true },
    depth = 0, density = popts.density, theme = popts.theme,
    season = (popts.theme == "shochikubai") and "fuyu" or popts.theme,
    seal = popts.seal, birds = popts.birds,
    page = page, opts = popts, records = {},
  }
  page.seed = seed
  local function has_tok(kind, tok)
    for t in tostring(kind):gmatch("[^%-_:%.]+") do if t == tok then return true end end
    return false
  end
  local function is_bleed(kind)
    for tok in tostring(kind):gmatch("[^%-_:%.]+") do if M.BLEED_KINDS[tok] then return true end end
    return false
  end
  local function is_ground(kind) return has_tok(kind, "ground") end
  local function is_inline(kind) return has_tok(kind, "inline") end
  ctx.is_bleed = is_bleed
  ctx.is_ground = is_ground
  ctx.is_inline = is_inline

  -- Check whether a bleed kind `rect` stays within `c.region`/`c.safe` except across
  -- paper edges listed in `c.bleed` (and never across opposite paper edges at once).
  local function bleed_ok(rect, c, check_reg)
    local reg = c.region or page.safe
    local sf = c.safe or page.safe
    local bl = c.bleed or {}
    local eps = 0.01
    local x0_out = (check_reg and rect.x0 < reg.x0 - eps) or (rect.x0 < sf.x0 - eps)
    local x1_out = (check_reg and rect.x1 > reg.x1 + eps) or (rect.x1 > sf.x1 + eps)
    local y0_out = (check_reg and rect.y0 < reg.y0 - eps) or (rect.y0 < sf.y0 - eps)
    local y1_out = (check_reg and rect.y1 > reg.y1 + eps) or (rect.y1 > sf.y1 + eps)
    if x0_out and (not bl.left or (check_reg and reg.x0 > sf.x0 + 0.5)) then return false end
    if x1_out and (not bl.right or (check_reg and reg.x1 < sf.x1 - 0.5)) then return false end
    if y0_out and (not bl.bottom or (check_reg and reg.y0 > sf.y0 + 0.5)) then return false end
    if y1_out and (not bl.top or (check_reg and reg.y1 < sf.y1 - 0.5)) then return false end
    if (x0_out and x1_out) or (y0_out and y1_out) then return false end
    return true
  end

  --- fits(rect, kind): true if rect may be painted for `kind` in context c.
  local function make_fits(c)
    return function(rect, kind)
      if not rect then return false end
      if kind and is_ground(kind) then return true end
      if not (c.inline or (kind and is_inline(kind))) and not geom.clear_of(rect, c.exclude) then return false end
      if kind and is_bleed(kind) then return bleed_ok(rect, c, true) end
      return geom.contains(c.region, rect, 0.01) and geom.contains(c.safe, rect, 0.01)
    end
  end
  ctx.fits = make_fits(ctx)

  --- Record one drawn element (debug log + self check). Returns rect.
  local function make_record(c)
    return function(kind, rect)
      if not rect then return nil end
      local r = { kind = kind, bbox = geom.copy(rect) }
      ctx.records[#ctx.records + 1] = r
      local problems = {}
      if not is_ground(kind) then
        if not (c.inline or is_inline(kind)) and not geom.clear_of(rect, page.exclude) then
          problems[#problems + 1] = "overlaps text exclusion"
        end
        if is_bleed(kind) then
          if not bleed_ok(rect, c, false) then problems[#problems + 1] = "outside safe zone" end
        elseif not geom.contains(page.safe, rect, 0.01) then
          problems[#problems + 1] = "outside safe zone"
        end
      end
      if log then
        log(fmt("page=%d elem=%s bbox=%s textblock=%s", page.index, kind, geom.fmt(rect), geom.fmt(page.block)))
        for _, p in ipairs(problems) do log(fmt("# WARN page=%d elem=%s %s", page.index, kind, p)) end
      end
      for _, p in ipairs(problems) do warn(fmt("page %d: %s %s", page.index, kind, p)) end
      return rect
    end
  end
  ctx.record = make_record(ctx)

  --- Trial fit (growth limiting): run fn(tc) where tc is a copy of context c
  --- drawing into a scratch writer and buffering tc.record calls; if every
  --- recorded part (or the returned bbox when nothing was recorded) fits in c,
  --- the drawing and its records are committed and the bbox returned, else nil.
  function ctx.try(c, kind, fn)
    local scratch = c.pdf:sub()
    scratch.cur = c.pdf.cur
    local tc = {}
    for k, v in pairs(c) do tc[k] = v end
    tc.pdf = scratch
    local recs = {}
    tc._trial_records = recs
    tc.record = function(k, r)
      if r then recs[#recs + 1] = { k, geom.copy(r) } end
      return r
    end
    local bb = fn(tc)
    if not bb then return nil end
    if #recs > 0 then
      for _, rr in ipairs(recs) do
        local k, r = rr[1], rr[2]
        if not is_ground(k) and not c.fits(r, k) then return nil end
      end
    else
      if not (kind and is_ground(kind)) and not c.fits(bb, kind) then return nil end
    end
    c.pdf:merge(scratch)
    for _, rr in ipairs(recs) do c.record(rr[1], rr[2]) end
    return bb
  end

  --- Shallow copy with overrides; `tag` derives an order-independent child RNG.
  function ctx.sub(self, t)
    if t == nil then t = self; self = ctx end
    local c = {}
    for k, v in pairs(self) do c[k] = v end
    for k, v in pairs(t or {}) do c[k] = v end
    c.rng = self.rng.child(t and t.tag or "sub")
    c.fits = make_fits(c)
    c.record = make_record(c)
    return c
  end
  return ctx
end

---------------------------------------------------------------- demo layout
-- PLACEHOLDER / DEMO MOTIF (M1): proves the pipeline end to end until the M2
-- motif library and M3 layouts land (they replace it via kacho-layout). A plum
-- tree in the outer margin:
--   * a grassy bank centred under the trunk base: a low irregular hump with a
--     bokashi fill fading upward into the paper, granulation, layered grass
--     blades in several greens behind and in front of the trunk, pebbles,
--     small flowers and moss tufts; roots and root crown tucked into it;
--   * a two-tone dry-brush trunk with brush-pressure variation, knots and moss;
--   * a spray with depth: lighter far limbs behind the trunk, dark near limbs
--     in front, crossing limbs, zig-zag and drooping twigs, water shoots;
--   * blossoms in small clusters AT the twig nodes (joints and tips): filled,
--     softly graded petals (light centre -> deeper edge, no outline), stamens,
--     half-open side views and round buds, overlapping each other and the twig;
--     some nodes stay bare (ma).
-- When the M2 module kacho-flora is present and provides `ume`, the tree itself
-- is delegated to flora.ume (M.demo_flora = false forces the built-in tree);
-- the ground bank and the front grass stay here. Every part is growth-limited to
-- the region (no clipping, no bleed).

M.demo_flora = true

local flora_mod
local function load_flora()
  if flora_mod == nil then
    local ok, m = pcall(require, "kacho-flora")
    flora_mod = (ok and type(m) == "table" and type(m.ume) == "function") and m or false
  end
  return flora_mod
end
--- Test hook: forget (or inject) the cached kacho-flora module.
function M._set_flora(m) flora_mod = m end

-- petal colours (centre, body, edge, rim) for white or pink plum
local function petal_colors(P, white)
  local mix = palette_mod.mix
  local hanga = P.name == "hanga"
  if white then
    local g = P.color("gofun")
    return g, g, mix(g, P.color("sakura-pale"), 0.55), mix(P.color("sakura-pale"), P.color("sumi-light"), 0.45)
  end
  local pale, momo = P.color("sakura-pale"), P.color("momo")
  if hanga then
    return mix(P.color("gofun"), pale, 0.5), pale, mix(pale, momo, 0.6), momo
  end
  return mix(P.color("gofun"), pale, 0.6), mix(pale, momo, 0.45), momo, mix(momo, P.color("beni"), 0.5)
end

-- inner rim darkening of one petal (pigment pooled at the drying edge): two
-- strokes graded wide/faint -> narrow/stronger, clipped to the petal
local function petal_rim(W, path, c, r, a)
  W:clip(path)
  W:stroke(path, c, r * 0.22, a * 0.45)
  W:stroke(path, c, r * 0.09, a)
  W:unclip()
end

-- one blossom: kind = "open" | "side" | "bud"; white = white plum (else pink).
-- rot = facing direction (side views and buds open away from the twig).
-- far = on a background branch: paler (aerial perspective), drawn behind the
-- near branches.
local function demo_blossom(ctx, x, y, r, rot, kind, white, far)
  local W, P, rng = ctx.pdf, ctx.palette, ctx.rng
  local hanga = P.name == "hanga"
  local cos, sin = math.cos, math.sin
  local c_mid, c_body, c_edge, c_rim = petal_colors(P, white)
  local calyx_c = hanga and P.color("matsuba") or palette_mod.mix(P.color("sumi-dark"), P.color("ume-centre"), 0.45)
  if far then
    local paper = P.paper or P.color("washi")
    local function fade(c) return palette_mod.mix(c, paper, 0.38) end
    c_mid, c_body, c_edge, c_rim, calyx_c = fade(c_mid), fade(c_body), fade(c_edge), fade(c_rim), fade(calyx_c)
  end
  local bb
  W:layer(far and 17 or 40)
  if kind == "bud" then
    local rb = r * 0.42
    local deep = white and palette_mod.mix(c_edge, P.color("momo"), 0.35) or palette_mod.mix(c_rim, P.color("beni"), 0.4)
    local light = white and P.color("gofun") or c_body
    -- highlight toward the upper left, deeper pigment on the far side
    local hx, hy = x - rb * 0.35, y + rb * 0.35
    local pat = W:radial(hx, hy, 0, rb * 1.45, { { 0, light }, { 0.55, white and light or c_edge }, { 1, deep } })
    local bud = W:ellipse(x, y, rb, rb * 0.88, rot)
    bb = W:fill_pattern(bud, pat, far and 0.72 or 0.95)
    if white then petal_rim(W, bud, c_rim, rb, 0.55) end
    -- calyx on the twig side
    local cs = {}
    for k = -1, 1 do
      local a = rot + pi + k * 0.6
      cs[#cs + 1] = W:ellipse(x + cos(a) * rb * 0.8, y + sin(a) * rb * 0.8, max(0.35, rb * 0.3), max(0.25, rb * 0.2), a)
    end
    bb = brush.union(bb, W:fill(W:join(cs), calyx_c, 0.8))
    return bb
  end
  local petals = {}
  local n, spread, dist, a0 = 5, 2 * pi / 5, 0.5, rot + rng.range(0, 2 * pi / 5)
  local cx, cy = x, y
  if kind == "side" then
    -- half-open cup seen from the side: three petals fanned toward `rot`
    n, spread, dist, a0 = 3, 0.85, 0.36, rot - 0.85
    cx, cy = x - cos(rot) * r * 0.18, y - sin(rot) * r * 0.18
  end
  local outer = 0
  for i = 0, n - 1 do
    local a = a0 + i * spread + rng.sym(0.14)
    local pr = r * 0.47 * rng.range(0.88, 1.08)
    local d = dist * r * rng.range(0.92, 1.06)
    local px, py = cx + d * cos(a), cy + d * sin(a)
    -- rounded petal, slightly longer radially
    petals[#petals + 1] = W:ellipse(px, py, pr * rng.range(1.0, 1.1), pr * rng.range(0.86, 0.98), a)
    outer = max(outer, d + pr * 1.1)
  end
  -- softly graded fill: light centre -> body -> slightly deeper edge
  local pat = W:radial(cx, cy, 0, outer, { { 0, c_mid }, { 0.42, c_mid }, { 0.78, c_body }, { 1, c_edge } })
  bb = W:fill_pattern(W:join(petals), pat, far and 0.7 or (white and 0.96 or 0.93))
  -- each petal's own rim gives petal separation without an outline
  for _, p in ipairs(petals) do petal_rim(W, p, c_rim, r * 0.5, white and 0.5 or 0.25) end
  -- stamens: fine lines with yellow anther dots, a red-brown heart
  local ns = kind == "side" and 6 or rng.int(9, 13)
  local lines, tips = {}, {}
  for _ = 1, ns do
    local a = (kind == "side") and (rot + rng.sym(0.55)) or rng.range(0, 2 * pi)
    local l = r * rng.range(0.32, 0.5) * (kind == "side" and 1.25 or 1)
    local ex, ey = cx + cos(a) * l, cy + sin(a) * l
    lines[#lines + 1] = W:poly({ { cx, cy }, { ex, ey } }, false)
    tips[#tips + 1] = W:circle(ex, ey, max(0.26, r * 0.05))
  end
  W:stroke(W:join(lines), palette_mod.mix(P.color("ume-centre"), P.color("sumi-mid"), 0.5), max(0.16, r * 0.025), 0.7)
  bb = brush.union(bb, W:fill(W:join(tips), P.color(hanga and "yamabuki" or "kigaki"), 0.95))
  if kind ~= "side" then W:fill(W:circle(cx, cy, r * 0.11), P.color("ume-centre"), 0.7) end
  if kind == "side" then
    -- calyx cupping the petals on the twig side
    local cs = {}
    for k = -1, 1 do
      local a = rot + pi + k * 0.6
      cs[#cs + 1] = W:ellipse(cx + cos(a) * r * 0.24, cy + sin(a) * r * 0.24, max(0.35, r * 0.12), max(0.25, r * 0.08), a)
    end
    bb = brush.union(bb, W:fill(W:join(cs), calyx_c, 0.75))
  end
  return bb
end

--- Built-in M1 demo layout. Returns an info table (used by tests):
--- { base = {x, y} trunk foot, ground = bbox of the ground bank,
---   delegated = true if kacho-flora.ume drew the tree, blossoms = list of
---   {x, y, r, node = {x, y}, kind, far} for the built-in tree,
---   limbs = list of {kind, far, bbox} }.
function M.demo_layout(ctx, page)
  local R = page.regions or {}
  -- the whole outer band; measured protrusions (page.exclude) are avoided by fits()
  local col = (page.bands and page.bands.outer) or R.outer
  local mm = geom.MM
  if not col or geom.width(col) < 10 * mm or geom.height(col) < 60 * mm then
    if ctx.log then ctx.log(fmt("# page=%d demo skipped: outer margin too small", page.index)) end
    return
  end
  local rng = ctx.rng.child("demo")
  local W, P = ctx.pdf, ctx.palette
  local hanga = P.name == "hanga"
  local mix = palette_mod.mix
  local paper = P.paper
  local sub = ctx:sub({ region = col, tag = "demo", bleed = {} })
  sub.rng = rng
  local info = { blossoms = {}, limbs = {} }
  local cw, chh = geom.width(col), geom.height(col)
  local inward = (page.outer == "right") and -1 or 1          -- toward the text
  local w0 = max(4.5, min(12, cw * 0.15))
  local br = max(3.5, min(7.6, cw * 0.09))                     -- blossom radius
  local white = (not hanga) and rng.chance(0.55)               -- white or pink plum
  local bark = P.color(hanga and "kuri" or "sumi-mid")
  local bark_far = mix(bark, paper, 0.5)                       -- background ink: lighter, greyer
  local twigc = P.color(hanga and "kuri" or "sumi-dark")
  -- greens for the bank and grass, light -> dark
  local greens = hanga and { P.color("moegi"), P.color("wakatake"), P.color("matsuba"), mix(P.color("matsuba"), P.color("sumi-dark"), 0.35) }
    or { mix(P.color("koke"), paper, 0.3), P.color("koke"), mix(P.color("koke"), P.color("sumi-mid"), 0.5), P.color("sumi-mid") }
  -- keep branch points inside the column with room for blossoms (growth limiting)
  local px0, px1 = col.x0 + br * 1.35, col.x1 - br * 1.35
  local py1 = col.y1 - br * 1.35
  local function clampp(x, y) return { max(px0, min(px1, x)), min(py1, y) } end

  -- 1. ground: a soft grassy bank centred on the trunk base. Its contour is a
  -- low irregular hump; the fill is a bokashi (deeper green below fading
  -- upward into the paper) under a feathered mask, with granulation; grass
  -- blades in several greens grow from it, behind and in front of the trunk.
  local gh = min(52, max(25, cw * 0.58))                       -- bank height
  local base_x = col.x0 + cw * (0.5 - inward * rng.range(0.0, 0.06))
  local gw = max(w0 * 2.45, min(cw * 0.5, base_x - col.x0 - 1, col.x1 - 1 - base_x))     -- half width
  local yb = col.y0 + 1.5                                      -- bank bottom (dissolves)
  local crest_x = base_x + rng.sym(gw * 0.12)
  local cnoise = rng.noise(3)
  local cph = rng.range(0, 50)
  local function contour(x, k)                                 -- contour height at x (scale k)
    local half = (x < crest_x) and (crest_x - (base_x - gw * k)) or ((base_x + gw * k) - crest_x)
    local t = max(-1, min(1, (x - crest_x) / max(1, half)))
    local hump = (1 - t * t) ^ 0.7
    return yb + gh * (0.22 + 0.6 * hump) + gh * 0.06 * cnoise(x / 9 + cph)
  end
  local y_crest = contour(base_x, 1)
  local y_foot = y_crest - gh * 0.26                           -- foot sits in the bank, below the crest
  local y_base = y_foot
  info.base = { base_x, y_base }
  local fl_real = M.demo_flora and load_flora()
  if fl_real and type(fl_real.wisteria) == "function" then
    local ok_l, lay = pcall(require, "kacho-layout")
    if ok_l and lay and type(lay.demo_garden) == "function" then
      local n0 = #ctx.records
      lay.demo_garden(ctx, page)
      if #ctx.records > n0 then
        info.delegated = true
        info.ground = ctx.records[#ctx.records].bbox
        if ctx.log then ctx.log(fmt("# page=%d demo garden drawn by kacho-layout", page.index)) end
        return info
      end
    end
    local dc = sub:sub({ tag = "demo-flora", bleed = {} })
    local oy = col.y0 + chh * 0.22
    local is_r = (page.outer == "right")
    for _, sc in ipairs({ 1.0, 0.88, 0.76, 0.65, 0.55 }) do
      local spec = {
        x = base_x,
        y = oy,
        angle = pi / 2 + (is_r and -0.06 or 0.06),
        counter_angle = -pi / 2 + (is_r and 0.16 or -0.16),
        size = chh * (0.78 + 0.16 * ctx.density) * sc,
        density = ctx.density,
        variant = white and "white" or "pink",
        region = col,
      }
      local ok, bb = pcall(dc.try, dc, "ume-trunk", function(tc)
        local res = fl_real.ume(tc, spec)
        if not res or #tc._trial_records == 0 then return nil end
        return res
      end)
      if ok and bb then
        info.delegated = true
        info.ground = bb
        if ctx.log then ctx.log(fmt("# page=%d demo tree drawn by kacho-flora.ume", page.index)) end
        return info
      end
    end
  end

  local ground
  for _, k in ipairs({ 1, 0.82, 0.66 }) do
    ground = sub:try("demo-earth", function(tc)
      local TW = tc.pdf
      TW:layer(10)
      local rx, ry = gw * k * 0.42, gh * 0.28
      local pb = wash.blob(rng, base_x, y_foot, rx, ry, 0.18, 16, rng.sym(0.2))
      local b = TW:fill(TW:smooth(pb, true), mix(P.color("sumi-light"), paper, 0.62), 0.22)
      wash.rim(tc, pb, { rgb = P.color("sumi-mid"), strength = 0.08, width = 0.55, partial = true })
      return b
    end)
    if ground then info.k = k; break end
  end
  if ground then ctx.record("demo-earth", ground); info.ground = ground end
  local gk = info.k or 0.66

  local function front_grass()
    local fg = sub:try("demo-earth", function(tc)
      local TW = tc.pdf
      TW:layer(26)
      local b
      for _ = 1, 2 do
        local x = base_x + (rng.chance(0.5) and 1 or -1) * gw * gk * rng.range(0.18, 0.36)
        local y = y_foot + rng.sym(gh * 0.08)
        local s = rng.range(1.6, 2.4)
        local pb = wash.blob(rng, x, y, s * 1.3, s * 0.8, 0.22, 14, rng.sym(0.3))
        b = brush.union(b, TW:fill(TW:smooth(pb, true), mix(P.color("sumi-light"), paper, 0.42), 0.45))
      end
      return b
    end)
    if fg then ctx.record("demo-earth", fg) end
  end

  -- 2. delegate the tree to the M2 motif library when it is available
  local fl = M.demo_flora and load_flora()
  if fl then
    local dc = sub:sub({ tag = "demo-flora", bleed = {} })
    local spec = { x = base_x, y = y_base, angle = pi / 2, size = (chh - gh) * (0.7 + 0.25 * ctx.density),
      density = ctx.density, variant = white and "white" or "pink", region = col }
    local reason
    local ok, bb = pcall(dc.try, dc, "ume-trunk", function(tc)
      local res = fl.ume(tc, spec)
      if not res then reason = "drew nothing"; return nil end
      if #tc._trial_records == 0 then reason = "rejected (no records)"; return nil end
      if not dc.fits(res, "ume-trunk") then reason = "rejected (bbox outside region)"; return nil end
      return res
    end)
    if ok and bb then
      front_grass()
      info.delegated = true
      if ctx.log then ctx.log(fmt("# page=%d demo tree drawn by kacho-flora.ume", page.index)) end
      return info
    end
    if ctx.log then
      local msg = not ok and ("failed: " .. tostring(bb):gsub("%s+", " "))
        or (reason or "rejected (record outside region)")
      ctx.log(fmt("# page=%d demo: kacho-flora.ume %s; using the built-in tree", page.index, msg))
    end
  end

  -- 3. trunk: varied gesture (S-curve, diagonal leaning, or classical crooked)
  -- rising out of the bank; the first segment stays near-vertical so the foot
  -- sits at the bank centre.
  local gesture = ((page.index or 1) + math.floor(rng.u() * 3)) % 3 + 1
  local Ht = min(chh * (0.38 + 0.15 * ctx.density), 102 * mm)
  local y0t = y_foot - w0 * 0.3                                 -- foot tucked into the bank
  local pts = { { base_x, y0t } }
  local n = 4
  local zig = rng.chance(0.5) and 1 or -1
  for i = 1, n do
    local t = i / n
    zig = -zig
    local x
    if gesture == 1 then
      -- S-curve trunk: bows toward outer margin in mid-section, then curves inward
      local s_bow = math.sin(t * pi) * (-inward) * cw * 0.14 + inward * (t ^ 1.4) * cw * 0.16
      x = base_x + ((i == 1) and 0 or s_bow) + zig * cw * 0.04
    elseif gesture == 2 then
      -- Diagonal leaning trunk: leans steadily inward with crooked turns
      local amp = (i == 1) and rng.range(0.02, 0.04) or rng.range(0.06, 0.12)
      x = base_x + inward * (t ^ 1.15) * cw * 0.18 + zig * cw * amp
    else
      -- Crooked classical zig-zag trunk
      local amp = (i == 1) and rng.range(0.02, 0.05) or rng.range(0.09, 0.17)
      x = base_x + zig * cw * amp + inward * t * cw * 0.11
    end
    pts[#pts + 1] = clampp(max(col.x0 + w0, min(col.x1 - w0, x)), y0t + Ht * t)
  end
  local function tprof(u)       -- gently flared foot, thinning to 35% at the fork
    local flare = u < 0.08 and (1 + 0.25 * (1 - u / 0.08) ^ 2) or 1
    return flare * (1 - 0.65 * u)
  end
  local function trunk_w(u) return w0 * tprof(u) end
  -- gnarled knots where the trunk turns
  local function knots(list, wf, scale)
    local j = {}
    for i = 2, #list - 1 do
      j[#j + 1] = { list[i][1] + rng.sym(0.5), list[i][2] + rng.sym(0.5), wf(i) * scale * rng.range(0.85, 1.05) }
    end
    return j
  end
  local spine, S, tb
  for _ = 1, 5 do
    spine = brush.chain(pts, 0.7)
    local tj = knots(pts, function(i) return trunk_w((i - 1) / n) end, 0.44)
    tb = sub:try("demo-trunk", function(tc)
      -- solid ink body underneath (narrower than the dry-brush silhouette so it never bulges outside)
      tc.pdf:layer(19)
      local b = brush.stroke(tc, spine, { w = w0 * 0.76, profile = tprof, rgb = bark, alpha = 0.35, jitter = 0.02 })
      tc.pdf:layer(20)
      return brush.union(b, brush.dry(tc, spine, { w = w0, profile = tprof, pressure = 0.3, pfreq = 3,
        rgb = bark, alpha = 0.85, dryness = 0.4, bristles = 8, under = 0.48, joints = tj }))
    end)
    if tb then break end
    for i = 2, #pts do pts[i][2] = y0t + (pts[i][2] - y0t) * 0.8 end
  end
  if not tb then front_grass(); return info end
  S = brush.spine(spine)
  -- roots: tapered buttress strokes that flare smoothly from the lower trunk into
  -- the grassy bank (no flat dark root-crown ellipse; front grass tucks over them)
  local roots = sub:try("demo-trunk", function(tc)
    tc.pdf:layer(20)
    local b
    for k = 1, 4 do
      local side = (k <= 2) and ((k == 1) and -1 or 1) or ((k == 3) and -1 or 1)
      local u0 = (k <= 2) and 0.06 or 0.03
      local fx, fy = brush.at(S, u0)
      local reach = w0 * ((k <= 2) and rng.range(0.75, 1.15) or rng.range(0.45, 0.7))
      local sx, sy = fx + side * trunk_w(u0) * 0.25, fy
      local ex = max(col.x0 + 2, min(col.x1 - 2, base_x + side * (trunk_w(0) * 0.4 + reach)))
      local ey = y_foot - gh * rng.range(0.06, 0.13)
      local mx, my = sx + (ex - sx) * 0.42, sy - (sy - ey) * 0.65
      local seg = brush.chain({ { sx, sy }, { mx, my }, { ex, ey } }, 0.55)
      b = brush.union(b, brush.stroke(tc, seg, { w = w0 * rng.range(0.36, 0.48), profile = "taper", rgb = bark,
        alpha = 0.78, jitter = 0.04 }))
    end
    return b
  end)
  if roots then tb = brush.union(tb, roots) end
  -- darker ink along one flank (two-tone sumi-e bark)
  local side = rng.chance(0.5) and 1 or -1
  local fl_pts = {}
  for i = 1, #S, max(1, #S // 14) do
    local p = S[i]
    if p.u > 0.06 and p.u < 0.85 then
      local off = side * trunk_w(p.u) * 0.28
      fl_pts[#fl_pts + 1] = { p.x - p.ty * off, p.y + p.tx * off }
    end
  end
  if #fl_pts >= 3 then
    W:layer(22)
    tb = brush.union(tb, brush.dry(sub, brush.chain(fl_pts, 0.7), { w = w0 * 0.42, profile = "both", pressure = 0.4,
      rgb = P.color(hanga and "sumi-dark" or "sumi-noir"), alpha = 0.8, dryness = 0.55, bristles = 5, under = 0.15 }))
  end
  -- moss dots (ten) along the bark
  local dots = {}
  for _ = 1, 4 + math.floor(ctx.density * 6) do
    local u = rng.range(0.15, 0.9)
    local x, y, tx, ty = brush.at(S, u)
    local off = (rng.chance(0.5) and 1 or -1) * trunk_w(u) * rng.range(0.35, 0.55)
    dots[#dots + 1] = W:ellipse(x - ty * off, y + tx * off, w0 * rng.range(0.08, 0.13), w0 * rng.range(0.05, 0.08), rng.range(0, pi))
  end
  W:layer(23)
  tb = brush.union(tb, W:fill(W:join(dots), P.color(hanga and "matsuba" or "sumi-noir"), 0.9))
  ctx.record("demo-trunk", tb)
  front_grass()

  -- 4. the spray. Near limbs are dark and drawn over the trunk; far limbs are
  -- lighter, greyer and drawn behind it, so branches cross in front of and
  -- behind each other. Twigs zig-zag, some droop, long straight water shoots
  -- (a hallmark of ume) rise through the crown, and blossoms cluster at the
  -- nodes, overlapping each other and their twigs.
  -- flowers are kept as circles {x, y, r}: inside a cluster they may overlap
  -- (centres >= 0.5 (r1 + r2) apart); clusters may touch but not pile up
  local placed = {}
  local function crowded(list, x, y, r, k)
    for _, q in ipairs(list) do
      local dx, dy = q[1] - x, q[2] - y
      if dx * dx + dy * dy < (k * (q[3] + r)) ^ 2 then return true end
    end
    return false
  end
  -- place one flower if it fits; mine = this cluster's circles
  local function put(x, y, r, kind, rot, node, mine, far)
    local rr = kind == "bud" and r * 0.5 or r
    local probe = { x0 = x - rr * 1.05, y0 = y - rr * 1.05, x1 = x + rr * 1.05, y1 = y + rr * 1.05 }
    if not sub.fits(probe, "demo-blossom") or crowded(placed, x, y, rr, 0.5) or crowded(mine, x, y, rr, 0.5) then
      return false
    end
    -- the probe is only a quick reject: the drawn flower itself must fit
    local kd = kind == "bud" and "demo-bud" or "demo-blossom"
    local bb = sub:try(kd, function(tc) return demo_blossom(tc, x, y, r, rot, kind, white, far) end)
    if not bb then return false end
    mine[#mine + 1] = { x, y, rr }
    ctx.record(kd, bb)
    info.blossoms[#info.blossoms + 1] = { x = x, y = y, r = r, node = { node[1], node[2] }, kind = kind, far = far }
    return true
  end
  -- a cluster at twig node (x, y) with twig direction (tx, ty)
  local function cluster(x, y, tx, ty, tip, far)
    local mine = {}
    local nx, ny = -ty, tx                          -- twig normal
    local s = rng.chance(0.5) and 1 or -1
    local r0 = br * rng.range(0.9, 1.15) * (far and 0.85 or 1)
    local count = 1 + rng.int(1, 2 + math.floor(ctx.density * 3))
    -- main flower sits on the node, overlapping the twig
    local first = tip and (rng.chance(0.6) and "open" or "side") or (rng.chance(0.75) and "open" or "side")
    local off = r0 * rng.range(0.1, 0.35) * s
    local fx, fy = x + nx * off, y + ny * off
    local ok = put(fx, fy, r0, first, math.atan(ny * s, nx * s), { x, y }, mine, far)
    if not ok then
      -- no room for an open flower here: a bud still marks the node
      put(x + nx * br * 0.25 * s, y + ny * br * 0.25 * s, br * 0.8, "bud", math.atan(ny * s, nx * s), { x, y }, mine, far)
      for _, p in ipairs(mine) do placed[#placed + 1] = p end
      return
    end
    for _ = 2, count do
      s = -s
      local kind = rng.u()
      kind = kind < 0.4 and "bud" or (kind < 0.7 and "side" or "open")
      local r = ((kind == "bud") and br * rng.range(0.75, 0.95) or br * rng.range(0.7, 0.95)) * (far and 0.85 or 1)
      -- around the node: across the twig, or a little along it
      -- (offsets scale with the flower's own radius, so it always overlaps the node)
      local along = rng.sym(0.9) * r
      local across = s * r * ((kind == "bud") and rng.range(0.3, 0.6) or rng.range(0.55, 0.85))
      local bx, by = x + tx * along + nx * across, y + ty * along + ny * across
      put(bx, by, r, kind, math.atan(by - y, bx - x), { x, y }, mine, far)
    end
    for _, p in ipairs(mine) do placed[#placed + 1] = p end
  end

  -- Steer step (x, y) along heading `a` by distance `l` so the branch turns
  -- smoothly away from column walls [px0, px1] x [py0, py1] instead of clamping
  -- into orthogonal staple/wire segments along the wall.
  local py0 = col.y0 + gh * 0.45
  local function steer_step(x, y, a, l)
    local margin = br * 2.2
    if x - px0 < margin and math.cos(a) < 0.15 then
      a = a + (math.sin(a) >= 0 and -1 or 1) * rng.range(0.38, 0.68)
    elseif px1 - x < margin and math.cos(a) > -0.15 then
      a = a + (math.sin(a) >= 0 and 1 or -1) * rng.range(0.38, 0.68)
    end
    if py1 - y < margin and math.sin(a) > 0 then
      local turn = (x > (px0 + px1) * 0.5) and 1 or -1
      a = math.atan(math.sin(a) * 0.35, math.cos(a)) + turn * 0.25
    end
    local ca, sa = math.cos(a), math.sin(a)
    local max_l = l
    if ca > 1e-4 then max_l = min(max_l, max(0, (px1 - x) * 0.86) / ca)
    elseif ca < -1e-4 then max_l = min(max_l, max(0, (x - px0) * 0.86) / (-ca)) end
    if sa > 1e-4 then max_l = min(max_l, max(0, (py1 - y) * 0.86) / sa)
    elseif sa < -1e-4 then max_l = min(max_l, max(0, (y - py0) * 0.86) / (-sa)) end
    l = max(1.8, min(l, max_l))
    local nx = max(px0, min(px1, x + ca * l))
    local ny = max(py0, min(py1, y + sa * l))
    return nx, ny, a
  end

  -- build a zig-zag chain from parent spine S at u, heading `ang`, total length L;
  -- droop > 0 bends the later segments downward (weeping twig)
  local function limb_points(parentS, u, ang, L, nseg, droop)
    local x, y, tx, ty = brush.at(parentS, u)
    local p = { { x, y } }
    -- first point continues partly along the parent (flow), then turns
    local a = math.atan(ty, tx) * 0.45 + ang * 0.55
    if math.abs(a - ang) > pi then a = ang end
    local z = rng.chance(0.5) and 1 or -1
    for i = 1, nseg do
      local l = L / nseg * rng.range(0.8, 1.2)
      x, y, a = steer_step(x, y, a, l)
      p[#p + 1] = { x, y }
      z = -z
      a = a + z * rng.range(0.24, 0.44)              -- organic alternate turns
      if droop and droop > 0 then
        -- arc over and hang: turn toward straight down on the side the twig
        -- already leans to (never swing back across the top)
        local an = math.atan(math.sin(a), math.cos(a))             -- (-pi, pi]
        local down = (math.cos(an) < 0) and (3 * pi / 2) or (-pi / 2)
        if down > 0 and an < 0 then an = an + 2 * pi end
        a = an + (down - an) * min(1, droop * i / nseg)
      end
    end
    return p
  end
  local function node_dir(lp, i)
    local a, b = lp[max(1, i - 1)], lp[min(#lp, i + 1)]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1e-6 then return 0, 1 end
    return dx / l, dy / l
  end
  local function grow(parentS, u, ang, L, wbase, depth, far, droop)
    for _, scale in ipairs({ 1, 0.75, 0.55 }) do
      local lp = limb_points(parentS, u, ang, L * scale, depth == 1 and 3 or 2, droop)
      local segs = brush.chain(lp, 0.45)
      local kind = depth == 1 and "demo-branch" or "demo-twig"
      local ink = far and bark_far or (depth == 1 and bark or twigc)
      local tip_floor = (depth == 1) and 0.28 or max(0.40, 0.52 / max(1, wbase))
      local lprof = function(t)
        local w = 1 - (1 - tip_floor) * t
        if t > 0.96 then w = w * math.sqrt(max(0, 1 - ((t - 0.96) / 0.04) ^ 2)) end
        return w
      end
      local jt = depth == 1 and knots(lp, function(i) return wbase * (1 - 0.72 * (i - 1) / (#lp - 1)) end, 0.48) or nil
      local done = sub:try(kind, function(tc)
        tc.pdf:layer(far and 15 or 21)
        local b = brush.stroke(tc, segs, { w = wbase, profile = lprof, pressure = 0.2,
          rgb = ink, alpha = far and 0.78 or 0.9, jitter = 0.04, joints = jt })
        if depth == 1 and not far then
          -- dry-brush texture on near limbs
          tc.pdf:layer(22)
          b = brush.union(b, brush.dry(tc, segs, { w = wbase * 0.8, profile = lprof,
            rgb = P.color(hanga and "sumi-dark" or "sumi-noir"), alpha = 0.5, dryness = 0.55, bristles = 4, under = 0 }))
        end
        return b
      end)
      if done then
        ctx.record(kind, done)      -- one record per limb/twig: exact, not a union
        info.limbs[#info.limbs + 1] = { kind = kind, far = far or false, bbox = done }
        local bS = brush.spine(segs)
        if depth == 1 then
          for k, tu in ipairs({ 0.35, 0.6, 0.82 }) do
            if k < 3 or rng.chance(0.4 + 0.4 * ctx.density) then
              local _, _, ltx, lty = brush.at(bS, tu)
              local la = math.atan(lty, ltx)
              local s2 = (k % 2 == 0) and 1 or -1
              local dr = rng.chance(0.3) and rng.range(0.5, 0.9) or nil
              grow(bS, tu, la + s2 * rng.range(0.5, 0.95), L * scale * rng.range(0.35, 0.55),
                max(1.25, wbase * (1 - 0.72 * tu) * 0.68), 2, far, dr)
            end
          end
        end
        -- clusters at the joints (some left bare) and always at the tip
        for i = 2, #lp do
          local tip = (i == #lp)
          if tip or rng.chance(0.4 + 0.35 * ctx.density) then
            local tx, ty = node_dir(lp, i)
            cluster(lp[i][1], lp[i][2], tx, ty, tip, far)
          end
        end
        return bS, lp
      end
    end
    return nil
  end
  -- water shoot: a long, nearly straight tapered shoot rising from a limb, with
  -- buds alternating along it
  local function shoot(parentS, u, L, far)
    local x, y = brush.at(parentS, u)
    local a = pi / 2 + rng.sym(0.22)
    local ex, ey = steer_step(x, y, a, L)
    local e = { ex, ey }
    local lp = { { x, y }, { (x + e[1]) / 2 + rng.sym(1.0), (y + e[2]) / 2 }, e }
    local segs = brush.chain(lp, 0.3)
    local done = sub:try("demo-twig", function(tc)
      tc.pdf:layer(far and 15 or 21)
      return brush.stroke(tc, segs, { w = 1.65, profile = "taper", rgb = far and bark_far or twigc, alpha = 0.85, jitter = 0.03 })
    end)
    if not done then return end
    ctx.record("demo-twig", done)
    info.limbs[#info.limbs + 1] = { kind = "demo-twig", far = far or false, bbox = done }
    local sS = brush.spine(segs)
    local nb = rng.int(2, 4)
    for k = 1, nb do
      local uu = (k + 0.2) / (nb + 0.6)
      local bx, by, tx, ty = brush.at(sS, uu)
      local sd = (k % 2 == 0) and 1 or -1
      local mine = {}
      put(bx - ty * sd * br * 0.25, by + tx * sd * br * 0.25, br * 0.8, "bud", math.atan(tx * sd, -ty * sd), { bx, by }, mine, far)
      for _, p in ipairs(mine) do placed[#placed + 1] = p end
    end
    local tx, ty = node_dir(lp, #lp)
    cluster(e[1], e[2], tx, ty, true, far)
  end

  local up = pi / 2
  local Lmax = min(chh * 0.34, 74 * mm)
  local wtop = trunk_w(1)
  -- far limbs first (behind): they leave the trunk and cross it toward the
  -- other side, so the near limbs and the trunk pass in front of them
  for i = 1, 1 + (ctx.density >= 0.4 and 1 or 0) do
    local u = 0.5 + 0.22 * (i - 1) + rng.sym(0.05)
    local s = (i % 2 == 1) and -inward or inward
    grow(S, u, up + s * rng.range(0.55, 0.95), Lmax * rng.range(0.55, 0.8), trunk_w(u) * 0.48, 1, true)
  end
  -- the trunk forks at its top into two near limbs (obeying the pipe model:
  -- 0.78^2 + 0.58^2 < 1), plus side limbs lower down; one side limb sweeps
  -- across or overhangs the crown
  local a1 = grow(S, 1, up + inward * rng.range(0.18, 0.45), Lmax * rng.range(0.8, 1.0), wtop * 0.78, 1,
    false, (gesture == 2) and 0.45 or nil)
  local a2 = grow(S, 0.97, up - inward * rng.range(0.25, 0.52), Lmax * rng.range(0.5, 0.72), wtop * 0.58, 1)
  local nside = 1 + (ctx.density >= 0.5 and 1 or 0)
  for i = 1, nside do
    local u = 0.55 + 0.2 * (i - 1) + rng.sym(0.05)
    local s = (i % 2 == 1) and inward or -inward
    local cross = (i == 1)
    local ang = cross and (up - s * rng.range(0.12, 0.35)) or (up + s * rng.range(0.55, 0.85))
    grow(S, u, ang, Lmax * rng.range(0.45, 0.65), trunk_w(u) * 0.5, 1, false, (not cross and rng.chance(0.4)) and 0.6 or nil)
  end
  -- water shoots from the upper limbs
  for _, a in ipairs({ a1, a2 }) do
    if a and rng.chance(0.5 + 0.4 * ctx.density) then
      local u = rng.range(0.3, 0.6)
      local _, _, tx = brush.at(a, u)
      if math.abs(tx) > 0.35 then shoot(a, u, Lmax * rng.range(0.35, 0.55), false) end
    end
  end
  return info
end

M.layouts.demo = M.demo_layout

---------------------------------------------------------------- TeX side
M.in_tex = false
M.state = { on = true, index = 0, persistent = {}, title_pending = nil, pages = 0, decorated = 0 }
local logf
local MARK_ID = 0x4B4143   -- 'KAC'

local function log(line)
  if logf then logf:write(line, "\n") end
end
M.log = log

--- Called once from kacho.sty after options are processed.
function M.init()
  M.in_tex = true
  M.apply_env()
  if M.opts.debug then
    local dir = status and status.output_directory
    if not dir or dir == "" then dir = os.getenv("TEXMF_OUTPUT_DIRECTORY") end
    local name = tex.jobname .. ".kacho.log"
    if dir and dir ~= "" then name = dir .. "/" .. name end
    logf = io.open(name, "w")
    if logf then
      logf:setvbuf("line")
      log(fmt("# kacho %s job=%s seed=%d palette=%s theme=%s layout=%s density=%.2f off=%s",
        M.VERSION, tex.jobname, M.opts.seed, M.opts.palette, M.opts.theme, M.opts.layout, M.opts.density,
        tostring(M.opts.off)))
    else
      warn("cannot open debug log " .. name)
    end
  end
  local backend = {
    extgs = function(name, dict)
      tex.sprint(luatexbase.registernumber("catcodetable@atletter"),
        "\\pgfutil@addpdfresource@extgs{/" .. name .. " << " .. dict .. " >>}")
    end,
    pattern = function(name, objnum)
      tex.sprint(luatexbase.registernumber("catcodetable@atletter"),
        "\\pgfutil@addpdfresource@patterns{/" .. name .. "\\space " .. objnum .. " 0 R}")
    end,
    obj = function(dict) return pdf.immediateobj(dict) end,
    stream = function(dict, data) return pdf.immediateobj("stream", data, dict) end,
  }
  M.registry = pdfw.registry(backend)
end

--- Insert a marker whatsit at the current position (travels with the content).
function M.mark(value)
  local n = node.new("whatsit", "user_defined")
  n.user_id = MARK_ID
  n.type = 115
  n.value = value
  node.write(n)
end

---------------------------------------------------------------- shipout box walk
local SP2BP = 1 / geom.SP_PER_BP
local RUNNING = -1073741824

local function walker()
  local GLYPH, HLIST, VLIST, RULE, GLUE, KERN, WHATSIT, DISC, MATH =
    node.id("glyph"), node.id("hlist"), node.id("vlist"), node.id("rule"),
    node.id("glue"), node.id("kern"), node.id("whatsit"), node.id("disc"), node.id("math")
  local USERDEF = node.subtype("user_defined")
  local LITERAL = node.subtype("pdf_literal")
  local SAVE = node.subtype("pdf_save")
  local st = {}
  local walk_v
  local function opaque(st_, box, x, y)   -- graphics in a box: treat the whole box as ink
    st_.graphics[#st_.graphics + 1] = { x, y - box.depth, x + box.width, y + box.height }
  end
  local function marker(st_, n, box, x, y)
    st_.marks[#st_.marks + 1] = n.value
    if n.value == "titlebox" then
      st_.titlebox = { x, y - box.depth, x + box.width, y + box.height }
    elseif n.value:sub(1, 6) == "spray:" then
      st_.sprays[#st_.sprays + 1] = {
        keys = n.value:sub(7),
        rect = { x, y - box.depth, x + box.width, y + box.height },
      }
    end
  end
  local function walk_h(box, x, y, s)
    local cx = x
    local gx0, gy0, gx1, gy1
    local gfx = false
    for n in node.traverse(box.head) do
      local id = n.id
      if id == GLYPH then
        local yy = y - (n.yoffset or 0)
        local x0 = cx + (n.xoffset or 0)
        local x1 = x0 + n.width
        gx0 = gx0 and min(gx0, x0) or x0; gx1 = gx1 and max(gx1, x1) or x1
        gy0 = gy0 and min(gy0, yy - n.depth) or yy - n.depth; gy1 = gy1 and max(gy1, yy + n.height) or yy + n.height
        cx = cx + n.width
      elseif id == HLIST or id == VLIST then
        local sy = y - n.shift
        if n.head then
          if id == HLIST then walk_h(n, cx, sy, s) else walk_v(n, cx, sy, s) end
        end
        cx = cx + n.width
      elseif id == RULE then
        local h, dp = n.height, n.depth
        if h == RUNNING then h = box.height end
        if dp == RUNNING then dp = box.depth end
        if n.width > 0 and h + dp > 0 then s.ink[#s.ink + 1] = { cx, y - dp, cx + n.width, y + h } end
        cx = cx + n.width
      elseif id == GLUE then
        local gw = node.effective_glue(n, box)
        if n.leader and gw > 0 then
          local lh = (n.leader.height and n.leader.height > 0) and n.leader.height or box.height
          local ld = (n.leader.depth and n.leader.depth > 0) and n.leader.depth or box.depth
          if lh + ld > 0 then s.ink[#s.ink + 1] = { cx, y - ld, cx + gw, y + lh } end
        end
        cx = cx + gw
      elseif id == KERN then
        cx = cx + n.kern
      elseif id == DISC then
        if n.replace then for r in node.traverse(n.replace) do if r.width then cx = cx + r.width end end end
      elseif id == MATH then
        cx = cx + (n.surround or 0) + (n.width or 0)
      elseif id == WHATSIT then
        if n.subtype == USERDEF and n.user_id == MARK_ID then marker(s, n, box, x, y)
        elseif n.subtype == LITERAL or n.subtype == SAVE then gfx = true end
      end
    end
    if gx0 then s.ink[#s.ink + 1] = { gx0, gy0, gx1, gy1 } end
    if gfx then opaque(s, box, x, y) end
  end
  walk_v = function(box, x, y, s)
    local cy = y + box.height
    local gfx = false
    for n in node.traverse(box.head) do
      local id = n.id
      if id == HLIST or id == VLIST then
        local base = cy - n.height
        if n.head then
          if id == HLIST then walk_h(n, x + n.shift, base, s) else walk_v(n, x + n.shift, base, s) end
        end
        cy = base - n.depth
      elseif id == RULE then
        local w = n.width
        if w == RUNNING then w = box.width end
        if w > 0 and n.height + n.depth > 0 then s.ink[#s.ink + 1] = { x, cy - n.height - n.depth, x + w, cy } end
        cy = cy - n.height - n.depth
      elseif id == GLUE then
        local gh = node.effective_glue(n, box)
        if n.leader and gh > 0 then
          local lw = (n.leader.width and n.leader.width > 0) and n.leader.width or box.width
          if lw > 0 then s.ink[#s.ink + 1] = { x, cy - gh, x + lw, cy } end
        end
        cy = cy - gh
      elseif id == KERN then
        cy = cy - n.kern
      elseif id == WHATSIT then
        if n.subtype == USERDEF and n.user_id == MARK_ID then marker(s, n, box, x, y)
        elseif n.subtype == LITERAL or n.subtype == SAVE then gfx = true end
      end
    end
    if gfx then opaque(s, box, x, y) end
  end
  return walk_v
end
local walk_v_fn

local function tex_dims()
  local d = {}
  for _, k in ipairs({ "paperwidth", "paperheight", "oddsidemargin", "evensidemargin", "topmargin",
                       "headheight", "headsep", "textheight", "textwidth", "footskip" }) do
    d[k] = tex.dimen[k]
  end
  d.hoffset, d.voffset = tex.hoffset, tex.voffset
  d.baselineskip = tex.skip.baselineskip.width
  if tex.pagewidth and tex.pagewidth ~= 0 then d.paperwidth = tex.pagewidth end
  if tex.pageheight and tex.pageheight ~= 0 then d.paperheight = tex.pageheight end
  return d
end

local function lit_node(data, mode)
  local n = node.new("whatsit", "pdf_literal")
  n.mode = mode or 1      -- 1 = "page": absolute page coordinates, origin bottom-left
  n.data = data
  return n
end

-- Emit a transparency group as a Form XObject (box resource) placed at the page origin.
local function emit_group(piece, pw_sp, ph_sp)
  local inner = lit_node(piece.data, 0)
  local box = node.hpack(inner)
  box.width, box.height, box.depth = pw_sp, ph_sp, 0
  local res
  local eg = token.get_macro("pgf@sys@pdf@extgs@objnum")
  local pt = token.get_macro("pgf@sys@pdf@pattern@objnum")
  if eg and pt and eg ~= "" and pt ~= "" then
    res = fmt("/ExtGState %s 0 R /Pattern %s 0 R", eg, pt)
  else
    return false
  end
  local idx = tex.saveboxresource(box, "/Group << /S /Transparency /I true /K false >>", res, true)
  local use = tex.useboxresource(idx)
  local h = node.hpack(use)
  h.width, h.height, h.depth = 0, 0, 0
  h.shift = ph_sp            -- hook origin is the top-left corner: move the form's base to y = 0
  node.write(lit_node("q" .. (piece.gs and (" /" .. piece.gs .. " gs") or "")))
  node.write(h)
  node.write(lit_node("Q"))
  return true
end

-- Safety clip: the union of free rects = paper (+ bleed) minus every exclusion
-- shrunk by half the buffer. Motifs are growth-limited and should never reach
-- it; it only guarantees that no paint can ever land on the text itself.
local function safety_clip(page)
  local big = { x0 = -50, y0 = -50, x1 = page.paper.w + 50, y1 = page.paper.h + 50 }
  local xs = {}
  for i, x in ipairs(page.exclude) do xs[i] = geom.inflate(x, -page.buffer / 2) end
  local pieces = geom.subtract_all(big, xs)
  local t = {}
  for _, p in ipairs(pieces) do
    t[#t + 1] = fmt("%s %s %s %s re", pdfw.num(p.x0), pdfw.num(p.y0), pdfw.num(p.x1 - p.x0), pdfw.num(p.y1 - p.y0))
  end
  return table.concat(t, " ") .. " W n"
end

--- Shipout hook: called from \AddToHook{shipout/background}.
function M.shipout(boxnum, twoside)
  local st = M.state
  st.index = st.index + 1
  st.pages = st.pages + 1
  local index = st.index
  -- walk the page for markers and ink (also needed when off, for state tracking)
  walk_v_fn = walk_v_fn or walker()
  local s = { ink = {}, graphics = {}, marks = {}, sprays = {} }
  local box = tex.box[boxnum]
  local d = tex_dims()
  local ph_bp = geom.bp(d.paperheight)
  if box and box.head then
    walk_v_fn(box, 72 * geom.SP_PER_BP + tex.hoffset, (ph_bp - 72) * geom.SP_PER_BP - tex.voffset - box.height, s)
  end
  -- markers in page order
  local this_on = st.on
  local thisopts = {}
  local title
  local spawns = {}
  for _, m in ipairs(s.marks) do
    if m == "off" then st.on = false; this_on = false
    elseif m == "on" then st.on = true; this_on = true
    elseif m:sub(1, 5) == "page:" then M.apply_keys(thisopts, M.parse_keyvals(m:sub(6)), M.PAGE_KEYS)
    elseif m:sub(1, 6) == "setup:" then M.apply_keys(st.persistent, M.parse_keyvals(m:sub(7)), M.PAGE_KEYS)
    elseif m:sub(1, 6) == "title:" then title = M.parse_keyvals(m:sub(7))
    elseif m:sub(1, 6) == "spawn:" then spawns[#spawns + 1] = m:sub(7) end
  end
  if thisopts.off == true then this_on = false end
  if M.opts.off then
    log(fmt("# page=%d off (option)", index))
    return
  end
  if not this_on then
    log(fmt("# page=%d off", index))
    return
  end
  -- effective options: document < persistent setup < this page < title keys
  local popts = {}
  for k, v in pairs(M.opts) do popts[k] = v end
  for k, v in pairs(st.persistent) do popts[k] = v end
  for k, v in pairs(thisopts) do popts[k] = v end
  local title_layout
  if title then
    for _, kv in ipairs(title) do
      if kv[1] == "layout" then title_layout = M.check("layout", kv[2])
      elseif M.PAGE_KEYS[kv[1]] and kv[1] ~= "off" then popts[kv[1]] = M.check(kv[1], kv[2]) end
    end
  end
  if popts.spawn and popts.spawn ~= "" then spawns[#spawns + 1] = popts.spawn end
  local sprays = {}
  for _, sp in ipairs(s.sprays) do
    local r = sp.rect
    sprays[#sprays + 1] = {
      keys = sp.keys,
      rect = { x0 = r[1] * SP2BP, y0 = r[2] * SP2BP, x1 = r[3] * SP2BP, y1 = r[4] * SP2BP },
    }
  end
  -- geometry and regions
  local page = geom.page(d, { folio = tex.count[0], index = index, twoside = twoside,
                              safe_mm = popts.safe, buffer_mm = popts.buffer })
  local ink = {}
  for _, r in ipairs(s.ink) do ink[#ink + 1] = { x0 = r[1] * SP2BP, y0 = r[2] * SP2BP, x1 = r[3] * SP2BP, y1 = r[4] * SP2BP } end
  local paper_area = page.paper.w * page.paper.h
  for _, r in ipairs(s.graphics) do
    local g = { x0 = r[1] * SP2BP, y0 = r[2] * SP2BP, x1 = r[3] * SP2BP, y1 = r[4] * SP2BP }
    if geom.area(g) > 1 and geom.area(g) < 0.4 * paper_area then ink[#ink + 1] = g end
  end
  page.ink = ink
  local block = page.typearea
  if title and s.titlebox then
    local tb = s.titlebox
    block = { x0 = tb[1] * SP2BP, y0 = tb[2] * SP2BP, x1 = tb[3] * SP2BP, y1 = tb[4] * SP2BP }
    page.title = { rect = block, layout = title_layout or "kakejiku" }
  elseif not title and popts.layout == "shikishi" then
    local ib
    for _, r in ipairs(ink) do
      if geom.intersection(r, page.text) then ib = ib and geom.union(ib, r) or geom.copy(r) end
    end
    if ib then block = ib end
  end
  geom.regions(page, block, ink)
  page.opts = popts
  page.user = { spawns = spawns, sprays = sprays }
  -- draw
  local W = pdfw.new(M.registry)
  local ctx = M.make_context(page, popts, W, logf and log or nil)
  ctx.log = logf and log or nil
  local lname = title and (title_layout or "kakejiku") or popts.layout
  local name, fn = M.resolve_layout(lname, page, ctx)
  log(fmt("# page=%d folio=%s layout=%s outer=%s safe=%s ground=%s seed=%d", index, tostring(page.folio), name,
    page.outer, geom.fmt(page.safe), popts.ground, popts.seed))
  for _, r in ipairs(page.region_list) do
    log(fmt("# page=%d region=%s rect=%s", index, r.name, geom.fmt(r)))
  end
  -- optional full-page paper tint (kind "ground", exempt from overlap checks)
  -- (own writer: emitted before, and outside, the safety clip)
  local gname = palette_mod.ground(popts.ground)
  local Wg
  if gname then
    Wg = pdfw.new(M.registry)
    ctx.record("ground", Wg:fill(Wg:rect(0, 0, page.paper.w, page.paper.h), ctx.palette.color(gname), 1))
  end
  if fn then
    local ok, e = pcall(fn, ctx, page)
    if not ok then
      warn(fmt("layout '%s' failed on page %d: %s", name, index, tostring(e)))
      log(fmt("# ERROR page=%d layout=%s %s", index, name, tostring(e):gsub("\n", " ")))
      if M.opts.debug then err("layout '" .. name .. "' failed: " .. tostring(e)) end
      if Wg then
        node.write(lit_node("q\n" .. Wg:body() .. "\nQ"))
        st.decorated = st.decorated + 1
      end
      return
    end
  end
  if (#spawns > 0 or #sprays > 0) and M.layout_module and type(M.layout_module.user) == "function" then
    local ok, e = pcall(M.layout_module.user, ctx, page, page.user)
    if not ok then
      warn(fmt("user spawn/spray failed on page %d: %s", index, tostring(e)))
      log(fmt("# ERROR page=%d user %s", index, tostring(e):gsub("\n", " ")))
      if M.opts.debug then err("user spawn/spray failed: " .. tostring(e)) end
    end
  end
  local pw_sp, ph_sp = d.paperwidth, d.paperheight
  if Wg then node.write(lit_node("q\n" .. Wg:body() .. "\nQ")) end
  local Wu = ctx.under
  local has_u = Wu and not Wu:is_empty()
  if has_u then
    local ok_u, upieces = pcall(Wu.pieces, Wu)
    if ok_u then
      node.write(lit_node("q 1 J 1 j"))
      for _, p in ipairs(upieces) do
        if p.kind == "literal" then node.write(lit_node(p.data))
        elseif not emit_group(p, pw_sp, ph_sp) then
          node.write(lit_node("q " .. (p.gs and ("/" .. p.gs .. " gs\n") or "") .. p.data .. "\nQ"))
        end
      end
      node.write(lit_node("Q"))
    else
      warn("page " .. index .. " (under): " .. tostring(upieces))
      has_u = false
    end
  end
  if W:is_empty() then
    if Wg or has_u then st.decorated = st.decorated + 1 end
    return
  end
  local ok, pieces = pcall(W.pieces, W)
  if not ok then warn("page " .. index .. ": " .. tostring(pieces)); return end
  st.decorated = st.decorated + 1
  -- the ground tint and under-layer (above) are not clipped; everything else sits inside the safety clip
  node.write(lit_node("q 1 J 1 j " .. safety_clip(page)))
  for _, p in ipairs(pieces) do
    if p.kind == "literal" then node.write(lit_node(p.data))
    elseif not emit_group(p, pw_sp, ph_sp) then
      node.write(lit_node("q " .. (p.gs and ("/" .. p.gs .. " gs\n") or "") .. p.data .. "\nQ"))
    end
  end
  node.write(lit_node("Q"))
end

--- End of document (enddocument/afterlastpage): close the log, print a summary.
function M.finish()
  local st = M.state
  log(fmt("# done pages=%d decorated=%d", st.pages, st.decorated))
  if logf then logf:close(); logf = nil end
  if texio then
    texio.write_nl("log", fmt("kacho: %d page(s), %d decorated", st.pages, st.decorated))
  end
end

return M
