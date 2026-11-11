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
-- Portions of this file are adapted from florilegium
-- (https://github.com/kevinraymond/florilegium),
-- Copyright (c) 2026 Kevin Raymond, licensed under the MIT License.
-- See NOTICE.md for the full MIT License text and details of adapted portions.
--
-- kacho-layout.lua — Page composition archetypes, seasonal theme pools,
-- per-page variety deck, multi-scale free-disc garden packer, wispy secondary
-- sprays (cymes, umbels, sprigs, Euler-spiral tendrils, C^1 branch_path), and
-- user-controlled placement (\kachoSpawn, \kachospray, regions=, motif=, spawn=).
--
-- ALGORITHMS & REFERENCES:
--   * Adaptive Ornament Composition & Greedy Free-Disc Packing:
--     Inspired by Michael T. Wong, Douglas E. Zongker, and David H. Salesin,
--     "Computer-Generated Floral Ornament", Proceedings of SIGGRAPH 1998,
--     pp. 423-434 (1998), and adapted from Kevin Raymond, florilegium
--     (florilegium-grow.lua, florilegium-flora.lua, florilegium-layout.lua,
--     MIT License, 2026).
--   * Space-Colonization Envelopes & Pipe-Model Branching:
--     Inspired by Adam Runions, Brendan Lane, and Przemyslaw Prusinkiewicz,
--     "Modeling Trees with a Space Colonization Algorithm", EGWNP 2007, and
--     Kichiro Shinozaki et al., "The Pipe Model Theory", 1964.
--   * Multi-Glaze Watercolor & OKLCH Tone Ramps:
--     Inspired by Cassidy J. Curtis et al., "Computer-Generated Watercolor",
--     SIGGRAPH 1997, and Björn Ottosson, "A perceptual color space for image
--     processing" (OKLab/OKLCH, 2020).

local geom  = require("kacho-geom")
local rngm  = require("kacho-rng")
local palm  = require("kacho-palette")
local brush = require("kacho-brush")
local wash  = require("kacho-wash")
local INK   = require("kacho-ink")

local min, max, abs, pi, sin, cos, atan, floor, sqrt =
  math.min, math.max, math.abs, math.pi, math.sin, math.cos, math.atan, math.floor, math.sqrt
local fmt = string.format
local L = { layouts = {} }

local function warn_msg(msg)
  local ok, k = pcall(require, "kacho")
  if ok and k and type(k.warn) == "function" then
    k.warn(msg)
  elseif texio and texio.write_nl then
    texio.write_nl("term and log", "Package kacho Warning: " .. msg)
  end
end

---------------------------------------------------------------- themes
L.THEMES = {
  haru = {
    branch   = { "sakura", "ume", "wisteria" },
    column   = { "orchid", "bamboo" },
    garland  = "wisteria",
    ground   = { "orchid", "iris" },
    petals   = "sakura",
    bird     = "uguisu",
    variants = { "overhang", "corner-spray", "rising", "header-garland", "margin-column", "footer-ground" },
    stub     = { blossom = "sakura-pale", deep = "momo", leaf = "moegi", vine = "fuji", kind = "sakura" },
  },
  natsu = {
    branch   = { "bamboo", "wisteria" },
    column   = { "iris", "bamboo" },
    garland  = "wisteria",
    ground   = { "iris", "bamboo" },
    petals   = "bamboo",
    bird     = "uguisu",
    variants = { "margin-column", "overhang", "footer-ground", "header-garland", "rising", "corner-spray" },
    stub     = { blossom = "fuji-pale", deep = "fuji", leaf = "wakatake", vine = "fuji", kind = "iris" },
  },
  aki = {
    branch   = { "maple", "osmanthus" },
    column   = { "chrysanthemum", "maple" },
    garland  = "maple",
    ground   = { "chrysanthemum", "osmanthus" },
    petals   = "maple",
    bird     = "mejiro",
    variants = { "overhang", "corner-spray", "rising", "footer-ground", "header-garland", "margin-column" },
    stub     = { blossom = "momiji", deep = "bengara", leaf = "kigaki", vine = "kuri", kind = "maple" },
  },
  fuyu = {
    branch   = { "ume", "camellia" },
    column   = { "bamboo", "narcissus" },
    garland  = "ume",
    ground   = { "narcissus", "camellia" },
    petals   = "ume",
    bird     = "sparrow",
    variants = { "overhang", "rising", "margin-column", "corner-spray", "footer-ground", "header-garland" },
    stub     = { blossom = "gofun", deep = "beni", leaf = "matsuba", vine = "sumi-mid", kind = "ume" },
  },
  shochikubai = {
    branch   = { "pine", "ume" },
    column   = { "pine", "bamboo" },
    garland  = "pine",
    ground   = { "pine", "ume" },
    petals   = "ume",
    bird     = "uguisu",
    variants = { "overhang", "corner-spray", "rising", "margin-column", "footer-ground", "header-garland" },
    stub     = { blossom = "gofun", deep = "beni", leaf = "matsuba", vine = "matsuba", kind = "pine" },
  },
}

local function theme_of(ctx)
  local key = (ctx and (ctx.theme or ctx.season)) or "haru"
  return L.THEMES[key] or L.THEMES.haru, key
end

local MOTIF_ALIASES = {
  ume = "ume", plum = "ume", sakura = "sakura", cherry = "sakura",
  bamboo = "bamboo", take = "bamboo", orchid = "orchid", ran = "orchid", shunran = "orchid",
  maple = "maple", momiji = "maple", wisteria = "wisteria",
  iris = "iris", ayame = "iris", kakitsubata = "iris",
  pine = "pine", matsu = "pine", camellia = "camellia", tsubaki = "camellia",
  osmanthus = "osmanthus", kinmokusei = "osmanthus",
  narcissus = "narcissus", suisen = "narcissus",
  chrysanthemum = "chrysanthemum", kiku = "chrysanthemum",
  bird = "bird", uguisu = "uguisu", robin = "robin", sparrow = "sparrow",
  suzume = "sparrow", mejiro = "mejiro", swallow = "swallow", tsubame = "swallow",
  rock = "rock", fuji = "fuji", seal = "seal", hanko = "seal",
  wash = "wash", kasumi = "wash", bokashi = "wash",
}

local BIRD_MOTIFS = {
  bird = true, uguisu = true, robin = true, sparrow = true, mejiro = true, swallow = true,
}

function L.parse_motifs(raw, do_warn)
  if not raw or raw == "" or raw == "auto" then return nil end
  local s = tostring(raw):gsub("^%s*{", ""):gsub("}%s*$", "")
  local out = {}
  for tok in s:gmatch("[^,%s;]+") do
    local k = tok:lower()
    if k ~= "auto" then
      local m = MOTIF_ALIASES[k]
      if m then out[#out + 1] = m
      elseif do_warn then warn_msg("unknown motif '" .. tok .. "'; falling back to theme default") end
    end
  end
  return (#out > 0) and out or nil
end

local function page_motifs(page)
  local raw = page and page.opts and (page.opts.motif or page.opts.motifs)
  if not raw or raw == "" then return nil end
  if page._parsed_motifs == nil then
    page._parsed_motifs = L.parse_motifs(raw, true) or false
  end
  return page._parsed_motifs or nil
end

---------------------------------------------------------------- helpers & Plan
local function is_tok(kind, set)
  for tok in tostring(kind):gmatch("[^%-_:%.]+") do if set[tok] then return true end end
  return false
end
local BLEED = { trunk = true, culm = true, stem = true, vine = true }
local GROUND = { ground = true }
local function angdiff(a, b) local d = (a - b) % (2 * pi); if d > pi then d = d - 2 * pi end; return d end
local function col(ctx, name) local P = ctx.palette; return P.has(name) and P.color(name) or P.role("blossom") end

local Plan = {}; Plan.__index = Plan
function L.plan(ctx, page)
  return setmetatable({ ctx = ctx, page = page, occ = {}, flower_occ = {}, gap = 4, n = 0 }, Plan)
end
function Plan:excl(interleave, ignore_flowers)
  local t = {}
  for _, e in ipairs(self.page.exclude) do t[#t + 1] = e end
  if ignore_flowers then
    return t
  elseif interleave then
    for _, o in ipairs(self.flower_occ) do t[#t + 1] = o end
  else
    for _, o in ipairs(self.occ) do t[#t + 1] = o end
  end
  return t
end
function Plan:log(s) if self.ctx.log then self.ctx.log(fmt("# page=%d layout: %s", self.page.index, s)) end end

local FLOWER_TOK = { blossom = true, flower = true, raceme = true }

function Plan:attempt(tag, t, fn)
  t = t or {}; t.tag = t.tag or tag; t.exclude = self:excl(t.interleave, t.ignore_flowers)
  local base = self.ctx:sub(t)
  if t.writer then base.pdf = t.writer end
  local scratch = base.pdf:sub(); scratch.cur = base.pdf.cur
  local c = {}
  for k, v in pairs(base) do c[k] = v end
  c.pdf = scratch
  local recs = {}
  c.record = function(kind, rect) if rect then recs[#recs + 1] = { kind, geom.copy(rect) } end; return rect end
  local ok, bb, info = pcall(fn, c)
  if not ok then self:log("ERROR " .. tag .. ": " .. tostring(bb):gsub("\n", " ")); return nil end
  if not bb or #recs == 0 then self:log(tag .. " drew nothing"); return nil end
  local page, safe = self.page, self.page.safe
  for _, r in ipairs(recs) do
    local kind, rect = r[1], r[2]
    if not is_tok(kind, GROUND) then
      local why
      if t.inline then
        if not geom.clear_of(rect, c.exclude) then why = "inline-ink"
        elseif not geom.contains(c.region, rect, 0.01) then why = "inline-box" end
      elseif not geom.clear_of(rect, page.exclude) then why = "text"
      elseif not t.interleave and not geom.clear_of(rect, self.occ) then why = "occupied"
      elseif not is_tok(kind, BLEED) and not (geom.contains(safe, rect, 0.01) and geom.contains(c.region, rect, 0.01)) then why = "region" end
      if not why and t.max_dist and t.origin then
        local ox, oy = t.origin[1], t.origin[2]
        local function hyp(dx, dy) return sqrt(dx * dx + dy * dy) end
        local dmax = max(
          hyp(rect.x0 - ox, rect.y0 - oy), hyp(rect.x1 - ox, rect.y0 - oy),
          hyp(rect.x0 - ox, rect.y1 - oy), hyp(rect.x1 - ox, rect.y1 - oy)
        )
        if dmax > t.max_dist then why = "max_dist" end
      end
      if why then self:log(fmt("%s rejected (%s %s %s)", tag, kind, why, geom.fmt(rect))); return nil end
    end
  end
  base.pdf:merge(scratch)
  for _, r in ipairs(recs) do
    self.ctx.record(r[1], r[2])
    if not is_tok(r[1], GROUND) then
      if not t.interleave then
        self.occ[#self.occ + 1] = geom.inflate(r[2], self.gap)
      end
      if is_tok(r[1], FLOWER_TOK) then
        local rc = r[2]
        local dx, dy = (rc.x1 - rc.x0) * 0.22, (rc.y1 - rc.y0) * 0.22
        self.flower_occ[#self.flower_occ + 1] = { x0 = rc.x0 + dx, y0 = rc.y0 + dy, x1 = rc.x1 - dx, y1 = rc.y1 - dy }
      end
    end
  end
  self.n = self.n + 1
  self:log(fmt("%s committed parts=%d", tag, #recs))
  return bb, info or {}, recs
end

function Plan:fit(tag, t, spec, fn, scales)
  for i, s in ipairs(scales or { 1, 0.8, 0.64, 0.5, 0.38 }) do
    local sp = {}
    for k, v in pairs(spec) do sp[k] = v end
    sp.size = spec.size * s
    local tt = {}
    for k, v in pairs(t or {}) do tt[k] = v end
    local bb, info = self:attempt(tag .. "#" .. i, tt, function(c) return fn(c, sp) end)
    if bb then return bb, info end
  end
  return nil
end

local function raw_side_band(page, side)
  local sf = page.safe
  local blk = geom.inflate(page.block, page.buffer or 11.34)
  if side == "outer" then side = page.outer or "right" end
  if side == "inner" then side = (page.outer == "left") and "right" or "left" end
  local r
  if side == "top" then r = { x0 = sf.x0, y0 = max(sf.y0, blk.y1), x1 = sf.x1, y1 = sf.y1, name = "top" }
  elseif side == "bottom" then r = { x0 = sf.x0, y0 = sf.y0, x1 = sf.x1, y1 = min(sf.y1, blk.y0), name = "bottom" }
  elseif side == "left" then r = { x0 = sf.x0, y0 = sf.y0, x1 = min(sf.x1, blk.x0), y1 = sf.y1, name = "left" }
  elseif side == "right" then r = { x0 = max(sf.x0, blk.x1), y0 = sf.y0, x1 = sf.x1, y1 = sf.y1, name = "right" } end
  if r and geom.width(r) >= 8 and geom.height(r) >= 8 then return r end
  return nil
end

function L.zones(page)
  local B = page.bands or {}
  local O  = B.outer  or raw_side_band(page, "outer")
  local T  = B.top    or raw_side_band(page, "top")
  local Bo = B.bottom or raw_side_band(page, "bottom")
  local In = B.inner  or raw_side_band(page, "inner")
  local Lf = B.left   or raw_side_band(page, "left")
  local Rt = B.right  or raw_side_band(page, "right")
  local is_r = page.outer == "right"
  return {
    outer = O, top = T, bottom = Bo, inner = In, left = Lf, right = Rt,
    wO = O and geom.width(O) or 0, hT = T and geom.height(T) or 0, hB = Bo and geom.height(Bo) or 0,
    is_right = is_r, inward = is_r and -1 or 1,
  }
end
L.MIN = { column = 24, band = 22 }


---------------------------------------------------------------- 2D free-disc field (adapted from florilegium-grow.lua)
local function inside_one(r, x, y)
  return min(x - r.x0, r.x1 - x, y - r.y0, r.y1 - y)
end

local function bridge_rects(a, b, x, y)
  local ox0, ox1 = max(a.x0, b.x0), min(a.x1, b.x1)
  local oy0, oy1 = max(a.y0, b.y0), min(a.y1, b.y1)
  if ox1 <= ox0 or oy1 <= oy0 then return -1e9 end
  local ux0, ux1 = min(a.x0, b.x0), max(a.x1, b.x1)
  local uy0, uy1 = min(a.y0, b.y0), max(a.y1, b.y1)
  local dx = (x >= ox0 and x <= ox1) and min(x - ux0, ux1 - x) or min(x - ox0, ox1 - x)
  local dy = (y >= oy0 and y <= oy1) and min(y - uy0, uy1 - y) or min(y - oy0, oy1 - y)
  return min(dx, dy)
end

function L.field(rects, excl, safe)
  local placed = {}
  local function edge(x, y)
    local d = -1e9
    for i = 1, #rects do
      local r = rects[i]
      if r then
        d = max(d, inside_one(r, x, y))
        for j = i + 1, #rects do
          if rects[j] then d = max(d, bridge_rects(r, rects[j], x, y)) end
        end
      end
    end
    if safe then d = min(d, inside_one(safe, x, y)) end
    for _, e in ipairs(excl or {}) do
      local de = max(e.x0 - x, x - e.x1, e.y0 - y, y - e.y1) - 1.5
      if de < d then d = de end
    end
    return d
  end
  local function place(x, y, r, tag)
    placed[#placed + 1] = { x = x, y = y, r = r, tag = tag }
  end
  local function free_r(x, y, pad, ignore_stems)
    pad = pad or 0.8
    local r = edge(x, y) - 0.6
    if r <= 0 then return r end
    for _, c in ipairs(placed) do
      if not (ignore_stems and (c.tag == "stem" or c.tag == "branch" or c.tag == "twig")) then
        local d = sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2) - c.r - pad
        if d < r then r = d; if r <= 0 then return r end end
      end
    end
    return r
  end
  local function add_pts(pts, r, step, tag)
    step = step or max(2.2, r * 0.9)
    local n, lastx, lasty = #pts, nil, nil
    local out = {}
    for i, p in ipairs(pts) do
      if not lastx or (p[1] - lastx) ^ 2 + (p[2] - lasty) ^ 2 >= step * step then
        place(p[1], p[2], r, tag)
        lastx, lasty = p[1], p[2]
        local a, b = pts[max(1, i - 1)], pts[min(n, i + 1)]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local dl = sqrt(dx * dx + dy * dy); if dl < 1e-9 then dl = 1 end
        out[#out + 1] = { x = p[1], y = p[2], tx = dx / dl, ty = dy / dl, u = (i - 1) / max(1, n - 1) }
      end
    end
    return out
  end
  return { rects = rects, placed = placed, edge = edge, place = place, free_r = free_r, add_pts = add_pts }
end

---------------------------------------------------------------- painterly & wispy flora primitives (adapted from florilegium-flora.lua)
local W = {}
L.wispy = W

local function motif_style(c, mkind)
  local P = c.palette
  local mix = palm.mix
  mkind = mkind or theme_of(c).branch[1] or "sakura"
  local stem_c = mix(P.color("koke"), P.color("sumi-mid"), 0.36)
  local leaf_c = P.color("matsuba")
  local leaf_alt = P.color("moegi")
  local fl1, fl2, fl3 = P.color("sakura-pale"), P.color("momo"), P.color("gofun")
  local acc = P.color("yamabuki")
  local notch, petals, pointed = 0.05, 5, false
  if mkind == "sakura" then
    fl1, fl2, fl3 = mix(P.color("sakura-pale"), P.color("momo"), 0.38), P.color("momo"), P.color("gofun")
    notch, petals = 0.13, 5
  elseif mkind == "ume" then
    fl1, fl2, fl3 = P.color("beni"), P.color("gofun"), P.color("momo")
    notch, petals = 0, 5
  elseif mkind == "wisteria" then
    fl1, fl2, fl3 = P.color("fuji"), P.color("fuji-pale"), P.color("momo")
    notch, petals = 0.04, 5
  elseif mkind == "iris" then
    fl1, fl2, fl3 = P.color("fuji"), P.color("ai"), P.color("fuji-pale")
    leaf_c = P.color("wakatake"); petals, pointed = 6, true
  elseif mkind == "orchid" then
    fl1, fl2, fl3 = P.color("wakatake"), P.color("momo"), P.color("fuji-pale")
    leaf_c = P.color("matsuba"); petals, pointed = 6, true
  elseif mkind == "narcissus" then
    fl1, fl2, fl3 = P.color("gofun"), P.color("yamabuki"), P.color("sakura-pale")
    leaf_c = P.color("wakatake"); petals, pointed = 6, true
  elseif mkind == "maple" then
    fl1, fl2, fl3 = P.color("momiji"), P.color("shu"), P.color("yamabuki")
    leaf_c, leaf_alt = P.color("momiji"), P.color("yamabuki")
    stem_c = mix(P.color("kuri"), P.color("sumi-mid"), 0.45)
  elseif mkind == "chrysanthemum" or mkind == "osmanthus" then
    fl1, fl2, fl3 = P.color("yamabuki"), P.color("momo"), P.color("shu")
    leaf_c = P.color("koke"); petals, pointed = 8, true
  elseif mkind == "pine" then
    stem_c = mix(P.color("kuri"), P.color("sumi-dark"), 0.38)
    leaf_c = P.color("matsuba"); leaf_alt = P.color("koke")
    fl1, fl2, fl3 = P.color("matsuba"), P.color("koke"), P.color("wakatake")
    acc = P.color("kuri")
  elseif mkind == "camellia" then
    fl1, fl2, fl3 = P.color("beni"), P.color("gofun"), P.color("shu")
    leaf_c = P.color("matsuba"); notch, petals = 0, 5
  elseif mkind == "bamboo" then
    if P.name == "sumi" then
      stem_c = mix(P.color("sumi-dark"), P.color("koke"), 0.28)
      leaf_c = mix(P.color("sumi-dark"), P.color("koke"), 0.22)
      leaf_alt = mix(P.color("sumi-mid"), P.color("koke"), 0.38)
      fl1, fl2, fl3 = leaf_c, leaf_alt, P.color("sumi-mid")
      acc = P.color("sumi-dark")
    else
      stem_c, leaf_c, leaf_alt = P.color("wakatake"), P.color("matsuba"), P.color("wakatake")
      fl1, fl2, fl3 = P.color("matsuba"), P.color("wakatake"), P.color("koke")
      acc = P.color("matsuba")
    end
  end
  local organ_tag = (mkind == "pine" and "pine-needles")
    or (mkind == "maple" and "maple-leaf")
    or (mkind == "bamboo" and "bamboo-leaf")
    or (mkind == "wisteria" and "wisteria-raceme")
    or (mkind == "iris" and "iris-flower")
    or (mkind == "orchid" and "orchid-flower")
    or (mkind == "narcissus" and "narcissus-flower")
    or (mkind == "chrysanthemum" and "chrysanthemum-flower")
    or (mkind .. "-blossom")
  local stem_tag = (mkind == "bamboo" and "bamboo-culm")
    or (mkind == "wisteria" and "wisteria-vine")
    or (mkind .. "-branch")
  return {
    mkind = mkind, stem = stem_c, leaf = leaf_c, leaf_alt = leaf_alt,
    fl = { fl1, fl2, fl3 }, accent = acc, notch = notch, petals = petals, pointed = pointed,
    organ_tag = organ_tag, stem_tag = stem_tag, twig_tag = mkind .. "-twig", leaf_tag = mkind .. "-leaf",
  }
end

function W.floret(rng, s, o)
  o = o or {}
  local np = o.petals or 5
  local t0 = o.tone or rng.range(0.32, 0.54)
  INK.push(); INK.scale(s); INK.rotate(rng.range(0, 360))
  for k = 1, np do
    INK.push(); INK.rotate(k * 360 / np + rng.sym(8)); INK.translate(0, 0.14)
    local sp = function(v) return 0, v * 0.86 end
    local hw = function(v) return 0.30 * sin(pi * v ^ 0.65) end
    local sh = INK.blade(sp, 10, hw, hw)
    INK.smooth(sh, true); INK.fill(INK.tone(t0 + rng.sym(0.05)))
    INK.smooth(sh, true); INK.stroke(INK.tone(max(0.10, t0 - 0.18)), max(0.15, 0.014 * s), 0.24, true)
    INK.streak(sp, 5, 0.06, 0.01, INK.white, 0.48)
    INK.pop()
  end
  INK.circle(0, 0, 0.15); INK.fill(INK.accent(-0.10))
  INK.circle(0, 0.03, 0.08); INK.fill(INK.accent(0.35))
  INK.pop()
end

function W.cyme(rng, s, o)
  o = o or {}
  local curl = o.curl or (rng.chance(0.5) and 1 or -1) * rng.range(0.42, 0.68)
  local n = o.n or rng.int(5, 7)
  local st_rgb = o.stem_rgb or { 0.28, 0.42, 0.22 }
  INK.push(); INK.scale(s)
  local spine = INK.bezier3(0, 0, 0, 0.38, curl * 0.42, 0.76, curl, 1.0)
  local function tang(v)
    local x0, y0 = spine(max(0, v - 0.01)); local x1, y1 = spine(min(1, v + 0.01))
    local dx, dy = x1 - x0, y1 - y0; local L2 = sqrt(dx * dx + dy * dy) + 1e-9
    return dx / L2, dy / L2
  end
  INK.streak(spine, 18, 0.036, 0.011, st_rgb, 0.88)
  for i = 1, n do
    local v = 0.15 + 0.78 * (i - 0.5) / n
    local x0, y0 = spine(v)
    local tx, ty = tang(v)
    local side = (curl >= 0) and -1 or 1
    if i % 2 == 0 then side = -side * 0.68 end
    local ang = atan(ty, tx) + side * rng.range(0.55, 0.92)
    local ped = (0.24 - 0.10 * v) * rng.range(0.85, 1.15)
    local bx, by = x0 + cos(ang) * ped, y0 + sin(ang) * ped
    local pb = INK.bezier3(x0, y0, x0 + tx * ped * 0.35, y0 + ty * ped * 0.35, bx - cos(ang) * ped * 0.3, by - sin(ang) * ped * 0.3, bx, by)
    INK.smooth(INK.sample(pb, 5), false); INK.stroke(st_rgb, max(0.24, 0.010 * s), 0.78)
    INK.push(); INK.translate(bx, by); INK.rotate(ang * 180 / pi - 90)
    local bsz = 0.19 - 0.06 * v
    if i <= 2 and rng.chance(0.65) then W.floret(rng, bsz, { tone = o.tone })
    else INK.bud(rng, bsz, { tone = o.tone, sepal = st_rgb }) end
    INK.pop()
  end
  local tx, ty = tang(1)
  INK.push(); INK.translate(curl, 1.0); INK.rotate(atan(ty, tx) * 180 / pi - 90)
  INK.bud(rng, 0.13, { tone = o.tone, sepal = st_rgb })
  INK.pop()
  INK.pop()
end

function W.sprig(rng, s, o)
  o = o or {}
  local bend = rng.sym(0.22)
  local n = o.n or rng.int(5, 8)
  local st_rgb = o.stem_rgb or { 0.28, 0.42, 0.22 }
  INK.push(); INK.scale(s)
  local spine = function(v) return bend * v * v, v end
  INK.streak(spine, 16, 0.032, 0.010, st_rgb, 0.86)
  for i = 1, n do
    local v = 0.14 + 0.78 * (i - 0.5) / n
    local x0, y0 = spine(v)
    local side = (i % 2 == 0) and 1 or -1
    local a = (side * rng.range(32, 52) + bend * 25) * pi / 180
    local l = (0.28 - 0.12 * v) * rng.range(0.85, 1.15)
    local bx, by = x0 + sin(a) * l, y0 + cos(a) * l
    INK.smooth(INK.sample(INK.bezier3(x0, y0, x0 + sin(a) * l * 0.3, y0 + cos(a) * l * 0.5, bx - sin(a) * l * 0.2, by - cos(a) * l * 0.2, bx, by), 5), false)
    INK.stroke(st_rgb, max(0.22, 0.009 * s), 0.75)
    INK.push(); INK.translate(bx, by); W.floret(rng, 0.13 - 0.03 * v, o); INK.pop()
  end
  INK.push(); INK.translate(bend, 1.0); W.floret(rng, 0.12, o); INK.pop()
  INK.pop()
end

function W.umbel(rng, s, o)
  o = o or {}
  local n = o.n or rng.int(7, 11)
  local st_rgb = o.stem_rgb or { 0.28, 0.42, 0.22 }
  INK.push(); INK.scale(s)
  for i = 1, n do
    local f = (i - 0.5) / n * 2 - 1 + rng.sym(0.08)
    local a = f * 68 * pi / 180
    local r = (0.88 - 0.20 * f * f) * rng.range(0.88, 1.08)
    local x, y = sin(a) * r, cos(a) * r * 0.78 + 0.14
    INK.smooth(INK.sample(INK.bezier3(0, 0, sin(a) * r * 0.3, cos(a) * r * 0.35, x * 0.75, y * 0.85, x, y), 5), false)
    INK.stroke(st_rgb, max(0.20, 0.012 * s), 0.70)
    INK.push(); INK.translate(x, y); W.floret(rng, rng.range(0.14, 0.19), o); INK.pop()
  end
  INK.pop()
end

function W.tendril(rng, s, o)
  o = o or {}
  local sign = o.sign or (rng.chance(0.5) and 1 or -1)
  local turns = o.turns or rng.range(1.6, 2.35)
  local st_rgb = o.stem_rgb or { 0.26, 0.40, 0.20 }
  INK.push(); INK.scale(s)
  local pts, x, y, a = { { 0, 0 } }, 0, 0, 0
  local N = 44
  local step = 1.60 / N
  for i = 1, N do
    local u = i / N
    a = a + sign * (0.4 + 2.8 * u * u) * turns * 2 * pi / N
    local ds = step * (1 - 0.52 * u)
    x, y = x - sin(a) * ds, y + cos(a) * ds
    pts[#pts + 1] = { x, y }
  end
  INK.smooth(INK.ribbon(pts, function(u) return 0.042 * (1 - u) + 0.006 end), true)
  INK.fill(st_rgb, 0.86)
  INK.pop()
end

function W.branch_path(x0, y0, tx, ty, x1, y1, r, curl)
  local dx, dy = x1 - x0, y1 - y0
  local d = sqrt(dx * dx + dy * dy); if d < 1e-6 then d = 1 end
  local ux, uy = dx / d, dy / d
  local side = (tx * uy - ty * ux >= 0) and 1 or -1
  if tx * ux + ty * uy < -0.15 then tx, ty = -tx, -ty end
  local ca, sa = cos(0.58), sin(0.58) * side
  local d0x, d0y = tx * ca - ty * sa, tx * sa + ty * ca
  if d0x * ux + d0y * uy < 0.2 then d0x, d0y = ux, uy end
  local nx, ny = -uy * side, ux * side
  local d1x, d1y = ux + nx * (curl or 0.15), uy + ny * (curl or 0.15)
  local dl = sqrt(d1x * d1x + d1y * d1y); d1x, d1y = d1x / dl, d1y / dl
  local ex, ey = x1 - d1x * r * 0.28, y1 - d1y * r * 0.28
  local L2 = sqrt((ex - x0) ^ 2 + (ey - y0) ^ 2)
  return INK.bezier3(x0, y0, x0 + d0x * L2 * 0.38, y0 + d0y * L2 * 0.38, ex - d1x * L2 * 0.36, ey - d1y * L2 * 0.36, ex, ey),
    atan(d1y, d1x) * 180 / pi - 90, ex, ey, d1x, d1y
end


---------------------------------------------------------------- transactional INK helpers & multi-scale garden packer
local function fit_rect(c, rect, kind)
  if not rect then return false end
  if c.fits and not c.fits(rect, kind or "blossom") then return false end
  if not geom.clear_of(rect, c.exclude) then return false end
  if not is_tok(kind, BLEED) then
    if not geom.contains(c.safe, rect, 0.01) then return false end
    if c.region and not geom.contains(c.region, rect, 0.01) then return false end
  end
  return true
end

local function record_pts(c, kind, pts, w0, w1, chunk)
  chunk = chunk or 4
  local bb
  local n = #pts
  for i = 1, n - 1, chunk do
    local r
    for j = i, min(n, i + chunk) do
      local u = (j - 1) / max(1, n - 1)
      local hw = (w0 + (w1 - w0) * u) * 0.55 + 0.5
      local p = pts[j]
      r = geom.union(r, { x0 = p[1] - hw, y0 = p[2] - hw, x1 = p[1] + hw, y1 = p[2] + hw })
    end
    c.record(kind, r); bb = geom.union(bb, r)
  end
  return bb
end

function W.paint_stem(c, spine, w0, w1, n, hue, kind, layer, alpha)
  n = n or 32
  local raw = INK.sample(spine, n)
  local pts = {}
  local sf = c.safe
  local rg = (not is_tok(kind, BLEED)) and c.region or nil
  for i, p in ipairs(raw) do
    local px, py = p[1], p[2]
    local u = (i - 1) / max(1, #raw - 1)
    local hw = (w0 + (w1 - w0) * u) * 0.55 + 0.8
    if sf and not is_tok(kind, BLEED) then
      px = max(sf.x0 + hw + 0.5, min(sf.x1 - hw - 0.5, px))
      py = max(sf.y0 + hw + 0.5, min(sf.y1 - hw - 0.5, py))
    end
    if rg then
      px = max(rg.x0 + hw + 0.5, min(rg.x1 - hw - 0.5, px))
      py = max(rg.y0 + hw + 0.5, min(rg.y1 - hw - 0.5, py))
    end
    for _, e in ipairs(c.exclude or {}) do
      if px > e.x0 - hw - 2.5 and px < e.x1 + hw + 2.5 and py > e.y0 - hw - 2.5 and py < e.y1 + hw + 2.5 then
        local dxL, dxR = abs(px - e.x0), abs(px - e.x1)
        local dyB, dyT = abs(py - e.y0), abs(py - e.y1)
        if min(dxL, dxR) < min(dyB, dyT) then
          px = (dxL < dxR) and (e.x0 - hw - 3.0) or (e.x1 + hw + 3.0)
        else
          py = (dyB < dyT) and (e.y0 - hw - 3.0) or (e.y1 + hw + 3.0)
        end
      end
    end
    local r = { x0 = px - hw, y0 = py - hw, x1 = px + hw, y1 = py + hw }
    if fit_rect(c, r, kind) then
      pts[#pts + 1] = { px, py }
    elseif #pts >= 4 then
      break
    end
  end
  if #pts < 4 then return nil, nil end
  local sub = c.pdf:sub(); sub.cur = c.pdf.cur
  sub:layer(layer or 22)
  INK.begin(sub, hue, { alpha = alpha })
  local rib = INK.ribbon(pts, function(u)
    local w = w0 + (w1 - w0) * u
    if u < 0.08 then w = w * (0.35 + 8.1 * u) end
    if u > 0.92 then w = w * max(0.25, (1 - u) * 12.5) end
    return w
  end)
  INK.smooth(rib, true); INK.fill(INK.tone(0.32), 0.94)
  INK.smooth(rib, true); INK.clip()
    INK.streak(function(v)
      local idx = max(1, min(#pts, floor(v * (#pts - 1)) + 1))
      return pts[idx][1], pts[idx][2]
    end, min(18, #pts), w0 * 0.28, w1 * 0.22, INK.white, 0.44)
  INK.unclip()
  INK.smooth(rib, true); INK.stroke(INK.tone(0.14), 0.22, 0.34, true)
  if kind == "bamboo-culm" and #pts >= 10 then
    for _, nf in ipairs({ 0.18, 0.38, 0.58, 0.78 }) do
      local idx = max(2, min(#pts - 1, floor(nf * #pts)))
      local p = pts[idx]
      local p_prev, p_next = pts[idx - 1], pts[idx + 1]
      local dx, dy = p_next[1] - p_prev[1], p_next[2] - p_prev[2]
      local dl = max(1e-6, sqrt(dx * dx + dy * dy))
      local nx, ny = -dy / dl, dx / dl
      local hw = (w0 + (w1 - w0) * nf) * 0.72
      INK.smooth({ { p[1] - nx * hw, p[2] - ny * hw }, { p[1] + nx * hw, p[2] + ny * hw } }, false)
      INK.stroke(INK.tone(0.08), 0.75, 0.88)
    end
  end
  INK.finish()
  c.pdf:merge(sub)
  local bb = record_pts(c, kind, pts, w0, w1, 4)
  return bb, pts
end

function W.sway_spine(x0, y0, x1, y1, nx, ny, amp, ph1, ph2)
  ph1, ph2 = ph1 or 0.4, ph2 or 1.7
  return function(v)
    local w = amp * sin(2 * pi * v * 1.55 + ph1) + amp * 0.44 * cos(2 * pi * v * 2.85 + ph2)
    local env = sin(pi * v) ^ 0.72
    return x0 + (x1 - x0) * v + nx * w * env, y0 + (y1 - y0) * v + ny * w * env
  end
end

function W.corner_spine(x0, y0, cx, cy, x1, y1, r_arc, amp0, ph, amp1)
  ph = ph or 0.6
  amp0 = amp0 or 8
  amp1 = amp1 or (amp0 * 0.65)
  local dx0, dy0 = x0 - cx, y0 - cy
  local l0 = max(1, sqrt(dx0 * dx0 + dy0 * dy0))
  local dx1, dy1 = x1 - cx, y1 - cy
  local l1 = max(1, sqrt(dx1 * dx1 + dy1 * dy1))
  local rc = min(r_arc or 24, 26, l0 * 0.34, l1 * 0.34)
  local ax, ay = cx + (dx0 / l0) * rc, cy + (dy0 / l0) * rc
  local bx, by = cx + (dx1 / l1) * rc, cy + (dy1 / l1) * rc
  local bez = INK.bezier3(ax, ay, cx + (dx0 / l0) * rc * 0.12, cy + (dy0 / l0) * rc * 0.12,
    cx + (dx1 / l1) * rc * 0.12, cy + (dy1 / l1) * rc * 0.12, bx, by)
  local n0x, n0y = -dy0 / l0, dx0 / l0
  local n1x, n1y = -dy1 / l1, dx1 / l1
  return function(v)
    if v < 0.40 then
      local u = v / 0.40
      local w = amp0 * sin(2 * pi * u * 1.35 + ph) * sin(pi * u)
      return x0 + (ax - x0) * u + n0x * w, y0 + (ay - y0) * u + n0y * w
    elseif v <= 0.60 then
      return bez((v - 0.40) / 0.20)
    else
      local u = (v - 0.60) / 0.40
      local w = amp1 * sin(2 * pi * u * 1.35 + ph + 1.4) * sin(pi * u)
      return bx + (x1 - bx) * u + n1x * w, by + (y1 - by) * u + n1y * w
    end
  end
end

function W.bamboo_fan(rng, r, n_blades, tone_base)
  n_blades = n_blades or 5
  local t0 = tone_base or 0.34
  for k = 1, n_blades do
    local ft = (k - (n_blades + 1) / 2) / max(1, n_blades - 1)
    local a = ft * 112 + rng.sym(7)
    local blen = r * rng.range(1.06, 1.24) * (1 - 0.22 * abs(ft))
    local btone = max(0.16, min(0.84, t0 + rng.sym(0.08)))
    INK.push(); INK.rotate(a); INK.scale(blen)
    INK.leaflet(rng, { w = rng.range(0.13, 0.17), bend = (ft >= 0 and 1 or -1) * rng.range(0.14, 0.22), tone = btone })
    INK.pop()
  end
end

function W.pine_fan(rng, r, n_needles, tone_base)
  n_needles = n_needles or 15
  local t0 = tone_base or 0.32
  for k = 1, n_needles do
    local ft = (k - (n_needles + 1) / 2) / max(1, n_needles - 1)
    local a = ft * 76 + rng.sym(3)
    local nlen = r * (1.08 - 0.18 * abs(ft))
    INK.push(); INK.rotate(a); INK.scale(nlen)
    INK.leaflet(rng, { w = 0.055, bend = ft * 0.08, tone = max(0.16, min(0.82, t0 + rng.sym(0.06))) })
    INK.pop()
  end
  INK.circle(0, 0, r * 0.14)
  INK.fill(INK.accent(-0.18), 0.88, true)
end

-- Multi-ring chrysanthemum (kiku) ray-floret bloom
function W.kiku_bloom(rng, r, tone_base)
  local t0 = tone_base or 0.36
  for ring = 1, 2 do
    local nr = (ring == 1) and 16 or 12
    local rr = r * ((ring == 1) and 0.98 or 0.68)
    local rt = (ring == 1) and (t0 + 0.08) or max(0.16, t0 - 0.06)
    for k = 1, nr do
      local a = (k - 0.5 * ring) * (360 / nr) + rng.sym(4)
      INK.push(); INK.rotate(a); INK.scale(rr * rng.range(0.92, 1.06))
      INK.leaflet(rng, { w = 0.14, bend = rng.sym(0.08), tone = max(0.14, min(0.84, rt + rng.sym(0.05))) })
      INK.pop()
    end
  end
  INK.circle(0, 0, r * 0.18); INK.fill(INK.accent(-0.08), 0.92)
  INK.circle(0, 0, r * 0.10); INK.fill(INK.accent(0.28), 0.95)
end

-- 6-tepal winter narcissus (suisen) with golden-vermilion cup corona (sakazuki)
function W.narcissus_bloom(rng, r, tone_base)
  local t0 = max(0.56, tone_base or 0.68)
  for k = 1, 6 do
    local a = k * 60 + rng.sym(4)
    INK.push(); INK.rotate(a); INK.scale(r * 0.95)
    INK.leaflet(rng, { w = 0.25, bend = rng.sym(0.05), tone = min(0.90, t0 + rng.sym(0.04)) })
    INK.pop()
  end
  INK.circle(0, 0, r * 0.30); INK.fill(INK.accent(0.05), 0.92)
  INK.circle(0, 0, r * 0.28); INK.stroke(INK.accent(-0.22), max(0.35, r * 0.04), 0.86, true)
  INK.circle(0, 0, r * 0.11); INK.fill(INK.white, 0.88)
end

-- Drooping wisteria (fuji) raceme of tiered papilionaceous florets tapering to buds
function W.wisteria_raceme(rng, r, st)
  local st_rgb = st.stem or { 0.28, 0.42, 0.22 }
  local L_rac = r * 1.35
  local sway = rng.sym(0.18) * L_rac
  local spine = INK.bezier3(0, 0, sway * 0.3, -L_rac * 0.35, sway * 0.8, -L_rac * 0.72, sway, -L_rac)
  INK.smooth(INK.sample(spine, 10), false); INK.stroke(st_rgb, max(0.28, r * 0.03), 0.82)
  local nf = 6
  for i = 1, nf do
    local v = i / (nf + 0.5)
    local x0, y0 = spine(v)
    local side = (i % 2 == 0) and 1 or -1
    local fsz = r * (0.30 - 0.14 * v)
    local dx = side * fsz * 0.55
    INK.smooth({ { x0, y0 }, { x0 + dx, y0 - fsz * 0.25 } }, false); INK.stroke(st_rgb, 0.22, 0.74)
    INK.push(); INK.translate(x0 + dx, y0 - fsz * 0.25)
    if v < 0.68 then W.floret(rng, fsz, { petals = 5, tone = 0.40 + 0.22 * v })
    else INK.Rotate = 180; INK.bud(rng, fsz * 0.85, { sepal = st_rgb }) end
    INK.pop()
  end
end

function W.try_ink(c, kind, layer, hue, accent, fn, alpha)
  for _, sc in ipairs({ 1.0, 0.78, 0.58, 0.42 }) do
    local sub = c.pdf:sub(); sub.cur = c.pdf.cur
    sub:layer(layer or 36)
    INK.begin(sub, hue, { accent = accent, alpha = alpha })
    fn(sc)
    local bb = INK.finish()
    INK.detail = 1
    if bb and fit_rect(c, bb, kind) then
      c.pdf:merge(sub)
      c.record(kind, bb)
      return bb
    end
  end
  INK.detail = 1
  return nil
end

function W.draw_organ(c, st, mode, x, y, r, deg, layer, hue_override)
  local rng = c.rng
  local fl_rgb = hue_override or st.fl[rng.int(1, #st.fl)]
  -- 3-tier depth variation: tier 1 (back ghost, alpha 0.36..0.46), tier 2 (mid, alpha 0.64..0.76), tier 3 (front, alpha 0.92..0.98)
  local tier = (mode == "ghost" and 1) or (mode == "hero" and 3)
    or ((layer and layer <= 20) and 1)
    or (rng.chance(0.28) and 1 or (rng.chance(0.48) and 2 or 3))
  local d_alpha = (tier == 1 and rng.range(0.36, 0.46)) or (tier == 2 and rng.range(0.64, 0.76)) or rng.range(0.92, 0.98)
  local d_layer = (mode == "hero" and 42) or (tier == 1 and 16) or (tier == 2 and 27) or (layer or 37)
  INK.detail = (mode == "hero" or (r >= 18 and tier >= 2)) and 1 or 0.35
  if mode == "bamboo_fan" or (st.mkind == "bamboo" and mode ~= "flower" and mode ~= "cyme" and mode ~= "umbel") then
    local is_ghost = (tier == 1)
    local tone = is_ghost and rng.range(0.58, 0.74) or (tier == 2 and rng.range(0.36, 0.50) or rng.range(0.22, 0.38))
    local n_bl = (mode == "hero") and 7 or ((mode == "bud" or mode == "v_leaflets" or mode == "tendril") and 3 or 5)
    return W.try_ink(c, st.organ_tag, d_layer, is_ghost and st.leaf_alt or st.leaf, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.bamboo_fan(rng, r * sc, n_bl, tone)
      INK.pop()
    end, d_alpha)
  elseif mode == "pine_fan" or (st.mkind == "pine" and mode ~= "flower" and mode ~= "cyme") then
    local is_ghost = (tier == 1)
    local tone = is_ghost and rng.range(0.56, 0.72) or (tier == 2 and rng.range(0.34, 0.48) or rng.range(0.22, 0.38))
    local nn = (mode == "hero") and 19 or ((mode == "bud" or mode == "v_leaflets" or mode == "tendril") and 9 or 15)
    return W.try_ink(c, st.organ_tag, d_layer, is_ghost and st.leaf_alt or st.leaf, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.pine_fan(rng, r * sc, nn, tone)
      INK.pop()
    end, d_alpha)
  elseif mode == "kiku" then
    local tone = (tier == 1 and rng.range(0.56, 0.70)) or rng.range(0.32, 0.48)
    return W.try_ink(c, st.organ_tag, d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.kiku_bloom(rng, r * 0.96 * sc, tone)
      INK.pop()
    end, d_alpha)
  elseif mode == "raceme" then
    return W.try_ink(c, st.organ_tag, d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y)
      W.wisteria_raceme(rng, r * 0.92 * sc, st)
      INK.pop()
    end, d_alpha)
  elseif mode == "maple_leaf" then
    local tone = (tier == 1 and 0.62) or (tier == 2 and 0.48) or 0.36
    local mcol = (st.mkind == "maple") and fl_rgb or st.leaf_alt
    local ktag = (st.mkind == "maple") and "maple-leaf" or st.leaf_tag
    return W.try_ink(c, ktag, d_layer, mcol, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      INK.scale(r * 1.05 * sc); INK.maple_leaf(rng, { lobes = 7, tone = tone })
      INK.pop()
    end, d_alpha)
  elseif mode == "hero" or mode == "flower" or mode == "ghost" then
    local is_ghost = (tier == 1)
    local tone = is_ghost and rng.range(0.58, 0.74) or (mode == "hero" and rng.range(0.28, 0.42) or rng.range(0.34, 0.52))
    return W.try_ink(c, st.organ_tag, d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      if st.mkind == "maple" and mode ~= "hero" and rng.chance(0.45) then
        INK.scale(r * 1.05 * sc); INK.maple_leaf(rng, { lobes = 7, tone = tone })
      elseif st.mkind == "chrysanthemum" or (mode == "flower" and rng.chance(0.18)) then
        W.kiku_bloom(rng, r * 0.96 * sc, tone)
      elseif st.mkind == "narcissus" then
        W.narcissus_bloom(rng, r * 0.96 * sc, tone)
      else
        INK.flower(rng, r * sc, {
          petals = st.petals, notch = st.notch, tone = tone,
          sy = (mode == "hero") and rng.range(0.86, 0.99) or rng.range(0.74, 0.95),
          tilt = rng.range(0, 180), blush = true, calyx_dots = (mode == "hero"), sepal = st.stem,
        })
      end
      INK.pop()
    end, d_alpha)
  elseif mode == "side" then
    return W.try_ink(c, st.organ_tag, d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      INK.flower_side(rng, r * 0.98 * sc, { notch = st.notch, half = rng.chance(0.38), blush = true, sepal = st.stem })
      INK.pop()
    end, d_alpha)
  elseif mode == "leaf" then
    local lcol = rng.chance(0.68) and st.leaf or st.leaf_alt
    local ktag = (st.mkind == "maple") and "maple-leaf" or (st.mkind == "pine" and "pine-needles" or st.leaf_tag)
    local l_lyr = (tier == 1 and 16) or (tier == 2 and 25) or 31
    return W.try_ink(c, ktag, l_lyr, lcol, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      if st.mkind == "maple" or rng.chance(0.20) then
        INK.scale(r * 1.08 * sc); INK.maple_leaf(rng, { lobes = 7, tone = (tier == 1 and 0.62 or 0.46) })
      elseif st.mkind == "bamboo" or st.mkind == "iris" or st.mkind == "narcissus" or st.mkind == "orchid" or rng.chance(0.22) then
        W.bamboo_fan(rng, r * 0.95 * sc, 5, (tier == 1 and 0.60 or 0.34))
      else
        INK.scale(r * 1.28 * sc); INK.leaf(rng, { lobes = rng.int(3, 5), depth = rng.range(0.34, 0.58), tone = (tier == 1 and 0.58 or 0.42) })
      end
      INK.pop()
    end, d_alpha)
  elseif mode == "cyme" then
    return W.try_ink(c, st.organ_tag, d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.cyme(rng, r * 1.25 * sc, { stem_rgb = st.stem })
      INK.pop()
    end, d_alpha)
  elseif mode == "umbel" then
    return W.try_ink(c, st.organ_tag, d_layer, st.fl[min(#st.fl, 2)], st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.umbel(rng, r * 1.05 * sc, { stem_rgb = st.stem })
      INK.pop()
    end, d_alpha)
  elseif mode == "sprig" then
    return W.try_ink(c, st.organ_tag, d_layer, st.fl[#st.fl], st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.sprig(rng, r * 1.22 * sc, { stem_rgb = st.stem })
      INK.pop()
    end, d_alpha)
  elseif mode == "bud" then
    return W.try_ink(c, st.mkind .. "-bud", d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      INK.bud(rng, r * 1.08 * sc, { sepal = st.stem })
      INK.pop()
    end, d_alpha)
  elseif mode == "tendril" then
    return W.try_ink(c, st.twig_tag, layer or 26, st.stem, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      W.tendril(rng, r * 1.05 * sc, { stem_rgb = st.stem })
      INK.pop()
    end, d_alpha)
  elseif mode == "v_leaflets" then
    local ktag = (st.mkind == "pine") and "pine-needles" or st.leaf_tag
    return W.try_ink(c, ktag, d_layer, st.leaf, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      for side = -1, 1, 2 do
        INK.push(); INK.rotate(side * rng.range(24, 38)); INK.scale(r * 1.15 * sc)
        INK.leaflet(rng, { w = 0.21, bend = side * 0.16 })
        INK.pop()
      end
      INK.pop()
    end, d_alpha)
  elseif mode == "floret_cluster" then
    return W.try_ink(c, st.organ_tag, d_layer, fl_rgb, st.accent, function(sc)
      INK.push(); INK.translate(x, y); INK.rotate(deg or 0)
      for k = -1, 1 do
        local a = (k * 28 + rng.sym(6)) * pi / 180
        local l = r * 0.56 * sc
        local bx, by = -sin(a) * l, cos(a) * l
        INK.smooth(INK.sample(INK.bezier3(0, 0, bx * 0.4, by * 0.5, bx * 0.8, by * 0.85, bx, by), 4), false)
        INK.stroke(st.stem, 0.26, 0.76)
        INK.push(); INK.translate(bx, by); W.floret(rng, r * 0.36 * sc); INK.pop()
      end
      INK.pop()
    end, d_alpha)
  end
  return nil
end


function L.grow_garden(c, rects, opts)
  opts = opts or {}
  local rng = c.rng
  local dens = opts.density or c.density or 0.5
  local st = motif_style(c, opts.motif)
  local F = L.field(rects, c.exclude, c.safe)
  local bb
  local info = { perch = {}, spts = {} }
  local spts = info.spts
  local stem_groups = {}

  for idx, sd in ipairs(opts.stems or {}) do
    local s_layer = sd.layer or (idx == 1 and 22 or (idx == 2 and 18 or 15))
    local s_alpha = sd.alpha or (idx == 1 and 0.96 or (idx == 2 and 0.62 or 0.36))
    local sbb, pts = W.paint_stem(c, sd.spine, sd.w0 or 2.8, sd.w1 or 0.55, sd.n or 40, st.stem,
      idx == 1 and st.stem_tag or (st.mkind .. "-branch"), s_layer, s_alpha)
    if sbb and pts then
      bb = geom.union(bb, sbb)
      local gp = F.add_pts(pts, sd.pad or 1.8, sd.step or 3.8, "stem")
      stem_groups[#stem_groups + 1] = { pts = gp, raw = pts, is_main = (idx == 1), is_horiz = sd.horiz }
      for _, p in ipairs(gp) do spts[#spts + 1] = p end
      if #gp >= 4 then
        local mp = gp[floor(#gp * 0.52)]
        info.perch[#info.perch + 1] = { x = mp.x, y = mp.y + 1.2, cx = mp.x, cy = mp.y, w = 2.0, angle = atan(mp.ty, mp.tx) }
      end
    end
  end
  if #spts == 0 then return nil, info end

  if opts.root then
    local tb = W.draw_organ(c, st, "tendril", opts.root[1], opts.root[2], opts.root_r or 12, opts.root_deg or 180, 21)
    if tb then bb = geom.union(bb, tb) end
  end

  -- 1. Pale background ghost blooms (R = 20..32 bp) for 3-tier depth
  if dens >= 0.30 and #spts >= 5 then
    for _, frac in ipairs({ 0.24, 0.54, 0.80 }) do
      local gp = spts[min(#spts, max(2, floor(#spts * frac)))]
      local gr = min(32, max(12, F.free_r(gp.x, gp.y, 0.5, true) * 0.92))
      if gr >= 11 then
        local gbb = W.draw_organ(c, st, "ghost", gp.x, gp.y, gr, rng.range(0, 360), 15)
        if gbb then bb = geom.union(bb, gbb) end
      end
    end
  end

  -- 2. Hero blooms (R = 26..40 bp, clamped to fit local margin/corner space)
  local heroes = opts.heroes or {}
  if #heroes == 0 and stem_groups[1] and #stem_groups[1].pts >= 3 then
    local p1 = stem_groups[1].pts[min(#stem_groups[1].pts, max(2, floor(#stem_groups[1].pts * 0.22)))]
    local p2 = stem_groups[1].pts[min(#stem_groups[1].pts, max(3, floor(#stem_groups[1].pts * 0.62)))]
    local p3 = stem_groups[1].pts[#stem_groups[1].pts]
    heroes = { { p1.x, p1.y, 38 }, { p2.x, p2.y, 32 }, { p3.x, p3.y, 28 } }
  end
  for hi, h in ipairs(heroes) do
    if hi <= 2 or dens >= 0.35 then
      local hx, hy, hmax = h[1], h[2], (h[3] or 36) * (0.68 + 0.32 * dens)
      local avail = F.edge(hx, hy) - 1.0
      local hr = min(hmax, max(9.5, avail * 0.94))
      if hr >= 9.0 then
        local hbb = W.draw_organ(c, st, "hero", hx, hy, hr, rng.range(0, 360), 42, st.fl[(hi - 1) % #st.fl + 1])
        if hbb then
          bb = geom.union(bb, hbb)
          F.place(hx, hy, hr * 0.55, "hero")
        end
      end
    end
  end

  -- 3. Mixed foliage at stem nodes (sculpted leaves, maple leaves, bamboo fans, pine fans, V-leaflets)
  for _, sg in ipairs(stem_groups) do
    local gp = sg.pts
    local step = max(1, floor(#gp / max(4, floor(7 + 8 * dens))))
    local side = 1
    for i = 2, #gp - 1, step do
      local p = gp[i]
      local sdeg = atan(p.ty, p.tx) * 180 / pi - 90
      local deg = sdeg + side * rng.range(34, 58)
      local rad_a = (deg + 90) * pi / 180
      local lreach = min(22, max(8.5, F.edge(p.x + cos(rad_a) * 5, p.y + sin(rad_a) * 5) * 0.88)) * (0.72 + 0.28 * dens)
      if lreach >= 8.0 then
        local lbb = W.draw_organ(c, st, "leaf", p.x, p.y, lreach, deg, 28)
        if lbb then
          bb = geom.union(bb, lbb)
          F.place(p.x + cos(rad_a) * lreach * 0.55, p.y + sin(rad_a) * lreach * 0.55, lreach * 0.28, "leaf")
        end
      end
      if i + 1 <= #gp - 1 then
        local p2 = gp[i + 1]
        local lr = min(14, max(7.0, F.free_r(p2.x, p2.y, 0.5, true) * 0.82))
        if lr >= 6.5 then
          local vbb = W.draw_organ(c, st, "v_leaflets", p2.x, p2.y, lr, sdeg - side * 46, 27)
          if vbb then bb = geom.union(bb, vbb); F.place(p2.x, p2.y, lr * 0.34, "leaflet") end
        end
      end
      side = -side
    end
  end

  -- 4. Greedy multi-scale free-disc branch loop (mixing flowers, kiku, racemes, cymes, umbels, sprigs, leaves, bamboo/pine fans)
  --    IMPORTANT: We verify the terminal organ fits FIRST, and only draw the connecting twig if the organ succeeded (zero bare headless twigs!).
  local function nearest_s(x, y)
    local best, bd = nil, 1e9
    for _, p in ipairs(spts) do
      local d = (x - p.x) ^ 2 + (y - p.y) ^ 2
      if d < bd then best, bd = p, d end
    end
    return best, sqrt(bd)
  end
  local function pick_disc(rmin, rmax, dmin, dmax, ntry, pref_rc)
    local best
    for _ = 1, ntry do
      local rc = pref_rc or rects[rng.int(1, #rects)]
      if rc and geom.width(rc) > 10 and geom.height(rc) > 10 then
        local x = rng.range(rc.x0 + 5, rc.x1 - 5)
        local y = rng.range(rc.y0 + 5, rc.y1 - 5)
        local r = min(rmax, F.free_r(x, y, 0.6, true))
        if r >= rmin then
          local sp, d = nearest_s(x, y)
          if sp and d >= dmin and d <= dmax then
            local sc = r - 0.08 * d + rng.sym(1.2)
            if not best or sc > best.sc then best = { x = x, y = y, r = r, s = sp, d = d, sc = sc } end
          end
        end
      end
    end
    return best
  end

  local nb = opts.nb or max(4, floor(10 + 18 * dens))
  local seq = { "flower", "cyme", "umbel", "leaf", "kiku", "sprig", "side", "bamboo_fan", "cyme", "maple_leaf", "umbel", "flower", "raceme", "sprig", "bud" }
  for b = 1, nb do
    local prc = (opts.balanced and #rects > 1) and rects[(b - 1) % #rects + 1] or nil
    local cnd = pick_disc(5.2, 24 * (0.68 + 0.32 * dens), 5, 92, 70, prc) or (prc and pick_disc(5.2, 24 * (0.68 + 0.32 * dens), 5, 92, 50, nil))
    if cnd then
      local S = cnd.s
      local mode = seq[(b - 1) % #seq + 1]
      local r = min(cnd.r, (mode == "flower" or mode == "kiku" or mode == "side" or mode == "leaf" or mode == "maple_leaf") and 19 or 15) * (0.72 + 0.28 * dens)
      local bez, deg, ex, ey, d1x, d1y = W.branch_path(S.x, S.y, S.tx, S.ty, cnd.x, cnd.y, r, rng.sym(0.22))
      local is_centered = (mode == "flower" or mode == "kiku" or mode == "umbel" or mode == "bamboo_fan")
      local ox = is_centered and (ex + d1x * r * 0.25) or ex
      local oy = is_centered and (ey + d1y * r * 0.25) or ey
      local obb = W.draw_organ(c, st, mode, ox, oy, r, deg, 35)
      if obb then
        bb = geom.union(bb, obb)
        F.place(cnd.x, cnd.y, r * 0.56, mode)
        local bbb, bpts = W.paint_stem(c, bez, 1.02, 0.32, 16, st.stem, st.twig_tag, 23)
        if bbb and bpts then
          bb = geom.union(bb, bbb)
          local gp = F.add_pts(bpts, 1.1, 3.6, "branch")
          for _, p in ipairs(gp) do spts[#spts + 1] = p end
        end
      end
    end
  end

  -- 5. Small-hole wispy filler loop (hairline stalks with V-leaflets, floret clusters, cymes, buds, tendrils)
  local nf = opts.nf or max(3, floor(8 + 16 * dens))
  local fseq = { "v_leaflets", "floret_cluster", "tendril", "cyme", "sprig", "bud" }
  for f = 1, nf do
    local prc = (opts.balanced and #rects > 1) and rects[(f - 1) % #rects + 1] or nil
    local cnd = pick_disc(4.0, 13.5, 4, 58, 50, prc) or (prc and pick_disc(4.0, 13.5, 4, 58, 40, nil))
    if cnd then
      local S = cnd.s
      local mode = fseq[(f - 1) % #fseq + 1]
      local r = min(cnd.r, 11.0) * (0.72 + 0.28 * dens)
      local bez, deg, ex, ey = W.branch_path(S.x, S.y, S.tx, S.ty, cnd.x, cnd.y, r, rng.sym(0.22))
      local obb = W.draw_organ(c, st, mode, ex, ey, r, deg, 33)
      if obb then
        bb = geom.union(bb, obb)
        F.place(cnd.x, cnd.y, r * 0.52, mode)
        local bbb, bpts = W.paint_stem(c, bez, 0.52, 0.22, 12, st.stem, st.twig_tag, 24)
        if bbb and bpts then
          bb = geom.union(bb, bbb)
          F.add_pts(bpts, 0.9, 3.8, "twig")
        end
      end
    end
  end

  return bb, info
end


---------------------------------------------------------------- compact in-band guarantors & M2 dispatch
local S = {}
L.stub = S

local function record_spine(c, kind, Sp, wfn, chunk)
  chunk = chunk or 4
  local bb
  for i = 1, #Sp - 1, chunk do
    local r
    for j = i, min(#Sp, i + chunk) do
      local w = wfn(Sp[j].u or (j / #Sp)) * 0.52 + 0.6
      r = geom.union(r, { x0 = Sp[j].x - w, y0 = Sp[j].y - w, x1 = Sp[j].x + w, y1 = Sp[j].y + w })
    end
    c.record(kind, r); bb = geom.union(bb, r)
  end
  return bb
end

local function disc_ok(c, x, y, r, kind)
  return c.fits({ x0 = x - r, y0 = y - r, x1 = x + r, y1 = y + r }, kind or "blossom")
end

local function grow_pts(c, x, y, ang, len, flow, pull, w, bleed)
  local pts = { { x, y } }
  local step = max(6, len / 12)
  local n = max(3, floor(len / step))
  local R = c.rng
  for i = 1, n do
    ang = ang + R.sym(0.14) + pull * angdiff(flow, ang) * (i / n)
    local placed
    for _, d in ipairs({ 0, 0.22, -0.22, 0.45, -0.45, 0.75, -0.75 }) do
      local a = ang + d
      local nx, ny = x + cos(a) * step, y + sin(a) * step
      local okp
      if bleed and (nx < c.safe.x0 + w or nx > c.safe.x1 - w or ny < c.safe.y0 + w or ny > c.safe.y1 - w) then
        okp = geom.clear_of({ x0 = nx - w, y0 = ny - w, x1 = nx + w, y1 = ny + w }, c.exclude)
      else
        okp = disc_ok(c, nx, ny, w + 1.8, "twig") and disc_ok(c, (x + nx) / 2, (y + ny) / 2, w + 1.8, "twig")
      end
      if okp then x, y, ang, placed = nx, ny, a, true; break end
    end
    if not placed then break end
    pts[#pts + 1] = { x, y }
  end
  return pts
end

function S.branch(c, spec)
  local R = c.rng
  local th = theme_of(c)
  local mkind = spec.motif or th.stub.kind or "sakura"
  local st = motif_style(c, mkind)
  local size = spec.size or 160
  local w0 = max(2.2, min(4.0, size * 0.018))
  local flow = spec.flow or spec.angle
  local main = grow_pts(c, spec.x, spec.y, spec.angle, size, flow, spec.pull or 0.30, w0 * 0.5, spec.bleed)
  if #main < 3 then return nil end
  local segs = brush.chain(main, 0.5)
  c.pdf:layer(21)
  local wfn = function(u) return w0 * (1 - 0.72 * u) end
  local sb, Sp = brush.stroke(c, segs, { w = w0, profile = "both", rgb = st.stem, alpha = 0.92, pressure = 0.18, cap = true })
  if not sb then return nil end
  local trunk_tag = spec.bleed and (mkind .. "-trunk") or st.stem_tag
  local bb = record_spine(c, trunk_tag, Sp, wfn)
  local info = { perch = {} }

  -- Companion background stem curving alongside the main branch for depth (no 180-deg hook)
  local cw = w0 * 0.68
  local ca = spec.angle + R.sym(0.18)
  local ox = max(c.safe.x0 + cw + 3, min(c.safe.x1 - cw - 3, spec.x - sin(spec.angle) * w0 * 1.6))
  local oy = max(c.safe.y0 + cw + 3, min(c.safe.y1 - cw - 3, spec.y + cos(spec.angle) * w0 * 1.6))
  if disc_ok(c, ox, oy, cw + 2.0, "twig") then
    local cpts = grow_pts(c, ox, oy, ca, size * R.range(0.52, 0.72), flow, 0.28, cw * 0.45, false)
    if #cpts >= 3 then
      c.pdf:layer(18)
      local cb, CSp = brush.stroke(c, brush.chain(cpts, 0.5), { w = cw, profile = "both", rgb = st.stem, alpha = 0.56, cap = true })
      if cb then
        bb = geom.union(bb, record_spine(c, mkind .. "-branch", CSp, function(uu) return cw * (1 - 0.78 * uu) end))
      end
    end
  end

  local dens = c.density or 0.5
  local nt = spec.nt or floor(7 + 8 * dens)
  local spread_min = spec.directed and 0.28 or 0.38
  local spread_max = spec.directed and 0.62 or 0.85
  local len_max    = spec.directed and 0.26 or 0.36
  local modes = { "flower", "leaf", "cyme", "umbel", "sprig", "side", "bamboo_fan", "v_leaflets", "bud", "tendril" }

  -- Hero & medium blooms directly along the main stem
  for _, frac in ipairs({ 0.24, 0.54, 0.80 }) do
    local idx_sp = min(#Sp, max(2, floor(#Sp * frac)))
    local h_sp = Sp[idx_sp]
    if h_sp then
      local hr = min(24, max(9.5, size * (frac < 0.35 and 0.11 or 0.082))) * (0.68 + 0.32 * dens)
      local hmode = (frac < 0.35) and "hero" or "flower"
      local hbb = W.draw_organ(c, st, hmode, h_sp.x, h_sp.y, hr, R.range(0, 360), 42)
      if hbb then bb = geom.union(bb, hbb) end
    end
  end

  local nb = 0
  for i = 1, nt do
    local u = 0.14 + 0.80 * (i - 0.5) / nt + R.sym(0.025)
    local x, y, tx, ty = brush.at(Sp, u)
    local pa = atan(ty, tx)
    local side = (i % 2 == 0) and 1 or -1
    local a = pa + side * R.range(spread_min, spread_max)
    local tw = max(0.38, wfn(u) * 0.46)
    local tp = grow_pts(c, x, y, a, size * R.range(0.12, len_max) * (1 - 0.28 * u), spec.twigflow or a, 0.2, tw * 0.5, false)
    if #tp >= 3 then
      local deg = a * 180 / pi - 90
      local mode = modes[(i - 1) % #modes + 1]
      local r = min(16, max(7.0, size * 0.062)) * (0.68 + 0.32 * dens)
      -- Verify tip organ fits BEFORE drawing twig stroke (eliminates bare headless sticks)
      local obb = W.draw_organ(c, st, mode, tp[#tp][1], tp[#tp][2], r, deg, 35)
      if not obb and mode ~= "leaf" and mode ~= "bud" then
        obb = W.draw_organ(c, st, "leaf", tp[#tp][1], tp[#tp][2], r * 0.82, deg, 30)
      end
      if obb then
        bb = geom.union(bb, obb); nb = nb + 1
        c.pdf:layer(22)
        local tb, TS = brush.stroke(c, brush.chain(tp, 0.5), { w = tw, profile = "twig", rgb = st.stem, alpha = 0.84 })
        if tb then
          bb = geom.union(bb, record_spine(c, st.twig_tag, TS, function(uu) return tw * (1 - 0.85 * uu) end))
          local mid = tp[floor(#tp / 2) + 1]
          if abs(sin(a)) < 0.75 then
            info.perch[#info.perch + 1] = { x = mid[1], y = mid[2] + tw * 0.4, cx = mid[1], cy = mid[2], w = tw, angle = a }
          end
        end
      end
    end
    -- Also place direct sessile leaves/buds along internodes
    if i % 2 == 1 then
      local ldeg = (pa + side * 0.85) * 180 / pi - 90
      local lr = min(12, max(5.5, size * 0.048))
      local lbb = W.draw_organ(c, st, (i % 4 == 1) and "v_leaflets" or "leaf", x, y, lr, ldeg, 28)
      if lbb then bb = geom.union(bb, lbb); nb = nb + 1 end
    end
  end
  if #Sp >= 4 then
    local mid_sp = Sp[floor(#Sp * 0.52)]
    if mid_sp then info.perch[#info.perch + 1] = { x = mid_sp.x, y = mid_sp.y + w0 * 0.3, cx = mid_sp.x, cy = mid_sp.y, w = w0 * 0.5, angle = 0.1 } end
  end
  -- Ensure canonical organ_tag is recorded at least once even on tiny strips
  if nb == 0 and #Sp >= 2 then
    local tip = Sp[#Sp]
    local r = 4.2
    if disc_ok(c, tip.x, tip.y, r + 1.0, st.organ_tag) then
      local fb = c.pdf:fill(c.pdf:circle(tip.x, tip.y, r), st.fl[1], 0.90)
      c.record(st.organ_tag, fb); bb = geom.union(bb, fb); nb = 1
    end
  end
  info.n = nb
  return bb, info
end

function S.bird(c, spec)
  local p = spec.perch
  local s = spec.size or 26
  local x, y = p.cx or p.x, p.cy or p.y
  local face = spec.facing or 1
  local bkind = spec.kind or theme_of(c).bird or "uguisu"
  local rect = { x0 = x - s * 0.9, y0 = y - 1, x1 = x + s * 0.9, y1 = y + s * 0.85 }
  if not c.fits(rect, bkind) then return nil end
  local Wp, P = c.pdf, c.palette
  Wp:layer(50)
  Wp:fill(Wp:ellipse(x - face * s * 0.05, y + s * 0.32, s * 0.42, s * 0.25, face * 0.25), P.color("uguisu"), 0.95)
  Wp:fill(Wp:circle(x + face * s * 0.35, y + s * 0.55, s * 0.17), P.color("sumi-dark"), 0.95)
  Wp:fill(Wp:ellipse(x + face * s * 0.02, y + s * 0.24, s * 0.25, s * 0.13, face * 0.2), P.color("shu"), 0.55)
  Wp:fill(Wp:poly({ { x - face * s * 0.35, y + s * 0.38 }, { x - face * s * 0.85, y + s * 0.22 }, { x - face * s * 0.8, y + s * 0.12 }, { x - face * s * 0.3, y + s * 0.26 } }, true), P.color("sumi-dark"), 0.9)
  Wp:fill(Wp:poly({ { x + face * s * 0.48, y + s * 0.58 }, { x + face * s * 0.66, y + s * 0.53 }, { x + face * s * 0.48, y + s * 0.5 } }, true), P.color("sumi-noir"), 1)
  Wp:stroke(Wp:poly({ { x, y + s * 0.12 }, { x - face * 1, y } }, false), P.color("sumi-dark"), 0.6, 1)
  c.record(bkind, rect)
  return rect
end

function S.culms(c, spec)
  local R = c.rng
  local Z = spec.zone
  local mkind = spec.motif or "bamboo"
  local st = motif_style(c, mkind)
  local wZ, hZ = geom.width(Z), geom.height(Z)
  local cx = (Z.x0 + Z.x1) * 0.5
  local y0 = max(c.safe.y0 + 6, Z.y0 + 8)
  local y1 = min(c.safe.y1 - 8, Z.y0 + hZ * 0.88)
  local sw = min(15, wZ * 0.28)
  local bb, info = L.grow_garden(c, { Z }, {
    motif = mkind,
    stems = {
      { spine = W.sway_spine(cx - sw * 0.22, y0, cx + sw * 0.16, y1, 1, 0, sw, 0.3, 1.6), w0 = 3.1, w1 = 0.62, n = 40, layer = 22, alpha = 0.96 },
      { spine = W.sway_spine(cx + sw * 0.32, y0 + 10, cx - sw * 0.24, y0 + (y1 - y0) * 0.86, 1, 0, sw * 0.88, 2.2, 0.7), w0 = 2.1, w1 = 0.46, n = 34, layer = 18, alpha = 0.60 },
      { spine = W.sway_spine(cx - sw * 0.42, y0 + 22, cx + sw * 0.36, y0 + (y1 - y0) * 0.74, 1, 0, sw * 0.72, 4.1, 1.9), w0 = 1.5, w1 = 0.34, n = 28, layer = 15, alpha = 0.34 },
    },
    root = { cx, y0 + 4 }, root_r = min(12, wZ * 0.25), root_deg = 180,
    heroes = { { cx, y0 + min(42, hZ * 0.16), min(38, wZ * 0.44) }, { cx, (y0 + y1) * 0.56, min(30, wZ * 0.38) } },
  })
  if bb then return bb, info end
  local pts = { { cx, y0 }, { cx + R.sym(1.5), (y0 + y1) * 0.5 }, { cx, y1 } }
  local sb, Sp = brush.stroke(c, brush.chain(pts, 0.3), { w = 2.2, profile = "both", rgb = st.stem, alpha = 0.9 })
  if not sb then return nil end
  bb = record_spine(c, st.stem_tag, Sp, function() return 2.2 end, 3)
  local lb = W.draw_organ(c, st, "v_leaflets", cx, (y0 + y1) * 0.5, min(9, wZ * 0.3), 0, 28)
  if lb then bb = geom.union(bb, lb) end
  return bb, { perch = {} }
end

function S.vine(c, spec)
  local R = c.rng
  local Z = spec.zone
  local mkind = spec.motif or "wisteria"
  local st = motif_style(c, mkind)
  local hZ = geom.height(Z)
  local x0 = max(Z.x0 + 6, min(Z.x1 - 6, spec.from or (Z.x0 + 8)))
  local x1 = max(Z.x0 + 6, min(Z.x1 - 6, spec.to or (Z.x1 - 8)))
  local ym = (Z.y0 + Z.y1) * 0.5
  local sw = min(11, hZ * 0.28)
  local bb, info = L.grow_garden(c, { Z }, {
    motif = mkind,
    stems = {
      { spine = W.sway_spine(x0, ym - sw * 0.15, x1, ym + sw * 0.15, 0, 1, sw, 0.4, 1.8), w0 = 2.4, w1 = 0.48, n = 34, horiz = true },
      { spine = W.sway_spine(x0 + (x1 - x0) * 0.08, ym + sw * 0.2, x0 + (x1 - x0) * 0.86, ym - sw * 0.2, 0, 1, sw * 0.78, 2.3, 0.9), w0 = 1.6, w1 = 0.36, n = 26, horiz = true },
    },
    heroes = { { x0 + (x1 - x0) * 0.16, ym, min(28, hZ * 0.42) }, { x0 + (x1 - x0) * 0.56, ym, min(22, hZ * 0.36) } },
    nb = max(5, floor(12 * (c.density or 0.5))),
    nf = max(4, floor(10 * (c.density or 0.5))),
  })
  if bb then return bb, info end
  local pts = { { x0, ym }, { (x0 + x1) * 0.5, ym + R.sym(1.5) }, { x1, ym } }
  local sb, Sp = brush.stroke(c, brush.chain(pts, 0.5), { w = 1.8, profile = "both", rgb = st.stem, alpha = 0.85 })
  if not sb then return nil end
  bb = record_spine(c, st.stem_tag, Sp, function(u) return 1.8 * (1 - u) end, 3)
  local mx = (x0 + x1) * 0.5
  local r = min(3.2, hZ * 0.18)
  if disc_ok(c, mx, ym, r + 1.0, st.organ_tag) then
    local fb = c.pdf:fill(c.pdf:circle(mx, ym, r), st.fl[1], 0.85)
    c.record(st.organ_tag, fb); bb = geom.union(bb, fb)
  end
  return bb, {}
end

-- Footer atmospheric wash + horizontal stem (subtle mist, NEVER a dark brown band or scratchy grass ticks!)
function S.bank(c, spec)
  local P = c.palette
  local x0, x1, y = spec.x0, spec.x1, spec.y
  local h = spec.height or 16
  c.pdf:layer(10)
  local wcol = palm.mix(P.color(P.name == "hanga" and "bokashi-sky" or "sumi-wash"), P.paper, 0.22)
  local bb = wash.band(c, { x0 = x0, x1 = x1, y = y + h * 0.55 + 1, height = min(14, h * 0.65), rgb = wcol, alpha = 0.14, fade = { 0.32, 0.32 } })
  if not bb then return nil end
  c.record("bank-wash", bb)
  c.record("kasumi-wash", bb)
  return bb, {}
end

function S.petal(c, x, y, r, rot, rgb, pkind)
  if not disc_ok(c, x, y, r + 1, "petal") then return nil end
  local Wp = c.pdf
  Wp:layer(40)
  local bb = Wp:fill(Wp:ellipse(x, y, r, r * 0.62, rot), rgb, 0.82)
  c.record((pkind or "sakura") .. "-petal", bb)
  return bb
end

function S.seal(c, x, y, s)
  local rect = { x0 = x - 1, y0 = y - 1, x1 = x + s + 1, y1 = y + s * 1.25 + 1 }
  if not c.fits(rect, "seal") then return nil end
  local Wp, P = c.pdf, c.palette
  Wp:layer(60)
  local R = c.rng
  local pts = {}
  for _, q in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1.25 }, { 0, 1.25 } }) do pts[#pts + 1] = { x + q[1] * s + R.sym(0.5), y + q[2] * s + R.sym(0.5) } end
  Wp:fill(Wp:poly(pts, true), P.color("shu"), 0.88)
  for k = 1, 3 do
    local yy = y + s * (0.3 * k)
    Wp:fill(Wp:rect(x + s * 0.18, yy, x + s * 0.82, yy + s * 0.08), P.paper, 0.85)
  end
  c.record("seal", rect)
  return rect
end


---------------------------------------------------------------- M2 motif dispatch & composition helpers
local function opt(name) local ok, m = pcall(require, name); return ok and type(m) == "table" and m or nil end
L.M2 = { flora = opt("kacho-flora"), fauna = opt("kacho-fauna"), scenery = opt("kacho-scenery"), seal = opt("kacho-seal") }

local function pick_branch_candidates(c, spec)
  if spec and spec.motif then return { spec.motif } end
  local forced = page_motifs(c.page)
  if forced then
    local list = {}
    for _, m in ipairs(forced) do
      if not BIRD_MOTIFS[m] and m ~= "seal" then list[#list + 1] = m end
    end
    if #list > 0 then return list end
  end
  return theme_of(c).branch
end

local function add_bird(plan, info, z, forced_kind)
  local ctx = plan.ctx
  if not ctx.birds and not forced_kind then return end
  if not forced_kind and (ctx.density or 0.5) < 0.3 then return end
  if not info or not info.perch or #info.perch == 0 then return end
  local R = ctx.rng.child("bird")
  local th = theme_of(ctx)
  local bkind = forced_kind or th.bird or "uguisu"
  if bkind == "bird" or bkind == "swallow" then bkind = "uguisu" end
  local s = max(20, min(32, (z.wO or 60) * 0.32))
  local off = R.int(0, 9)
  local fn_m2 = L.M2.fauna and L.M2.fauna.bird
  for i = 1, #info.perch do
    local p = info.perch[(i + off) % #info.perch + 1]
    local saved = plan.occ; plan.occ = plan.host_occ or {}
    local bb = plan:attempt("bird", {}, function(c)
      local r, bi
      if fn_m2 then r, bi = fn_m2(c, { perch = p, kind = bkind, size = s, facing = z.inward }) end
      if not r then r, bi = S.bird(c, { perch = p, kind = bkind, size = s, facing = z.inward }) end
      if r then
        local px, py = p.cx or p.x, p.cy or p.y
        c.record("perch-twig", { x0 = px - 2.5, y0 = py - 1.0, x1 = px + 2.5, y1 = py + 1.0 })
      end
      return r, bi
    end)
    plan.occ = saved
    if bb then plan.occ[#plan.occ + 1] = geom.inflate(bb, plan.gap); return bb end
  end
end

local function add_seal(plan, cands)
  local ctx = plan.ctx
  if not ctx.seal then return end
  local s = max(14, min(20, plan.page.paper.h / 40))
  local fn_m2 = L.M2.seal and L.M2.seal.hanko
  for _, p in ipairs(cands) do
    local bb = plan:attempt("seal", {}, function(c)
      if fn_m2 then
        local r, si = fn_m2(c, { x = p[1] + s * 0.5, y = p[2] + s * 0.6, size = s, style = "shubun", shape = "square" })
        if r then return r, si end
      end
      return S.seal(c, p[1], p[2], s)
    end)
    if bb then return bb end
  end
end

local function add_sky_bokashi(plan, z)
  local ctx = plan.ctx
  if ctx.wash == false then return end
  local T = z.top or z.outer
  if not T or geom.width(T) < 36 or geom.height(T) < 18 then return end
  plan:attempt("sky-wash", { region = T }, function(c)
    local P = c.palette
    c.pdf:layer(10)
    local h = min(20, geom.height(T) * 0.42)
    local wcol = palm.mix(P.color(P.name == "hanga" and "bokashi-sky" or "sumi-wash"), P.paper, 0.28)
    local bb = wash.band(c, {
      x0 = T.x0 + 4, x1 = T.x1 - 4, y = T.y1 - h * 0.55 - 2,
      height = h, rgb = wcol, alpha = 0.30, fade = { 0.25, 0.25 },
    })
    if bb then c.record("kasumi-wash", bb) end
    return bb, {}
  end)
  plan.occ = {}
end

local function petals(plan, zones_list, n)
  local ctx = plan.ctx
  local th, tname = theme_of(ctx)
  local forced = page_motifs(plan.page)
  local pkind = (forced and forced[1]) or th.petals or "sakura"
  local rgb = palm.mix(col(ctx, th.stub.blossom), col(ctx, th.stub.deep), 0.55)
  local zl = {}
  for _, Z in ipairs(zones_list) do if Z and geom.width(Z) > 14 and geom.height(Z) > 14 then zl[#zl + 1] = Z end end
  if #zl == 0 then return end
  return plan:attempt("petals", {}, function(c)
    local bb, k = nil, 0
    local R = c.rng
    if tname == "shochikubai" and not forced then
      local Z0 = zl[1]
      local px, py = (Z0.x0 + Z0.x1) * 0.5, (Z0.y0 + Z0.y1) * 0.5
      local st = motif_style(c, "pine")
      local fb = W.draw_organ(c, st, "v_leaflets", px, py, 7.5, 25, 30)
      if fb then bb = geom.union(bb, fb) end
    end
    for i = 1, n * 6 do
      local Z = zl[(i % #zl) + 1]
      local x, y = R.range(Z.x0 + 6, Z.x1 - 6), R.range(Z.y0 + 6, Z.y1 - 6)
      local pb = S.petal(c, x, y, R.range(2.6, 4.2), R.range(0, pi), rgb, pkind)
      if pb then bb = geom.union(bb, pb); k = k + 1 end
      if k >= n then break end
    end
    return bb, {}
  end)
end

local function apply_extra_motifs(plan, info, z)
  local forced = page_motifs(plan.page)
  if not forced then return end
  for i = 1, #forced do
    local m = forced[i]
    if i >= 2 and BIRD_MOTIFS[m] then
      add_bird(plan, info, z, m)
    elseif i >= 2 and m == "seal" and z.outer then
      local O = z.outer
      local sx = z.is_right and (O.x1 - 24) or (O.x0 + 6)
      add_seal(plan, { { sx, O.y0 + 28 }, { sx, O.y0 + 65 } })
    elseif m == "rock" and L.M2.scenery and (z.outer or z.bottom) then
      local Z = z.outer or z.bottom
      plan:attempt("extra-rock", { region = Z }, function(c)
        return L.M2.scenery.rock(c, { x = (Z.x0 + Z.x1) * 0.5, y = Z.y0 + 12, size = min(geom.width(Z) * 0.65, 68) })
      end)
    elseif m == "fuji" and L.M2.scenery and (z.bottom or z.outer) then
      local Z = z.bottom or z.outer
      plan:attempt("extra-fuji", { region = Z }, function(c)
        return L.M2.scenery.fuji(c, { x = (Z.x0 + Z.x1) * 0.5, y = Z.y0 + 8, width = min(geom.width(Z) * 0.58, 150) })
      end)
    end
  end
end

---------------------------------------------------------------- body layouts
local WOODY_BOUGHS = { ume = true, sakura = true, maple = true, camellia = true, osmanthus = true, pine = true }
local HERB_FLORA   = { iris = true, orchid = true, narcissus = true, chrysanthemum = true }

--- Interleaved 3-tier segmented bamboo culms + repeated woody space-colonized
--- boughs (ume, sakura, maple, camellia, osmanthus, pine) in the margin.
--- Because kacho-flora paints back bamboo culms (layer 14-17), tree back limbs
--- & ghost blooms (layer 16.5-18), front bamboo culms & tree trunks (layer 20),
--- tree front limbs (layer 21), back bamboo fans (layer 22-26), mid blooms &
--- wispy sprays (layer 25-28), front bamboo fans & tree leaves (layer 30-31),
--- and foreground hero blossoms (layer 40), bamboo and repeated woody boughs
--- naturally weave in front of and behind one another in true 3D depth!
function L.interleaved_boughs_and_bamboo(plan, z, opts)
  opts = opts or {}
  local ctx, page = plan.ctx, plan.page
  local fl = L.M2.flora
  local O = opts.zone or z.outer
  if not fl or not O then return nil, nil end
  local wO, hO = geom.width(O), geom.height(O)
  if wO < 42 or hO < 120 then return nil, nil end

  local dens = ctx.density or 0.5
  local sf = page.safe
  local mode = opts.mode or "overhang"
  local mkind = opts.motif or "sakura"
  local forced = page_motifs(page)
  local th = theme_of(ctx)
  local bb_total
  local info_total = { perch = {} }
  local function merge_info(inf)
    if inf and inf.perch then
      for _, p in ipairs(inf.perch) do info_total.perch[#info_total.perch + 1] = p end
    end
  end

  local cx = (O.x0 + O.x1) * 0.5
  local is_r = (opts.is_right ~= nil) and opts.is_right or z.is_right
  local inward = is_r and -1 or 1
  local x_edge = is_r and (O.x1 - min(14, wO * 0.16)) or (O.x0 + min(14, wO * 0.16))
  local y_top = min(sf.y1 - 12, O.y1 - 12)
  local y_bot = max(sf.y0 + 12, O.y0 + 12)

  -- 1. Soft atmospheric kasumi mist bands in the margin (layer 12)
  if ctx.wash ~= false and L.M2.scenery and L.M2.scenery.kasumi and dens >= 0.35 then
    plan:attempt(mode .. "-kasumi", { region = O, interleave = true }, function(c)
      return L.M2.scenery.kasumi(c, { region = O, bands = 2 })
    end)
  end

  -- Determine whether to interleave 3-tier segmented bamboo culms and which woody bough to repeat
  local has_forced_bamboo = false
  local forced_bough = nil
  if forced then
    for _, fm in ipairs(forced) do
      if fm == "bamboo" then has_forced_bamboo = true end
      if WOODY_BOUGHS[fm] and not forced_bough then forced_bough = fm end
    end
  end

  local bough_kind = forced_bough or (WOODY_BOUGHS[mkind] and mkind) or nil
  if not bough_kind then
    for _, bm in ipairs(th.branch or {}) do
      if WOODY_BOUGHS[bm] then bough_kind = bm; break end
    end
    bough_kind = bough_kind or "ume"
  end

  -- Interleave bamboo whenever density >= 0.35 (unless a single non-bamboo motif is explicitly forced on a test page
  -- where another motif is forbidden, though bamboo is never forbidden; we include bamboo on all normal/multi-motif/bamboo pages!)
  local with_bamboo = (dens >= 0.35) and (opts.with_bamboo ~= false) and (not forced or has_forced_bamboo or #forced >= 2 or WOODY_BOUGHS[mkind])
  if mkind == "bamboo" then with_bamboo = true end

  -- 2. If the primary motif is wisteria or a clump herb (iris, orchid, narcissus, chrysanthemum), draw it first with M2 flora
  if mkind == "wisteria" and fl.wisteria then
    local w_reg = (mode == "column") and O or sf
    local w_spec = {
      x = x_edge, y = y_top - 10, angle = -pi / 2 + inward * 0.25,
      size = min(hO * (0.45 + 0.25 * dens), 320), droop = min(hO * 0.26, 130),
      racemes = max(3, floor(4 + 4 * dens)), ground = false,
    }
    local wb, wi = plan:fit(mode .. "-wisteria", { region = w_reg, interleave = true }, w_spec, fl.wisteria, { 1, 0.82, 0.66 })
    if wb then bb_total = geom.union(bb_total, wb); merge_info(wi) end
  elseif HERB_FLORA[mkind] and fl[mkind] then
    local h_spec = {
      x = cx, y = y_bot + 6, angle = pi / 2 + inward * 0.08,
      size = min(hO * (0.36 + 0.18 * dens), wO * 2.1, 210),
      leaves = max(4, floor(5 + 4 * dens)), flowers = max(1, floor(1 + 2 * dens)),
      ground = false,
    }
    local hb, hi = plan:fit(mode .. "-" .. mkind, { region = O, interleave = true }, h_spec, fl[mkind], { 1, 0.82, 0.66 })
    if hb then bb_total = geom.union(bb_total, hb); merge_info(hi) end
  end

  -- 3. Tall 3-tier segmented bamboo culms rising through the margin (interleaved in depth layers 14..30)
  if with_bamboo and fl.bamboo then
    local b_y0 = (mode == "overhang") and max(y_bot, O.y0 + hO * 0.08)
      or ((mode == "corner") and max(y_bot, O.y0 + hO * 0.22) or y_bot)
    local b_h = (mode == "corner") and min(hO * (0.48 + 0.24 * dens), 360)
      or min((y_top - b_y0) * (0.68 + 0.26 * dens), 480)
    local n_culms = (wO >= 64 and dens >= 0.50) and 3 or 2
    local b_spec = {
      x = cx + inward * min(8, wO * 0.08),
      y = b_y0,
      angle = pi / 2 + inward * 0.025,
      size = max(120, b_h),
      culms = n_culms,
      width = min(5.4, wO * 0.064),
      leaf = min(32, wO * 0.36),
      density = dens,
    }
    local b_bb, b_inf = plan:fit(mode .. "-bamboo", { region = O, interleave = true, ignore_flowers = true }, b_spec, function(c, sp)
      c.rng = c.rng.child("bamboo-" .. mode)
      return fl.bamboo(c, sp)
    end, { 1, 0.85, 0.70 })
    if b_bb then bb_total = geom.union(bb_total, b_bb); merge_info(b_inf) end
  end

  -- 4. Repeated woody bough stations (2 to 3 stations along the margin weaving through the bamboo culms!)
  --    When forced is a single non-woody motif (e.g. motif=iris or motif=wisteria alone), skip extra woody boughs
  --    if we already drew the forced motif; otherwise draw the repeated woody boughs!
  local want_boughs = (not forced) or (forced_bough ~= nil) or (#forced >= 2) or (mkind == "bamboo" and mode ~= "column") or (not bb_total)
  if want_boughs and bough_kind and fl[bough_kind] then
    local b_reg = (mode == "column") and O or sf
    local o_scale = (dens < 0.35) and 0.78 or min(1.0, max(0.84, wO / 95))
    local stations = {}

    if dens < 0.35 then
      -- Low density (e.g., density=0.2): 1 compact bough station so density_monotonic holds strictly
      if mode == "rising" or mode == "column" then
        stations[#stations + 1] = {
          tag = "bough1", x = cx, y = y_bot + 16, angle = pi / 2 + inward * 0.22,
          size = min(hO * 0.36, 170), fade_base = false, bloom_k = 0.65, wispy_count = 3,
        }
      else
        stations[#stations + 1] = {
          tag = "bough1", x = x_edge, y = y_top - 14, angle = -pi / 2 + inward * 0.28,
          size = min(hO * 0.36, 170), fade_base = true, bloom_k = 0.65, wispy_count = 3,
        }
      end
    else
      -- Normal & high density (0.35..1.0): 2 to 3 repeated woody bough stations interleaved with bamboo!
      if mode == "overhang" then
        -- Station 1: Upper overhanging bough cascading from top-outer corner (arches into top margin T & down O)
        stations[#stations + 1] = {
          tag = "bough-top", x = x_edge, y = y_top - 12,
          angle = -pi / 2 + inward * 0.34,
          size = min(hO * (0.46 + 0.16 * dens), 285),
          fade_base = true, bloom_k = 1.15 + 0.35 * dens, wispy_count = floor(7 + 5 * dens),
        }
        -- Station 2: Lower rising bough with bilateral tapered iri-fude base weaving upward through bamboo
        stations[#stations + 1] = {
          tag = "bough-bot", x = cx - inward * min(10, wO * 0.12), y = y_bot + hO * 0.08,
          angle = pi / 2 + inward * 0.26,
          size = min(hO * (0.44 + 0.14 * dens), 265),
          fade_base = false, bloom_k = 1.10 + 0.30 * dens, wispy_count = floor(6 + 5 * dens),
        }
        -- Station 3: Mid-margin / top-corner repeat bough on tall pages
        if hO >= 340 and dens >= 0.45 then
          stations[#stations + 1] = {
            tag = "bough-mid", x = x_edge, y = y_bot + hO * 0.56,
            angle = -pi / 2 + inward * 0.42,
            size = min(hO * 0.36, 220),
            fade_base = false, bloom_k = 1.05, wispy_count = 6,
          }
        end
      elseif mode == "rising" then
        -- Station 1: Primary rising bough from bottom-outer margin with bilateral tapered iri-fude base
        stations[#stations + 1] = {
          tag = "bough-bot", x = cx - inward * min(8, wO * 0.10), y = y_bot + 14,
          angle = pi / 2 + inward * 0.24,
          size = min(hO * (0.48 + 0.16 * dens), 290),
          fade_base = false, bloom_k = 1.15 + 0.35 * dens, wispy_count = floor(7 + 5 * dens),
        }
        -- Station 2: Upper counter-cascading bough from upper outer margin weaving down into the bamboo crown
        stations[#stations + 1] = {
          tag = "bough-top", x = x_edge, y = y_top - hO * 0.06,
          angle = -pi / 2 + inward * 0.32,
          size = min(hO * (0.42 + 0.14 * dens), 255),
          fade_base = true, bloom_k = 1.10 + 0.30 * dens, wispy_count = floor(6 + 5 * dens),
        }
        -- Station 3: Mid-margin rising repeat bough
        if hO >= 340 and dens >= 0.45 then
          stations[#stations + 1] = {
            tag = "bough-mid", x = x_edge, y = y_bot + hO * 0.44,
            angle = pi / 2 + inward * 0.34,
            size = min(hO * 0.36, 220),
            fade_base = false, bloom_k = 1.05, wispy_count = 6,
          }
        end
      elseif mode == "corner" then
        -- Station 1: Corner-arch bough sweeping down outer margin O
        stations[#stations + 1] = {
          tag = "bough-corner1", x = x_edge, y = y_top - 10,
          angle = -pi / 2 + inward * 0.36,
          size = min(hO * (0.44 + 0.16 * dens), 275),
          fade_base = true, bloom_k = 1.15 + 0.35 * dens, wispy_count = floor(7 + 5 * dens),
        }
        -- Station 2: Repeat bough rising from mid-margin to meet the corner bough & bamboo
        stations[#stations + 1] = {
          tag = "bough-corner2", x = cx - inward * min(10, wO * 0.12), y = max(y_bot + 16, y_top - hO * 0.66),
          angle = pi / 2 + inward * 0.28,
          size = min(hO * (0.38 + 0.14 * dens), 240),
          fade_base = false, bloom_k = 1.10 + 0.25 * dens, wispy_count = floor(6 + 4 * dens),
        }
      else -- "column" (strictly inside O)
        stations[#stations + 1] = {
          tag = "bough-col1", x = cx - inward * min(8, wO * 0.10), y = y_bot + hO * 0.06,
          angle = pi / 2 + inward * 0.18,
          size = min(hO * (0.44 + 0.14 * dens), 265),
          fade_base = false, bloom_k = 1.10 + 0.25 * dens, wispy_count = floor(6 + 4 * dens),
        }
        stations[#stations + 1] = {
          tag = "bough-col2", x = x_edge, y = y_top - hO * 0.06,
          angle = -pi / 2 + inward * 0.22,
          size = min(hO * (0.40 + 0.14 * dens), 245),
          fade_base = true, bloom_k = 1.05 + 0.25 * dens, wispy_count = floor(5 + 4 * dens),
        }
      end
    end

    for idx, st in ipairs(stations) do
      local sp0 = {
        x = st.x, y = st.y, angle = st.angle,
        size = st.size, band_w = wO,
        fade_base = st.fade_base, ground = false,
        organ_scale = o_scale * (idx == 1 and 1.0 or 0.92),
        bloom_k = st.bloom_k, wispy_count = st.wispy_count,
        density = dens,
      }
      local sb, si = plan:fit(mode .. "-" .. st.tag, { region = b_reg, interleave = true }, sp0, function(c, sp)
        c.rng = c.rng.child(mode .. "-bough-" .. idx)
        return fl[bough_kind](c, sp)
      end, { 1, 0.84, 0.70, 0.56 })
      if sb then bb_total = geom.union(bb_total, sb); merge_info(si) end
    end
  end

  return bb_total, info_total
end

function L.layouts.overhang(ctx, page)
  local z = L.zones(page)
  local O = z.outer or z.top or z.bottom
  if not O then return end
  local plan = L.plan(ctx, page)
  add_sky_bokashi(plan, z)
  local cands = pick_branch_candidates({ page = page, theme = ctx.theme }, nil)
  local mkind = cands[1] or "sakura"
  local wO, hO = geom.width(O), geom.height(O)
  local cx = (O.x0 + O.x1) * 0.5
  local y_top = min(page.safe.y1 - 8, O.y1 - 10)
  local y_bot = max(page.safe.y0 + 10, O.y0 + hO * 0.12)
  local bb, info = L.interleaved_boughs_and_bamboo(plan, z, { mode = "overhang", zone = O, motif = mkind })
  if not bb then
    local sw = min(18, wO * 0.30)
    local rects = { O }
    local stems = {}
    if z.top and geom.height(z.top) >= 22 then
      rects[#rects + 1] = z.top
      local T = z.top
      local tx1 = max(T.x0 + 14, min(T.x1 - 14, cx + z.inward * min(geom.width(T) * 0.56, 220)))
      local tym = (T.y0 + T.y1) * 0.5
      local ampT = min(5.5, geom.height(T) * 0.20)
      stems[#stems + 1] = { spine = W.corner_spine(tx1, tym, cx, tym, cx - z.inward * sw * 0.2, y_bot, 26, ampT, 0.3, sw), w0 = 3.2, w1 = 0.55, n = 48 }
      stems[#stems + 1] = { spine = W.sway_spine(cx + z.inward * sw * 0.28, y_top - 8, cx + z.inward * sw * 0.15, y_bot + (y_top - y_bot) * 0.14, 1, 0, sw * 0.88, 2.2, 0.8), w0 = 2.2, w1 = 0.45, n = 36 }
      stems[#stems + 1] = { spine = W.sway_spine(cx - z.inward * sw * 0.32, y_top - 18, cx - z.inward * sw * 0.18, y_bot + (y_top - y_bot) * 0.26, 1, 0, sw * 0.72, 4.0, 1.8), w0 = 1.5, w1 = 0.34, n = 28, layer = 15, alpha = 0.34 }
    else
      stems[#stems + 1] = { spine = W.sway_spine(cx - z.inward * sw * 0.15, y_top, cx + z.inward * sw * 0.15, y_bot, 1, 0, sw, 0.3, 1.7), w0 = 3.1, w1 = 0.55, n = 42 }
      stems[#stems + 1] = { spine = W.sway_spine(cx + z.inward * sw * 0.3, y_top - 10, cx - z.inward * sw * 0.2, y_bot + (y_top - y_bot) * 0.16, 1, 0, sw * 0.88, 2.2, 0.8), w0 = 2.1, w1 = 0.45, n = 32 }
    end
    bb, info = plan:attempt("overhang-garden", {}, function(c)
      return L.grow_garden(c, rects, {
        motif = mkind, stems = stems,
        root = { cx, y_top }, root_r = min(13, wO * 0.25), root_deg = 0,
        heroes = {
          { cx, y_top - min(36, hO * 0.10), min(40, wO * 0.45) },
          { cx - z.inward * sw * 0.25, (y_top + y_bot) * 0.54, min(30, wO * 0.38) },
          { cx + z.inward * sw * 0.20, y_bot + (y_top - y_bot) * 0.22, min(24, wO * 0.32) },
        },
      })
    end)
  end
  if not bb then
    local spec = { x = cx, y = y_top - 18, angle = -pi / 2 + z.inward * 0.22, size = hO * 0.72, motif = mkind }
    bb, info = plan:fit("overhang-stub", { region = O }, spec, S.branch)
  end
  if not bb then return plan:log("overhang: no fit") end
  plan.host_occ = {}
  add_bird(plan, info, z)
  local sx = z.is_right and (O.x1 - 24) or (O.x0 + 6)
  add_seal(plan, { { sx, O.y0 + 28 }, { sx, O.y0 + 62 } })
  if theme_of(ctx).petals then petals(plan, { z.bottom or O }, 3) end
  apply_extra_motifs(plan, info, z)
end

function L.layouts.rising(ctx, page)
  local z = L.zones(page)
  local O = z.outer or z.bottom or z.top
  if not O then return end
  local plan = L.plan(ctx, page)
  add_sky_bokashi(plan, z)
  local cands = pick_branch_candidates({ page = page, theme = ctx.theme }, nil)
  local mkind = cands[1] or "sakura"
  local wO, hO = geom.width(O), geom.height(O)
  local cx = (O.x0 + O.x1) * 0.5
  local y_bot = max(page.safe.y0 + 10, O.y0 + 12)
  local y_top = min(page.safe.y1 - 10, O.y1 - hO * 0.06)
  local bb, info = L.interleaved_boughs_and_bamboo(plan, z, { mode = "rising", zone = O, motif = mkind })
  if not bb then
    local sw = min(18, wO * 0.30)
    local rects = { O }
    local stems = {}
    if z.bottom and geom.height(z.bottom) >= 22 then
      rects[#rects + 1] = z.bottom
      local Bo = z.bottom
      local bx1 = max(Bo.x0 + 14, min(Bo.x1 - 14, cx + z.inward * min(geom.width(Bo) * 0.42, 170)))
      local bym = (Bo.y0 + Bo.y1) * 0.5
      local ampB = min(5.0, geom.height(Bo) * 0.18)
      stems[#stems + 1] = { spine = W.corner_spine(bx1, bym, cx, bym, cx - z.inward * sw * 0.2, y_top, 26, ampB, 0.5, sw), w0 = 3.2, w1 = 0.55, n = 50 }
      stems[#stems + 1] = { spine = W.sway_spine(cx + z.inward * sw * 0.28, y_bot + 8, cx + z.inward * sw * 0.15, y_top - (y_top - y_bot) * 0.14, 1, 0, sw * 0.88, 2.3, 0.9), w0 = 2.2, w1 = 0.45, n = 36 }
      stems[#stems + 1] = { spine = W.sway_spine(cx - z.inward * sw * 0.32, y_bot + 18, cx - z.inward * sw * 0.18, y_top - (y_top - y_bot) * 0.24, 1, 0, sw * 0.72, 4.1, 1.9), w0 = 1.5, w1 = 0.34, n = 28, layer = 15, alpha = 0.34 }
    else
      stems[#stems + 1] = { spine = W.sway_spine(cx - z.inward * sw * 0.15, y_bot, cx + z.inward * sw * 0.15, y_top, 1, 0, sw, 0.5, 1.8), w0 = 3.1, w1 = 0.55, n = 42 }
      stems[#stems + 1] = { spine = W.sway_spine(cx + z.inward * sw * 0.3, y_bot + 10, cx - z.inward * sw * 0.2, y_top - (y_top - y_bot) * 0.14, 1, 0, sw * 0.88, 2.3, 0.9), w0 = 2.1, w1 = 0.45, n = 32 }
    end
    bb, info = plan:attempt("rising-garden", {}, function(c)
      return L.grow_garden(c, rects, {
        motif = mkind, stems = stems,
        root = { cx, y_bot }, root_r = min(13, wO * 0.25), root_deg = 180,
        heroes = {
          { cx, y_bot + min(36, hO * 0.12), min(40, wO * 0.45) },
          { cx - z.inward * sw * 0.25, (y_bot + y_top) * 0.56, min(30, wO * 0.38) },
          { cx + z.inward * sw * 0.20, y_top - (y_top - y_bot) * 0.18, min(24, wO * 0.32) },
        },
      })
    end)
  end
  if not bb then
    local spec = { x = cx, y = y_bot + 18, angle = pi / 2 + z.inward * 0.20, size = hO * 0.72, motif = mkind }
    bb, info = plan:fit("rising-stub", { region = O }, spec, S.branch)
  end
  if not bb then return plan:log("rising: no fit") end
  plan.host_occ = {}
  add_bird(plan, info, z)
  local sx = z.is_right and (O.x0 + 6) or (O.x1 - 24)
  add_seal(plan, { { sx, O.y1 - 42 }, { sx, O.y0 + 28 } })
  apply_extra_motifs(plan, info, z)
end

L.demo_garden = L.layouts.rising


L.layouts["corner-spray"] = function(ctx, page)
  local z = L.zones(page)
  local plan = L.plan(ctx, page)
  add_sky_bokashi(plan, z)
  local O, T = z.outer, z.top
  if not O and not T then return end
  local dens = ctx.density or 0.5
  local scale_d = 0.38 + 0.62 * dens
  local cands = pick_branch_candidates({ page = page, theme = ctx.theme }, nil)
  local mkind = cands[1] or "sakura"
  local bb, info
  if O then
    bb, info = L.interleaved_boughs_and_bamboo(plan, z, { mode = "corner", zone = O, motif = mkind })
  end
  local cx = O and ((O.x0 + O.x1) * 0.5) or (T and ((T.x0 + T.x1) * 0.5) or 100)
  if not bb then
    local rects, stems, heroes = {}, {}, {}
    if O and T and geom.height(T) >= 22 then
      rects[#rects + 1] = O
      rects[#rects + 1] = T
      local wO, hO = geom.width(O), geom.height(O)
      local wT = geom.width(T)
      local y_top = min(page.safe.y1 - 10, O.y1 - 12)
      local y_bot = max(page.safe.y0 + 12, y_top - hO * 0.76 * scale_d)
      local tx1 = max(T.x0 + 14, min(T.x1 - 14, cx + z.inward * min(wT * 0.58, 220) * scale_d))
      local tym = (T.y0 + T.y1) * 0.5
      local sw = min(15, wO * 0.28) * scale_d
      local ampT = min(5.5, geom.height(T) * 0.20) * scale_d
      stems[#stems + 1] = {
        spine = W.corner_spine(cx, y_bot, cx, tym, tx1, tym, 24, sw, 0.4, ampT),
        w0 = 2.9 * scale_d, w1 = 0.52 * scale_d, n = max(20, floor(42 * scale_d)),
      }
      stems[#stems + 1] = {
        spine = W.sway_spine(cx + z.inward * sw * 0.25, y_top - 8, cx - z.inward * sw * 0.2, y_bot + (y_top - y_bot) * 0.18, 1, 0, sw * 0.85, 2.1, 0.8),
        w0 = 1.9 * scale_d, w1 = 0.42 * scale_d, n = max(14, floor(28 * scale_d)),
      }
      heroes[#heroes + 1] = { cx, y_top - min(28, hO * 0.10), min(38, wO * 0.44) * scale_d }
      heroes[#heroes + 1] = { cx, (y_top + y_bot) * 0.52, min(28, wO * 0.36) * scale_d }
    elseif O then
      rects[#rects + 1] = O
      local wO, hO = geom.width(O), geom.height(O)
      local y_top = min(page.safe.y1 - 10, O.y1 - 12)
      local y_bot = max(page.safe.y0 + 12, y_top - hO * 0.74 * scale_d)
      local sw = min(15, wO * 0.28) * scale_d
      stems[#stems + 1] = {
        spine = W.sway_spine(cx, y_top, cx, y_bot, 1, 0, sw, 0.4, 1.7),
        w0 = 2.8 * scale_d, w1 = 0.52 * scale_d, n = max(16, floor(34 * scale_d)),
      }
      heroes[#heroes + 1] = { cx, y_top - min(28, hO * 0.10), min(38, wO * 0.44) * scale_d }
    elseif T then
      rects[#rects + 1] = T
      local wT, hT = geom.width(T), geom.height(T)
      local tx0 = z.is_right and (T.x1 - 14) or (T.x0 + 14)
      local tx1 = max(T.x0 + 12, min(T.x1 - 12, tx0 + z.inward * wT * 0.68 * scale_d))
      local tym = (T.y0 + T.y1) * 0.5
      stems[#stems + 1] = {
        spine = W.sway_spine(tx0, tym, tx1, tym, 0, 1, min(9, hT * 0.25) * scale_d, 0.4, 1.7),
        w0 = 2.3 * scale_d, w1 = 0.45 * scale_d, n = max(14, floor(28 * scale_d)), horiz = true,
      }
      heroes[#heroes + 1] = { tx0 + (tx1 - tx0) * 0.18, tym, min(28, hT * 0.42) * scale_d }
    end
    bb, info = plan:attempt("corner-garden", {}, function(c)
      return L.grow_garden(c, rects, {
        motif = mkind, density = dens, stems = stems, heroes = heroes,
        nb = max(1, floor(3 + 20 * dens)),
        nf = max(1, floor(2 + 16 * dens)),
      })
    end)
  end
  if not bb and O then
    local spec = { x = cx, y = O.y1 - 22, angle = -pi / 2 + z.inward * 0.24, size = geom.height(O) * 0.65 * scale_d, motif = mkind, nt = max(2, floor(2 + 6 * dens)) }
    bb, info = plan:fit("corner-stub", { region = O }, spec, S.branch)
  end
  if not bb then return plan:log("corner: no fit") end
  plan.host_occ = {}
  if dens >= 0.45 then add_bird(plan, info, z) end
  if dens >= 0.55 and theme_of(ctx).petals then
    petals(plan, { O, z.bottom or O }, max(1, floor(5 * dens)))
  end
  apply_extra_motifs(plan, info, z)
end

L.layouts["margin-column"] = function(ctx, page)
  local z = L.zones(page)
  local O = z.outer or z.right or z.left
  if not O then return end
  local plan = L.plan(ctx, page)
  local forced = page_motifs(page)
  local th = theme_of(ctx)
  local mkind = (forced and forced[1]) or (th.column and th.column[1]) or "bamboo"
  local bb, info = L.interleaved_boughs_and_bamboo(plan, z, { mode = "column", zone = O, motif = mkind })
  if not bb then
    bb, info = plan:attempt("column-garden", { region = O }, function(c)
      return S.culms(c, { zone = O, n = z.wO > 90 and 3 or 2, motif = mkind })
    end)
  end
  apply_extra_motifs(plan, info, z)
end

L.layouts["header-garland"] = function(ctx, page)
  local z = L.zones(page)
  local T = z.top
  if not T then return end
  local plan = L.plan(ctx, page)
  local forced = page_motifs(page)
  local mkind = (forced and forced[1]) or theme_of(ctx).garland or "wisteria"
  local wT = geom.width(T)
  local from = z.is_right and (T.x1 - 10) or (T.x0 + 10)
  local to   = z.is_right and (T.x0 + wT * 0.16) or (T.x1 - wT * 0.16)
  local bb, info = plan:attempt("garland", { region = T }, function(c)
    return S.vine(c, { zone = T, from = from, to = to, motif = mkind })
  end)
  if not bb then petals(plan, { T }, 4) end
  apply_extra_motifs(plan, info, z)
end

L.layouts["footer-ground"] = function(ctx, page)
  local z = L.zones(page)
  local Bo = z.bottom
  if not Bo then return end
  local plan = L.plan(ctx, page)
  local w, h = geom.width(Bo), geom.height(Bo)
  local forced = page_motifs(page)
  local has_fuji = (forced and forced[1] == "fuji")
  local x0 = z.is_right and (Bo.x1 - 10) or (Bo.x0 + 10)
  local x1 = z.is_right and (Bo.x0 + w * 0.14) or (Bo.x1 - w * 0.14)
  plan:attempt("footer-wash", { region = Bo }, function(c)
    return S.bank(c, { x0 = min(x0, x1), x1 = max(x0, x1), y = Bo.y0 + 2, height = min(16, h * 0.38) })
  end)
  plan.occ = {}
  local th = theme_of(ctx)
  local mkind = (forced and forced[1] ~= "fuji" and forced[1] ~= "rock" and forced[1]) or (th.ground and th.ground[1]) or th.branch[1] or "iris"
  if has_fuji and L.M2.scenery then
    local O = z.outer
    if O and geom.width(O) >= 70 then
      -- Place distant Mount Fuji in the open lower-outer corner vista so it has vertical room for proper 35-deg slopes
      local fw = min(geom.width(O) * 0.92, 115)
      local fx = (O.x0 + O.x1) * 0.5
      local fzone = { x0 = O.x0, y0 = Bo.y0, x1 = O.x1, y1 = min(O.y1, Bo.y0 + 96) }
      plan:attempt("footer-fuji", { region = fzone }, function(c)
        return L.M2.scenery.fuji(c, { x = fx, y = Bo.y0 + 14, width = fw, height = fw * 0.36 })
      end)
      -- Place Scholar Rock at the junction and sweep the floral garland across the rest of the footer
      local v0 = z.is_right and (Bo.x0 + 14) or (O.x1 + 26)
      local v1 = z.is_right and (O.x0 - 26) or (Bo.x1 - 14)
      local rx = z.is_right and (O.x0 - 10) or (O.x1 + 10)
      if abs(v1 - v0) > 60 then
        local vine_z = { x0 = min(v0, v1) - 8, y0 = Bo.y0, x1 = max(v0, v1) + 8, y1 = Bo.y1 }
        plan:attempt("footer-garden", { region = vine_z }, function(c)
          return S.vine(c, { zone = vine_z, from = v0, to = v1, motif = mkind })
        end)
      end
      plan.occ = {}
      if h >= 26 then
        plan:attempt("footer-rock", { region = Bo }, function(c)
          return L.M2.scenery.rock(c, { x = rx, y = Bo.y0 + 4, size = min(h * 0.58, 34) })
        end)
      end
    else
      local vine_z = { x0 = Bo.x0, y0 = Bo.y0, x1 = Bo.x0 + w * 0.56, y1 = Bo.y1 }
      plan:attempt("footer-garden", { region = vine_z }, function(c)
        return S.vine(c, { zone = vine_z, from = Bo.x0 + 10, to = Bo.x0 + w * 0.52, motif = mkind })
      end)
      plan.occ = {}
      if h >= 26 then
        plan:attempt("footer-rock", { region = Bo }, function(c)
          return L.M2.scenery.rock(c, { x = Bo.x0 + w * 0.60, y = Bo.y0 + 4, size = min(h * 0.56, 32) })
        end)
      end
      plan:attempt("footer-fuji", { region = Bo }, function(c)
        return L.M2.scenery.fuji(c, { x = Bo.x0 + w * 0.78, y = Bo.y0 + 4, width = min(w * 0.36, (h - 6) * 2.7, 135) })
      end)
    end
  else
    plan:attempt("footer-garden", { region = Bo }, function(c)
      return S.vine(c, { zone = Bo, from = x0, to = x1, motif = mkind })
    end)
    plan.occ = {}
    if L.M2.scenery and h >= 32 then
      plan:attempt("footer-rock", { region = Bo }, function(c)
        return L.M2.scenery.rock(c, { x = min(x0, x1) + abs(x1 - x0) * 0.24, y = Bo.y0 + 4, size = min(h * 0.58, 38) })
      end)
    end
  end
end

L.layouts["scattered-petals"] = function(ctx, page)
  local z = L.zones(page)
  local plan = L.plan(ctx, page)
  petals(plan, { z.outer, z.bottom, z.top }, 7)
end

---------------------------------------------------------------- corners-only & sides-only (for `regions=`)
L.layouts["corners"] = function(ctx, page)
  local sf = page.safe
  local tb = page.block
  local blk = geom.inflate(tb, page.buffer or 11.34)
  local plan = L.plan(ctx, page)
  local cboxes = {
    { x0 = sf.x0,  y0 = blk.y1, x1 = blk.x0, y1 = sf.y1, name = "tl" },
    { x0 = blk.x1, y0 = blk.y1, x1 = sf.x1,  y1 = sf.y1, name = "tr" },
    { x0 = sf.x0,  y0 = sf.y0,  x1 = blk.x0, y1 = blk.y0, name = "bl" },
    { x0 = blk.x1, y0 = sf.y0,  x1 = sf.x1,  y1 = blk.y0, name = "br" },
  }
  for _, cb in ipairs(cboxes) do
    if geom.width(cb) >= 24 and geom.height(cb) >= 24 then
      plan:attempt("corner-" .. cb.name, { region = cb }, function(c)
        return S.vine(c, { zone = cb, from = cb.x0 + 6, to = cb.x1 - 6, motif = theme_of(ctx).branch[1] })
      end)
    end
  end
end

local VALID_REGION_TOKENS = {
  auto = true, none = true, corners = true, frame = true,
  outer = true, inner = true, left = true, right = true, top = true, bottom = true,
}

function L.parse_regions_opt(raw, page)
  if not raw or raw == "" or raw == "auto" then return { mode = "auto" } end
  local s = tostring(raw):gsub("^%s*{", ""):gsub("}%s*$", "")
  local tokens = {}
  for tok in s:gmatch("[^,%s;]+") do
    local k = tok:lower()
    if not VALID_REGION_TOKENS[k] then
      warn_msg("unknown region '" .. tok .. "' in regions=" .. tostring(raw))
    else
      tokens[k] = true
    end
  end
  if tokens.none then return { mode = "none" } end
  if tokens.frame then return { mode = "frame" } end
  if tokens.corners then return { mode = "corners" } end
  local sides = {}
  local outer_s = (page and page.outer) or "right"
  local inner_s = (outer_s == "right") and "left" or "right"
  if tokens.outer then sides[outer_s] = true end
  if tokens.inner then sides[inner_s] = true end
  for _, k in ipairs({ "left", "right", "top", "bottom" }) do
    if tokens[k] then sides[k] = true end
  end
  if next(sides) == nil then return { mode = "auto" } end
  return { mode = "sides", sides = sides }
end

L.layouts["regions-sides"] = function(ctx, page)
  local rspec = L.parse_regions_opt(page and page.opts and page.opts.regions, page)
  local sides = rspec.sides or {}
  local plan = L.plan(ctx, page)
  local mkind = theme_of(ctx).branch[1]
  for _, sname in ipairs({ "top", "bottom", "left", "right" }) do
    if sides[sname] then
      local B = raw_side_band(page, sname)
      if B then
        if sname == "top" or sname == "bottom" then
          plan:attempt("side-" .. sname, { region = B }, function(c)
            return S.vine(c, { zone = B, from = B.x0 + 8, to = B.x1 - 8, motif = mkind })
          end)
        else
          plan:attempt("side-" .. sname, { region = B }, function(c)
            return S.culms(c, { zone = B, n = 2, motif = mkind })
          end)
        end
      end
    end
  end
end

---------------------------------------------------------------- auto + deck
local function feasible(v, z)
  if v == "header-garland" then return z.hT >= 32 end
  if v == "footer-ground" then return z.hB >= 32 end
  if v == "corner-spray" then return z.hT >= 28 and z.wO >= 28 end
  return z.wO >= 28
end
L.feasible = feasible

function L.deck_pick(seed, index, list)
  list = list or { "overhang", "corner-spray", "rising", "margin-column", "header-garland", "footer-ground" }
  local n = #list
  if n == 0 then return "scattered-petals" end
  if n == 1 then return list[1] end
  local function deck(k)
    local r = rngm.new(rngm.hash("kacho-deck:" .. (seed or 1) .. ":" .. k))
    local d = {}
    for i = 1, n do d[i] = list[i] end
    for i = n, 2, -1 do local j = r.int(1, i); d[i], d[j] = d[j], d[i] end
    return d
  end
  local idx = max(1, index or 1)
  local k, pos = floor((idx - 1) / n), (idx - 1) % n + 1
  local d = deck(k)
  if k > 0 and d[1] == deck(k - 1)[n] then d[1], d[2] = d[2], d[1] end
  return d[pos]
end

function L.auto(a, b)
  local page, ctx
  if a and a.paper then page, ctx = a, b else ctx, page = a, b end
  page_motifs(page)

  local rspec = L.parse_regions_opt(page and page.opts and page.opts.regions, page)
  if rspec.mode == "none" then return "none", nil
  elseif rspec.mode == "frame" then return "border-frame", L.layouts["border-frame"]
  elseif rspec.mode == "corners" then return "corners", L.layouts["corners"]
  elseif rspec.mode == "sides" then return "regions-sides", L.layouts["regions-sides"] end

  local forced = page_motifs(page)
  if forced and forced[1] == "wisteria" then return "overhang", L.layouts.overhang end
  if forced and forced[1] == "fuji" then return "footer-ground", L.layouts["footer-ground"] end

  local th = theme_of(ctx)
  local z = L.zones(page)
  local ok = {}
  for _, v in ipairs(th.variants) do if feasible(v, z) then ok[#ok + 1] = v end end
  if #ok == 0 then
    local fb = (z.wO >= 16 or z.hB >= 16 or z.hT >= 16) and "scattered-petals" or "none"
    return fb, L.layouts[fb]
  end
  local seed = (ctx and ctx.opts and ctx.opts.seed) or (page and page.opts and page.opts.seed) or 1
  local chosen = L.deck_pick(seed, page and page.index or 1, ok)
  return chosen, L.layouts[chosen]
end


---------------------------------------------------------------- kakejiku title page & shikishi chapter opener
L.layouts.kakejiku = function(ctx, page)
  local P = ctx.palette
  local pw, ph = page.paper.w, page.paper.h
  local tb = page.block
  local U = ctx.under
  local hanga = P.name == "hanga"
  local mount = hanga and palm.mix(P.color("ai"), P.paper, 0.15) or palm.mix(P.color("kincha"), P.color("sumi-mid"), 0.35)
  local mount_lt = palm.mix(mount, P.paper, 0.55)
  local gold = palm.mix(P.color("kincha"), P.paper, 0.25)
  local panel_c = P.color(hanga and "torinoko" or "koson-greige")
  local side = max(page.safe.x0 + 18, pw * 0.08)
  local ten = min(ph * 0.13, max(36, ph - tb.y1 - 26))
  local chi = min(ph * 0.085, ten * 0.72)
  local ich = ph * 0.012
  local panel = { x0 = side, y0 = chi + ich, x1 = pw - side, y1 = ph - ten - ich }
  if U then
    local rec = function(b) ctx.record("kakejiku-ground", b) end
    rec(U:fill(U:rect(0, 0, pw, ph), mount_lt, 1))
    rec(U:fill(U:rect(0, ph - ten, pw, ph), mount, 1))
    rec(U:fill(U:rect(0, 0, pw, chi), mount, 1))
    rec(U:fill(U:rect(side, panel.y1, pw - side, panel.y1 + ich), gold, 1))
    rec(U:fill(U:rect(side, panel.y0 - ich, pw - side, panel.y0), gold, 1))
    for _, fx in ipairs({ 0.36, 0.64 }) do
      rec(U:fill(U:rect(pw * fx - 6, ph - ten, pw * fx + 6, ph), mount_lt, 0.9))
      rec(U:fill(U:rect(pw * fx - 6, ph - ten, pw * fx - 5.2, ph), gold, 1))
      rec(U:fill(U:rect(pw * fx + 5.2, ph - ten, pw * fx + 6, ph), gold, 1))
    end
    rec(U:fill(U:rect(panel), panel_c, 1))
    local top = min(panel.y0 + (panel.y1 - panel.y0) * 0.35, tb.y0 - 20)
    if top > panel.y0 + 30 then
      local pat = U:axial(0, panel.y0, 0, top, { { 0, palm.mix(P.color(hanga and "bokashi-sky" or "sumi-wash"), panel_c, 0.3) }, { 1, panel_c } })
      rec(U:fill_pattern(U:rect(panel.x0, panel.y0, panel.x1, top), pat, 0.55))
    end
  end
  local plan = L.plan(ctx, page)
  local art = geom.inflate(panel, -8)
  local cands = pick_branch_candidates({ page = page, theme = ctx.theme }, nil)
  local mkind = cands[1] or "sakura"
  local xl, xr = art.x0 + 18, art.x1 - 18
  local yt = min(art.y1 - 16, max(tb.y1 + 22, art.y1 - 28))
  local yb = max(art.y0 + 16, min(tb.y0 - 28, art.y0 + geom.height(art) * 0.24))
  local xm = (xl + xr) * 0.5
  local stems = {
    -- Paired symmetric top-corner floral arches + rising right/bottom garden with smooth rounded corners
    { spine = W.corner_spine(xl, yt - 62, xl, yt, xm - 14, yt - 2, 50, 7, 0.4), w0 = 2.6, w1 = 0.48, n = 34 },
    { spine = W.corner_spine(xr, yt - 62, xr, yt, xm + 14, yt - 2, 50, 7, 0.4), w0 = 2.6, w1 = 0.48, n = 34 },
    { spine = W.corner_spine(xl + 28, yb, xr - 4, yb, xr - 4, yt - 32, 58, 10, 0.6), w0 = 3.0, w1 = 0.58, n = 46 },
    { spine = W.sway_spine(xr - 12, yb + 10, xr - 8, yt - 44, 1, 0, 9, 2.2, 0.9), w0 = 2.0, w1 = 0.42, n = 30 },
  }
  local bb, info = plan:attempt("kakejiku-garden", { region = art }, function(c)
    return L.grow_garden(c, { art }, {
      motif = mkind, stems = stems,
      heroes = { { xl + 16, yt - 10, 32 }, { xr - 16, yt - 10, 32 }, { xr - 12, yb + 24, 38 }, { xm, yb + 10, 28 } },
      nb = 20, nf = 16,
    })
  end)
  if not bb then
    local spec = { x = xr - 12, y = yb + 12, angle = pi / 2 - 0.15, size = geom.height(art) * 0.72, motif = mkind }
    bb, info = plan:fit("kakejiku-stub", { region = art }, spec, S.branch)
  end
  plan.host_occ = {}
  if bb then add_bird(plan, info, { wO = 90, inward = -1 }) end
  local s = max(14, min(20, ph / 38))
  local sx = tb.x0 + 4
  for _, y in ipairs({ tb.y0 - page.buffer - s * 1.25 - 6, tb.y0 - page.buffer - 2 * s * 1.25 - 12 }) do
    add_seal(plan, { { sx, y } })
  end
  return bb
end

L.layouts.shikishi = function(ctx, page)
  local P = ctx.palette
  local U = ctx.under
  local tb = page.block
  local s = page.safe
  local below = { x0 = s.x0, y0 = s.y0, x1 = s.x1, y1 = tb.y0 - page.buffer }
  for i = 2, #page.exclude do
    local e = page.exclude[i]
    if e.y1 < below.y1 then below.y0 = max(below.y0, e.y1) end
  end
  local side = min(geom.width(page.text) * 0.95, geom.height(below) - 24)
  if side < 110 then return L.layouts.overhang(ctx, page) end
  local cx = (page.text.x0 + page.text.x1) / 2
  local sq = { x0 = cx - side / 2, y0 = below.y1 - 12 - side, x1 = cx + side / 2, y1 = below.y1 - 12 }
  local plan = L.plan(ctx, page)
  if U then
    local gold = palm.mix(P.color("kincha"), P.paper, 0.2)
    ctx.record("shikishi-ground", U:fill(U:rect(geom.inflate(sq, 4)), gold, 1))
    ctx.record("shikishi-ground", U:fill(U:rect(sq), P.color(P.name == "hanga" and "torinoko" or "koson-greige"), 1))
  end
  local art = geom.inflate(sq, -10)
  local cands = pick_branch_candidates({ page = page, theme = ctx.theme }, nil)
  local mkind = cands[1] or "sakura"
  local ox, oy = art.x1 - side * 0.16, art.y0 + side * 0.16
  local stems = {
    { spine = INK.bezier3(ox, oy, ox + 6, oy + side * 0.25, ox - side * 0.18, oy + side * 0.55, art.x0 + side * 0.28, art.y1 - side * 0.18), w0 = 2.6, w1 = 0.55, n = 30 },
    { spine = INK.bezier3(ox, oy, ox - side * 0.25, oy - 4, art.x0 + side * 0.35, oy + 8, art.x0 + side * 0.16, oy + side * 0.28), w0 = 2.0, w1 = 0.42, n = 24, horiz = true },
  }
  local bb, info = plan:attempt("shikishi-garden", { region = art }, function(c)
    return L.grow_garden(c, { art }, {
      motif = mkind, stems = stems,
      root = { ox, oy }, root_r = 9, root_deg = 135,
      heroes = { { ox - 12, oy + 18, min(30, side * 0.18) }, { cx, (art.y0 + art.y1) * 0.55, min(22, side * 0.14) } },
      nb = 14, nf = 10,
    })
  end)
  if not bb then
    local spec = { x = ox, y = oy + 10, angle = pi * 0.72, size = side * 0.78, motif = mkind }
    bb, info = plan:fit("shikishi-stub", { region = art }, spec, S.branch)
  end
  plan.host_occ = {}
  if bb then add_bird(plan, info, { wO = side * 0.35, inward = -1 }) end
  local ssz = max(14, min(18, side / 16))
  add_seal(plan, { { art.x0 + 8, art.y0 + 10 } })
end

---------------------------------------------------------------- user placement
local UNITS = { pt = 72 / 72.27, bp = 1, mm = 72 / 25.4, cm = 72 / 2.54, ["in"] = 72 }
local function dim(s, dflt)
  if type(s) == "number" then return s end
  if s == nil or s == "" then return dflt end
  local n, u = tostring(s):match("^%s*([%-%+]?[%d%.]+)%s*(%a*)%s*$")
  if not n then return dflt end
  return tonumber(n) * (UNITS[u ~= "" and u or "bp"] or 1)
end
L.dim = dim

local function kv(input)
  if type(input) == "table" then
    if input[1] and type(input[1]) == "table" then
      local t = {}
      for _, p in ipairs(input) do t[p[1]] = p[2] end
      return t
    end
    return input
  end
  if type(input) == "string" then
    local ok, k = pcall(require, "kacho")
    if ok and k and type(k.parse_keyvals) == "function" then
      local list = k.parse_keyvals(input)
      local t = {}
      for _, p in ipairs(list) do t[p[1]] = p[2] end
      return t
    end
  end
  return {}
end

function L.parse_spawn(spec)
  if type(spec) ~= "string" then return nil end
  local s = spec:match("^%s*(.-)%s*$")
  if s == "" then return nil end
  if s:find("=", 1, true) then return kv(s) end
  local head, ang = s:match("^(.-)@([%+%-]?%d*%.?%d+)%s*$")
  if not head then head = s end
  local at, rest = head:match("^([%a%-]+)(.*)$")
  if not at then return nil end
  local dx_s, dy_s
  if rest and rest ~= "" then
    dx_s, dy_s = rest:match("^([%+%-][^%+%-]+)([%+%-].+)$")
    if not dx_s then dx_s = rest end
  end
  return { at = at, dx = dx_s, dy = dy_s, angle = ang }
end

local function expand_spawns(raw_list)
  local out = {}
  for _, item in ipairs(raw_list or {}) do
    if type(item) == "table" then out[#out + 1] = kv(item)
    elseif type(item) == "string" then
      local s = item:gsub("^%s*{", ""):gsub("}%s*$", "")
      if s:find("=", 1, true) and not s:find(";", 1, true) then out[#out + 1] = kv(s)
      else
        for part in s:gmatch("[^;]+") do
          local sp = L.parse_spawn(part)
          if sp then out[#out + 1] = sp end
        end
      end
    end
  end
  return out
end

local ANCHOR_MAP = {
  tl = { 0, 1 }, tc = { 0.5, 1 }, tr = { 1, 1 },
  ml = { 0, 0.5 }, c = { 0.5, 0.5 }, mr = { 1, 0.5 },
  bl = { 0, 0 }, bc = { 0.5, 0 }, br = { 1, 0 },
  ["top-left"] = { 0, 1 }, ["top-center"] = { 0.5, 1 }, ["top-right"] = { 1, 1 },
  ["mid-left"] = { 0, 0.5 }, center = { 0.5, 0.5 }, centre = { 0.5, 0.5 }, ["mid-right"] = { 1, 0.5 },
  ["bottom-left"] = { 0, 0 }, ["bottom-center"] = { 0.5, 0 }, ["bottom-right"] = { 1, 0 },
  top = { 0.5, 1 }, bottom = { 0.5, 0 }, left = { 0, 0.5 }, right = { 1, 0.5 },
  ["l-top"] = { 0, 1 }, ["top-l"] = { 0, 1 }, ["r-top"] = { 1, 1 }, ["top-r"] = { 1, 1 },
  ["l-bottom"] = { 0, 0 }, ["bottom-l"] = { 0, 0 }, ["r-bottom"] = { 1, 0 }, ["bottom-r"] = { 1, 0 },
  ["l-mid"] = { 0, 0.5 }, ["mid-l"] = { 0, 0.5 }, ["r-mid"] = { 1, 0.5 }, ["mid-r"] = { 1, 0.5 },
  l = { 0, 0.5 }, r = { 1, 0.5 },
}

function L.anchor(page, at, from)
  local R = (from == "text") and (page.block or page.typearea) or (from == "safe" and page.safe) or page.paperrect
  local o = page.outer == "right"
  local norm = tostring(at or "br"):lower():match("^%s*(.-)%s*$")
  norm = norm:gsub("outer", o and "r" or "l"):gsub("inner", o and "l" or "r")
  local f = ANCHOR_MAP[norm]
  if not f then return nil, nil, nil end
  return R.x0 + f[1] * (R.x1 - R.x0), R.y0 + f[2] * (R.y1 - R.y0), f
end

local function default_angle(f)
  local dx, dy = 0.5 - f[1], 0.5 - f[2]
  if dx == 0 and dy == 0 then return pi / 2 end
  return atan(dy, dx)
end

function L.user(ctx, page, items)
  if not items then return end
  local plan = L.plan(ctx, page)
  local spawns = expand_spawns(items.spawns)
  for i, k in ipairs(spawns) do
    local x, y, f = L.anchor(page, k.at, k.from)
    if not f then
      warn_msg("unknown spawn anchor '" .. tostring(k.at) .. "'")
      if ctx.log then ctx.log(fmt("# page=%d user spawn=%d at=%s invalid-anchor skipped", page.index, i, tostring(k.at))) end
    else
      x, y = x + dim(k.dx, 0), y + dim(k.dy, 0)
      local ang = k.angle and (tonumber(k.angle) * pi / 180) or default_angle(f)
      local size = dim(k.size, 200)
      local mlist = k.motif and L.parse_motifs(k.motif, true) or nil
      local mkind = mlist and mlist[1] or nil
      local onpaper = x > page.safe.x0 and x < page.safe.x1 and y > page.safe.y0 and y < page.safe.y1
      local sx = max(page.safe.x0 + 4, min(page.safe.x1 - 4, x))
      local sy = max(page.safe.y0 + 4, min(page.safe.y1 - 4, y))
      local blk = geom.inflate(page.block, page.buffer or 11.34)
      if sx >= blk.x0 - 2 and sx <= blk.x1 + 2 and sy >= blk.y0 - 2 and sy <= blk.y1 + 2 then
        if f[1] <= 0.2 then sx = max(page.safe.x0 + 4, blk.x0 - 6)
        elseif f[1] >= 0.8 then sx = min(page.safe.x1 - 4, blk.x1 + 6) end
        if f[2] <= 0.2 then sy = max(page.safe.y0 + 4, blk.y0 - 6)
        elseif f[2] >= 0.8 then sy = min(page.safe.y1 - 4, blk.y1 + 6) end
      end
      local spec = { x = sx, y = sy, angle = ang, flow = ang, pull = 0.15, bleed = not onpaper, size = size * 0.85, motif = mkind, directed = true }
      local seed = tonumber(k.seed) or i
      local fit_opts = {
        tag = "spawn-" .. i .. "-" .. seed,
        bleed = { left = true, right = true, top = true, bottom = true },
        max_dist = size * 1.18, origin = { x, y },
      }
      local bb = plan:fit("user-spawn" .. i, fit_opts, spec, S.branch)
      if ctx.log then
        ctx.log(fmt("# page=%d user spawn=%d at=%s origin=%.2f %.2f angle=%.1f size=%.1f %s",
          page.index, i, tostring(k.at or "br"), x, y, ang * 180 / pi, size, bb and "drawn" or "skipped"))
      end
    end
  end
  for i, sp in ipairs(items.sprays or {}) do
    local k = kv(sp.keys)
    local box = sp.rect
    if not box or geom.width(box) < 6 or geom.height(box) < 6 then
      if ctx.log and box then ctx.log(fmt("# page=%d inline spray=%d box=%s skipped", page.index, i, geom.fmt(box))) end
    else
      local mlist = k.motif and L.parse_motifs(k.motif, true) or nil
      local mkind = mlist and mlist[1] or nil
      local ex = {}
      for _, r in ipairs(page.ink or {}) do
        if geom.area(r) > 1 and not geom.contains(geom.inflate(box, 0.5), r) then ex[#ex + 1] = geom.inflate(r, 3) end
      end
      local region = geom.inflate(box, -2)
      local from = k.from or "left"
      local fx = {
        left   = { region.x0 + 10, (region.y0 + region.y1) / 2, 0.12 },
        right  = { region.x1 - 10, (region.y0 + region.y1) / 2, pi - 0.12 },
        bottom = { (region.x0 + region.x1) / 2, region.y0 + 10, pi / 2 },
        top    = { (region.x0 + region.x1) / 2, region.y1 - 10, -pi / 2 },
      }
      local o = fx[from] or fx.left
      local spec = { x = o[1], y = o[2], angle = o[3], flow = o[3], pull = 0.2, bleed = false, fade_base = true, size = max(geom.width(region), geom.height(region)) * 0.84, nt = 8, motif = mkind, directed = true }
      local seed = tonumber(k.seed) or i
      local saved = plan.occ; plan.occ = {}
      local bb = plan:fit("inline" .. i, { tag = "inline-" .. i .. "-" .. seed, region = region, inline = true, writer = ctx.under }, spec, function(c, s)
        c.exclude = ex
        c.fits = function(rect, _kind) return geom.clear_of(rect, ex) and geom.contains(region, rect, 0.01) end
        local rec = c.record
        c.record = function(kind, rect) return rec("inline-" .. kind, rect) end
        local wR, hR = geom.width(region), geom.height(region)
        if wR >= 48 and hR >= 22 then
          local th = theme_of(c)
          local gmotif = mkind or th.branch[1] or "sakura"
          local x_start = (from == "right") and (region.x1 - 10) or (region.x0 + 10)
          local x_end   = (from == "right") and (region.x0 + 12) or (region.x1 - 12)
          local ym = (region.y0 + region.y1) * 0.5
          local sw = min(9.5, hR * 0.22)
          local gbb, ginfo = L.grow_garden(c, { region }, {
            motif = gmotif,
            stems = {
              { spine = W.sway_spine(x_start, ym - sw * 0.15, x_end, ym + sw * 0.15, 0, 1, sw, 0.4, 1.8), w0 = 2.5, w1 = 0.46, n = 36, horiz = true, layer = 22, alpha = 0.94 },
              { spine = W.sway_spine(x_start + (x_end - x_start) * 0.06, ym + sw * 0.22, x_start + (x_end - x_start) * 0.88, ym - sw * 0.18, 0, 1, sw * 0.78, 2.3, 0.9), w0 = 1.6, w1 = 0.36, n = 28, horiz = true, layer = 18, alpha = 0.58 },
            },
            root = { x_start, ym }, root_r = min(8.5, hR * 0.18), root_deg = (from == "right") and 90 or -90,
            heroes = {
              { x_start + (x_end - x_start) * 0.18, ym, min(22, hR * 0.38) },
              { x_start + (x_end - x_start) * 0.52, ym, min(19, hR * 0.34) },
              { x_start + (x_end - x_start) * 0.80, ym, min(16, hR * 0.30) },
            },
            nb = 12, nf = 10,
          })
          if gbb then return gbb, ginfo end
        end
        return S.branch(c, s)
      end)
      plan.occ = saved
      if ctx.log then ctx.log(fmt("# page=%d inline spray=%d box=%s %s", page.index, i, geom.fmt(box), bb and "drawn" or "skipped")) end
    end
  end
end

---------------------------------------------------------------- border frame (4-side rounded-corner florilegium frame)
L.layouts["border-frame"] = function(ctx, page)
  local z = L.zones(page)
  local L_, Rr, T, Bo = z.left, z.right, z.top, z.bottom
  if not (L_ and Rr and T and Bo) then return L.layouts["scattered-petals"](ctx, page) end
  local xl, xr = (L_.x0 + L_.x1) / 2, (Rr.x0 + Rr.x1) / 2
  local yb, yt = (Bo.y0 + Bo.y1) / 2, (T.y0 + T.y1) / 2
  local rad = min(56, (xr - xl) * 0.16, (yt - yb) * 0.16)
  local plan = L.plan(ctx, page)
  add_sky_bokashi(plan, z)
  local cands = pick_branch_candidates({ page = page, theme = ctx.theme }, nil)
  local mkind = cands[1] or "sakura"
  local min_band = min(geom.width(L_), geom.width(Rr), geom.height(T), geom.height(Bo))
  local lscale = max(0.50, min(1.0, min_band / 34))
  local swV = min(10, min(geom.width(L_), geom.width(Rr)) * 0.24) * lscale
  local swH = min(5.5, min(geom.height(T), geom.height(Bo)) * 0.18) * lscale
  local xm, ym = (xl + xr) * 0.5, (yb + yt) * 0.5
  local stems = {
    { spine = W.corner_spine(xl, ym, xl, yb, xm, yb, rad, swV, 0.3, swH), w0 = 2.8 * lscale, w1 = 1.6 * lscale, n = 34 },
    { spine = W.corner_spine(xm, yb, xr, yb, xr, ym, rad, swH, 1.1, swV), w0 = 2.6 * lscale, w1 = 1.6 * lscale, n = 34 },
    { spine = W.corner_spine(xr, ym, xr, yt, xm, yt, rad, swV, 1.9, swH), w0 = 2.6 * lscale, w1 = 1.6 * lscale, n = 34 },
    { spine = W.corner_spine(xm, yt, xl, yt, xl, ym, rad, swH, 2.7, swV), w0 = 2.6 * lscale, w1 = 1.5 * lscale, n = 34 },
  }
  local hr = max(18, min(36, max(geom.width(L_), geom.width(Rr)) * 0.42))
  local bb, info = plan:attempt("frame-garden", { interleave = true }, function(c)
    return L.grow_garden(c, { L_, Rr, T, Bo }, {
      motif = mkind, stems = stems, balanced = true,
      heroes = {
        { xl, yt - rad * 0.85, hr },
        { xl, yb + rad * 0.85, hr },
        { (xl + xr) * 0.34, yt, min(hr, geom.height(T) * 0.44) },
        { (xl + xr) * 0.68, yt, min(hr, geom.height(T) * 0.42) },
        { (xl + xr) * 0.36, yb, min(hr, geom.height(Bo) * 0.42) },
        { (xl + xr) * 0.68, yb, min(hr, geom.height(Bo) * 0.44) },
        { xr, yb + (yt - yb) * 0.32, min(hr, geom.width(Rr) * 0.44) },
        { xr, yb + (yt - yb) * 0.72, min(hr, geom.width(Rr) * 0.44) },
      },
      nb = max(28, floor(40 * lscale)),
      nf = max(20, floor(28 * lscale)),
    })
  end)
  -- Interleave bamboo culms & woody boughs along the left and right frame margins
  if geom.width(L_) >= 46 then
    local bL, iL = L.interleaved_boughs_and_bamboo(plan, z, { mode = "overhang", zone = L_, is_right = false, motif = mkind })
    if bL then
      bb = geom.union(bb, bL)
      if iL and iL.perch and info and info.perch then
        for _, p in ipairs(iL.perch) do info.perch[#info.perch + 1] = p end
      end
    end
  end
  if geom.width(Rr) >= 46 then
    local bR, iR = L.interleaved_boughs_and_bamboo(plan, z, { mode = "rising", zone = Rr, is_right = true, motif = mkind })
    if bR then
      bb = geom.union(bb, bR)
      if iR and iR.perch and info and info.perch then
        for _, p in ipairs(iR.perch) do info.perch[#info.perch + 1] = p end
      end
    end
  end
  if bb then
    plan.host_occ = {}
    add_bird(plan, info, z)
    return bb
  end
  return L.layouts["scattered-petals"](ctx, page)
end

L.layouts["none"] = function(_ctx, _page) end

L.FALLBACK = {
  ["header-garland"]   = {},
  ["footer-ground"]    = {},
  ["margin-column"]    = {},
  ["corner-spray"]     = { "overhang", "rising", "margin-column", "scattered-petals" },
  overhang             = { "rising", "margin-column", "corner-spray", "scattered-petals" },
  rising               = { "overhang", "margin-column", "footer-ground", "scattered-petals" },
  ["scattered-petals"] = {},
  ["border-frame"]     = { "corner-spray", "scattered-petals" },
}

function L.install(K)
  local names = {}
  for k in pairs(L.layouts) do names[#names + 1] = k end
  table.sort(names)
  for _, name in ipairs(names) do
    local fn = L.layouts[name]
    K.register_layout(name, function(ctx, page)
      page_motifs(page)
      local n0 = #ctx.records
      fn(ctx, page)
      if #ctx.records > n0 then return end
      for _, alt in ipairs(L.FALLBACK[name] or {}) do
        L.layouts[alt](ctx, page)
        if #ctx.records > n0 then
          if ctx.log then ctx.log(fmt("# page=%d layout: fallback %s -> %s", page.index, name, alt)) end
          return
        end
      end
    end)
  end
end

return L
