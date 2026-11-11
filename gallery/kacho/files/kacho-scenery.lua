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
-- kacho-scenery.lua: scenery motifs of the kacho package (M2): craggy scholar
-- rock, Mt Fuji, bokashi sky, kasumi mist bands, wash bands and a painted grass
-- bank (ground).
--
-- ALGORITHMS & REFERENCES:
--   * rock, fuji, sky, kasumi, bank: own procedural constructions; Fuji profile,
--     snowcap tongues and the sky's rectangular feather adapted from the team's
--     explorer_m2_3 prototype (kscen.lua); layered watercolour bands via
--     kacho-wash (M1). Rock texture strokes after the Chinese/Japanese cun
--     (texture stroke) vocabulary, e.g. Mai-mai Sze 1956, "The Tao of Painting"
--     (Mustard Seed Garden Manual) -- inspired by.
--   * cr_open: Catmull-Rom interpolation (Catmull & Rom 1974).
--   No external code copied.
--
-- Same contract as the flora motifs (tex/API.md section 3):
--   M.<name>(ctx, spec) -> bbox, info ; every piece logged with ctx.record(kind,
--   bbox) (kinds "rock", "fuji", "bokashi-sky", "kasumi", "bank-...");
--   growth-limited to ctx.region and clear of ctx.exclude (shrink, then skip).
-- Washes are layered irregular bands or native gradients under soft masks:
-- never standalone soft discs (explorer_m2_3 P10).
-- Designs follow the explorer_m2_3 prototypes (Fuji profile and snowcap,
-- bokashi sky through a rectangular feather) and the user feedback of
-- 2026-11-02 (craggy rock with texture strokes, grassy bank with bokashi).
-- Pure Lua; randomness only from ctx.rng.
local M = {}

local B = require("kacho-brush")
local Wsh = require("kacho-wash")
local F = require("kacho-flora")
local U = F.util

local sin, cos, pi, abs, max, min, sqrt, floor, exp = math.sin, math.cos, math.pi, math.abs, math.max, math.min, math.sqrt, math.floor, math.exp
local function atan2(y, x) return math.atan(y, x) end
local TAU = 2 * pi
local union, mix, lerp, clamp = U.union, U.mix, U.lerp, U.clamp

local function C(ctx, n) return ctx.palette.color(n) end

---------------------------------------------------------------- shrink-to-fit helper
-- try(scale) -> bbox of the planned shape (no painting); returns the largest
-- scale in {1, .9, ...} whose bbox fits ctx, or nil
local function fit_scale(ctx, plan, minscale)
  local s = 1
  while s >= (minscale or 0.45) do
    local b = plan(s)
    if b and U.fits_rect(ctx, b) then return s, b end
    s = s * 0.9
  end
  return nil
end
M.fit_scale = fit_scale

