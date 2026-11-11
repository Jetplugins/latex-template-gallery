-- Copyright 2026 Allen Jue
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- kacho-anim.lua: Optional animated growth demo (Milestone M5, Feature 31).
--
-- Portions adapted from tikz-flora (clock.lua, plant growth clock):
-- Copyright (c) 2026 the tikz-flora authors. MIT License.
--
-- Portions adapted from florilegium (https://github.com/kevinraymond/florilegium,
-- watch-it-grow animation staging, bilateral root/footer stem sprouting, tangential
-- branch_path departures, multi-scale hero/medium/small blooms, wispy scorpioid
-- cymes, radiating umbels, branching sprigs, logarithmic-spiral tendrils,
-- multi-opacity ghost/foreground depth, and kacho-ink.lua watercolour glazing):
-- Copyright (c) 2026 Kevin Raymond. MIT License:
--
--   Permission is hereby granted, free of charge, to any person obtaining a copy
--   of this software and associated documentation files (the "Software"), to deal
--   in the Software without restriction, including without limitation the rights
--   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--   copies of the Software, and to permit persons to whom the Software is
--   furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in all
--   copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--   SOFTWARE.
--
-- ALGORITHMS & REFERENCES:
--   * Normalized growth clock & staged interval mapping: adapted from tikz-flora
--     (clock.lua, MIT) and Kevin Raymond, florilegium (florilegium-grow.lua, 2026,
--     MIT), parameterized over t in [0, 1] with smooth cubic easing.
--   * De Casteljau cubic Bézier prefix subdivision for growing stems & twigs:
--     Paul de Casteljau (1959); Gerald Farin, "Curves and Surfaces for CAGD", 2002;
--     applied to skeletal brush strokes (Hsu & Lee, SIGGRAPH 1994).
--   * Bilateral origin sprouting, power-law taper w(u) = lerp(w0, w1, u^0.75),
--     pipe-model cross-sectional area conservation at branch forks, C1 tangential
--     branch departures, and wispy secondary flora (scorpioid cymes, compound
--     umbels, dichotomous sprigs, spiral tendrils): adapted from Kevin Raymond,
--     florilegium (florilegium-grow.lua, florilegium-flora.lua M.stem /
--     M.branch_path / M.cyme / M.umbel / M.sprig / M.tendril, 2026, MIT),
--     K. Shinozaki et al., "A Quantitative Analysis of Plant Form: The Pipe
--     Model Theory", Japanese Journal of Ecology 14(3), 1964, and P. Prusinkiewicz
--     & A. Lindenmayer, "The Algorithmic Beauty of Plants", Springer, 1990.
--   * Multi-glaze watercolour blossom, bud, and leaf rendering: Curtis et al.,
--     "Computer-Generated Watercolor", SIGGRAPH 1997, via kacho-ink.lua /
--     kacho-flora.lua (adapted from florilegium-flora.lua, Kevin Raymond, 2026, MIT).
--   * Adaptive multi-scale floral ornament staging: inspired by M. T. Wong, D. E.
--     Zongker & D. H. Salesin, "Computer-Generated Floral Ornament", SIGGRAPH 1998.

local M = {}

local pdfw    = require("kacho-pdf")
local rng     = require("kacho-rng")
local palette = require("kacho-palette")
local brush   = require("kacho-brush")
local wash    = require("kacho-wash")
local ink     = require("kacho-ink")
local flora   = require("kacho-flora")
local fauna   = require("kacho-fauna")
local seal    = require("kacho-seal")

local min, max, floor, sin, cos, pi, sqrt, abs =
  math.min, math.max, math.floor, math.sin, math.cos, math.pi, math.sqrt, math.abs
local rad = pi / 180
local fmt = string.format

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
local REG -- shared document-wide PDF resource registry

local function lerp(a, b, t) return a + (b - a) * t end

------------------------------------------------------------------------
-- 1. Growth Clock (adapted from tikz-flora clock.lua & florilegium)
------------------------------------------------------------------------
local Clock = {}
Clock.__index = Clock

function Clock.new(t)
  return setmetatable({ t = max(0, min(1, tonumber(t) or 1)) }, Clock)
end

function Clock:span(t0, t1)
  if self.t <= t0 then return 0 end
  if self.t >= t1 then return 1 end
  return (self.t - t0) / max(1e-6, t1 - t0)
end

function Clock:smooth(t0, t1)
  local u = self:span(t0, t1)
  return u * u * (3 - 2 * u)
end

function Clock:ease_out(t0, t1)
  local u = self:span(t0, t1)
  local inv = 1 - u
  return 1 - inv * inv * inv
end

M.Clock = Clock

------------------------------------------------------------------------
-- 2. Partial Spine Subdivision, Power-Law Taper & Tangential Offshoots
------------------------------------------------------------------------
local function partial_segs(segs, p)
  segs = brush.normalize(segs)
  local n = #segs
  if n == 0 or p <= 0 then return {} end
  if p >= 1 then return segs end
  local scaled = p * n
  local full = floor(scaled)
  local rem = scaled - full
  local out = {}
  for i = 1, full do
    out[#out + 1] = segs[i]
  end
  if rem > 1e-4 and full < n then
    local left, _ = brush.split(segs[full + 1], rem)
    out[#out + 1] = left
  end
  return out
end

-- Power-law width profile w(u) = lerp(w0, w1, (u * p)^0.75) with smooth
-- tip-sharpening over the final 32% of the growing stroke so every tip
-- at every frame t narrows to a fine hairline (< 0.45 bp).
local function power_taper_profile(w0, w1, p)
  w1 = w1 or 0.26
  p = max(0.05, min(1.0, p or 1.0))
  return function(u)
    local uf = u * p
    local w_nat = w0 + (w1 - w0) * (uf ^ 0.75)
    if u > 0.68 then
      local s = (u - 0.68) / 0.32
      local k = 1 - s * s * (3 - 2 * s)
      w_nat = w1 + (w_nat - w1) * k
    end
    return max(0.015, w_nat / max(1e-6, w0))
  end
end

-- Tangential C1 cubic Bézier branch departure (adapted from florilegium-flora.lua
-- M.branch_path): leaves parent spine S at arc fraction u along a tangent turned
-- gently inside the parent ribbon, curving toward turn_deg over length len.
local function tangential_branch(S, u, side, turn_deg, len, bend_deg)
  local sx, sy, tx, ty = brush.at(S, u)
  local turn = side * turn_deg * rad
  local turn0 = turn * 0.36
  local c1x = tx * cos(turn0) - ty * sin(turn0)
  local c1y = tx * sin(turn0) + ty * cos(turn0)
  local dx = tx * cos(turn) - ty * sin(turn)
  local dy = tx * sin(turn) + ty * cos(turn)
  local bend = (bend_deg or (side * 14)) * rad
  local ax = dx * cos(bend) - dy * sin(bend)
  local ay = dx * sin(bend) + dy * cos(bend)
  local bx = sx + (dx * 0.58 + ax * 0.42) * len
  local by = sy + (dy * 0.58 + ay * 0.42) * len
  local seg = {
    { sx, sy },
    { sx + c1x * len * 0.42, sy + c1y * len * 0.42 },
    { bx - ax * len * 0.36,  by - ay * len * 0.36 },
    { bx, by },
  }
  return { seg }
end

-- Wrap a painting call in a PDF CTM scale around (cx, cy) so that
-- kacho-ink's internal I.unit() stays constant across all frames t
-- (guaranteeing identical RNG draws and zero flicker while opening).
local function scaled_organ(W, cx, cy, k, fn)
  if k >= 0.999 then return fn() end
  if k <= 0.001 then return nil end
  local tx = cx * (1 - k)
  local ty = cy * (1 - k)
  W:put(fmt("q %.4f 0 0 %.4f %.3f %.3f cm", k, k, tx, ty))
  local bb = fn()
  W:put("Q")
  if bb then
    return {
      x0 = cx + (bb.x0 - cx) * k,
      y0 = cy + (bb.y0 - cy) * k,
      x1 = cx + (bb.x1 - cx) * k,
      y1 = cy + (bb.y1 - cy) * k,
    }
  end
  return nil
end

------------------------------------------------------------------------
-- 3. Wispy Secondary Flora (Ported from florilegium-flora.lua:
--    floret, scorpioid cyme, radiating umbel, branching sprig, tendril)
------------------------------------------------------------------------
-- Integrate a path from a heading function h(s) in degrees at arclength s
local function walk_path(x, y, h_fn, L, n)
  local pts, ds = { { x, y } }, L / n
  for i = 1, n do
    local a = h_fn((i - 0.5) * ds) * rad
    x, y = x + ds * cos(a), y + ds * sin(a)
    pts[#pts + 1] = { x, y }
  end
  return pts
end

local function pts_normals(pts)
  local n, out = #pts, {}
  for i = 1, n do
    local a, b = pts[max(1, i - 1)], pts[min(n, i + 1)]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local L = sqrt(dx * dx + dy * dy)
    if L < 1e-9 then L = 1 end
    out[i] = { -dy / L, dx / L }
  end
  return out
end

-- Tapered stem along polyline pts using kacho-ink ribbon/stroke
local function ink_stem(pts, w0, w1, c, op)
  if #pts < 2 then return end
  local w_mid = (w0 + w1) * 0.5 * ink.unit()
  if w_mid < 0.55 then
    ink.smooth(pts, false)
    ink.stroke(c or ink.tone(0.18), max(0.18, w_mid), op or 0.88)
    return
  end
  ink.smooth(ink.ribbon(pts, function(t) return lerp(w0, w1, t ^ 0.75) end), true)
  ink.fill(c or ink.tone(0.18), op or 0.90)
end

-- Tiny 5-petal starry/rounded floret at local origin, radius r (ported from florilegium)
local function ink_floret(R, r, o)
  o = o or {}
  local star = o.star
  local t0 = o.tone or R.range(0.42, 0.58)
  local alpha = o.alpha or 0.92
  ink.push()
  ink.scale(r)
  ink.rotate(R.range(0, 72))
  for k = 0, 4 do
    ink.push()
    ink.rotate(k * 72 + R.sym(6))
    local w = star and 0.24 or 0.38
    local hw = function(v)
      return w * sin(pi * (v ^ 0.65)) ^ (star and 0.95 or 0.72)
    end
    local outline = ink.blade(function(v) return 0, v end, 10, hw, hw)
    ink.smooth(outline, true)
    ink.fill(ink.tone(min(0.92, t0 + R.sym(0.05))), alpha)
    ink.smooth(outline, true)
    ink.stroke(ink.tone(max(0.16, t0 - 0.18)), 0.18, 0.28 * alpha, true)
    ink.pop()
  end
  ink.circle(0, 0, 0.20)
  ink.fill(ink.white, 0.90 * alpha)
  ink.circle(0, 0, 0.10)
  ink.fill(ink.accent(0.1), 0.92 * alpha)
  ink.pop()
end

-- Forget-me-not / sakura-spray scorpioid cyme (ported from florilegium M.cyme):
-- A slender stem of length L (bp) that curls at its tip, with tiny florets
-- crowding along it and shrinking into buds.
local function paint_cyme(W, R, x0, y0, h0_deg, L, side, hue_rgb, stem_col, alpha)
  ink.begin(W, hue_rgb, { accent = { 0.88, 0.64, 0.22 }, chroma = 0.95 })
  ink.detail = 0.75
  local turn = R.range(165, 225)
  local N = 28
  local pts = walk_path(x0, y0, function(s) return h0_deg + side * turn * ((s / L) ^ 2.2) end, L, N)
  ink_stem(pts, 0.82, 0.18, stem_col, alpha)
  local nrm = pts_normals(pts)
  local nf = R.int(10, 14)
  for k = 1, nf do
    local f = 0.16 + 0.82 * ((k / nf) ^ 0.76)
    local idx = max(2, min(#pts, floor(f * N + 1.5)))
    local sg = (k % 2 == 0) and 1 or -1
    local px, py = pts[idx][1], pts[idx][2]
    local stalk = lerp(3.4, 0.7, f) * R.range(0.75, 1.18)
    local qx, qy = px + nrm[idx][1] * sg * stalk, py + nrm[idx][2] * sg * stalk
    if stalk > 0.8 then
      ink.moveto(px, py)
      ink.lineto(qx, qy)
      ink.stroke(stem_col, 0.22, 0.82 * alpha)
    end
    local r = lerp(3.2, 0.95, f) * R.range(0.88, 1.12)
    ink.push()
    ink.translate(qx, qy)
    if f > 0.76 then
      ink.circle(0, 0, r * 0.62)
      ink.fill(ink.tone(R.range(0.44, 0.58)), 0.90 * alpha)
    else
      ink_floret(R, r, { star = false, tone = R.range(0.52, 0.68), alpha = alpha })
    end
    ink.pop()
  end
  -- Small basal leaflet on the cyme stalk
  local bidx = max(2, floor(N * 0.18))
  local ldeg = h0_deg + side * 48
  ink.push()
  ink.translate(pts[bidx][1], pts[bidx][2])
  ink.rotate(ldeg - 90)
  ink.scale(L * 0.24)
  ink.leaflet(R, { w = 0.18, tone = 0.42, alpha = alpha })
  ink.pop()
  return ink.finish()
end

-- Radiating compound umbel (yuki-yanagi / kodemari / Queen Anne's lace,
-- ported from florilegium M.umbel): hairline rays fanning from (x0,y0),
-- each ending in a mini-umbel of starry florets, with bracts at the base.
local function paint_umbel(W, R, x0, y0, h0_deg, reach, hue_rgb, leaf_rgb, stem_col, alpha)
  -- Bracts at base in leaf_rgb
  ink.begin(W, leaf_rgb, { chroma = 0.85 })
  for k = -1, 1 do
    ink.push()
    ink.translate(x0, y0)
    ink.rotate(h0_deg - 90 + k * 38 + R.sym(8) + 180)
    ink.scale(reach * R.range(0.18, 0.25))
    ink.leaflet(R, { w = 0.09, bend = k * 0.18, tone = 0.40, alpha = alpha * 0.85 })
    ink.pop()
  end
  local bb1 = ink.finish()

  -- Rays & starry florets
  ink.begin(W, hue_rgb, { accent = { 0.88, 0.64, 0.22 }, chroma = 0.92 })
  local nr = R.int(8, 11)
  for k = 1, nr do
    local a = h0_deg + (k - (nr + 1) / 2) * (104 / nr) + R.sym(3.5)
    local L = reach * R.range(0.76, 1.0) * (1 - 0.14 * abs(a - h0_deg) / 55)
    local ar = a * rad
    local ex, ey = x0 + L * cos(ar), y0 + L * sin(ar)
    local mx1, my1 = lerp(x0, ex, 0.35), lerp(y0, ey, 0.48)
    local mx2, my2 = lerp(x0, ex, 0.72), lerp(y0, ey, 0.88)
    ink.smooth(ink.sample(ink.bezier3(x0, y0, mx1, my1, mx2, my2, ex, ey), 5), false)
    ink.stroke(stem_col, 0.24, 0.82 * alpha)
    local ns = R.int(4, 6)
    for j = 1, ns do
      local b = (a + (j - (ns + 1) / 2) * 17 + R.sym(4)) * rad
      local l = reach * R.range(0.12, 0.19)
      local fx, fy = ex + l * cos(b), ey + l * sin(b)
      ink.moveto(ex, ey)
      ink.lineto(fx, fy)
      ink.stroke(stem_col, 0.17, 0.76 * alpha)
      ink.push()
      ink.translate(fx, fy)
      ink_floret(R, reach * R.range(0.055, 0.080), {
        star  = true,
        tone  = R.range(0.56, 0.74),
        alpha = alpha,
      })
      ink.pop()
    end
  end
  local bb2 = ink.finish()
  return brush.union(bb1, bb2)
end

-- Wiry dichotomous branching sprig (ported from florilegium M.sprig):
-- forks 2 ways `depth` times with tiny leaflets and florets/buds at tips.
local function paint_sprig(W, R, x0, y0, h0_deg, L, hue_rgb, stem_col, alpha)
  ink.begin(W, hue_rgb, { accent = { 0.88, 0.64, 0.22 }, chroma = 0.90 })
  local depth = 3
  local t0 = R.range(0.50, 0.66)
  local function rec_branch(x, y, a, len, d, w)
    local bend = R.sym(18)
    local pts = walk_path(x, y, function(s) return a + bend * (s / len) end, len, 6)
    ink_stem(pts, w, w * 0.68, stem_col, alpha * 0.88)
    local ex, ey = pts[#pts][1], pts[#pts][2]
    local ea = a + bend
    if d == 0 then
      ink.push()
      ink.translate(ex, ey)
      if R.chance(0.72) then
        ink_floret(R, R.range(1.6, 2.5), { tone = t0 + R.sym(0.06), alpha = alpha })
      else
        ink.circle(0, 0, R.range(0.75, 1.15))
        ink.fill(ink.tone(max(0.32, t0 - 0.08)), 0.90 * alpha)
      end
      ink.pop()
      return
    end
    for k = 1, 2 do
      local da = (k == 1 and -1 or 1) * R.range(18, 32)
      rec_branch(ex, ey, ea + da, len * R.range(0.62, 0.76), d - 1, w * 0.70)
    end
  end
  rec_branch(x0, y0, h0_deg + R.sym(5), L * 0.42, depth, 0.68)
  return ink.finish()
end

-- Tapered logarithmic-spiral tendril (ported from florilegium M.tendril):
local function paint_tendril(W, R, x0, y0, h0_deg, sz, side, stem_col, alpha)
  ink.begin(W, stem_col, { chroma = 0.4 })
  ink.push()
  ink.translate(x0, y0)
  ink.rotate(h0_deg)
  local pts = {}
  local turns = R.range(1.45, 2.05)
  for i = 0, 44 do
    local t = i / 44
    local a = side * t * turns * 2 * pi
    local r = sz * ((1 - 0.90 * t) ^ 1.55)
    pts[#pts + 1] = { r * sin(a), side * (sz - r * cos(a)) }
  end
  ink_stem(pts, 0.68, 0.14, stem_col, alpha * 0.86)
  ink.pop()
  return ink.finish()
end

------------------------------------------------------------------------
-- 4. Deterministic Bilateral Multi-Scale Plant & Wispy Garden Plan
------------------------------------------------------------------------
local PLAN_CACHE = {}
local current_plan = nil
local frame_counter = 0
local debug_lines = {}

function M.plan(seed, w_bp, h_bp, opts)
  seed = tonumber(seed) or 7
  w_bp = tonumber(w_bp) or 220
  h_bp = tonumber(h_bp) or 280
  opts = opts or {}

  local P = {
    seed      = seed,
    W         = w_bp,
    H         = h_bp,
    box_x0    = opts.box_x0 or 25,
    box_y0    = opts.box_y0 or 28,
    textblock = opts.textblock or { 25, 314, 245, 329 },
  }

  -- Shared bilateral corner origin nexus at (OX, OY) = (44, 44):
  -- Like florilegium (media_1793595515060_395c8d00.jpg & 97206f1e.jpg),
  -- slender undulating main stems flow upward along the left/diagonal margin
  -- and arch across the top, while sibling footer stems flow horizontally in
  -- the opposite C1 direction across the bottom and curl upward at the right,
  -- plus a delicate origin scroll curl at the bottom-left corner.
  -- Zero flat-cut trunk bases and zero green oval grass mounds!
  local OX, OY = 44, 44

  -- Tier 3 (Foreground primary bilateral stems, alpha = 0.94):
  local f_up_segs = brush.chain({
    { OX, OY },
    { 36, 92 },
    { 46, 148 },
    { 66, 202 },
    { 106, 238 },
    { 156, 246 },
  }, 0.95, { -0.24, 0.97 }, { 0.92, 0.38 })
  local f_dn_segs = brush.chain({
    { OX, OY },
    { 64, 30 },
    { 106, 26 },
    { 148, 32 },
    { 174, 52 },
  }, 0.95, { 0.24, -0.97 }, { 0.62, 0.78 })

  local f_up_S = brush.spine(f_up_segs)
  local f_dn_S = brush.spine(f_dn_segs)

  -- Origin scroll curl at bottom-left corner (like florilegium-grow.lua line 524)
  local scroll_pts = {}
  for i = 0, 20 do
    local t = i / 20
    local a = pi * 0.62 + t * 1.35 * 2 * pi
    local r = 13.5 * ((1 - 0.82 * t) ^ 1.25)
    scroll_pts[#scroll_pts + 1] = { OX - 6.0 - r * cos(a), OY - 10.5 + r * sin(a) }
  end
  local f_scroll_segs = brush.chain(scroll_pts, 0.95)
  local f_scroll_S = brush.spine(f_scroll_segs)

  -- Tier 2 (Mid-ground interwoven stems, alpha = 0.68):
  local m_up_segs = brush.chain({
    { OX, OY },
    { 50, 96 },
    { 40, 154 },
    { 54, 212 },
    { 88, 244 },
  }, 0.95, { 0.16, 0.987 }, { 0.78, 0.62 })
  local m_dn_segs = brush.chain({
    { OX, OY },
    { 58, 34 },
    { 96, 32 },
    { 136, 28 },
    { 164, 38 },
  }, 0.95, { -0.16, -0.987 }, { 0.88, 0.47 })
  local m_up_S = brush.spine(m_up_segs)
  local m_dn_S = brush.spine(m_dn_segs)

  -- Tier 1 (Background ghost stems, alpha = 0.38):
  local g_up_segs = brush.chain({
    { OX + 2, OY + 4 },
    { 58, 104 },
    { 78, 164 },
    { 102, 216 },
    { 138, 242 },
  }, 0.95, { 0.32, 0.947 }, { 0.80, 0.60 })
  local g_dn_segs = brush.chain({
    { OX + 2, OY + 4 },
    { 52, 28 },
    { 88, 24 },
    { 126, 30 },
  }, 0.95, { -0.32, -0.947 }, { 0.94, 0.34 })
  local g_up_S = brush.spine(g_up_segs)
  local g_dn_S = brush.spine(g_dn_segs)

  local function w_at(w0, w1, u)
    return w0 + (w1 - w0) * (u ^ 0.75)
  end

  -- Graceful florilegium-proportioned stems (slender & sinuous, staggered across t in [0.02, 0.68])
  P.branches = {
    -- Tier 1: Background ghost (alpha = 0.38)
    { id = "g_up", tier = 1, segs = g_up_segs, S = g_up_S, w0 = 3.8, w1 = 0.22, t0 = 0.04, t1 = 0.64, seed = seed + 101 },
    { id = "g_dn", tier = 1, segs = g_dn_segs, S = g_dn_S, w0 = 3.8, w1 = 0.22, t0 = 0.04, t1 = 0.56, seed = seed + 102 },
    -- Tier 2: Mid-ground (alpha = 0.68)
    { id = "m_up", tier = 2, segs = m_up_segs, S = m_up_S, w0 = 5.0, w1 = 0.24, t0 = 0.03, t1 = 0.66, seed = seed + 201 },
    { id = "m_dn", tier = 2, segs = m_dn_segs, S = m_dn_S, w0 = 5.0, w1 = 0.24, t0 = 0.03, t1 = 0.58, seed = seed + 202 },
    -- Tier 3: Foreground bilateral primary (alpha = 0.94)
    { id = "f_up",     tier = 3, segs = f_up_segs,     S = f_up_S,     w0 = 6.8, w1 = 0.26, t0 = 0.02, t1 = 0.68, seed = seed + 301, kasure = true },
    { id = "f_dn",     tier = 3, segs = f_dn_segs,     S = f_dn_S,     w0 = 6.8, w1 = 0.26, t0 = 0.02, t1 = 0.60, seed = seed + 302, kasure = true },
    { id = "f_scroll", tier = 3, segs = f_scroll_segs, S = f_scroll_S, w0 = 3.6, w1 = 0.18, t0 = 0.04, t1 = 0.42, seed = seed + 303 },
  }

  -- Tangential C1 lateral branches arching into the garden space
  local offshoot_specs = {
    -- Tier 1 ghost offshoots
    { id = "g_tw1", tier = 1, pS = g_up_S, pw0 = 3.8, pw1 = 0.22, u = 0.38, side = -1, turn = 34, len = 48, bend = -14, scale = 0.62, t0 = 0.24, t1 = 0.68, seed = seed + 111 },
    { id = "g_tw2", tier = 1, pS = g_up_S, pw0 = 3.8, pw1 = 0.22, u = 0.68, side = -1, turn = 32, len = 44, bend = -12, scale = 0.58, t0 = 0.40, t1 = 0.78, seed = seed + 112 },

    -- Tier 2 mid-ground offshoots
    { id = "m_tw1", tier = 2, pS = m_up_S, pw0 = 5.0, pw1 = 0.24, u = 0.32, side = -1, turn = 36, len = 52, bend = -16, scale = 0.62, t0 = 0.22, t1 = 0.66, seed = seed + 211 },
    { id = "m_tw2", tier = 2, pS = m_up_S, pw0 = 5.0, pw1 = 0.24, u = 0.62, side = -1, turn = 34, len = 46, bend = -14, scale = 0.58, t0 = 0.38, t1 = 0.76, seed = seed + 212 },
    { id = "m_tw3", tier = 2, pS = m_dn_S, pw0 = 5.0, pw1 = 0.24, u = 0.48, side =  1, turn = 34, len = 42, bend =  14, scale = 0.58, t0 = 0.28, t1 = 0.68, seed = seed + 213 },

    -- Tier 3 foreground arching branches (creating a rich kacho-e / florilegium spray)
    { id = "f_tw1", tier = 3, pS = f_up_S, pw0 = 6.8, pw1 = 0.26, u = 0.25, side = -1, turn = 48, len = 78, bend = -22, scale = 0.64, t0 = 0.18, t1 = 0.64, seed = seed + 311, kasure = true },
    { id = "f_tw2", tier = 3, pS = f_up_S, pw0 = 6.8, pw1 = 0.26, u = 0.46, side = -1, turn = 36, len = 68, bend = -16, scale = 0.62, t0 = 0.30, t1 = 0.72, seed = seed + 312, kasure = true },
    { id = "f_tw3", tier = 3, pS = f_up_S, pw0 = 6.8, pw1 = 0.26, u = 0.68, side = -1, turn = 34, len = 54, bend = -14, scale = 0.58, t0 = 0.42, t1 = 0.80, seed = seed + 313 },
    { id = "f_tw4", tier = 3, pS = f_up_S, pw0 = 6.8, pw1 = 0.26, u = 0.84, side = -1, turn = 30, len = 38, bend = -12, scale = 0.56, t0 = 0.52, t1 = 0.86, seed = seed + 314 },
    { id = "f_tw5", tier = 3, pS = f_dn_S, pw0 = 6.8, pw1 = 0.26, u = 0.36, side =  1, turn = 36, len = 48, bend =  14, scale = 0.60, t0 = 0.22, t1 = 0.64, seed = seed + 315 },
    { id = "f_tw6", tier = 3, pS = f_dn_S, pw0 = 6.8, pw1 = 0.26, u = 0.72, side =  1, turn = 42, len = 54, bend =  18, scale = 0.56, t0 = 0.36, t1 = 0.76, seed = seed + 316 },
  }

  local by_id = {}
  for _, b in ipairs(P.branches) do by_id[b.id] = b end

  for _, s in ipairs(offshoot_specs) do
    local segs = tangential_branch(s.pS, s.u, s.side, s.turn, s.len, s.bend)
    local S = brush.spine(segs)
    local pw_u = w_at(s.pw0, s.pw1, s.u)
    local w0 = pw_u * s.scale
    local b = {
      id = s.id, tier = s.tier, segs = segs, S = S,
      pS = s.pS, pu = s.u, pw0 = s.pw0, pw1 = s.pw1,
      w0 = w0, w1 = 0.20, t0 = s.t0, t1 = s.t1, seed = s.seed, kasure = s.kasure,
    }
    P.branches[#P.branches + 1] = b
    by_id[b.id] = b
  end

  -- Tertiary hairline twigs
  local sub_specs = {
    { id = "f_sub1", tier = 3, pid = "f_tw1", u = 0.42, side = -1, turn = 32, len = 32, bend = -12, scale = 0.60, t0 = 0.42, t1 = 0.78, seed = seed + 321 },
    { id = "f_sub2", tier = 3, pid = "f_tw2", u = 0.54, side =  1, turn = 30, len = 34, bend =  12, scale = 0.60, t0 = 0.48, t1 = 0.84, seed = seed + 322 },
    { id = "f_sub3", tier = 3, pid = "f_tw6", u = 0.56, side =  1, turn = 34, len = 28, bend =  14, scale = 0.58, t0 = 0.52, t1 = 0.88, seed = seed + 323 },
  }
  for _, s in ipairs(sub_specs) do
    local pb = by_id[s.pid]
    local segs = tangential_branch(pb.S, s.u, s.side, s.turn, s.len, s.bend)
    local S = brush.spine(segs)
    local pw_u = w_at(pb.w0, pb.w1, s.u)
    local w0 = pw_u * s.scale
    local b = {
      id = s.id, tier = s.tier, segs = segs, S = S,
      pS = pb.S, pu = s.u, pw0 = pb.w0, pw1 = pb.w1,
      w0 = w0, w1 = 0.18, t0 = s.t0, t1 = s.t1, seed = s.seed,
    }
    P.branches[#P.branches + 1] = b
    by_id[b.id] = b
  end

  local function anchor_on(bid, u, normal_off, along_off)
    local b = by_id[bid]
    local x, y, tx, ty = brush.at(b.S, u)
    local nx, ny = -ty, tx
    return x + nx * (normal_off or 0) + tx * (along_off or 0),
           y + ny * (normal_off or 0) + ty * (along_off or 0),
           math.atan(ty, tx), b.tier
  end

  -- 4a. Wispy Secondary Flora: scorpioid cymes, radiating umbels, branching sprigs,
  -- and logarithmic-spiral tendrils departing tangentially from the stems!
  local wispy_specs = {
    -- Scorpioid Cymes (curling stems of tiny florets & buds)
    { kind = "cyme",    bid = "f_up",  u = 0.54, noff =  2.0, da = -32, len = 34, side =  1, t0 = 0.42, t1 = 0.86, seed = seed + 801 },
    { kind = "cyme",    bid = "f_up",  u = 0.92, noff = -1.5, da = -28, len = 30, side = -1, t0 = 0.58, t1 = 0.94, seed = seed + 802 },
    { kind = "cyme",    bid = "f_tw1", u = 0.86, noff = -1.5, da = -24, len = 30, side =  1, t0 = 0.48, t1 = 0.88, seed = seed + 803 },
    { kind = "cyme",    bid = "f_dn",  u = 0.82, noff =  1.5, da =  36, len = 32, side =  1, t0 = 0.46, t1 = 0.86, seed = seed + 804 },
    { kind = "cyme",    bid = "m_up",  u = 0.76, noff =  1.5, da =  30, len = 28, side = -1, t0 = 0.46, t1 = 0.84, seed = seed + 805 },

    -- Radiating Compound Umbels (yuki-yanagi / Queen Anne's lace fans)
    { kind = "umbel",   bid = "f_up",  u = 0.34, noff =  3.0, da =  46, len = 20, side =  1, t0 = 0.38, t1 = 0.82, seed = seed + 811 },
    { kind = "umbel",   bid = "f_tw2", u = 0.78, noff =  2.0, da =  28, len = 19, side = -1, t0 = 0.52, t1 = 0.90, seed = seed + 812 },
    { kind = "umbel",   bid = "f_dn",  u = 0.54, noff =  2.5, da =  48, len = 18, side =  1, t0 = 0.40, t1 = 0.82, seed = seed + 813 },

    -- Wiry Dichotomous Sprigs (baby's breath / kasumiso)
    { kind = "sprig",   bid = "m_tw1", u = 0.82, noff =  1.0, da =  18, len = 26, side =  1, t0 = 0.44, t1 = 0.84, seed = seed + 821 },
    { kind = "sprig",   bid = "f_tw3", u = 0.84, noff = -1.0, da = -18, len = 26, side = -1, t0 = 0.54, t1 = 0.92, seed = seed + 822 },
    { kind = "sprig",   bid = "f_tw5", u = 0.86, noff =  1.0, da =  22, len = 24, side =  1, t0 = 0.42, t1 = 0.84, seed = seed + 823 },

    -- Curling Logarithmic-Spiral Tendrils
    { kind = "tendril", bid = "f_up",  u = 0.14, noff =  1.5, da =  44, len = 14, side =  1, t0 = 0.26, t1 = 0.68, seed = seed + 831 },
    { kind = "tendril", bid = "f_up",  u = 0.76, noff =  1.5, da =  38, len = 15, side =  1, t0 = 0.52, t1 = 0.88, seed = seed + 832 },
    { kind = "tendril", bid = "f_dn",  u = 0.24, noff = -1.5, da = -42, len = 13, side = -1, t0 = 0.24, t1 = 0.66, seed = seed + 833 },
    { kind = "tendril", bid = "f_dn",  u = 0.96, noff =  0.5, da =  12, len = 15, side =  1, t0 = 0.52, t1 = 0.88, seed = seed + 834 },
    { kind = "tendril", bid = "f_tw6", u = 0.94, noff =  0.5, da =  16, len = 14, side = -1, t0 = 0.56, t1 = 0.92, seed = seed + 835 },
  }

  P.wispy = {}
  for _, s in ipairs(wispy_specs) do
    local x, y, tang, tier = anchor_on(s.bid, s.u, s.noff, 0)
    P.wispy[#P.wispy + 1] = {
      kind = s.kind, x = x, y = y, deg = math.deg(tang) + s.da,
      len = s.len, side = s.side, tier = tier,
      t0 = s.t0, t1 = s.t1, seed = s.seed,
    }
  end

  -- 4b. Mixed Multi-Scale Foliage (sculpted lobes, bamboo leaf fans, palmate momiji maple leaves,
  --     serrated sakura leaves, and V-pairs of leaflets along the stems)
  local leaf_specs = {
    -- Tier 2 mid-ground leaves & bamboo fans
    { bid = "m_up",  u = 0.24, noff =  2.0, deg_off =  44, len = 24.0, bend =  0.18, lobes = 4, depth = 0.42, kind = "leaf",       t0 = 0.28, t1 = 0.72, seed = seed + 701 },
    { bid = "m_up",  u = 0.56, noff =  2.0, deg_off =  48, len = 22.0, bend =  0.16, lobes = 3, depth = 0.38, kind = "bamboo_fan", t0 = 0.40, t1 = 0.80, seed = seed + 702 },
    { bid = "m_dn",  u = 0.36, noff =  2.0, deg_off =  42, len = 20.0, bend =  0.15, lobes = 3, depth = 0.36, kind = "leaf",       t0 = 0.32, t1 = 0.74, seed = seed + 703 },

    -- Tier 3 foreground large & medium sculpted leaves, bamboo leaf fans, and maple leaves
    { bid = "f_up",  u = 0.16, noff = -2.5, deg_off = -48, len = 28.0, bend = -0.20, lobes = 4, depth = 0.46, kind = "leaf",       t0 = 0.26, t1 = 0.70, seed = seed + 704 },
    { bid = "f_up",  u = 0.40, noff =  2.5, deg_off =  46, len = 24.0, bend =  0.18, lobes = 4, depth = 0.42, kind = "bamboo_fan", t0 = 0.38, t1 = 0.78, seed = seed + 705 },
    { bid = "f_up",  u = 0.62, noff =  2.0, deg_off =  42, len = 18.0, bend =  0.15, lobes = 0, depth = 0.00, kind = "maple",      t0 = 0.46, t1 = 0.84, seed = seed + 706 },
    { bid = "f_tw1", u = 0.28, noff =  2.0, deg_off =  48, len = 22.0, bend =  0.16, lobes = 3, depth = 0.38, kind = "leaf",       t0 = 0.36, t1 = 0.76, seed = seed + 707 },
    { bid = "f_tw2", u = 0.38, noff = -2.0, deg_off = -44, len = 23.0, bend = -0.16, lobes = 4, depth = 0.40, kind = "bamboo_fan", t0 = 0.42, t1 = 0.82, seed = seed + 708 },
    { bid = "f_dn",  u = 0.20, noff =  2.5, deg_off =  48, len = 25.0, bend =  0.18, lobes = 4, depth = 0.44, kind = "leaf",       t0 = 0.28, t1 = 0.70, seed = seed + 709 },
    { bid = "f_dn",  u = 0.58, noff = -2.0, deg_off = -42, len = 17.0, bend = -0.14, lobes = 0, depth = 0.00, kind = "maple",      t0 = 0.40, t1 = 0.80, seed = seed + 710 },
    { bid = "f_tw5", u = 0.42, noff = -1.8, deg_off = -40, len = 18.0, bend = -0.14, lobes = 0, depth = 0.00, kind = "leaf",       t0 = 0.42, t1 = 0.82, seed = seed + 711 },
  }

  P.leaves = {}
  for _, s in ipairs(leaf_specs) do
    local x, y, tang, tier = anchor_on(s.bid, s.u, s.noff, 0)
    local deg = math.deg(tang) - 90 + s.deg_off
    P.leaves[#P.leaves + 1] = {
      x = x, y = y, deg = deg, len = s.len, bend = s.bend,
      lobes = s.lobes, depth = s.depth, kind = s.kind or "leaf",
      tier = tier, t0 = s.t0, t1 = s.t1, seed = s.seed,
    }
  end

  -- V-pairs of small leaflets along stems (like florilegium small-hole filler)
  local vpair_specs = {
    { bid = "f_up",  u = 0.28, len = 13.0, t0 = 0.34, t1 = 0.72, seed = seed + 751 },
    { bid = "f_up",  u = 0.74, len = 11.5, t0 = 0.50, t1 = 0.86, seed = seed + 752 },
    { bid = "f_tw1", u = 0.42, len = 11.0, t0 = 0.44, t1 = 0.80, seed = seed + 753 },
    { bid = "f_tw2", u = 0.80, len = 11.5, t0 = 0.48, t1 = 0.84, seed = seed + 754 },
    { bid = "f_dn",  u = 0.44, len = 12.0, t0 = 0.38, t1 = 0.76, seed = seed + 755 },
    { bid = "m_up",  u = 0.42, len = 11.5, t0 = 0.38, t1 = 0.76, seed = seed + 756 },
  }
  P.vpairs = {}
  for _, s in ipairs(vpair_specs) do
    local x, y, tang, tier = anchor_on(s.bid, s.u, 0, 0)
    P.vpairs[#P.vpairs + 1] = {
      x = x, y = y, deg = math.deg(tang) - 90, len = s.len,
      tier = tier, t0 = s.t0, t1 = s.t1, seed = s.seed,
    }
  end

  -- 4c. Multi-Scale Blossoms (3x scale range: Hero R = 26..30 bp,
  --     Medium R = 14..19 bp, Small R = 6..10 bp, Buds R = 4.5..6 bp, plus mixed Kiku Chrysanthemum!)
  local bloom_specs = {
    -- Tier 1 (Background Ghost Blooms — including 2 large Ghost Hero Blooms for deep atmosphere!)
    { bid = "g_up",  u = 0.52, noff = -6.0, aoff = 0, r = 24.0, kind = "open", da =  0.4, t0 = 0.32, t1 = 0.76, seed = seed + 401, hero = true },
    { bid = "g_tw1", u = 0.82, noff =  2.0, aoff = 0, r = 20.0, kind = "open", da = -0.3, t0 = 0.42, t1 = 0.82, seed = seed + 402, hero = true },
    { bid = "g_up",  u = 0.88, noff =  2.0, aoff = 0, r = 13.5, kind = "open", da =  0.2, t0 = 0.50, t1 = 0.86, seed = seed + 403 },
    { bid = "g_tw2", u = 0.90, noff = -2.0, aoff = 0, r = 10.5, kind = "side", da =  0.4, t0 = 0.54, t1 = 0.90, seed = seed + 404 },
    { bid = "g_dn",  u = 0.85, noff =  3.0, aoff = 0, r = 12.0, kind = "open", da =  0.5, t0 = 0.40, t1 = 0.78, seed = seed + 405 },

    -- Tier 2 (Mid-ground Blossoms & Buds)
    { bid = "m_up",  u = 0.86, noff =  3.0, aoff = 0, r = 18.5, kind = "open", da =  0.3, t0 = 0.48, t1 = 0.86, seed = seed + 501 },
    { bid = "m_tw1", u = 0.68, noff = -3.0, aoff = 0, r = 15.0, kind = "open", da =  0.4, t0 = 0.44, t1 = 0.82, seed = seed + 502 },
    { bid = "m_tw2", u = 0.84, noff =  2.5, aoff = 0, r = 12.5, kind = "half", da = -0.4, t0 = 0.52, t1 = 0.88, seed = seed + 503 },
    { bid = "m_dn",  u = 0.76, noff =  3.0, aoff = 0, r = 14.0, kind = "open", da =  0.5, t0 = 0.42, t1 = 0.80, seed = seed + 504 },
    { bid = "m_tw3", u = 0.90, noff = -2.0, aoff = 0, r =  8.5, kind = "side", da = -0.3, t0 = 0.48, t1 = 0.86, seed = seed + 505 },

    -- Tier 3 (Foreground Hero Blooms R = 26..29 bp + Medium R = 14..18 bp + Small R = 7..10 bp + Buds)
    -- HERO BLOOM 1 (Upper-left focal blossom, like florilegium p.3 / p.4 hero flower):
    { bid = "f_up",   u = 0.66, noff =  4.0, aoff = 0, r = 27.5, kind = "open", da =  0.2, t0 = 0.44, t1 = 0.86, seed = seed + 601, hero = true },
    -- HERO BLOOM 2 (Mid-lower focal blossom near origin fork):
    { bid = "f_up",   u = 0.22, noff = -4.0, aoff = 0, r = 24.5, kind = "open", da = -0.3, t0 = 0.28, t1 = 0.72, seed = seed + 602, hero = true },

    -- Medium Blossoms (R = 14..18.5 bp, including golden kiku chrysanthemum ray bloom!)
    { bid = "f_tw2",  u = 0.56, noff = -3.0, aoff = 0, r = 17.5, kind = "kiku", da =  0.4, t0 = 0.46, t1 = 0.86, seed = seed + 603 },
    { bid = "f_tw3",  u = 0.62, noff = -3.0, aoff = 0, r = 16.5, kind = "open", da = -0.4, t0 = 0.50, t1 = 0.88, seed = seed + 604 },
    { bid = "f_up",   u = 0.88, noff = -3.0, aoff = 0, r = 15.5, kind = "open", da =  0.3, t0 = 0.56, t1 = 0.92, seed = seed + 605 },
    { bid = "f_dn",   u = 0.38, noff =  4.0, aoff = 0, r = 16.0, kind = "kiku", da =  0.6, t0 = 0.36, t1 = 0.78, seed = seed + 606 },
    { bid = "f_tw6",  u = 0.64, noff = -2.5, aoff = 0, r = 14.5, kind = "open", da = -0.3, t0 = 0.50, t1 = 0.88, seed = seed + 607 },

    -- Small Blossoms, Side Cups & Buds (R = 4.5..10.5 bp)
    { bid = "f_tw1",  u = 0.98, noff = -1.0, aoff = 2, r =  9.2, kind = "side", da = -0.2, t0 = 0.54, t1 = 0.90, seed = seed + 608 },
    { bid = "f_sub1", u = 0.92, noff =  1.5, aoff = 2, r =  8.0, kind = "half", da =  0.3, t0 = 0.58, t1 = 0.92, seed = seed + 609 },
    { bid = "f_tw2",  u = 0.96, noff =  1.5, aoff = 2, r =  9.8, kind = "side", da =  0.2, t0 = 0.58, t1 = 0.92, seed = seed + 610 },
    { bid = "f_sub2", u = 0.92, noff = -1.5, aoff = 2, r =  5.0, kind = "bud",  da = -0.2, t0 = 0.62, t1 = 0.94, seed = seed + 611 },
    { bid = "f_tw3",  u = 0.88, noff =  2.5, aoff = 0, r = 10.2, kind = "open", da =  0.4, t0 = 0.56, t1 = 0.92, seed = seed + 612 },
    { bid = "f_tw3",  u = 0.98, noff = -1.0, aoff = 2, r =  4.8, kind = "bud",  da = -0.1, t0 = 0.62, t1 = 0.94, seed = seed + 613 },
    { bid = "f_tw4",  u = 0.90, noff = -2.0, aoff = 0, r =  8.8, kind = "half", da = -0.3, t0 = 0.60, t1 = 0.94, seed = seed + 614 },
    { bid = "f_up",   u = 0.99, noff =  1.0, aoff = 2, r =  5.2, kind = "bud",  da =  0.1, t0 = 0.64, t1 = 0.95, seed = seed + 615 },
    { bid = "f_tw5",  u = 0.72, noff =  2.5, aoff = 0, r = 10.2, kind = "open", da =  0.4, t0 = 0.46, t1 = 0.84, seed = seed + 616 },
    { bid = "f_tw6",  u = 0.96, noff =  1.5, aoff = 2, r =  8.2, kind = "side", da =  0.2, t0 = 0.58, t1 = 0.92, seed = seed + 617 },
    { bid = "f_sub3", u = 0.92, noff = -1.5, aoff = 2, r =  4.6, kind = "bud",  da = -0.2, t0 = 0.62, t1 = 0.95, seed = seed + 618 },
  }

  P.blooms = {}
  for _, s in ipairs(bloom_specs) do
    local x, y, tang, tier = anchor_on(s.bid, s.u, s.noff, s.aoff)
    P.blooms[#P.blooms + 1] = {
      x = x, y = y, r = s.r, kind = s.kind, a = tang + (s.da or 0),
      tier = tier, t0 = s.t0, t1 = s.t1, seed = s.seed, hero = s.hero,
    }
  end

  -- 4d. Perched Mejiro (Japanese white-eye) on the arching bough `f_tw1`
  do
    local bx, by, tx, ty = brush.at(by_id["f_tw1"].S, 0.66)
    P.bird = {
      cx     = bx,
      cy     = by,
      angle  = math.atan(ty, tx),
      w      = 2.4,
      size   = 26,
      facing = 1,
      t0     = 0.76,
      t1     = 0.94,
      seed   = seed + 880,
    }
  end

  -- 4e. Drifting Sakura Petals in the upper-right / mid-right breeze (t = 0.78..0.98)
  P.petals = {
    { x = 166, y = 196, deg =  38, sz = 7.2, t0 = 0.76, t1 = 0.94, seed = seed + 891 },
    { x = 184, y = 172, deg = -26, sz = 6.4, t0 = 0.80, t1 = 0.96, seed = seed + 892 },
    { x = 154, y = 144, deg =  52, sz = 6.8, t0 = 0.82, t1 = 0.98, seed = seed + 893 },
    { x = 192, y = 124, deg = -42, sz = 5.8, t0 = 0.84, t1 = 0.99, seed = seed + 894 },
  }

  PLAN_CACHE[seed] = P
  current_plan = P
  frame_counter = 0
  debug_lines = {}
  return P
end

------------------------------------------------------------------------
-- 5. Frame Renderer into a kacho-pdf Writer
------------------------------------------------------------------------
function M.render_frame(W, t, opts)
  opts = opts or {}
  local P = current_plan or M.plan(opts.seed or 7, opts.w_bp or 220, opts.h_bp or 280)
  local seed = P.seed
  local w_bp = P.W
  local h_bp = P.H
  local clk = Clock.new(t)
  local pal = palette.get("sumi")

  local ctx = {
    pdf     = W,
    rng     = rng.new(seed),
    palette = pal,
    brush   = brush,
    wash    = wash,
    region  = { x0 = 0, y0 = 0, x1 = w_bp, y1 = h_bp },
    safe    = { x0 = 8, y0 = 8, x1 = w_bp - 8, y1 = h_bp - 8 },
    exclude = {},
  }
  if opts.record then ctx.record = opts.record end

  -- 5a. Warm washi paper ground
  local paper_col = pal.color("washi")
  W:fill(W:rect(0, 0, w_bp, h_bp), paper_col, 1)

  -- 5b. Hiroshige Ukiyo-e Bokashi Sky Band & Dawn-Rose Horizon Glow (t = 0.00 -> 0.28)
  local mist_p = clk:smooth(0.00, 0.28)
  if mist_p > 0 then
    -- Top Prussian-blue (ai / gunjo) bokashi sky band fading softly into paper
    -- (28 overlapping CTM-invariant glaze bands from top edge y = h_bp downward)
    local sky_top = palette.mix(pal.color("ai"), pal.color("gunjo"), 0.45)
    local n_bands = 28
    local band_a  = (0.34 / n_bands) * mist_p
    for i = 1, n_bands do
      local f = (i / n_bands) ^ 1.15
      local y_bot = h_bp - 66 * f
      local col = palette.mix(sky_top, pal.color("asagi"), 0.35 * f)
      W:fill(W:rect(0, y_bot, w_bp, h_bp), col, band_a)
    end

    -- Soft dawn-rose & ochre atmospheric bokashi glow behind the middle garden
    ctx.rng = rng.new(seed + 11)
    local dawn_col = palette.mix(pal.color("sakura-pale"), pal.color("bokashi-sky-horizon"), 0.38)
    wash.glaze(ctx, 108, 136, 56, 64, {
      rgb   = dawn_col,
      alpha = 0.26 * mist_p,
      s_in  = 0.36,
      s_out = 1.0,
      rough = 0.20,
      n     = 8,
    })
  end

  -- 5c. Colour & Blossom Styles across the 3 Opacity Depth Tiers
  local branch_alpha = { [1] = 0.38, [2] = 0.68, [3] = 0.94 }
  local branch_col = {
    [1] = palette.mix(pal.color("sumi-light"), pal.color("ai"), 0.22),
    [2] = palette.mix(pal.color("kuri"), pal.color("sumi-mid"), 0.52),
    [3] = palette.mix(pal.color("kuri"), pal.color("sumi-dark"), 0.48),
  }

  local sty_tier = {}
  for tier = 1, 3 do
    local s = flora.blossom_colors(ctx, "sakura")
    if tier == 1 then
      -- Ghost layer: pale misty rose-ivory blossoms
      s.tone = { 0.80, 0.90 }
      s.bud_tone = { 0.74, 0.84 }
      s.pool = 0.07
      s.chroma = 0.58
      s.blush = false
      s.calyx = palette.mix(pal.color("sumi-light"), paper_col, 0.40)
      s.anther = palette.mix(pal.color("yamabuki"), paper_col, 0.55)
      s.anther2 = palette.mix(pal.color("ume-centre"), paper_col, 0.55)
      s.filament = palette.mix(pal.color("kigaki"), paper_col, 0.60)
    elseif tier == 2 then
      -- Mid-ground layer: soft blush sakura blossoms
      s.tone = { 0.66, 0.78 }
      s.bud_tone = { 0.60, 0.72 }
      s.pool = 0.14
      s.chroma = 0.88
      s.calyx = palette.mix(pal.color("kuri"), paper_col, 0.28)
    else
      -- Foreground layer: luminous sakura & koubai blossoms with warm golden stamens
      s.tone = { 0.56, 0.72 }
      s.bud_tone = { 0.52, 0.64 }
      s.pool = 0.22
      s.chroma = 1.08
    end
    sty_tier[tier] = s
  end

  local leaf_hue = {
    [2] = palette.mix(pal.color("matsuba"), pal.color("asagi"), 0.28),
    [3] = palette.mix(pal.color("matsuba"), pal.color("wakatake"), 0.42),
  }
  local wispy_hue = {
    [1] = palette.mix(pal.color("sakura-pale"), paper_col, 0.35),
    [2] = palette.mix(pal.color("momo"), paper_col, 0.25),
    [3] = pal.color("momo"),
  }

  -- 5d. Render Depth Tier by Depth Tier (1 = Background Ghost, 2 = Mid-ground, 3 = Foreground)
  for tier = 1, 3 do
    -- 1. Compound branch fill for this depth tier (seamless alpha at origin & forks)
    local tier_parts = {}
    local kasure_list = {}

    for _, b in ipairs(P.branches) do
      if b.tier == tier then
        local p = clk:smooth(b.t0, b.t1)
        if p > 0.02 then
          local sub = partial_segs(b.segs, p)
          if #sub > 0 then
            ctx.rng = rng.new(b.seed)
            local pf = power_taper_profile(b.w0, b.w1, p)
            local path, S, _, wfn = brush.outline_path(ctx, sub, {
              w        = b.w0,
              profile  = pf,
              cap      = true,
              jitter   = 0.035,
              pressure = 0.10,
              pfreq    = 2.6,
            })
            if path then
              tier_parts[#tier_parts + 1] = path
              if b.pS and S and #S >= 2 then
                local pwfn = function(u) return b.pw0 + (b.pw1 - b.pw0) * (u ^ 0.75) end
                local cr = brush.crotch(W, b.pS, b.pu, pwfn, S, wfn, 0.80)
                if cr then tier_parts[#tier_parts + 1] = cr end
              end
              if b.kasure and p > 0.18 then
                kasure_list[#kasure_list + 1] = { sub = sub, w0 = b.w0, pf = pf, seed = b.seed + 50, p = p }
              end
            end
          end
        end
      end
    end

    if #tier_parts > 0 then
      local compound = W:join(tier_parts)
      local tier_bb = W:fill(compound, branch_col[tier], branch_alpha[tier])
      for _, ks in ipairs(kasure_list) do
        ctx.rng = rng.new(ks.seed)
        brush.dry(ctx, ks.sub, {
          w        = ks.w0 * 0.86,
          profile  = ks.pf,
          rgb      = pal.color("sumi-dark"),
          alpha    = 0.26 * min(1, (ks.p - 0.18) / 0.35),
          dryness  = 0.46,
          bristles = 5,
          under    = 0.04,
        })
      end
      if ctx.record and tier_bb then ctx.record("branch_tier_" .. tier, tier_bb) end
    end

    -- 2. Wispy secondary flora in this tier (cymes, umbels, sprigs, tendrils)
    for _, ws in ipairs(P.wispy) do
      if ws.tier == tier then
        local k = clk:smooth(ws.t0, ws.t1)
        if k > 0.01 then
          local sc = 0.15 + 0.85 * k
          local wrng = rng.new(ws.seed)
          local wcol = branch_col[tier]
          local walp = branch_alpha[tier]
          local whue = wispy_hue[tier] or wispy_hue[3]
          local bb = scaled_organ(W, ws.x, ws.y, sc, function()
            if ws.kind == "cyme" then
              return paint_cyme(W, wrng, ws.x, ws.y, ws.deg, ws.len, ws.side, whue, wcol, walp)
            elseif ws.kind == "umbel" then
              return paint_umbel(W, wrng, ws.x, ws.y, ws.deg, ws.len, whue, leaf_hue[3], wcol, walp)
            elseif ws.kind == "sprig" then
              return paint_sprig(W, wrng, ws.x, ws.y, ws.deg, ws.len, whue, wcol, walp)
            elseif ws.kind == "tendril" then
              return paint_tendril(W, wrng, ws.x, ws.y, ws.deg, ws.len, ws.side, wcol, walp)
            end
          end)
          if ctx.record and bb then ctx.record("wispy_" .. ws.kind, bb) end
        end
      end
    end

    -- 3. Mixed multi-scale foliage (sculpted leaves, bamboo leaf fans, momiji maple leaves & V-pair leaflets)
    for _, lf in ipairs(P.leaves) do
      if lf.tier == tier then
        local k = clk:smooth(lf.t0, lf.t1)
        if k > 0.01 then
          local sc = 0.15 + 0.85 * k
          local lrng = rng.new(lf.seed)
          local bb = scaled_organ(W, lf.x, lf.y, sc, function()
            if lf.kind == "bamboo_fan" then
              ink.begin(W, leaf_hue[tier] or leaf_hue[3], { accent = pal.color("wakatake"), chroma = 0.96 })
              for _, ang_off in ipairs({ -38, -14, 14, 38 }) do
                ink.push()
                ink.translate(lf.x, lf.y)
                ink.rotate(lf.deg + ang_off + lrng.sym(3))
                ink.scale(lf.len * (1 - 0.12 * abs(ang_off) / 38))
                ink.leaflet(lrng, {
                  w     = 0.13,
                  bend  = (ang_off < 0 and -1 or 1) * 0.18,
                  tone  = tier == 2 and 0.50 or 0.36,
                  alpha = branch_alpha[tier],
                })
                ink.pop()
              end
              return ink.finish()
            elseif lf.kind == "maple" then
              ink.begin(W, pal.color("momiji"), { accent = pal.color("yamabuki"), chroma = 1.05 })
              ink.push()
              ink.translate(lf.x, lf.y)
              ink.rotate(lf.deg)
              ink.scale(lf.len)
              ink.maple_leaf(lrng, { lobes = 7, tone = 0.42, alpha = branch_alpha[tier] })
              ink.pop()
              return ink.finish()
            else
              ink.begin(W, leaf_hue[tier] or leaf_hue[3], {
                accent = pal.color("yamabuki"),
                chroma = tier == 2 and 0.82 or 1.06,
              })
              ink.detail = tier == 2 and 0.72 or 1.0
              ink.push()
              ink.translate(lf.x, lf.y)
              ink.rotate(lf.deg)
              ink.scale(lf.len)
              ink.leaf(lrng, {
                w     = 0.24,
                bend  = lf.bend,
                lobes = lf.lobes or 3,
                depth = lf.depth or 0.38,
                tone  = tier == 2 and 0.54 or 0.38,
              })
              ink.pop()
              return ink.finish()
            end
          end)
          if ctx.record and bb then ctx.record("leaf", bb) end
        end
      end
    end

    for _, vp in ipairs(P.vpairs) do
      if vp.tier == tier then
        local k = clk:smooth(vp.t0, vp.t1)
        if k > 0.01 then
          local sc = 0.15 + 0.85 * k
          local vrng = rng.new(vp.seed)
          local bb = scaled_organ(W, vp.x, vp.y, sc, function()
            ink.begin(W, leaf_hue[tier] or leaf_hue[3], { chroma = 0.92 })
            for _, side in ipairs({ -1, 1 }) do
              ink.push()
              ink.translate(vp.x, vp.y)
              ink.rotate(vp.deg + side * 38 + vrng.sym(5))
              ink.scale(vp.len * vrng.range(0.88, 1.08))
              ink.leaflet(vrng, {
                w     = 0.20,
                bend  = side * 0.16,
                tone  = tier == 2 and 0.52 or 0.36,
                alpha = branch_alpha[tier],
              })
              ink.pop()
            end
            return ink.finish()
          end)
          if ctx.record and bb then ctx.record("leaflet_pair", bb) end
        end
      end
    end

    -- 4. Multi-scale blossoms (Hero R = 24..28 bp, Medium R = 14..18 bp, Small R = 5..10 bp, plus Kiku ray blooms)
    local sty = sty_tier[tier]
    for _, bl in ipairs(P.blooms) do
      if bl.tier == tier then
        local k = clk:smooth(bl.t0, bl.t1)
        if k > 0.01 then
          local sc = 0.15 + 0.85 * k
          local bctx = {
            pdf     = W,
            rng     = rng.new(bl.seed),
            palette = pal,
            brush   = brush,
            wash    = wash,
            region  = ctx.region,
          }
          local it = { x = bl.x, y = bl.y, r = bl.r, kind = bl.kind, a = bl.a }
          local bb = scaled_organ(W, bl.x, bl.y, sc, function()
            if bl.kind == "bud" then
              return flora.ink_bud(bctx, it, sty)
            elseif bl.kind == "kiku" then
              local krng = rng.new(bl.seed)
              ink.begin(W, pal.color("yamabuki"), { accent = pal.color("shu"), chroma = 1.05 })
              ink.push()
              ink.translate(bl.x, bl.y)
              ink.rotate(bl.a * 180 / pi)
              ink.scale(bl.r)
              for ring = 1, 2 do
                local np = (ring == 1) and 14 or 10
                local rsc = (ring == 1) and 1.0 or 0.68
                for j = 1, np do
                  ink.push()
                  ink.rotate((j - 0.5 * ring) * (360 / np) + krng.sym(3))
                  ink.scale(rsc)
                  ink.leaflet(krng, { w = 0.16, bend = krng.sym(0.08), tone = (ring == 1) and 0.62 or 0.48, alpha = branch_alpha[tier] })
                  ink.pop()
                end
              end
              ink.circle(0, 0, 0.22)
              ink.fill(ink.accent(0.25), 0.94 * branch_alpha[tier])
              ink.pop()
              return ink.finish()
            else
              return flora.ink_blossom(bctx, it, sty, {
                notch      = bl.hero and 0.10 or 0.13,
                petals     = 5,
                pw         = bl.hero and 0.50 or 0.52,
                calyx_dots = (bl.kind == "open" and tier == 3),
                nstamens   = tier == 1 and 10 or (bl.hero and 22 or 16),
              })
            end
          end)
          if ctx.record and bb then ctx.record("blossom", bb) end
        end
      end
    end
  end

  -- 5e. Perched Mejiro (Japanese white-eye bird) on the foreground bough (t >= 0.76)
  if P.bird then
    local bk = clk:ease_out(P.bird.t0, P.bird.t1)
    if bk > 0.01 then
      local bsc = 0.20 + 0.80 * bk
      local bird_ctx = {
        pdf     = W,
        rng     = rng.new(P.bird.seed),
        palette = pal,
        brush   = brush,
        wash    = wash,
        region  = ctx.region,
        safe    = ctx.safe,
        exclude = {},
      }
      local bb = scaled_organ(W, P.bird.cx, P.bird.cy, bsc, function()
        return fauna.mejiro(bird_ctx, {
          layer  = W.cur,
          perch  = { cx = P.bird.cx, cy = P.bird.cy, angle = P.bird.angle, w = P.bird.w },
          size   = P.bird.size,
          facing = P.bird.facing,
        })
      end)
      if ctx.record and bb then ctx.record("bird", bb) end
    end
  end

  -- 5f. Drifting Sakura Petals in the breeze (t >= 0.76)
  for _, pt in ipairs(P.petals) do
    local pk = clk:ease_out(pt.t0, pt.t1)
    if pk > 0.01 then
      local psc = 0.20 + 0.80 * pk
      local prng = rng.new(pt.seed)
      local bb = scaled_organ(W, pt.x, pt.y, psc, function()
        ink.begin(W, pal.color("momo"), { chroma = 1.05 })
        ink.push()
        ink.translate(pt.x, pt.y)
        ink.rotate(pt.deg)
        ink.scale(pt.sz)
        ink.petal(prng, {
          tone  = 0.64,
          notch = 0.12,
          w     = 0.36,
          pool  = 0.18,
          blush = true,
        })
        ink.pop()
        return ink.finish()
      end)
      if ctx.record and bb then ctx.record("petal", bb) end
    end
  end

  -- 5g. Vermilion Hanko Seal in the lower-right negative space (t >= 0.88)
  if clk.t >= 0.88 then
    local seal_ctx = {
      pdf     = W,
      rng     = rng.new(seed + 900),
      palette = pal,
      brush   = brush,
      wash    = wash,
      region  = ctx.region,
    }
    if ctx.record then seal_ctx.record = ctx.record end
    seal.hanko(seal_ctx, {
      x      = 190,
      y      = 38,
      size   = 15,
      style  = "shubun",
      shape  = "square",
      glyphs = 1,
      ground = paper_col,
    })
  end
end

------------------------------------------------------------------------
-- 6. LuaTeX Entry Points (M.is_frames_mode, M.frame, M.put)
------------------------------------------------------------------------
function M.is_frames_mode()
  if os.getenv("KACHO_ANIM_FRAMES") == "1" then return true end
  if token and token.is_defined then
    if token.is_defined("kachoAnimFrames") or token.is_defined("framespages") then
      return true
    end
  end
  return false
end

function M.frame(t, opts)
  opts = opts or {}
  REG = REG or pdfw.registry(backend)
  local W = pdfw.new(REG)
  local P = current_plan or M.plan(7, 220, 280)

  frame_counter = frame_counter + 1
  local page_num = frame_counter
  local debug_on = os.getenv("KACHO_DEBUG") == "1"
  local recs = {}

  M.render_frame(W, t, {
    seed     = P.seed,
    w_bp     = P.W,
    h_bp     = P.H,
    clip_box = opts.clip_box,
    record   = debug_on and function(kind, bb)
      if bb then recs[#recs + 1] = { kind = kind, bb = bb } end
    end or nil,
  })

  if debug_on and opts.frames_mode then
    local tb = P.textblock or { 25, 314, 245, 329 }
    local bx0, by0 = P.box_x0 or 25, P.box_y0 or 28
    for _, r in ipairs(recs) do
      local b = r.bb
      local x0 = max(bx0, bx0 + b.x0)
      local y0 = max(by0, by0 + b.y0)
      local x1 = min(bx0 + P.W, bx0 + b.x1)
      local y1 = min(by0 + P.H, by0 + b.y1)
      if x1 > x0 and y1 > y0 then
        debug_lines[#debug_lines + 1] = fmt(
          "page=%d elem=%s bbox=%.2f %.2f %.2f %.2f textblock=%.2f %.2f %.2f %.2f",
          page_num, r.kind, x0, y0, x1, y1, tb[1], tb[2], tb[3], tb[4]
        )
      end
    end
    local job = (tex and tex.jobname) or "kacho-animated"
    local f = io.open(job .. ".kacho.log", "w")
    if f then
      f:write(table.concat(debug_lines, "\n") .. "\n")
      f:close()
    end
  end

  if W:is_empty() then return "" end
  local body = W:body()
  if opts.clip_box then
    body = fmt("q 0 0 %.3f %.3f re W n %s Q", P.W, P.H, body)
  end
  return body
end

function M.check_frames_env()
  if os.getenv("KACHO_ANIM_FRAMES") == "1" then
    tex.sprint("\\def\\framespages{1}")
  end
end

function M.emit_frames_pages(n_frames)
  n_frames = tonumber(n_frames) or 24
  for i = 0, n_frames - 1 do
    local t = fmt("%.6f", i / max(1, n_frames - 1))
    if i > 0 then tex.sprint("\\newpage") end
    tex.sprint(fmt("\\kachoAnimFramePage{%d}{%s}", i + 1, t))
  end
end

function M.put(t, opts)
  local s = M.frame(t, opts)
  if s ~= "" then
    local n = node.new("whatsit", "pdf_literal")
    n.mode = 0
    n.data = "q 1 J 1 j " .. s .. " Q"
    node.write(n)
  end
end

return M