---------------------------------------------------------------- ROCK
-- angular closed silhouette: a stack of 2-3 faceted lobes merged into one
-- outline (taihu / scholar rock: waist, overhang, flat base)
local function rock_outline(R, cx, y0, h, wr, lean)
  local rx = h * wr / 2
  local nlev = 9
  local waist = R.range(0.3, 0.5)
  local left, right = {}, {}
  local sx = 0
  for i = 0, nlev do
    local t = i / nlev
    sx = sx + (i > 0 and R.sym(0.05 * h) or 0)
    local prof = 0.92 - 0.2 * math.exp(-((t - waist) / 0.12) ^ 2) + 0.18 * math.exp(-((t - (waist + 0.3)) / 0.14) ^ 2)
    if t > 0.8 then prof = prof * sqrt(max(0, 1 - ((t - 0.8) / 0.22) ^ 2)) end
    local yy = y0 + h * t
    local lx = cx + sx + lean * h * t - rx * prof * R.range(0.72, 1.18)
    local rxp = cx + sx + lean * h * t + rx * prof * R.range(0.72, 1.18)
    left[#left + 1] = { lx, yy }
    right[#right + 1] = { rxp, yy }
  end
  -- angular facets: insert a jagged corner between every pair of levels
  local function jag(side)
    local out = {}
    for i = 1, #side do
      out[#out + 1] = side[i]
      if i < #side then
        local a, b = side[i], side[i + 1]
        local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local l = max(1e-6, sqrt(dx * dx + dy * dy))
        local k = R.sym(0.34) * l
        out[#out + 1] = { mx - dy / l * k, my + dx / l * k }
        if R.chance(0.3) then
          -- a ledge: short near-horizontal shelf (angular scholar-rock facets)
          local q = out[#out]
          out[#out + 1] = { q[1] + (side[1][1] < cx and -1 or 1) * l * R.range(0.15, 0.35), q[2] + l * R.range(0.05, 0.15) }
        end
      end
    end
    return out
  end
  left, right = jag(left), jag(right)
  local pts = {}
  for i = 1, #right do pts[#pts + 1] = right[i] end
  pts[#pts + 1] = { cx + sx + lean * h + R.sym(0.08 * rx), y0 + h * 1.03 }
  for i = #left, 1, -1 do pts[#pts + 1] = left[i] end
  -- flat base
  for _, p in ipairs(pts) do if p[2] < y0 then p[2] = y0 end end
  return U.ccw(pts)
end

local function inside(poly, x, y) return Wsh.inside(poly, x, y) end

--- Rock: a craggy, angular scholar rock (taihu stone) with a faceted silhouette,
--- 0-2 holes, layered ochre (hanga) or grey-green (sumi / variant "moss") washes
--- that fade out at the flat base, darker facet planes, axe-cut texture strokes
--- (cun), a broken heavy dry-brush contour and moss dots on the upper ledges.
--- spec: x, y = base centre; size = height; width = width/height (0.5..0.85);
--- variant = "ochre" | "moss" | "ink"; holes = 0..2; lean.
function M.rock(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local h0 = spec.size or 160
  local wr = spec.width or R.range(0.6, 0.8)
  local lean = spec.lean or R.sym(0.1)
  local cx, y0 = spec.x, spec.y
  local s = fit_scale(ctx, function(k)
    local h = h0 * k
    return { x0 = cx - h * wr * 0.75 - abs(lean) * h - 0.25 * h, y0 = y0 - 2, x1 = cx + h * wr * 0.75 + abs(lean) * h + 0.25 * h, y1 = y0 + h * 1.08 }
  end)
  if not s then return nil end
  local h = h0 * s
  local sil = rock_outline(R, cx, y0, h, wr, lean)
  if not U.free_pts(ctx, sil, 1.5) then
    -- fall back to a smaller rock until the real outline fits
    for _ = 1, 5 do
      h = h * 0.88
      sil = rock_outline(R, cx, y0, h, wr, lean)
      if U.free_pts(ctx, sil, 1.5) then break end
    end
    if not U.free_pts(ctx, sil, 1.5) then return nil end
  end
  local hanga = U.hanga(ctx)
  local variant = spec.variant or (hanga and "tsun" or "ink")
  local base_c, deep_c, dark_c, upper_c
  if variant == "tsun" or variant == "ochre" then
    base_c, deep_c, dark_c = C(ctx, "odo"), C(ctx, "kincha"), C(ctx, "kuri")
    upper_c = C(ctx, "rokusho")
  elseif variant == "moss" then
    base_c, deep_c, dark_c = mix(C(ctx, "koke"), C(ctx, "sumi-wash"), 0.3), C(ctx, "koke"), C(ctx, "matsuba")
    upper_c = C(ctx, "wakatake")
  else
    base_c, deep_c, dark_c = C(ctx, "sumi-wash"), C(ctx, "sumi-light"), C(ctx, "sumi-mid")
    upper_c = mix(C(ctx, "koke"), C(ctx, "sumi-mid"), 0.55)
  end
  local noir = C(ctx, "sumi-noir")
  local paper = U.paper(ctx)
  local bb = U.bbox_pts(sil, 2)
  -- holes
  local holes = {}
  local nh = spec.holes or ((variant == "ochre" or variant == "tsun") and R.int(1, 2) or R.int(0, 1))
  local rxm = h * wr / 2
  for _ = 1, nh * 6 do
    if #holes >= nh then break end
    local hy = y0 + h * R.range(0.45, 0.82)
    local hx = cx + lean * (hy - y0) + R.sym(rxm * 0.35)
    local hr = rxm * R.range(0.12, 0.2)
    local asp = R.range(1.2, 1.9)
    local hp = U.ellipse_pts(hx, hy, hr, hr * asp, R.range(-0.5, 0.5), 9, 0.18, R)  -- angular (few vertices)
    local ok = true
    for _, p in ipairs(hp) do
      if not inside(sil, p[1] + (p[1] - hx) * 0.6, p[2] + (p[2] - hy) * 0.6) then ok = false; break end
    end
    for _, o in ipairs(holes) do if ok and (o.x - hx) ^ 2 + (o.y - hy) ^ 2 < ((o.r + hr) * 2.2) ^ 2 then ok = false end end
    if ok then
      local cw = {}
      for i = #hp, 1, -1 do cw[#cw + 1] = hp[i] end
      holes[#holes + 1] = { pts = cw, x = hx, y = hy, r = hr * asp }
    end
  end
  local silP = W:poly(sil, true)
  local clipparts = { silP }
  for _, o in ipairs(holes) do clipparts[#clipparts + 1] = W:poly(o.pts, true) end
  local clipP = W:join(clipparts)
  W:layer(spec.layer or 15)
  -- (1) washes inside the silhouette, fading out over the bottom 15 %
  local fb = { x0 = bb.x0 - 4, y0 = y0 - 4, x1 = bb.x1 + 4, y1 = bb.y1 + 4 }
  local fade = W:fade_axial(cx, y0 + h * 0.16, cx, y0 - 1, 1, 0, fb)
  W:with_gs(fade, function()
    W:clip(clipP, true)
    for _ = 1, 6 do
      local q = {}
      local k = R.range(0.93, 1.02)
      local ox, oy = R.sym(0.08 * rxm), R.sym(0.04 * h)
      for i, p in ipairs(sil) do q[i] = { cx + (p[1] - cx) * k + ox, y0 + (p[2] - y0) * k + oy } end
      W:fill(W:poly(q, true), base_c, 0.11)
    end
    -- axial mineral wash: warm ochre base grading into blue-green rokusho/gunjo on upper crags
    local rpat = W:axial(cx, y0, cx + lean * h, y0 + h, {
      { 0, base_c },
      { 0.48, mix(base_c, upper_c, 0.35) },
      { 0.82, upper_c },
      { 1, hanga and C(ctx, "gunjo-deep") or dark_c },
    })
    W:fill_pattern(silP, rpat, hanga and 0.58 or 0.40)
    -- facet planes: wedge-shaped darker planes on the shadow side of folds
    for _ = 1, R.int(4, 7) do
      local i = R.int(1, #sil)
      local p = sil[i]
      local tx, ty = (cx + lean * (p[2] - y0)) - p[1], (y0 + h * R.range(0.3, 0.7)) - p[2]
      local l = max(1e-6, sqrt(tx * tx + ty * ty))
      tx, ty = tx / l, ty / l
      local L = rxm * R.range(0.5, 1.1)
      local wdg = { p, { p[1] + tx * L + ty * L * 0.25, p[2] + ty * L - tx * L * 0.25 },
        { p[1] + tx * L * 0.55 - ty * L * 0.35, p[2] + ty * L * 0.55 + tx * L * 0.35 } }
      local fc = (p[2] > y0 + h * 0.52) and upper_c or deep_c
      W:fill(W:poly(U.ccw(wdg), true), fc, 0.30, { blend = "multiply" })
    end
    -- shadowed left/lower recesses and lifted highlights
    Wsh.soft(ctx, cx - rxm * 0.45, y0 + h * 0.3, rxm * 0.6, h * 0.3, { rgb = deep_c, alpha = 0.32, blend = "multiply" })
    Wsh.soft(ctx, cx + rxm * 0.15 + lean * h * 0.7, y0 + h * 0.75, rxm * 0.45, h * 0.18, { rgb = upper_c, alpha = hanga and 0.38 or 0.22, blend = "multiply" })
    Wsh.soft(ctx, cx - rxm * 0.10 + lean * h * 0.5, y0 + h * 0.62, rxm * 0.35, h * 0.14, { rgb = paper, alpha = 0.45 })
    for _, o in ipairs(holes) do
      Wsh.soft(ctx, o.x, o.y - o.r * 0.9, o.r * 1.2, o.r * 0.9, { rgb = dark_c, alpha = 0.3, blend = "multiply" })
    end
    W:unclip()
  end)
  -- (2) tsun texture: dry-brush fibre & axe-cut strokes following the crag facets
  local nsil = #sil
  for _ = 1, floor(5 + h / 28) do
    local i0 = R.int(1, nsil)
    local len = R.int(3, 6)
    local inset = R.range(0.10, 0.42)
    local run = {}
    for k = 0, len do
      local p = sil[(i0 + k - 1) % nsil + 1]
      local ax = cx + lean * (p[2] - y0)
      local q = { p[1] + (ax - p[1]) * inset, p[2] + (y0 + h * 0.55 - p[2]) * inset * 0.4 }
      if q[2] > y0 + h * 0.10 and inside(sil, q[1], q[2]) then run[#run + 1] = q end
    end
    if #run >= 3 then
      B.dry(ctx, B.chain(run, 0.55), { w = h * R.range(0.009, 0.016), profile = "both", rgb = dark_c, alpha = 0.62,
        dryness = 0.48, bristles = 5, under = 0.28 })
    end
  end
  local cun = {}
  for _ = 1, floor(4 + h / 32) do
    local px, py
    for _ = 1, 20 do
      px, py = cx + R.sym(rxm * 1.1), y0 + h * R.range(0.18, 0.92)
      if inside(sil, px, py) then break end
      px = nil
    end
    if px then
      local a = R.range(-1.45, -0.85) + (R.chance(0.5) and pi or 0)
      local L = h * R.range(0.04, 0.09)
      local ex, ey = px + cos(a) * L, py + sin(a) * L
      if inside(sil, ex, ey) then
        local seg = { { px, py }, { px + cos(a) * L * 0.4, py + sin(a) * L * 0.4 }, { ex - cos(a + 0.35) * L * 0.3, ey - sin(a + 0.35) * L * 0.3 }, { ex, ey } }
        cun[#cun + 1] = W:poly(B.outline(B.spine({ seg }, { step = 0.6 }), function(u) return h * 0.012 * (1 - u) ^ 0.65 * min(1, u * 6 + 0.35) end), true)
      end
    end
  end
  if #cun > 0 then W:fill(W:join(cun), noir, 0.52) end
  -- (3) broken heavy contour, angular, heavier on the shadow (left/lower) side
  local n = #sil
  local i = R.int(1, n)
  local done = 0
  while done < n do
    local len = R.int(max(3, floor(n * 0.08)), max(4, floor(n * 0.22)))
    local run = {}
    for k = 0, len do
      local p = sil[(i + k - 1) % n + 1]
      if p[2] > y0 + 0.5 then run[#run + 1] = p
      elseif #run > 0 then break end
    end
    if #run >= 3 then
      local p1, p2 = run[1], run[#run]
      local shade = clamp(0.5 + ((p1[2] - p2[2]) * 0.7 - (p2[1] - p1[1]) * 0.3) / max(1, sqrt((p2[1] - p1[1]) ^ 2 + (p2[2] - p1[2]) ^ 2)), 0.2, 1.4)
      local wc = h * R.range(0.011, 0.02) * (0.5 + 0.6 * shade)
      B.dry(ctx, B.chain(run, 0.35), { w = wc, profile = function(u) return 0.3 + 0.7 * sin(pi * u) ^ 0.5 end,
        rgb = noir, alpha = 0.9, dryness = 0.35, bristles = 6, under = 0.4 })
    end
    local gap = R.int(1, max(2, floor(n * 0.07)))
    i = i + len + gap
    done = done + len + gap
  end
  for _, o in ipairs(holes) do
    local hp = o.pts
    local half = {}
    for k = 1, floor(#hp * 0.6) do half[#half + 1] = hp[k] end
    if #half >= 3 then
      B.dry(ctx, B.chain(half, 0.4), { w = h * 0.016, profile = "both", rgb = noir, alpha = 0.85, dryness = 0.3, bristles = 5, under = 0.4 })
    end
  end
  -- (4) moss dots (tenko) on upper ledges
  local dots = {}
  for k = 1, n do
    local p, q = sil[k], sil[k % n + 1]
    local dx, dy = q[1] - p[1], q[2] - p[2]
    local l = max(1e-6, sqrt(dx * dx + dy * dy))
    local nx, ny = dy / l, -dx / l          -- outward normal (CCW outline)
    if ny > 0.30 and p[2] > y0 + h * 0.28 and R.chance(0.55) then
      for _ = 1, R.int(2, 5) do
        local t = R.u()
        local x, y = p[1] + dx * t + R.sym(2), p[2] + dy * t + R.range(-1, 2.5)
        local r = h * R.range(0.006, 0.013)
        dots[#dots + 1] = W:ellipse(x, y, r, r * R.range(0.6, 0.9), R.range(0, pi))
      end
    end
  end
  if #dots > 0 then W:fill(W:join(dots), hanga and C(ctx, "matsuba") or noir, 0.9) end
  U.rec(ctx, "rock", bb)
  return bb, { kinds = { "rock" }, top = { x = cx + lean * h, y = y0 + h } }
end

---------------------------------------------------------------- CLIFFS (coastal tsun promontory)
--- Coastal craggy rock cliffs with layered mineral blue-green (rokusho/gunjo)
--- and warm ochre (odo) washes, rhythmic vertical/diagonal tsun fissure strokes,
--- and optional foaming wave coves at the base (Hokusai / Hiroshige coastal style).
--- spec: x, y (base centre), width, height, side = "left" | "right" | "center",
--- with_waves = true/false.
function M.cliffs(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local cx, y0 = spec.x or (ctx.region.x0 + ctx.region.x1) / 2, spec.y or (ctx.region.y0 + 10)
  local w0 = spec.width or 170
  local h0 = spec.height or 220
  local side = spec.side or "left"
  local s = fit_scale(ctx, function(k)
    local w, h = w0 * k, h0 * k
    return { x0 = cx - w * 0.55 - 4, y0 = y0 - 4, x1 = cx + w * 0.55 + 4, y1 = y0 + h * 1.06 }
  end, 0.4)
  if not s then return nil end
  local w, h = w0 * s, h0 * s
  local hanga = U.hanga(ctx)
  local odo = hanga and C(ctx, "odo") or C(ctx, "sumi-wash")
  local rokusho = hanga and C(ctx, "rokusho") or C(ctx, "sumi-light")
  local gunjo = hanga and C(ctx, "gunjo-deep") or C(ctx, "sumi-mid")
  local matsuba = hanga and C(ctx, "matsuba") or C(ctx, "sumi-dark")
  local noir = C(ctx, "sumi-noir")
  local foam_c = hanga and C(ctx, "nami-foam") or C(ctx, "gofun")
  local bero = hanga and C(ctx, "bero-ai") or C(ctx, "sumi-dark")
  local bero_m = hanga and C(ctx, "bero-mid") or C(ctx, "sumi-mid")
  W:layer(spec.layer or 15)
  local bb
  local dir = (side == "right") and -1 or 1
  -- Build 3 tiered interlocking crag masses (back spire, main cliff wall, lower promontory shelf)
  local tiers = {
    { ox = -dir * w * 0.14, oy = h * 0.18, tw = w * 0.52, th = h * 0.82, lean = dir * 0.08 },
    { ox = dir * w * 0.04,  oy = h * 0.04, tw = w * 0.64, th = h * 0.72, lean = dir * 0.14 },
    { ox = dir * w * 0.18,  oy = 0,        tw = w * 0.58, th = h * 0.42, lean = dir * 0.10 },
  }
  for ti, tr in ipairs(tiers) do
    local tcx, ty0 = cx + tr.ox, y0 + tr.oy
    local sil = rock_outline(R, tcx, ty0, tr.th, tr.tw / max(1, tr.th), tr.lean)
    if U.free_pts(ctx, sil, 1.5) then
      local tbb = U.bbox_pts(sil, 1.5)
      bb = union(bb, tbb)
      local silP = W:poly(sil, true)
      local pat = W:axial(tcx, ty0, tcx, ty0 + tr.th, {
        { 0, odo },
        { 0.42, mix(odo, rokusho, 0.45) },
        { 0.78, rokusho },
        { 1, mix(rokusho, gunjo, 0.55) },
      })
      W:fill_pattern(silP, pat, hanga and (0.72 + 0.06 * ti) or (0.48 + 0.06 * ti))
      W:clip(silP)
      -- Vertical & diagonal columnar tsun cliff fissures
      local nf = R.int(6, 10)
      for k = 1, nf do
        local fx = tcx + (k / (nf + 1) - 0.5) * tr.tw * 0.85 + R.sym(tr.tw * 0.04)
        local fy0 = ty0 + tr.th * R.range(0.08, 0.25)
        local fy1 = ty0 + tr.th * R.range(0.65, 0.96)
        local fpts = {
          { fx, fy1 },
          { fx + R.sym(3), (fy0 + fy1) * 0.55 },
          { fx + R.sym(3) - tr.lean * (fy1 - fy0) * 0.25, fy0 },
        }
        B.dry(ctx, B.chain(fpts, 0.45), {
          w = tr.tw * R.range(0.012, 0.024),
          profile = "both",
          rgb = (k % 2 == 0) and gunjo or noir,
          alpha = hanga and 0.48 or 0.55,
          dryness = 0.42,
          bristles = 4,
          under = 0.25,
        })
      end
      -- Upper green/blue mineral cap wash
      Wsh.soft(ctx, tcx + tr.lean * tr.th * 0.6, ty0 + tr.th * 0.82, tr.tw * 0.42, tr.th * 0.22,
        { rgb = rokusho, alpha = hanga and 0.45 or 0.25, blend = "multiply" })
      W:unclip()
      -- Crisp faceted outer contour & horizontal ledge strokes
      local n = #sil
      for k = 1, n, R.int(3, 5) do
        local run = {}
        for j = 0, min(5, n - k) do
          local p = sil[(k + j - 1) % n + 1]
          if p[2] > ty0 + 1 then run[#run + 1] = p end
        end
        if #run >= 3 then
          B.dry(ctx, B.chain(run, 0.35), {
            w = tr.th * R.range(0.012, 0.022),
            profile = "both",
            rgb = noir,
            alpha = 0.88,
            dryness = 0.32,
            bristles = 5,
            under = 0.4,
          })
        end
      end
      -- Moss dots along upper crest
      local dots = {}
      for k = 1, n do
        local p = sil[k]
        if p[2] > ty0 + tr.th * 0.62 and R.chance(0.45) then
          for _ = 1, R.int(2, 4) do
            local r = tr.th * R.range(0.008, 0.015)
            dots[#dots + 1] = W:ellipse(p[1] + R.sym(3), p[2] + R.range(-1, 3), r, r * 0.75, R.range(0, pi))
          end
        end
      end
      if #dots > 0 then W:fill(W:join(dots), matsuba, 0.88) end
    end
  end
  -- Foaming wave cove at the cliff foot
  if spec.with_waves ~= false and bb then
    local wx0 = max(ctx.region.x0 + 3, cx - w * 0.50)
    local wx1 = min(ctx.region.x1 - 3, cx + w * 0.50)
    local wy = y0 + h * 0.06
    local wbb = { x0 = wx0, y0 = y0, x1 = wx1, y1 = wy + h * 0.12 }
    if U.fits_rect(ctx, wbb) then
      local span = wx1 - wx0
      local swell = {}
      for i = 0, 24 do
        local t = i / 24
        local x = wx0 + span * t
        local y = wy + h * 0.04 * sin(t * pi * 3) + h * 0.02 * cos(t * pi * 5)
        swell[#swell + 1] = { x, y }
      end
      swell[#swell + 1] = { wx1, y0 }
      swell[#swell + 1] = { wx0, y0 }
      W:fill(W:poly(swell, true), bero_m, hanga and 0.78 or 0.50)
      -- Fingered white surf tongues lapping the cliff base
      local surf, drops = {}, {}
      for k = 1, 7 do
        local sx = wx0 + span * (k - 0.5) / 7 + R.sym(span * 0.03)
        local sy = wy + h * R.range(0.01, 0.05)
        local sr = span * R.range(0.04, 0.07)
        if U.free(ctx, sx, sy, sr * 1.2) then
          surf[#surf + 1] = W:poly(U.ellipse_pts(sx, sy, sr, sr * 0.45, R.sym(0.3), 10, 0.18, R), true)
          for _ = 1, 3 do
            local a = R.range(0.3, 2.8)
            local d = sr * R.range(0.8, 1.4)
            drops[#drops + 1] = W:circle(sx + cos(a) * d, sy + sin(a) * d * 0.8, R.range(0.9, 1.8))
          end
        end
      end
      if #surf > 0 then
        W:fill(W:join(surf), foam_c, 0.94)
        W:stroke(W:join(surf), bero, 0.55, 0.75)
      end
      if #drops > 0 then W:fill(W:join(drops), foam_c, 0.92) end
      bb = union(bb, wbb)
    end
  end
  if not bb then return nil end
  U.rec(ctx, "cliffs", bb)
  return bb, { kinds = { "cliffs", "rock" }, top = { x = cx, y = y0 + h } }
end

---------------------------------------------------------------- WAVES / NAMI (Hokusai Great Wave)
--- Hokusai-style Prussian-blue wave swells with rhythmic curved stripe bands,
--- curling multi-fingered white foam claws at the crest, and sea spray droplets.
--- spec: x0, x1, y (base), height, crest_side = "left" | "right".
function M.waves(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0 = spec.x0 or (ctx.region.x0 + 6)
  local x1 = spec.x1 or (ctx.region.x1 - 6)
  local yb = spec.y or (ctx.region.y0 + 10)
  local h0 = spec.height or 140
  local s = fit_scale(ctx, function(k)
    local h = h0 * k
    return { x0 = x0 - 2, y0 = yb - 2, x1 = x1 + 2, y1 = yb + h * 1.08 }
  end, 0.4)
  if not s then return nil end
  local h = h0 * s
  local span = x1 - x0
  if span < 30 then return nil end
  local hanga = U.hanga(ctx)
  local c_deep = hanga and C(ctx, "bero-ai") or C(ctx, "sumi-noir")
  local c_mid  = hanga and C(ctx, "bero-mid") or C(ctx, "sumi-dark")
  local c_pale = hanga and C(ctx, "bero-pale") or C(ctx, "sumi-light")
  local c_foam = hanga and C(ctx, "nami-foam") or C(ctx, "gofun")
  local left_crest = (spec.crest_side ~= "right")
  W:layer(spec.layer or 16)

  -- Helper to map normalized u in [0,1] along x (flipped if right-crested)
  local function X(u)
    return left_crest and (x0 + u * span) or (x1 - u * span)
  end
  local dir = left_crest and 1 or -1

  -- (1) Main towering wave profile y(u): rises high on u in [0.05..0.38], curls over at u ~ 0.42,
  --     drops into a deep concave trough at u ~ 0.68, rises slightly at u ~ 0.92
  local function wave_y(u)
    local crest = 0.88 * math.exp(-((u - 0.24) / 0.22) ^ 2)
    local lip   = 0.16 * math.exp(-((u - 0.40) / 0.08) ^ 2)
    local tail  = 0.26 * math.exp(-((u - 0.88) / 0.18) ^ 2)
    return yb + h * (0.14 + crest + lip + tail)
  end

  local npts = 48
  local main_poly = {}
  for i = 0, npts do
    local u = i / npts
    main_poly[#main_poly + 1] = { X(u), wave_y(u) }
  end
  -- Overhanging curl under-arch near u = 0.44 -> 0.34
  main_poly[#main_poly + 1] = { X(1.0), yb }
  main_poly[#main_poly + 1] = { X(0.0), yb }
  local mainP = W:poly(main_poly, true)
  W:fill(mainP, c_deep, hanga and 0.92 or 0.78)

  -- Curved flow-stripe bands inside the main wave body (Hokusai woodblock stripe shading)
  W:clip(mainP)
  for band = 1, 9 do
    local frac = band / 10
    local bpts = {}
    for i = 0, 32 do
      local u = i / 32
      local wy = wave_y(u)
      local y_band = yb + (wy - yb) * frac + sin(u * pi * 2.5 + band * 0.7) * h * 0.025
      bpts[#bpts + 1] = { X(u), y_band }
    end
    local thick = h * (0.022 + 0.015 * (1 - frac))
    for i = 32, 0, -1 do
      local u = i / 32
      local wy = wave_y(u)
      local y_band = yb + (wy - yb) * frac + sin(u * pi * 2.5 + band * 0.7) * h * 0.025 - thick
      bpts[#bpts + 1] = { X(u), y_band }
    end
    local col = (band % 2 == 0) and c_mid or c_pale
    W:fill(W:poly(bpts, true), col, hanga and 0.78 or 0.52)
  end
  W:unclip()

  -- (2) Foreground interlocking wave swell in the trough
  local fg_poly = {}
  for i = 0, 36 do
    local u = i / 36
    local fy = yb + h * (0.10 + 0.24 * math.exp(-((u - 0.58) / 0.18) ^ 2) + 0.15 * math.exp(-((u - 0.16) / 0.14) ^ 2))
    fg_poly[#fg_poly + 1] = { X(u), fy }
  end
  fg_poly[#fg_poly + 1] = { X(1.0), yb }
  fg_poly[#fg_poly + 1] = { X(0.0), yb }
  local fgP = W:poly(fg_poly, true)
  W:fill(fgP, c_mid, hanga and 0.88 or 0.68)
  W:clip(fgP)
  for band = 1, 4 do
    local frac = band / 5
    local spts = {}
    for i = 0, 28 do
      local u = i / 28
      local fy = yb + h * (0.10 + 0.24 * math.exp(-((u - 0.58) / 0.18) ^ 2) + 0.15 * math.exp(-((u - 0.16) / 0.14) ^ 2))
      spts[#spts + 1] = { X(u), yb + (fy - yb) * frac }
    end
    for i = 28, 0, -1 do
      local u = i / 28
      local fy = yb + h * (0.10 + 0.24 * math.exp(-((u - 0.58) / 0.18) ^ 2) + 0.15 * math.exp(-((u - 0.16) / 0.14) ^ 2))
      spts[#spts + 1] = { X(u), yb + (fy - yb) * frac - h * 0.018 }
    end
    W:fill(W:poly(spts, true), (band % 2 == 1) and c_pale or c_deep, 0.72)
  end
  W:unclip()

  -- (3) Frothy cloud of overlapping off-white (gofun) scalloped foam puffs & sea-spray droplets
  local puffs, contours, drops = {}, {}, {}
  local function add_scallop_cluster(cx, cy, rad, base_ang, n_puffs)
    local r_arc = clamp(rad * 0.62, 5.5, 12.5)
    for k = 1, n_puffs do
      local ft = (k - (n_puffs + 1) / 2) / max(1, n_puffs - 1)
      local a_pos = base_ang + pi * 0.55 * ft
      local px = cx + cos(a_pos) * r_arc * 0.72 + R.sym(1.0)
      local py = cy + sin(a_pos) * r_arc * 0.52 + abs(ft) * 1.2 + R.sym(0.8)
      local rp = clamp(rad * R.range(0.26, 0.44) * (1.05 - 0.25 * abs(ft)), 2.8, 6.8)
      local puff = U.ellipse_pts(px, py, rp * 1.15, rp * R.range(0.62, 0.80), base_ang * 0.3 + ft * 0.35, 12, 0.10, R)
      if U.free_pts(ctx, puff, 1.0) then
        puffs[#puffs + 1] = W:poly(puff, true)
        local arc = {}
        for m = 1, 6 do arc[m] = puff[m] end
        contours[#contours + 1] = W:poly(arc, false)
      end
      -- Secondary smaller satellite foam bead above/beside main puff
      local sx = px - dir * rp * R.range(0.55, 0.95)
      local sy = py + rp * R.range(0.35, 0.70)
      local sr = rp * R.range(0.42, 0.62)
      local spuff = U.ellipse_pts(sx, sy, sr * 1.1, sr * 0.75, 0.2, 10, 0.08, R)
      if U.free_pts(ctx, spuff, 1.0) then
        puffs[#puffs + 1] = W:poly(spuff, true)
      end
    end
  end

  local claw_anchors = {
    { u = 0.14, r = h * 0.11, ang = pi * 0.48, np = 4 },
    { u = 0.22, r = h * 0.14, ang = pi * 0.50, np = 5 },
    { u = 0.30, r = h * 0.16, ang = pi * 0.52, np = 6 },
    { u = 0.38, r = h * 0.14, ang = pi * 0.48, np = 5 },
    { u = 0.45, r = h * 0.11, ang = pi * 0.45, np = 4 },
    { u = 0.58, r = h * 0.10, ang = pi * 0.50, np = 4 },
    { u = 0.86, r = h * 0.09, ang = pi * 0.50, np = 3 },
  }
  for _, ca in ipairs(claw_anchors) do
    local cx = X(ca.u)
    local cy = (ca.u > 0.50 and ca.u < 0.70)
      and (yb + h * (0.10 + 0.24 * math.exp(-((ca.u - 0.58) / 0.18) ^ 2)))
      or wave_y(ca.u)
    add_scallop_cluster(cx, cy, ca.r, ca.ang, ca.np)
    for _ = 1, 7 do
      local dx = cx + dir * R.range(-ca.r * 0.6, ca.r * 1.35) + R.sym(3.0)
      local dy = cy + R.range(1.0, ca.r * 0.85)
      local dr = R.range(0.7, 1.6)
      if U.free(ctx, dx, dy, dr + 1.5) then
        drops[#drops + 1] = W:circle(dx, dy, dr)
      end
    end
  end
  if #puffs > 0 then W:fill(W:join(puffs), c_foam, 0.96) end
  if #contours > 0 then W:stroke(W:join(contours), c_deep, 0.38, 0.65) end
  if #drops > 0 then
    W:fill(W:join(drops), c_foam, 0.94)
    W:stroke(W:join(drops), c_deep, 0.26, 0.42)
  end

  local bb = { x0 = x0, y0 = yb, x1 = x1, y1 = yb + h * 1.05 }
  U.rec(ctx, "waves", bb)
  return bb, { kinds = { "waves", "nami" }, crest_x = X(0.32), crest_y = wave_y(0.32) }
end
M.nami = M.waves

---------------------------------------------------------------- SKY (bokashi)
--- Bokashi sky: supports both diagonal corner feather and Hiroshige ichimonji
--- top Prussian-blue band + warm dawn-rose/golden horizon glow.
function M.sky(ctx, spec)
  spec = spec or {}
  local W = ctx.pdf
  local r = spec.rect or ctx.region
  if not U.fits_rect(ctx, r) then return nil end
  local hanga = U.hanga(ctx)
  local top = spec.top or (hanga and C(ctx, "bokashi-sky") or C(ctx, "sumi-wash"))
  local mid = spec.mid or (hanga and mix(top, C(ctx, "bokashi-sky-horizon"), 0.6) or mix(top, U.paper(ctx), 0.5))
  local paper = U.paper(ctx)
  local right = spec.corner ~= "left"
  local x0 = right and r.x1 or r.x0
  local x1 = right and (r.x0 + (r.x1 - r.x0) * 0.3) or (r.x1 - (r.x1 - r.x0) * 0.3)
  local hz = spec.horizon or (r.y0 + (r.y1 - r.y0) * 0.25)
  local pat = W:axial(x0, r.y1, x1, hz, { { 0, top }, { 0.55, mid }, { 1, paper } })
  local fx = spec.fx or (hanga and (right and { 0.45, 0.12 } or { 0.12, 0.45 }) or { 0.35, 0.35 })
  local fy = spec.fy or (hanga and { 0.3, 0.12 } or { 0.45, 0.3 })
  W:layer(spec.layer or 10)
  local g = W:fade_box(r, fx, fy)
  W:with_gs(g, function()
    W:fill_pattern(W:rect(r), pat, spec.alpha or (hanga and 0.9 or 0.5))
    -- Hiroshige ichimonji top Prussian-blue bokashi band + warm dawn horizon blush
    if spec.hiroshige or (hanga and spec.hiroshige ~= false) then
      local hgt = r.y1 - r.y0
      local top_pat = W:axial(r.x0, r.y1, r.x0, r.y1 - hgt * 0.42, {
        { 0, C(ctx, "bero-ai") },
        { 0.45, C(ctx, "bero-pale") },
        { 1, paper },
      })
      W:fill_pattern(W:rect(r), top_pat, 0.55)
      local dawn_pat = W:axial(r.x0, r.y0 + hgt * 0.12, r.x0, r.y0 + hgt * 0.52, {
        { 0, C(ctx, "akebono-rose") },
        { 0.55, C(ctx, "bokashi-sky-horizon") },
        { 1, paper },
      })
      W:fill_pattern(W:rect(r), dawn_pat, 0.42)
    end
  end)
  local bb = { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1 }
  U.rec(ctx, "bokashi-sky", bb)
  return bb, { kinds = { "bokashi-sky" } }
end
M.bokashi = M.sky

---------------------------------------------------------------- TANZAKU (Ukiyo-e vertical title cartouche)
-- Authentic calligraphic brush-stroke kanji templates in cell-local coordinates
-- (u, v) in [-0.48, 0.48] x [-0.48, 0.48] (+u right, +v up).
-- Each stroke is { pts = { {u,v}, ... }, w = relative_width }.
local CALLIG_KANJI = {
  ["花"] = { -- Hana (Flower: 艹 + 化)
    { pts = { { -0.40, 0.30 }, { 0.0, 0.34 }, { 0.40, 0.37 } }, w = 1.00 },
    { pts = { { -0.20, 0.45 }, { -0.18, 0.33 }, { -0.15, 0.19 } }, w = 0.85 },
    { pts = { { 0.22, 0.45 }, { 0.18, 0.33 }, { 0.12, 0.18 } }, w = 0.85 },
    { pts = { { -0.12, 0.12 }, { -0.25, -0.04 }, { -0.42, -0.22 } }, w = 0.90 },
    { pts = { { -0.24, -0.02 }, { -0.24, -0.24 }, { -0.24, -0.44 } }, w = 0.95 },
    { pts = { { 0.36, 0.04 }, { 0.19, -0.06 }, { 0.02, -0.14 } }, w = 0.85 },
    { pts = { { 0.06, 0.14 }, { 0.06, -0.35 }, { 0.32, -0.41 }, { 0.40, -0.22 } }, w = 1.05 },
  },
  ["鳥"] = { -- Tori (Bird)
    { pts = { { 0.02, 0.46 }, { -0.05, 0.38 }, { -0.12, 0.30 } }, w = 0.80 },
    { pts = { { -0.24, 0.32 }, { -0.24, 0.04 }, { -0.24, -0.20 } }, w = 0.92 },
    { pts = { { -0.24, 0.32 }, { 0.22, 0.35 }, { 0.20, 0.06 } }, w = 0.95 },
    { pts = { { -0.22, 0.19 }, { 0.0, 0.21 }, { 0.18, 0.22 } }, w = 0.72 },
    { pts = { { -0.22, 0.06 }, { 0.0, 0.08 }, { 0.20, 0.09 } }, w = 0.78 },
    { pts = { { -0.22, -0.07 }, { 0.04, -0.05 }, { 0.26, -0.04 } }, w = 0.78 },
    { pts = { { -0.24, -0.20 }, { 0.35, -0.16 }, { 0.31, -0.43 }, { 0.14, -0.35 } }, w = 1.02 },
    { pts = { { -0.36, -0.27 }, { -0.39, -0.35 }, { -0.42, -0.42 } }, w = 0.72 },
    { pts = { { -0.20, -0.27 }, { -0.19, -0.34 }, { -0.17, -0.40 } }, w = 0.68 },
    { pts = { { -0.04, -0.27 }, { -0.02, -0.33 }, { 0.0, -0.39 } }, w = 0.68 },
    { pts = { { 0.10, -0.27 }, { 0.13, -0.33 }, { 0.16, -0.39 } }, w = 0.68 },
  },
  ["風"] = { -- Kaze (Wind)
    { pts = { { -0.28, 0.40 }, { -0.30, 0.0 }, { -0.42, -0.42 } }, w = 0.95 },
    { pts = { { -0.28, 0.40 }, { 0.25, 0.43 }, { 0.27, -0.35 }, { 0.42, -0.41 }, { 0.40, -0.20 } }, w = 1.02 },
    { pts = { { 0.12, 0.26 }, { -0.02, 0.22 }, { -0.16, 0.18 } }, w = 0.78 },
    { pts = { { -0.17, 0.04 }, { 0.14, 0.06 }, { 0.12, -0.12 }, { -0.16, -0.12 } }, w = 0.78 },
    { pts = { { -0.02, 0.22 }, { -0.02, -0.04 }, { -0.02, -0.30 } }, w = 0.85 },
    { pts = { { -0.20, -0.32 }, { 0.0, -0.28 }, { 0.18, -0.24 } }, w = 0.82 },
    { pts = { { 0.14, -0.18 }, { 0.19, -0.25 }, { 0.24, -0.32 } }, w = 0.75 },
  },
  ["月"] = { -- Tsuki (Moon)
    { pts = { { -0.22, 0.42 }, { -0.24, -0.04 }, { -0.36, -0.44 } }, w = 0.95 },
    { pts = { { -0.22, 0.42 }, { 0.24, 0.45 }, { 0.24, -0.41 }, { 0.06, -0.33 } }, w = 1.05 },
    { pts = { { -0.20, 0.14 }, { 0.02, 0.16 }, { 0.22, 0.17 } }, w = 0.82 },
    { pts = { { -0.22, -0.10 }, { 0.02, -0.08 }, { 0.22, -0.07 } }, w = 0.82 },
  },
  ["山"] = { -- Yama (Mountain)
    { pts = { { 0.0, 0.44 }, { 0.0, 0.04 }, { 0.0, -0.32 } }, w = 1.08 },
    { pts = { { -0.34, 0.14 }, { -0.36, -0.34 }, { 0.34, -0.29 } }, w = 0.98 },
    { pts = { { 0.34, 0.18 }, { 0.34, -0.10 }, { 0.34, -0.38 } }, w = 0.98 },
  },
  ["水"] = { -- Mizu (Water)
    { pts = { { 0.0, 0.44 }, { 0.0, -0.38 }, { -0.14, -0.30 } }, w = 1.05 },
    { pts = { { -0.38, 0.14 }, { -0.12, 0.18 }, { -0.40, -0.34 } }, w = 0.92 },
    { pts = { { 0.36, 0.24 }, { 0.20, 0.12 }, { 0.06, 0.02 } }, w = 0.84 },
    { pts = { { 0.04, 0.04 }, { 0.22, -0.16 }, { 0.42, -0.36 } }, w = 0.98 },
  },
  ["清"] = { -- Sei (Pure: 氵 + 青)
    { pts = { { -0.39, 0.35 }, { -0.33, 0.29 }, { -0.27, 0.23 } }, w = 0.78 },
    { pts = { { -0.42, 0.10 }, { -0.35, 0.04 }, { -0.29, -0.02 } }, w = 0.78 },
    { pts = { { -0.40, -0.34 }, { -0.33, -0.21 }, { -0.25, -0.08 } }, w = 0.84 },
    { pts = { { -0.10, 0.34 }, { 0.14, 0.36 }, { 0.36, 0.38 } }, w = 0.78 },
    { pts = { { -0.06, 0.20 }, { 0.14, 0.22 }, { 0.32, 0.23 } }, w = 0.74 },
    { pts = { { -0.16, 0.06 }, { 0.14, 0.08 }, { 0.42, 0.10 } }, w = 0.84 },
    { pts = { { 0.14, 0.44 }, { 0.14, 0.26 }, { 0.14, 0.08 } }, w = 0.84 },
    { pts = { { -0.06, -0.04 }, { -0.06, -0.23 }, { -0.08, -0.42 } }, w = 0.82 },
    { pts = { { -0.06, -0.04 }, { 0.30, -0.02 }, { 0.30, -0.40 }, { 0.16, -0.34 } }, w = 0.88 },
    { pts = { { -0.04, -0.16 }, { 0.13, -0.15 }, { 0.28, -0.14 } }, w = 0.72 },
    { pts = { { -0.04, -0.28 }, { 0.13, -0.27 }, { 0.28, -0.26 } }, w = 0.72 },
  },
}

--- Vertical rectangular ukiyo-e title cartouche with double border, bokashi
--- vermilion/gold ground, authentic calligraphic kanji (花鳥風月 / 山水清風), and miniature seal.
--- spec: x, y (top-centre or centre), width, height, variant = "shu" | "gold".
function M.tanzaku(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local w0 = spec.width or 24
  local h0 = spec.height or 84
  local cx = spec.x or (ctx.region.x1 - 28)
  local top_y = spec.y or (ctx.region.y1 - 18)
  local s = fit_scale(ctx, function(k)
    local w, h = w0 * k, h0 * k
    return { x0 = cx - w / 2 - 2, y0 = top_y - h - 2, x1 = cx + w / 2 + 2, y1 = top_y + 2 }
  end, 0.5)
  if not s then return nil end
  local w, h = w0 * s, h0 * s
  local x0, y0, x1, y1 = cx - w / 2, top_y - h, cx + w / 2, top_y
  local bb = { x0 = x0 - 1, y0 = y0 - 1, x1 = x1 + 1, y1 = y1 + 1 }
  local hanga = U.hanga(ctx)
  local noir = C(ctx, "sumi-noir")
  local paper = U.paper(ctx)
  local c_top = hanga and C(ctx, spec.variant == "gold" and "yamabuki" or "shu") or C(ctx, "sumi-light")
  local c_bot = hanga and C(ctx, spec.variant == "gold" and "torinoko" or "akebono-rose") or paper

  W:layer(spec.layer or 44)
  local rect_outer = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
  local inset = max(1.4, w * 0.07)
  local rect_inner = { x0 = x0 + inset, y0 = y0 + inset, x1 = x1 - inset, y1 = y1 - inset }
  local pat = W:axial(cx, y1, cx, y0, { { 0, c_top }, { 0.45, mix(c_top, c_bot, 0.65) }, { 1, c_bot } })
  W:fill(W:rect(rect_outer), paper, 0.96)
  W:fill_pattern(W:rect(rect_inner), pat, hanga and 0.90 or 0.55)
  W:stroke(W:rect(rect_outer), noir, max(0.9, w * 0.045), 0.92)
  W:stroke(W:rect(rect_inner), noir, max(0.4, w * 0.02), 0.82)

  -- Vertical column of 4 authentic calligraphic brush-stroke kanji:
  -- 花鳥風月 (Kachō Fūgetsu) or 山水清風 (Sansui Seifū)
  local poem = (spec.variant == "gold") and { "山", "水", "清", "風" } or { "花", "鳥", "風", "月" }
  local ng = #poem
  local gw = (x1 - x0) * 0.64
  local gh = (y1 - y0 - inset * 4.5) / (ng + 0.85)
  local cell_sz = min(gw, gh * 0.86)
  local strokes = {}
  for k = 1, ng do
    local gy = y1 - inset * 2.2 - (k - 0.42) * gh
    local tpl = CALLIG_KANJI[poem[k]] or CALLIG_KANJI["花"]
    for _, st in ipairs(tpl) do
      local seg = {}
      for _, p in ipairs(st.pts) do
        seg[#seg + 1] = {
          cx + p[1] * cell_sz + R.sym(cell_sz * 0.012),
          gy + p[2] * cell_sz + R.sym(cell_sz * 0.012),
        }
      end
      local sw_max = w * 0.046 * (st.w or 1.0)
      local poly = B.outline(B.spine(B.chain(seg, 0.5), { step = 0.35 }), function(u)
        return max(0.28, sw_max * (sin(pi * u) ^ 0.42) * (1.12 - 0.28 * u))
      end)
      strokes[#strokes + 1] = W:poly(poly, true)
    end
  end
  if #strokes > 0 then W:fill(W:join(strokes), noir, 0.92) end
  -- Miniature square vermilion hanko seal with white tenshotai strokes at bottom of cartouche
  local sr = min(w * 0.19, gh * 0.34)
  local sy = y0 + inset * 2.1 + sr
  local srect = { x0 = cx - sr, y0 = sy - sr, x1 = cx + sr, y1 = sy + sr }
  W:fill(W:rect(srect), C(ctx, "shu"), 0.90)
  local sw_seal = max(0.32, sr * 0.16)
  W:stroke(W:poly({ { cx - sr * 0.55, sy + sr * 0.42 }, { cx + sr * 0.55, sy + sr * 0.42 } }, false), paper, sw_seal, 0.92)
  W:stroke(W:poly({ { cx, sy - sr * 0.55 }, { cx, sy + sr * 0.55 } }, false), paper, sw_seal, 0.92)
  W:stroke(W:poly({ { cx - sr * 0.50, sy - sr * 0.38 }, { cx + sr * 0.50, sy - sr * 0.38 } }, false), paper, sw_seal, 0.92)
  U.rec(ctx, "tanzaku", bb)
  return bb, { kinds = { "tanzaku" } }
end

---------------------------------------------------------------- FUJI
local function cr_open(pts, nper)
  local out = {}
  local n = #pts
  local function P(i) return pts[max(1, min(n, i))] end
  for i = 1, n - 1 do
    local p0, p1, p2, p3 = P(i - 1), P(i), P(i + 1), P(i + 2)
    for k = 0, nper - 1 do
      local t = k / nper
      local t2, t3 = t * t, t * t * t
      local function c(a, b, cc, d) return 0.5 * ((2 * b) + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3) end
      out[#out + 1] = { c(p0[1], p1[1], p2[1], p3[1]), c(p0[2], p1[2], p2[2], p3[2]) }
    end
  end
  out[#out + 1] = pts[n]
  return out
end

--- Mt Fuji (Hiroshige / Hokusai / Sansui style):
--- Broad, serene concave volcanic silhouette (p = 1.76) with an asymmetric
--- Kengamine / Shaka-dake crater rim, receding distant mountain shoulders behind
--- the flanks for atmospheric depth, soft bokashi indigo/sumi wash dissolving
--- into basal mist, and slender radial snow-filled volcanic gullies (sawas)
--- curving naturally down the upper cone.
function M.fuji(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local Wd0 = spec.width or 240
  local cx, by = spec.x, spec.y
  local sumi = not U.hanga(ctx)
  local sc = fit_scale(ctx, function(k)
    local Wd = Wd0 * k
    local H = (spec.height or Wd * 0.29) * k
    return { x0 = cx - Wd / 2 * 1.15 - 2, y0 = by - 2, x1 = cx + Wd / 2 * 1.15 + 2, y1 = by + H * (sumi and 1.35 or 1.05) }
  end)
  if not sc then return nil end
  local Wd = Wd0 * sc
  local H = (spec.height or Wd * 0.29) * sc
  local hw = Wd / 2
  local p = spec.concave or 1.76
  local t0 = 0.082
  local body_c = spec.body or (sumi and C(ctx, "sumi-mid") or C(ctx, "bero-mid"))
  local lower_c = sumi and C(ctx, "sumi-wash") or C(ctx, "fuji-pale")
  local snow_c = C(ctx, "gofun")
  local peak_c = sumi and C(ctx, "sumi-dark") or C(ctx, "bero-ai")

  -- Asymmetric 3-lobed volcanic crater rim (Kengamine peak on left, saddle dip, Shaka-dake on right)
  local function prof(x)
    local u = x / hw
    local a = abs(u)
    if a <= t0 then
      local s = u / t0 -- -1..1 across summit plateau
      local kengamine = 0.022 * exp(-((s + 0.52) / 0.38) ^ 2)
      local shakadake = 0.014 * exp(-((s - 0.56) / 0.40) ^ 2)
      local crater_dip = -0.020 * exp(-((s - 0.04) / 0.42) ^ 2)
      return H * (0.988 + kengamine + shakadake + crater_dip)
    end
    if a >= 1 then return 0 end
    -- Slight natural asymmetry between left and right sweeping slopes
    local p_side = (u < 0) and (p * 0.97) or (p * 1.04)
    return H * ((1 - a) / (1 - t0)) ^ p_side
  end

  W:layer(spec.layer or 12)
  local bb = { x0 = cx - hw * 1.1, y0 = by - 1, x1 = cx + hw * 1.1, y1 = by + H * 1.02 }

  if sumi then
    local sb = Wsh.band(ctx, { x0 = cx - hw * 0.95, x1 = cx + hw * 0.95, y = by + H * 0.88, height = H * 0.65,
      rgb = C(ctx, "sumi-wash"), alpha = 0.42, blend = "multiply", pool = false, gran = 0.25, fade = { 0.35, 0.35 } })
    bb = union(bb, sb)
  end

  -- 1. Far distant receding mountain shoulders (Hiroshige horizon foothills) for multi-plane depth
  local function draw_distant_ridge(x_start, x_end, peak_u, peak_h, alpha_r)
    local rpts = {}
    local nr = 48
    for i = 0, nr do
      local t = i / nr
      local u = x_start + (x_end - x_start) * t
      local env = sin(pi * t) ^ 1.25
      local sub1 = exp(-((u - peak_u) / 0.22) ^ 2)
      local sub2 = 0.55 * exp(-((u - (peak_u + 0.16)) / 0.18) ^ 2)
      local hgt = H * peak_h * env * (0.45 + 0.55 * (sub1 + sub2))
      rpts[#rpts + 1] = { cx + u * hw, by + hgt }
    end
    rpts[#rpts + 1] = { cx + x_end * hw, by }
    rpts[#rpts + 1] = { cx + x_start * hw, by }
    local rP = W:poly(rpts, true)
    local rpat = W:axial(cx, by + H * peak_h, cx, by, {
      { 0, mix(body_c, lower_c, 0.35) },
      { 1, U.paper(ctx) },
    })
    W:fill_pattern(rP, rpat, alpha_r)
  end
  if H >= 44 then
    draw_distant_ridge(-1.06, -0.18, -0.68, 0.32, sumi and 0.28 or 0.36)
    draw_distant_ridge(0.16, 1.06, 0.64, 0.27, sumi and 0.24 or 0.32)
  end

  -- 2. Main Fuji silhouette, snow mantle, and keyblock contour inside basal mist fade
  local sil = {}
  local NS = 128
  for i = 0, NS do
    local x = -hw * 1.05 + 2.10 * hw * i / NS
    sil[#sil + 1] = { cx + x, by + prof(x) }
  end
  sil[#sil + 1] = { cx + hw * 1.05, by - 1 }
  sil[#sil + 1] = { cx - hw * 1.05, by - 1 }
  local silP = W:poly(sil, true)

  local ys_base = H * 0.74
  local function xat(hgt, side)
    local ps = (side < 0) and (p * 0.97) or (p * 1.04)
    return hw * (1 - (1 - t0) * max(0, min(1, hgt / H)) ^ (1 / ps))
  end

  local fb = { x0 = cx - hw * 1.12, y0 = by - 3, x1 = cx + hw * 1.12, y1 = by + H * 1.08 }
  local fg = W:fade_axial(cx, by + 0.44 * H, cx, by + 0.03 * H, 1, 0, fb)
  W:with_gs(fg, function()
    local fpat = W:axial(cx, by + H, cx, by, {
      { 0.00, peak_c },
      { 0.40, body_c },
      { 0.80, lower_c },
      { 1.00, mix(lower_c, U.paper(ctx), 0.78) },
    })
    W:fill_pattern(silP, fpat, sumi and 0.68 or 0.86)
    W:clip(silP)
    -- Subtle eastern flank shadow wash
    Wsh.soft(ctx, cx + hw * 0.32, by + H * 0.44, hw * 0.42, H * 0.38,
      { rgb = peak_c, alpha = sumi and 0.16 or 0.13, blend = "multiply" })

    -- 3. Serene Hiroshige/Hokusai summit snow mantle (soft asymmetric undulations + slender radial ridge wisps)
    local snow = {}
    local NT = 48
    local xl_top = xat(ys_base * 0.45, -1)
    local xr_top = xat(ys_base * 0.45, 1)
    for i = 0, NT do
      local x = -xl_top + (xl_top + xr_top) * i / NT
      snow[#snow + 1] = { cx + x, by + prof(x) + 1.0 }
    end
    -- Gentle, asymmetric natural snowline undulations (no cartoon saw-teeth)
    local swells = {
      { u = 0.52, dip = 0.11, w = 0.18 },
      { u = 0.08, dip = 0.16, w = 0.22 },
      { u = -0.38, dip = 0.13, w = 0.20 },
      { u = -0.72, dip = 0.08, w = 0.16 },
    }
    local NB = 64
    for i = 0, NB do
      local t = i / NB
      local u = 1.0 - 2.0 * t
      local dip = 0
      for _, sw in ipairs(swells) do
        local d = (u - sw.u) / sw.w
        dip = dip + sw.dip * exp(-d * d)
      end
      local h_snow = ys_base * (1.0 - dip) + H * 0.03 * cos(u * pi * 0.8)
      local x_flank = xat(h_snow, u < 0 and -1 or 1)
      snow[#snow + 1] = { cx + u * x_flank, by + h_snow }
    end
    local snowP = W:poly(snow, true)
    W:fill(snowP, sumi and U.paper(ctx) or snow_c, sumi and 0.94 or 0.92)

    -- Delicate radial snow ridge wisps following the natural concave slope flow lines
    for _, u_r in ipairs({ -0.56, -0.22, 0.16, 0.48 }) do
      local y_hi = ys_base * 0.94
      local y_lo = ys_base * (0.58 + 0.08 * abs(u_r))
      local streak = {}
      for k = 0, 8 do
        local tk = k / 8
        local yk = y_hi + (y_lo - y_hi) * tk
        local xfk = xat(yk, u_r < 0 and -1 or 1)
        streak[#streak + 1] = { cx + u_r * xfk, by + yk }
      end
      local s_poly = B.outline(B.spine(B.chain(streak, 0.5), { step = 0.5 }), function(u)
        return max(0.15, Wd * 0.0052 * (1 - u) ^ 1.5)
      end)
      W:fill(W:poly(s_poly, true), sumi and U.paper(ctx) or snow_c, sumi and 0.78 or 0.74)
    end
    W:unclip()

    -- 4. Fine woodblock keyblock contour (koppō) along upper slopes & crater rim (fades with fg)
    local contour = {}
    local NC = 64
    for i = 0, NC do
      local u = -0.68 + 1.36 * i / NC
      local x = u * hw
      contour[#contour + 1] = { cx + x, by + prof(x) }
    end
    local c_poly = B.outline(B.spine(B.chain(contour, 0.5), { step = 0.6 }), function(u)
      local edge_fade = sin(pi * u) ^ 0.85
      return max(0.18, H * 0.0075 * edge_fade)
    end)
    W:fill(W:poly(c_poly, true), peak_c, sumi and 0.66 or 0.62)
  end)

  U.rec(ctx, "fuji", bb)
  return bb, { kinds = { "fuji" }, base = by, summit = { cx, by + H } }
end

---------------------------------------------------------------- KASUMI / WASH BANDS
--- Kasumi (mist): 1-3 staggered irregular watercolour bands (never soft discs).
--- spec: x0, x1, y (centre line), height, rgb (default: paper / bokashi-sky
--- horizon at high alpha to veil what is behind it), bands = 1..3, alpha.
function M.kasumi(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, x1 = spec.x0 or ctx.region.x0 + 4, spec.x1 or ctx.region.x1 - 4
  local hgt = spec.height or 16
  local nb = spec.bands or R.int(1, 3)
  local col = spec.rgb or (U.hanga(ctx) and C(ctx, "bokashi-sky-horizon") or C(ctx, "sumi-wash"))
  local alpha = spec.alpha or (U.hanga(ctx) and 0.55 or 0.4)
  local bb
  W:layer(spec.layer or 13)
  for k = 1, nb do
    local span = x1 - x0
    local a0, a1 = x0, x1
    if k % 2 == 0 then a0 = x0 + span * R.range(0.25, 0.45) else a1 = x1 - span * R.range(0, 0.3) end
    local y = (spec.y or (ctx.region.y0 + ctx.region.y1) / 2) + (k - 1) * hgt * R.range(0.7, 1.1) * (k % 2 == 0 and -1 or 1)
    local h = hgt * R.range(0.8, 1.2)
    local rb = { x0 = a0 - 2, y0 = y - h * 0.9, x1 = a1 + 2, y1 = y + h * 0.9 }
    if U.fits_rect(ctx, rb) then
      local b = Wsh.band(ctx, { x0 = a0, x1 = a1, y = y, height = h, rgb = col, alpha = alpha, pool = spec.pool or false,
        gran = spec.gran or 0, fade = { 0.25, 0.25 }, blend = spec.blend })
      U.rec(ctx, "kasumi", b)
      bb = union(bb, b)
    end
  end
  return bb, { kinds = { "kasumi" } }
end

--- Plain watercolour band (ground strip, sky stroke): kacho-wash band with
--- growth limiting and a log record. spec as Wsh.band plus kind.
function M.wash_band(ctx, spec)
  spec = spec or {}
  local rb = { x0 = spec.x0 - 2, y0 = spec.y - (spec.height or 20) * 0.9, x1 = spec.x1 + 2, y1 = spec.y + (spec.height or 20) * 0.9 }
  if not U.fits_rect(ctx, rb) then return nil end
  ctx.pdf:layer(spec.layer or 11)
  local sp = {}
  for k, v in pairs(spec) do sp[k] = v end
  if sp.pool == nil then sp.pool = false end
  local b = Wsh.band(ctx, sp)
  U.rec(ctx, spec.kind or "wash-band", b)
  return b
end

---------------------------------------------------------------- BANK (mineral ledge & moss bank — zero scratchy grass)
local function greens(ctx)
  if U.hanga(ctx) then
    return { C(ctx, "rokusho"), C(ctx, "wakatake"), C(ctx, "matsuba"), C(ctx, "odo") }
  end
  return { C(ctx, "koke"), C(ctx, "sumi-light"), C(ctx, "sumi-mid"), C(ctx, "sumi-wash") }
end

--- Painted Kanga-e / Ukiyo-e mineral & moss bank: a layered ochre-and-malachite
--- rocky terrace whose wash fades smoothly into the paper (bokashi), accented
--- with angular tsun rock shelves, tenko moss clusters, and delicate wildflower
--- rosettes (no scratchy grass tick-marks).
function M.bank(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, x1, yb = spec.x0, spec.x1, spec.y
  local hh = spec.height or 30
  local s = fit_scale(ctx, function(k)
    local h = hh * k
    return { x0 = x0, y0 = yb - 2, x1 = x1, y1 = yb + h * 1.6 }
  end, 0.5)
  if not s then return nil end
  local h = hh * s
  local span = x1 - x0
  local bb
  -- terrace crest y(x): one or two soft humps
  local hump = { R.range(0.25, 0.75), R.range(0.1, 0.9) }
  local hw2 = { R.range(0.25, 0.45), R.range(0.15, 0.3) }
  local amp2 = R.range(0, 0.45)
  local function crest(x)
    local t = (x - x0) / span
    local v = math.exp(-((t - hump[1]) / hw2[1]) ^ 2) + amp2 * math.exp(-((t - hump[2]) / hw2[2]) ^ 2)
    if spec.root then v = max(v, 0.85 * math.exp(-((x - spec.root.x) / (span * 0.25)) ^ 2)) end
    local edge = min(1, t / 0.12, (1 - t) / 0.12)
    return yb + h * (0.25 + 0.75 * min(1, v)) * max(0, edge) ^ 0.6
  end
  local gs = greens(ctx)
  local hanga = U.hanga(ctx)
  local noir = C(ctx, "sumi-noir")
  if not spec.front then
    -- (1) mineral terrace body: warm ochre base grading into rokusho/koke green -> paper
    local pts = {}
    local n = max(24, floor(span / 5))
    for i = 0, n do local x = x0 + span * i / n; pts[#pts + 1] = { x, crest(x) } end
    pts[#pts + 1] = { x1, yb }
    pts[#pts + 1] = { x0, yb }
    local top = 0
    for _, p in ipairs(pts) do top = max(top, p[2]) end
    local rect = { x0 = x0, y0 = yb, x1 = x1, y1 = top + 2 }
    W:layer(spec.layer or 11)
    local pat = W:axial(x0, yb, x0, top, {
      { 0, gs[4] },
      { 0.52, gs[1] },
      { 1, mix(gs[1], U.paper(ctx), 0.72) },
    })
    local g = W:fade_box(rect, { 0.12, 0.12 }, { 0.08, 0.48 })
    W:with_gs(g, function()
      W:fill_pattern(W:poly(pts, true), pat, hanga and 0.68 or 0.42)
      -- faceted mineral stratum wash
      local q = {}
      local f = R.noise(2)
      local ph = R.range(0, 30)
      for i = 0, n do
        local x = x0 + span * i / n
        q[#q + 1] = { x, yb + (crest(x) - yb) * (0.62 + 0.22 * f(i / n * 4 + ph)) }
      end
      q[#q + 1] = { x1, yb }; q[#q + 1] = { x0, yb }
      W:fill(W:poly(q, true), gs[2], hanga and 0.24 or 0.16)
    end)
    bb = union(bb, rect)

    -- (2) angular Kanga-e rock shelf contour strokes along the terrace crest
    W:layer(spec.layer and spec.layer + 1 or 12)
    for k = 1, 3 do
      local sx0 = x0 + span * (0.10 + (k - 1) * 0.26 + R.sym(0.04))
      local sx1 = sx0 + span * R.range(0.18, 0.28)
      if sx1 < x1 - span * 0.06 then
        local shelf = {
          { sx0, crest(sx0) * 0.92 + yb * 0.08 },
          { (sx0 + sx1) * 0.5, crest((sx0 + sx1) * 0.5) },
          { sx1, crest(sx1) * 0.88 + yb * 0.12 },
        }
        if U.free_pts(ctx, shelf, 1.5) then
          B.dry(ctx, B.chain(shelf, 0.4), {
            w = max(1.1, h * 0.055),
            profile = "both",
            rgb = noir,
            alpha = 0.72,
            dryness = 0.38,
            bristles = 4,
          })
        end
      end
    end

    -- (3) small botanical rosettes & delicate 5-petal florets on the rocky terrace
    local np = spec.plants or floor(span / 75) + R.int(1, 2)
    local leaves, flw, cen = {}, {}, {}
    for _ = 1, np do
      local x = R.range(x0 + span * 0.12, x1 - span * 0.12)
      if not (spec.root and abs(x - spec.root.x) < (spec.root.w or 8) * 1.5) then
        local y = yb + (crest(x) - yb) * R.range(0.2, 0.55)
        local r = h * R.range(0.12, 0.18)
        if U.free(ctx, x, y + r, r * 1.6) then
          for k = 1, R.int(3, 5) do
            local a = pi / 2 + (k - 3) * 0.55 + R.sym(0.18)
            leaves[#leaves + 1] = W:poly(U.ellipse_pts(x + cos(a) * r * 0.8, y + sin(a) * r * 0.8 + r * 0.25, r * 0.7, r * 0.35, a, 12, 0.08, R), true)
          end
          if spec.flowers ~= false and R.chance(0.65) then
            for _ = 1, R.int(1, 3) do
              local fx, fy = x + R.sym(r * 1.1), y + r * R.range(1.1, 1.8)
              local fr = r * R.range(0.28, 0.38)
              for k = 0, 4 do
                local a = TAU * k / 5
                flw[#flw + 1] = W:circle(fx + cos(a) * fr * 0.6, fy + sin(a) * fr * 0.6, fr * 0.48)
              end
              cen[#cen + 1] = W:circle(fx, fy, fr * 0.28)
            end
          end
          bb = union(bb, { x0 = x - r * 2, y0 = y - r, x1 = x + r * 2, y1 = y + r * 2.4 })
        end
      end
    end
    W:layer(spec.layer and spec.layer + 2 or 13)
    if #leaves > 0 then W:fill(W:join(leaves), hanga and gs[3] or C(ctx, "sumi-mid"), 0.82) end
    if #flw > 0 then
      W:fill(W:join(flw), hanga and C(ctx, "momo") or C(ctx, "gofun"), 0.92)
      W:fill(W:join(cen), C(ctx, "yamabuki"), 0.92)
    end
  end
  -- (4) foreground tenko moss dots (no scratchy blades)
  W:layer(spec.front and 24 or (spec.layer and spec.layer + 3 or 14))
  local moss = {}
  for _ = 1, floor(span / 9) do
    local x = spec.root and R.chance(0.55) and spec.root.x + R.sym((spec.root.w or 8) * 1.8) or R.range(x0 + span * 0.08, x1 - span * 0.08)
    local y = yb + R.range(1.0, h * 0.38)
    if x > x0 + 2 and x < x1 - 2 and U.free(ctx, x, y, 2.2) then
      local r = R.range(0.7, 1.6)
      moss[#moss + 1] = W:ellipse(x, y, r, r * 0.72, R.range(0, pi))
      bb = union(bb, { x0 = x - r - 1, y0 = y - r - 1, x1 = x + r + 1, y1 = y + r + 1 })
    end
  end
  if #moss > 0 then W:fill(W:join(moss), hanga and C(ctx, "matsuba") or noir, 0.85) end
  if bb then U.rec(ctx, spec.front and "bank-moss" or "bank", bb) end
  return bb, { kinds = { "bank", "bank-moss" }, crest = crest }
end

return M
