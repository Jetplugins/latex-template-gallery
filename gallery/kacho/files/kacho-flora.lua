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
-- kacho-flora.lua: plant motifs of the kacho package (M2).
--
-- Portions of the watercolour organ glazing pipeline (ink_blossom, ink_bud,
-- sakura leaves/petals, maple_leaf via kacho-ink.lua) are adapted from
-- florilegium (https://github.com/kevinraymond/florilegium):
-- Copyright (c) 2026 Kevin Raymond. MIT License:
--   Permission is hereby granted, free of charge, to any person obtaining a copy
--   of this software and associated documentation files (the "Software"), to deal
--   in the Software without restriction, including without limitation the rights
--   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--   copies of the Software, and to permit persons to whom the Software is
--   furnished to do so, subject to the following conditions:
--   The above copyright notice and this permission notice shall be included in all
--   copies or substantial portions of the Software.
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--   SOFTWARE.
--
-- ALGORITHMS & REFERENCES:
--   * ink_blossom, ink_bud, maple_leaf, sakura foliage: layered watercolour
--     glazes (mottling, granulation specks, edge pooling, lifted white veins
--     and streaks) via kacho-ink.lua, adapted from florilegium-flora.lua and
--     florilegium-ink.lua (Kevin Raymond 2026, MIT; after Curtis et al. 1997,
--     "Computer-Generated Watercolor", SIGGRAPH '97).
--   * grow_sc (trees of ume, sakura, maple, osmanthus, camellia): renders the
--     skeleton of kacho-growth (space colonization, Runions et al. 2007; pipe
--     model, Shinozaki et al. 1964; branching rules, Prusinkiewicz &
--     Lindenmayer 1990, "The Algorithmic Beauty of Plants").
--   * grow_tree / grow_one (legacy random-walk branches, spec.engine = "walk"),
--     place_clusters, prune, perches, draw_tree, blossom_open/side, bud,
--     bamboo, orchid, iris, wisteria, narcissus, pine, maple_shape: adapted
--     from the team's explorer prototypes (explorer_m2_1 kflora.lua,
--     explorer_m2_2 flora.lua), own work; kachō-e conventions from survey_2.
--   * fit_stroke (shrink / re-aim / drop growth limiting): inspired by Wong,
--     Zongker & Salesin 1998, "Computer-Generated Floral Ornament", SIGGRAPH.
--   * graded petals: native PDF radial / axial shadings (ISO 32000-1 §8.7.4.5).
--
-- Every motif is  M.<name>(ctx, spec) -> bbox, info  (tex/API.md section 3):
--   ctx  : drawing context from kacho.lua (pdf, rng, palette, brush, wash,
--          region, safe, exclude, record, density ...)
--   spec : { x, y (anchor / base point), angle (growth direction, radians),
--            size (overall extent in bp), density (0..1), variant, ... }
--   bbox : union of everything painted (nil when nothing fitted)
--   info : { perch = {{x,y,cx,cy,angle,w,t}, ...} (branch motifs), kinds = {...} }
--
-- Pure Lua (no TeX globals); randomness only from ctx.rng.
local M = {}

local B = require("kacho-brush")
local Wsh = require("kacho-wash")
local PAL = require("kacho-palette")

local sin, cos, pi, abs, max, min, sqrt, floor = math.sin, math.cos, math.pi, math.abs, math.max, math.min, math.sqrt, math.floor
local function atan2(y, x) return math.atan(y, x) end
local TAU = 2 * pi

---------------------------------------------------------------- utilities
local U = {}
M.util = U

function U.union(a, b)
  if not a then return b and { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 } end
  if not b then return a end
  return { x0 = min(a.x0, b.x0), y0 = min(a.y0, b.y0), x1 = max(a.x1, b.x1), y1 = max(a.y1, b.y1) }
end
local union = U.union

--- Log one drawn piece (if the context logs) and return its bbox.
function U.rec(ctx, kind, bb)
  if bb and ctx.record then ctx.record(kind, bb) end
  return bb
end

function U.bbox_pts(pts, pad)
  pad = pad or 0
  local b
  for _, p in ipairs(pts) do
    if not b then b = { x0 = p[1], y0 = p[2], x1 = p[1], y1 = p[2] }
    else
      if p[1] < b.x0 then b.x0 = p[1] end
      if p[1] > b.x1 then b.x1 = p[1] end
      if p[2] < b.y0 then b.y0 = p[2] end
      if p[2] > b.y1 then b.y1 = p[2] end
    end
  end
  if b and pad ~= 0 then b.x0, b.y0, b.x1, b.y1 = b.x0 - pad, b.y0 - pad, b.x1 + pad, b.y1 + pad end
  return b
end

--- Disc (x,y,r) clear of every exclusion rect.
function U.clear(ctx, x, y, r)
  for _, e in ipairs(ctx.exclude or {}) do
    if x + r > e.x0 and x - r < e.x1 and y + r > e.y0 and y - r < e.y1 then return false end
  end
  return true
end

--- Disc (x,y,r) inside ctx.region (and ctx.safe) and clear of exclusions.
--- ctx.eps (default 1.2 bp) covers anti-aliasing and edge wobble.
function U.free(ctx, x, y, r)
  r = (r or 0) + (ctx.eps or 1.2)
  local R, S = ctx.region, ctx.safe
  local x0, y0, x1, y1 = R.x0, R.y0, R.x1, R.y1
  if S then x0, y0, x1, y1 = max(x0, S.x0), max(y0, S.y0), min(x1, S.x1), min(y1, S.y1) end
  if x - r < x0 or x + r > x1 or y - r < y0 or y + r > y1 then return false end
  return U.clear(ctx, x, y, r)
end

--- Every point of a polygon free (inside region, clear of exclusions).
function U.free_pts(ctx, pts, r)
  for _, p in ipairs(pts) do if not U.free(ctx, p[1], p[2], r or 0) then return false end end
  return true
end

--- Rect inside the region/safe box and clear of exclusions.
function U.fits_rect(ctx, b)
  if not b then return false end
  local R, S = ctx.region, ctx.safe
  local e = 0.01
  if b.x0 < R.x0 - e or b.y0 < R.y0 - e or b.x1 > R.x1 + e or b.y1 > R.y1 + e then return false end
  if S and (b.x0 < S.x0 - e or b.y0 < S.y0 - e or b.x1 > S.x1 + e or b.y1 > S.y1 + e) then return false end
  for _, x in ipairs(ctx.exclude or {}) do
    if b.x0 < x.x1 and x.x0 < b.x1 and b.y0 < x.y1 and x.y0 < b.y1 then return false end
  end
  return true
end

function U.area2(pts)
  local a = 0
  for i = 1, #pts do local p, q = pts[i], pts[i % #pts + 1]; a = a + p[1] * q[2] - q[1] * p[2] end
  return a
end
function U.ccw(pts)
  if U.area2(pts) < 0 then
    local r = {}
    for i = #pts, 1, -1 do r[#r + 1] = pts[i] end
    return r
  end
  return pts
end
function U.rot(x, y, a) local c, s = cos(a), sin(a); return x * c - y * s, x * s + y * c end
function U.angdiff(a, b)
  local d = (a - b) % TAU
  if d > pi then d = d - TAU end
  return d
end
function U.clamp(v, a, b) return max(a, min(b, v)) end
function U.mix(c1, c2, t) return PAL.mix(c1, c2, t) end
function U.lerp(c1, c2, t) if type(c1) == "number" then return c1 + (c2 - c1) * t end; return { c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t } end
function U.hanga(ctx) return ctx.palette and ctx.palette.name == "hanga" end
function U.C(ctx, name) return ctx.palette.color(name) end
--- Colour actually under the art: ctx.paper_color if given; else the page
--- ground tint (option `ground`), or white paper when there is none; outside a
--- page context (unit tests) the palette's assumed paper.
function U.paper(ctx)
  if ctx.paper_color then return ctx.paper_color end
  local o = ctx.opts
  if o and o.ground ~= nil then
    local g = PAL.ground(o.ground)
    if g then return ctx.palette.color(g) end
    return { 1, 1, 1 }
  end
  return (ctx.palette and ctx.palette.paper) or { 0.953, 0.933, 0.863 }
end
local rot, angdiff, clamp, mix, lerp = U.rot, U.angdiff, U.clamp, U.mix, U.lerp

--- Shallow copy of ctx with spec.region (if any) as the allowed region.
function U.with_region(ctx, region)
  if not region then return ctx end
  local c = {}
  for k, v in pairs(ctx) do c[k] = v end
  c.region = region
  return c
end

--- Closed polygon approximating an ellipse (rx along angle a), with optional
--- radial wobble `rough` (organic edge) from rng.
function U.ellipse_pts(cx, cy, rx, ry, a, n, rough, rng)
  n = n or 20
  local out = {}
  local ph = rng and rng.range(0, TAU) or 0
  local ph2 = rng and rng.range(0, TAU) or 0
  for i = 0, n - 1 do
    local t = TAU * i / n
    local k = 1
    if rough and rough > 0 then k = 1 + rough * (0.6 * sin(2 * t + ph) + 0.4 * sin(3 * t + ph2)) end
    local x, y = rot(rx * k * cos(t), ry * k * sin(t), a or 0)
    out[#out + 1] = { cx + x, cy + y }
  end
  return out
end

--- Leaf / petal blade: outline of a variable-width stroke along a gently bent
--- cubic from (x,y) heading a, length L. prof(u) in 0..1 multiplies wmax.
--- Returns CCW points, the spine cubic and the sampled spine.
function U.blade(x, y, a, L, wmax, prof, bend, droop)
  bend, droop = bend or 0, droop or 0
  local dx, dy = cos(a), sin(a)
  local nx, ny = -dy, dx
  local seg = { { x, y },
    { x + dx * L * 0.33 + nx * bend * L, y + dy * L * 0.33 + ny * bend * L },
    { x + dx * L * 0.7 + nx * bend * L * 0.8, y + dy * L * 0.7 + ny * bend * L * 0.8 - droop * L * 0.4 },
    { x + dx * L, y + dy * L - droop * L } }
  local S = B.spine({ seg }, { step = max(0.6, L / 30) })
  local out = B.outline(S, function(u) return wmax * prof(u) end)
  return U.ccw(out), seg, S
end

U.prof = {
  lance = function(u) return sin(pi * u ^ 0.85) ^ 0.85 end,
  ovate = function(u) return sin(pi * u ^ 0.7) ^ 0.75 end,
  petiole = function(u) local s = min(1, u / 0.12); return s * s * sin(pi * u ^ 0.75) ^ 0.75 end,
  bamboo = function(u)
    local e = u < 0.06 and (0.35 + 0.65 * sin(pi / 2 * u / 0.06)) or 1
    return e * (u < 0.3 and 1 or ((1 - u) / 0.7) ^ 0.75)
  end,
  sword = function(u) return (0.72 + 0.28 * min(1, u / 0.05)) * (u < 0.62 and 1 or ((1 - u) / 0.38) ^ 0.85) end,
  strap = function(u) return min(1, u / 0.05) ^ 0.5 * (u < 0.8 and (1 - 0.15 * u) or 0.88 * ((1 - u) / 0.2) ^ 0.45) end,
  needle = function(u) return min(1, u / 0.1) ^ 0.5 * (1 - u) ^ 0.6 end,
  petal = function(u) return sin(pi * u ^ 0.8) ^ 0.7 end,
  leaflet = function(u) return sin(pi * u) ^ 0.75 * (1 - 0.25 * u) end,
  taper = function(u) return (1 - u) ^ 0.8 end,
}

--- Paint a closed polygon with a radial gradient (stops = {{t, rgb}, ...})
--- centred at (gx,gy) with radius gr, then an inner pooled rim (Multiply).
local function graded_fill(ctx, pts, gx, gy, gr, stops, rimc, rimw, rima)
  local W = ctx.pdf
  local path = W:poly(pts, true)
  if not path then return nil end
  local pat = W:radial(gx, gy, 0, max(0.5, gr), stops)
  local bb = W:fill_pattern(path, pat, 1)
  if rimc and rimw and rimw > 0 then
    W:clip(path)
    W:stroke(path, rimc, rimw, rima or 0.25, { blend = "multiply" })
    W:stroke(path, rimc, rimw * 0.4, (rima or 0.25) * 0.8, { blend = "multiply" })
    W:unclip()
  end
  return bb
end
U.graded_fill = graded_fill

local function axial_fill(ctx, pts, x0, y0, x1, y1, stops, rimc, rimw, rima)
  local W = ctx.pdf
  local path = W:poly(pts, true)
  if not path then return nil end
  local pat = W:axial(x0, y0, x1, y1, stops)
  local bb = W:fill_pattern(path, pat, 1)
  if rimc and rimw and rimw > 0 then
    W:clip(path)
    W:stroke(path, rimc, rimw, rima or 0.25, { blend = "multiply" })
    W:unclip()
  end
  return bb
end
U.axial_fill = axial_fill

---------------------------------------------------------------- branch engine
-- A branch is { nodes = {{x,y,w,s,a,knot}}, depth, L, parent, attach_s }.
-- Segments between nodes are straight; the painted silhouette is the union of
-- per-segment trapezoids and node discs, so eval_at() lies on the painted path.

local function densify(nodes, sub)
  local n = #nodes
  if n < 3 or sub <= 1 then return nodes end
  local out = {}
  local function at(i) return nodes[max(1, min(n, i))] end
  for i = 1, n - 1 do
    local p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
    for k = 0, sub - 1 do
      local t = k / sub
      local t2, t3 = t * t, t * t * t
      local function cr(a, b, c, d) return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3) end
      out[#out + 1] = { x = cr(p0.x, p1.x, p2.x, p3.x), y = cr(p0.y, p1.y, p2.y, p3.y), knot = (k == 0) and p1.knot or nil }
    end
  end
  out[#out + 1] = { x = nodes[n].x, y = nodes[n].y, knot = nodes[n].knot }
  return out
end

local function finalize(nodes, w0, wtip, pw)
  local s = 0
  nodes[1].s = 0
  for i = 2, #nodes do
    s = s + sqrt((nodes[i].x - nodes[i - 1].x) ^ 2 + (nodes[i].y - nodes[i - 1].y) ^ 2)
    nodes[i].s = s
  end
  local L = max(s, 1e-6)
  for i, nd in ipairs(nodes) do
    local j = min(#nodes, i + 1)
    local k = j == i and i - 1 or i
    nd.a = atan2(nodes[j].y - nodes[k].y, nodes[j].x - nodes[k].x)
    if w0 then nd.w = wtip + (w0 - wtip) * (1 - nd.s / L) ^ (pw or 0.9) end
  end
  return L
end

--- Point exactly on branch at arc length s: x, y, width, heading.
local function eval_at(br, s)
  local nd = br.nodes
  for i = 2, #nd do
    if nd[i].s >= s then
      local a, b = nd[i - 1], nd[i]
      local t = (s - a.s) / max(1e-9, b.s - a.s)
      return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.w + (b.w - a.w) * t, atan2(b.y - a.y, b.x - a.x)
    end
  end
  local z = nd[#nd]
  return z.x, z.y, z.w, z.a
end
M.eval_at = eval_at

local function seg_cross(a1x, a1y, a2x, a2y, b1x, b1y, b2x, b2y)
  local rx, ry, sx, sy = a2x - a1x, a2y - a1y, b2x - b1x, b2y - b1y
  local den = rx * sy - ry * sx
  if abs(den) < 1e-12 then return false end
  local t = ((b1x - a1x) * sy - (b1y - a1y) * sx) / den
  local u = ((b1x - a1x) * ry - (b1y - a1y) * rx) / den
  return t > 0 and t < 1 and u > 0 and u < 1
end
local function crosses(st, x0, y0, x1, y1, ox, oy, clear)
  for _, sg in ipairs(st.segs) do
    local near = (sg[1] - ox) ^ 2 + (sg[2] - oy) ^ 2 < clear * clear or (sg[3] - ox) ^ 2 + (sg[4] - oy) ^ 2 < clear * clear
    if not near and seg_cross(x0, y0, x1, y1, sg[1], sg[2], sg[3], sg[4]) then return true end
  end
  return false
end

-- grow one branch polyline with growth limiting (st = state of this motif)
local function grow_one(st, P, x, y, a, L, w0, depth, entering, target_a, wcap)
  local ctx, R = st.ctx, st.rng
  local nodes = { { x = x, y = y, knot = true } }
  local s, heading = 0, a
  local target = (target_a or a) + (P.droop or 0) * depth
  local sign = R.chance(0.5) and 1 or -1
  local cx, cy = st.attract[1], st.attract[2]
  local guard = 0
  local entered_at
  while s < L - 1e-6 and guard < 200 do
    guard = guard + 1
    local step = min(L - s, st.size * R.range(P.seg[1], P.seg[2]) * (depth == 0 and 1.25 or 1))
    if step < 0.25 * st.size * P.seg[1] and #nodes > 1 then break end
    if R.chance(P.alt or 0.8) then sign = -sign end
    local h = heading + sign * R.range(P.turn[1], P.turn[2])
    h = h - (P.bias or 0.3) * angdiff(h, target)
    local placed = false
    local tries = { 0, 0.35, -0.35, 0.7, -0.7, 1.1, -1.1 }
    for pass = 1, 2 do
      local mg = max(pass == 1 and (P.margin or 6) or (P.twig_margin or 3), 0.7 * w0 + 1)
      for _, dt in ipairs(tries) do
        local toc = angdiff(atan2(cy - y, cx - x), h)
        local hh = h + (toc >= 0 and dt or -dt)
        local nx, ny = x + step * cos(hh), y + step * sin(hh)
        local ok
        if entering then
          ok = U.clear(ctx, nx, ny, mg) and U.clear(ctx, (x + nx) / 2, (y + ny) / 2, mg)
        else
          ok = U.free(ctx, nx, ny, mg) and U.free(ctx, (x + nx) / 2, (y + ny) / 2, mg * 0.8)
            and not (P.nocross and crosses(st, x, y, nx, ny, nodes[1].x, nodes[1].y, 0.5 * w0 + 2))
        end
        if ok then x, y, heading, placed = nx, ny, hh, true; break end
      end
      if placed then break end
    end
    if not placed then break end
    local px, py = nodes[#nodes].x, nodes[#nodes].y
    nodes[#nodes + 1] = { x = x, y = y, knot = true }
    st.segs[#st.segs + 1] = { px, py, x, y }
    s = s + step
    if entering and U.free(ctx, x, y, max(P.twig_margin or 3, 0.7 * w0 + 1)) then entering = false; entered_at = #nodes end
  end
  if #nodes < 2 or entering then return nil end
  local br = { nodes = nodes, depth = depth, entered = entered_at }
  if P.smooth and P.smooth > 1 then br.nodes = densify(nodes, P.smooth) end
  br.L = finalize(br.nodes, w0, (P.wtip or 0.5) * clamp(st.size / 220, 0.7, 1.6), P.pw)
  local nz = R.noise(2)
  local amp = depth == 0 and (P.press or 0.22) or (P.press or 0.22) * 0.55
  local ph = R.range(0, 50)
  local fl = 0.14 * br.L
  for _, nd in ipairs(br.nodes) do
    nd.w = nd.w * max(0.65, 1 + amp * nz(nd.s / (0.12 * st.size) + ph))
    if depth > 0 and nd.s < fl then nd.w = nd.w * (1 + (P.collar or 0.4) * (1 - nd.s / fl) ^ 2) end
    if wcap then nd.w = min(nd.w, wcap) end
  end
  return br
end

--- Grow a whole tree: trunk from (spec.x, spec.y) along spec.angle, children
--- spawned exactly on their parent (start width <= 0.8x the parent's).
local function grow_tree(st, P, spec)
  local R = st.rng
  local tree = {}
  local size = st.size
  local entering = not U.free(st.ctx, spec.x, spec.y, 0)
  local trunk = grow_one(st, P, spec.x, spec.y, spec.angle or pi / 2, P.len[1] * size * (spec.reach or 1),
    P.w0 * size * (spec.width or 1), 0, entering)
  if not trunk then return tree end
  trunk.entering = entering
  tree[1] = trunk
  local queue, qi = { trunk }, 1
  while qi <= #queue do
    local par = queue[qi]
    qi = qi + 1
    local d = par.depth + 1
    if d < #P.len and #tree < (P.maxbranches or 40) then
      local nkids = floor(P.kids[d] * (0.7 + 0.6 * R.u()) * (0.5 + st.density) + 0.5)
      local side = R.chance(0.5) and 1 or -1
      local s_lo = par.entered and par.nodes[par.entered] and par.nodes[par.entered].s / par.L or 0
      for k = 1, nkids do
        local f = max(s_lo + 0.05, 0.15 + 0.77 * ((k - 0.5) / nkids) + R.sym(0.06))
        if f < 0.97 then
          local s = f * par.L
          local x, y, w, h = eval_at(par, s)
          side = -side
          local ca = h + side * R.range(P.child_angle[1], P.child_angle[2])
          -- some twigs droop (weight of the blossoms) and cross their neighbours
          if d >= 2 and R.chance(P.droop_p or 0.25) then ca = ca - 0.45 * angdiff(ca, -pi / 2) end
          local L = P.len[d + 1] * size * R.range(0.7, 1.2) * (1 - 0.45 * f)
          local w0 = min(P.w0 * size * (spec.width or 1) * (P.wdecay or 0.45) ^ d, 0.8 * w)
          local a0 = h + (P.flow or 0.4) * angdiff(ca, h)
          local br = grow_one(st, P, x, y, a0, L, w0, d, false, ca, 0.95 * w)
          if br and br.L > 0.3 * L then
            br.parent, br.attach_s = par, s
            -- ink depth: limbs go behind (-1, paler, under the trunk) or in front (+1)
            if d == 1 then br.z = R.chance(P.back_p or 0.4) and -1 or 1
            else br.z = par.z or 1 end
            tree[#tree + 1] = br
            queue[#queue + 1] = br
          end
        end
      end
    end
  end
  return tree
end

--- Grow a tree with the space-colonization engine (kacho-growth) and return
--- it in this module's branch format; limbs get an ink depth z (back / front).
local function grow_sc(st, spec, species)
  local GR = require("kacho-growth")
  local ctx = st.ctx
  local gctx = {}
  for k, v in pairs(ctx) do gctx[k] = v end
  gctx.__free = U.free
  local base_sp = GR.SPECIES[species]
  local sp = {}
  for k, v in pairs(base_sp) do sp[k] = v end
  if spec.species_override then
    for k, v in pairs(spec.species_override) do sp[k] = v end
  end
  local reg = ctx.region
  local rw = spec.band_w or (reg and (reg.x1 - reg.x0)) or st.size
  if rw < 150 or (spec.ground and species == "ume") then
    local max_base = rw < 150 and min(rw * 0.12, 11.0) or min(rw * 0.095, 16.0)
    if sp.w0 * st.size > max_base then
      sp.w0 = max_base / st.size
    end
    if rw < 150 then
      sp.wtip = min(sp.wtip or 0.5, 0.34)
      sp.taper = (sp.taper or 1.3) * 1.45
      sp.step = min(sp.step or 0.03, 0.024)
      sp.kill = min(sp.kill or 0.045, 0.035)
      sp.attractors = max(sp.attractors or 420, 560)
      sp.lateral_cap = max(sp.lateral_cap or 0.62, 0.78)
      sp.stub_p = 0
    end
  end
  local skel = GR.grow(gctx, { origins = spec.origins or { { x = spec.x, y = spec.y, angle = spec.angle or pi / 2 } }, size = st.size,
    density = st.density, species = sp, envelope = spec.envelope, attractors = spec.attractors, rng = st.rng })
  local tree = GR.to_branches(skel)
  local R = st.rng
  for _, br in ipairs(tree) do
    if br.depth == 1 then br.z = R.chance(spec.back_p or 0.38) and -1 or 1
    elseif br.depth > 1 then
      local p = br.parent
      while p and p.depth > 1 do p = p.parent end
      br.z = p and p.z or 1
    end
  end
  st.skeleton = skel
  return tree
end
M.grow_sc = grow_sc

local function use(br, s) if br then br.item_used = max(br.item_used or 0, s) end end

-- Every visible twig ends in something: remove empty twigs (depth >= mindepth),
-- cut the others at used + tail and re-taper (widths only decrease).
local function prune(st, tree, mindepth, tail)
  tail = tail or 0.03 * st.size
  for i = #tree, 1, -1 do
    local br = tree[i]
    local u = max(br.item_used or 0, br.child_used or 0)
    if br.depth >= mindepth then
      if u <= 0 then br.dead = (br.depth > 0)
      elseif u + tail < br.L then
        local s_cut = u + tail
        local out, nd = {}, br.nodes
        for k = 1, #nd do
          if nd[k].s < s_cut then out[#out + 1] = nd[k]
          else
            local a = nd[k - 1]
            local t = (s_cut - a.s) / max(1e-9, nd[k].s - a.s)
            out[#out + 1] = { x = a.x + (nd[k].x - a.x) * t, y = a.y + (nd[k].y - a.y) * t, s = s_cut,
              w = a.w + (nd[k].w - a.w) * t, a = a.a }
            break
          end
        end
        local _, _, wu = eval_at(br, u)
        local wt = min(wu, 0.45)
        for _, q in ipairs(out) do
          if q.s > u then q.w = min(q.w, wt + (wu - wt) * (1 - (q.s - u) / tail) ^ 0.7) end
        end
        br.nodes, br.L = out, s_cut
      end
    end
    if not br.dead and br.parent then br.parent.child_used = max(br.parent.child_used or 0, br.attach_s) end
  end
  local live = {}
  for _, br in ipairs(tree) do if not br.dead then live[#live + 1] = br end end
  return live
end

local function disc_pts(x, y, r, n)
  n = n or max(8, min(20, floor(r * 3)))
  local p = {}
  for i = 0, n - 1 do local a = TAU * i / n; p[#p + 1] = { x + r * cos(a), y + r * sin(a) } end
  return p
end
U.disc_pts = disc_pts

local function branch_parts(W, br, wscale)
  wscale = wscale or 1
  local parts, nd = {}, br.nodes
  for i = 1, #nd - 1 do
    local a, b = nd[i], nd[i + 1]
    local dx, dy = b.x - a.x, b.y - a.y
    local l = sqrt(dx * dx + dy * dy)
    if l > 1e-6 then
      local nx, ny = -dy / l, dx / l
      local ha, hb = a.w / 2 * wscale, b.w / 2 * wscale
      parts[#parts + 1] = W:poly(U.ccw({ { a.x + nx * ha, a.y + ny * ha }, { b.x + nx * hb, b.y + ny * hb },
        { b.x - nx * hb, b.y - ny * hb }, { a.x - nx * ha, a.y - ny * ha } }), true)
    end
  end
  for i = (br.depth == 0 and 2 or 1), #nd do
    local r = nd[i].w / 2 * (nd[i].knotr or 1) * wscale
    if r > 0.15 then parts[#parts + 1] = W:poly(disc_pts(nd[i].x, nd[i].y, r), true) end
  end
  return parts
end

local function branch_bbox(br, k)
  local b
  for _, nd in ipairs(br.nodes) do
    local r = nd.w / 2 * (nd.knotr or 1) * (k or 1) + 0.3
    b = union(b, { x0 = nd.x - r, y0 = nd.y - r, x1 = nd.x + r, y1 = nd.y + r })
  end
  return b
end

local function spine_from_nodes(nd)
  local pts = {}
  for i, n in ipairs(nd) do pts[i] = { n.x, n.y } end
  return B.chain(pts, 1)
end

--- Draw a tree in three ink-depth groups: back limbs (z = -1: paler, greyer,
--- under the trunk), the trunk, front limbs (z = +1: over the trunk), so
--- branches cross in front of and behind each other. In each group: thin
--- branches as one union fill, then thick limbs (start width > opt.drymin)
--- deepest first as an opaque body + dry-brush bristles (each limb covers the
--- base of what grows out of it). Records <name>-trunk / -branch / -twig.
local function draw_tree(st, tree, opt)
  local ctx = st.ctx
  local W = ctx.pdf
  local name = st.name
  local paper = U.paper(ctx)
  local groups = { {}, {}, {} }
  for _, br in ipairs(tree) do
    local z = br.depth == 0 and 0 or (br.z or 1)
    local g = groups[z + 2]
    g[#g + 1] = br
  end
  local bb
  for gi = 1, 3 do
    local z = gi - 2
    local back = z < 0
    local k = back and (opt.back_fade or 0.42) or 0
    local col = lerp(opt.col, paper, k)
    local body = lerp(opt.body, paper, k * 0.8)
    local drycol = lerp(opt.drycol or opt.col, paper, k)
    W:layer((opt.layer or 20) + (z < 0 and -3 or (z > 0 and 1 or 0)))
    local thin, thick = {}, {}
    for _, br in ipairs(groups[gi]) do
      if br.nodes[1].w > (opt.drymin or 5) then thick[#thick + 1] = br
      else for _, p in ipairs(branch_parts(W, br)) do thin[#thin + 1] = p end end
    end
    local branch_op = (opt.alpha or 0.94) * (back and 0.50 or (z == 0 and 0.82 or 0.98))
    if #thin > 0 then W:fill(W:join(thin), col, branch_op) end
    table.sort(thick, function(a, b) if a.depth ~= b.depth then return a.depth > b.depth end return a.L < b.L end)
    for _, br in ipairs(thick) do
      local function paint()
        W:fill(W:join(branch_parts(W, br)), body, back and 0.56 or (z == 0 and 0.88 or 1))
        local segs = spine_from_nodes(br.nodes)
        local L, w0 = br.L, br.nodes[1].w
        B.dry(ctx, segs, { w = w0, profile = function(u) local _, _, w = eval_at(br, u * L); return w / w0 end,
          rgb = drycol, alpha = (opt.dryalpha or 0.85) * (back and 0.48 or (z == 0 and 0.82 or 1)), dryness = opt.dryness or 0.45,
          bristles = opt.bristles or 8, under = opt.under or 0.12 })
      end
      local fade_to
      if br.depth == 0 and br.entering then
        fade_to = min(br.L * 0.3, (br.entered and br.nodes[br.entered] and br.nodes[br.entered].s or 0) + 0.12 * br.L)
      elseif br.depth == 0 and st.fade_base then
        fade_to = br.L * 0.2
      end
      if fade_to and W.fade_axial then
        -- the trunk enters from the edge of the picture: dissolve its base into the paper
        local n1 = br.nodes[1]
        local x1, y1 = eval_at(br, fade_to)
        local mb = branch_bbox(br, 1.6)
        mb = { x0 = mb.x0 - 4, y0 = mb.y0 - 4, x1 = mb.x1 + 4, y1 = mb.y1 + 4 }
        W:with_gs(W:fade_axial(n1.x, n1.y, x1, y1, 0, 1, mb), paint)
      else
        paint()
      end
    end
  end
  for _, br in ipairs(tree) do
    local kind = br.depth == 0 and (name .. "-trunk") or (br.depth == 1 and (name .. "-branch") or (name .. "-twig"))
    local b = branch_bbox(br, 1)
    U.rec(ctx, kind, b)
    bb = union(bb, b)
  end
  return bb
end

-- moss dots (tenko) and darker ink accents along the trunk / big limbs
local function bark_marks(st, tree, opt)
  local ctx, R = st.ctx, st.rng
  local W = ctx.pdf
  local dots = {}
  for _, br in ipairs(tree) do
    if br.depth <= 1 and br.nodes[1].w > 3 then
      local n = floor(br.L / (0.06 * st.size) * (opt.moss or 1))
      for _ = 1, n do
        local s = br.L * R.range(0.08, 0.85)
        local x, y, w, h = eval_at(br, s)
        local side = R.chance(0.5) and 1 or -1
        local off = side * w * R.range(0.38, 0.52)
        local dx, dy = x - sin(h) * off, y + cos(h) * off
        local rr = clamp(w * R.range(0.07, 0.13), 0.5, 2.0)
        dots[#dots + 1] = W:ellipse(dx, dy, rr, rr * R.range(0.55, 0.85), R.range(0, pi))
        if R.chance(0.5) then
          dots[#dots + 1] = W:ellipse(dx + R.sym(rr * 3), dy + R.sym(rr * 3), rr * 0.6, rr * 0.45, R.range(0, pi))
        end
      end
    end
  end
  if #dots > 0 then
    W:layer(23)
    W:fill(W:join(dots), opt.moss_col, 0.88)
  end
end

--- Perch candidates for birds on depth <= 1 branches: near-horizontal, wide
--- enough, with free space above. Returned points: (cx,cy) on the centre line,
--- (x,y) on top of the bark, angle (folded to +-90 deg), w (branch width),
--- t (arc fraction).
local function perches(st, tree, items, clear)
  local ctx = st.ctx
  clear = clear or 0.12 * st.size
  local out = {}
  for _, br in ipairs(tree) do
    if br.depth <= 2 then
      local L = br.L
      local n = max(3, floor(L / (0.024 * st.size)))
      for k = 1, n - 1 do
        local s = L * k / n
        local x, y, w, h = eval_at(br, s)
        local hn = angdiff(h, 0)
        if abs(hn) > pi / 2 then hn = angdiff(hn, pi) end
        if abs(hn) < math.rad(46) and w >= 1.2 and w <= 26 and U.free(ctx, x, y + clear * 0.55, clear * 0.85) then
          local near = 0
          for _, it in ipairs(items) do
            if (it.x - x) ^ 2 + (it.y - (y + clear * 0.65)) ^ 2 < (clear * 0.65 + it.r * 0.65) ^ 2 then
              near = near + 1
            end
          end
          local tx, ty = cos(hn), sin(hn)
          out[#out + 1] = { x = x - ty * w / 2, y = y + tx * w / 2, cx = x, cy = y, angle = hn, w = w,
            t = s / L, depth = br.depth, score = (1 - abs(hn)) + 0.35 * (1 - br.depth * 0.6) - 0.16 * near }
        end
      end
    end
  end
  table.sort(out, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.x < b.x end)
  return out
end

local function new_state(ctx, spec, name, P)
  local st = { ctx = ctx, rng = ctx.rng, name = name, size = spec.size or 260, segs = {},
    density = spec.density or ctx.density or 0.5, band_w = spec.band_w }
  local R = ctx.region
  st.attract = spec.attract or { (R.x0 + R.x1) / 2, (R.y0 + R.y1) / 2 }
  return st
end

---------------------------------------------------------------- blossoms
-- Colour sets for blossoms. c0 = centre, c1 = middle, c2 = petal edge.
local function blossom_colors(ctx, variant)
  local C = function(n) return ctx.palette.color(n) end
  local paper = U.paper(ctx)
  local gofun, pale, momo, beni = C("gofun"), C("sakura-pale"), C("momo"), C("beni")
  local s = {}
  if variant == "white" then
    s.c0 = mix(gofun, momo, 0.45); s.c1 = mix(gofun, pale, 0.55); s.c2 = gofun
    s.rim = mix(C("sumi-light"), momo, 0.35); s.rima = 0.32
    s.bud0 = mix(beni, C("sumi-dark"), 0.25); s.bud1 = mix(beni, momo, 0.35)
    s.calyx = mix(C("bengara"), C("sumi-dark"), 0.45)
  elseif variant == "red" then
    s.c0 = mix(beni, C("bengara"), 0.35); s.c1 = beni; s.c2 = mix(momo, beni, 0.25)
    s.rim = mix(beni, C("sumi-dark"), 0.35); s.rima = 0.3
    s.bud0 = mix(beni, C("sumi-dark"), 0.3); s.bud1 = beni
    s.calyx = mix(C("bengara"), C("sumi-dark"), 0.5)
  else -- pink
    s.c0 = mix(momo, beni, 0.55); s.c1 = mix(momo, pale, 0.35); s.c2 = mix(pale, gofun, 0.55)
    s.rim = mix(momo, beni, 0.4); s.rima = 0.28
    s.bud0 = mix(beni, C("bengara"), 0.15); s.bud1 = mix(momo, beni, 0.4)
    s.calyx = mix(C("bengara"), C("sumi-dark"), 0.4)
  end
  -- painterly (kacho-ink / florilegium) parameters: ramp hue, tone ranges, pooling
  if variant == "white" then
    s.hue = { 0.99, 0.97, 0.92 }
    s.tone, s.pool, s.bud_tone, s.chroma = { 0.80, 0.92 }, 0.16, { 0.56, 0.70 }, 0.32
    s.blush, s.blush_color, s.lift = true, { 0.92, 0.84, 0.76 }, 1.48
    s.throat = mix(C("moegi"), C("yamabuki"), 0.55)
  elseif variant == "red" then
    s.hue = { 0.86, 0.19, 0.35 }
    s.tone, s.pool, s.bud_tone, s.chroma = { 0.38, 0.54 }, 0.24, { 0.26, 0.38 }, 1.22
    s.blush, s.lift = true, 1.15
    s.throat = mix(beni, C("sumi-dark"), 0.22)
  elseif variant == "sakura" then
    s.hue = { 0.97, 0.68, 0.79 }
    s.tone, s.pool, s.bud_tone, s.chroma = { 0.70, 0.84 }, 0.18, { 0.44, 0.58 }, 1.12
    s.blush, s.blush_color, s.lift = true, { 0.90, 0.32, 0.48 }, 1.42
    s.throat = { 0.86, 0.26, 0.40 }
  else
    s.hue = { 0.93, 0.38, 0.55 }
    s.tone, s.pool, s.bud_tone, s.chroma = { 0.54, 0.70 }, 0.22, { 0.36, 0.50 }, 1.15
    s.blush, s.blush_color, s.lift = true, { 0.86, 0.22, 0.38 }, 1.25
    s.throat = mix(beni, C("bengara"), 0.18)
  end
  s.anther = C("yamabuki")
  s.eye = C("ume-centre")
  s.filament = variant == "red" and mix(gofun, pale, 0.4) or mix(C("kigaki"), C("sumi-mid"), 0.35)
  s.anther = C("yamabuki")
  s.anther2 = C("ume-centre")
  s.centre = mix(C("kigaki"), C("matsuba"), 0.25)
  s.paper = paper
  return s
end
M.blossom_colors = blossom_colors

-- map a point of the flower plane (local u,v, flower facing the viewer, then
-- squashed by sy and tilted) to the page
local function fplane(cx, cy, tilt, sy)
  return function(u, v)
    local x, y = u, v * sy
    x, y = rot(x, y, tilt)
    return cx + x, cy + y
  end
end

-- petal outline in the flower plane: rounded (ume) or notched (sakura) blade
-- from the centre outward at angle a, length pl, half width pw.
local function petal_shape(rng, a, pl, pw, notch, n)
  n = n or 18
  local pts = {}
  local wob = rng.range(0, TAU)
  for i = 0, n do
    local t = i / n                         -- 0..1 around one side, then mirrored
    local ang = pi * t                      -- 0 = tip, pi = base
    local r = 0.5 + 0.5 * cos(ang)          -- tip 1 -> base 0
    local u = pl * (0.12 + 0.88 * r ^ 0.9)
    local v = pw * sin(ang) ^ 0.9 * (0.65 + 0.35 * r)
    pts[#pts + 1] = { u, v }
  end
  local full = {}
  for i = #pts, 1, -1 do full[#full + 1] = { pts[i][1], -pts[i][2] } end
  for i = 2, #pts do full[#full + 1] = pts[i] end
  -- notch at the tip (sakura): pull the tip point inward
  if notch and notch > 0 then
    for _, p in ipairs(full) do
      if abs(p[2]) < pw * 0.18 and p[1] > pl * 0.8 then p[1] = p[1] - notch * pl * (1 - abs(p[2]) / (pw * 0.18)) end
    end
  end
  local out = {}
  local ca, sa = cos(a), sin(a)
  for _, p in ipairs(full) do
    local k = 1 + 0.04 * sin(3 * atan2(p[2], p[1]) + wob)
    out[#out + 1] = { (p[1] * ca - p[2] * sa) * k, (p[1] * sa + p[2] * ca) * k }
  end
  return out
end

-- stamens: filaments + anther dots radiating from (cx,cy)
local function stamens(ctx, cx, cy, r, n, lmin, lmax, dirfn, sty)
  local W, R = ctx.pdf, ctx.rng
  local lines, dots, dots2 = {}, {}, {}
  for k = 1, n do
    local ex, ey, sx, sy = dirfn(k, R.range(lmin, lmax) * r)
    lines[#lines + 1] = W:poly({ { sx, sy }, { ex, ey } }, false)
    local ar = max(0.32, r * R.range(0.045, 0.065))
    if R.chance(0.22) then dots2[#dots2 + 1] = W:circle(ex, ey, ar) else dots[#dots + 1] = W:circle(ex, ey, ar) end
  end
  local bb = W:stroke(W:join(lines), sty.filament, max(0.18, r * 0.022), 0.75)
  bb = union(bb, W:fill(W:join(dots), sty.anther, 0.95))
  bb = union(bb, W:fill(W:join(dots2), sty.anther2, 0.9))
  return bb
end

--- Open blossom seen from the front (5 petals). it = {x,y,r,a,tilt,sy}.
--- opt.notch > 0 gives notched (sakura) petals.
function M.blossom_open(ctx, it, sty, opt)
  opt = opt or {}
  local W, R = ctx.pdf, ctx.rng
  local x, y, r = it.x, it.y, it.r
  local sy = it.sy or R.range(0.82, 1)
  local tilt = it.tilt or R.range(0, TAU)
  local F = fplane(x, y, tilt, sy)
  local rot0 = R.range(0, TAU)
  local np = opt.petals or 5
  local stops = { { 0, sty.c0 }, { 0.28, sty.c1 }, { 0.78, sty.c2 }, { 1, sty.c2 } }
  local bb
  -- calyx tips peeking between the petals (ume, front view)
  if opt.calyx_dots then
    local cd = {}
    for k = 0, np - 1 do
      local a = rot0 + TAU * (k + 0.5) / np
      local px, py = F(cos(a) * r * 0.72, sin(a) * r * 0.72)
      cd[#cd + 1] = W:poly(U.ellipse_pts(px, py, r * 0.16, r * 0.1, a + tilt, 10), true)
    end
    W:fill(W:join(cd), sty.calyx, 0.9)
  end
  local order = {}
  for k = 0, np - 1 do order[#order + 1] = k end
  for _, k in ipairs(order) do
    local a = rot0 + TAU * k / np + R.sym(0.1)
    local pl = r * R.range(0.92, 1.06)
    local pw = r * (opt.pw or 0.52) * R.range(0.92, 1.08)
    local shp = petal_shape(R, a, pl, pw, opt.notch, 16)
    local pts = {}
    for i, p in ipairs(shp) do local px, py = F(p[1], p[2]); pts[i] = { px, py } end
    pts = U.ccw(pts)
    bb = union(bb, graded_fill(ctx, pts, x, y, r * 1.02, stops, sty.rim, max(0.5, r * 0.16), sty.rima))
  end
  -- centre and stamens
  local cpx, cpy = x, y
  W:fill(W:poly(U.ellipse_pts(cpx, cpy, r * 0.14, r * 0.14 * sy, tilt, 12), true), sty.centre, 0.85)
  local ns = opt.nstamens or R.int(12, 17)
  bb = union(bb, stamens(ctx, x, y, r, ns, opt.smin or 0.36, opt.smax or 0.62, function(k, l)
    local a = TAU * k / ns + R.sym(0.22)
    local ex, ey = F(cos(a) * l, sin(a) * l)
    local sx, sy2 = F(cos(a) * r * 0.1, sin(a) * r * 0.1)
    return ex, ey, sx, sy2
  end, sty))
  return bb
end

--- Side view / half-open blossom: a cup on a calyx, opening away from the twig
--- along it.a. half = true gives a tighter, half-open flower.
function M.blossom_side(ctx, it, sty, opt)
  opt = opt or {}
  local W, R = ctx.pdf, ctx.rng
  local x, y, r, ua = it.x, it.y, it.r, it.a or pi / 2
  local half = it.kind == "half"
  local ux, uy = cos(ua), sin(ua)
  local vx, vy = -uy, ux
  local function P(u, v) return x + ux * u + vx * v, y + uy * u + vy * v end
  -- the cup base sits at (x,y) - 0.25 r along the axis
  local base = -0.3 * r
  local spread = half and 0.2 or 0.36
  local stops = { { 0, sty.c0 }, { 0.35, sty.c1 }, { 1, sty.c2 } }
  local bx, by = P(base, 0)
  local tx, ty = P(r * 0.95, 0)
  local bb
  local function petal(cu, cv, ru, rv, ang)
    local pts = {}
    local n = 18
    local ph = R.range(0, TAU)
    for i = 0, n - 1 do
      local t = TAU * i / n
      local k = 1 + 0.05 * sin(3 * t + ph)
      local lu, lv = rot(ru * k * cos(t), rv * k * sin(t), ang)
      pts[#pts + 1] = { P(cu + lu, cv + lv) }
      pts[#pts] = { pts[#pts][1], pts[#pts][2] }
    end
    return U.ccw(pts)
  end
  -- back petal (seen from inside: paler), stamen tuft, side petals, front petal
  local back = petal(r * 0.42, 0, r * 0.42, r * (half and 0.34 or 0.44), 0)
  bb = union(bb, axial_fill(ctx, back, bx, by, tx, ty, { { 0, sty.c1 }, { 1, sty.c2 } }, sty.rim, max(0.4, r * 0.12), sty.rima))
  local ns = half and 4 or R.int(7, 10)
  bb = union(bb, stamens(ctx, x, y, r, ns, half and 0.45 or 0.6, half and 0.7 or 1.0, function(k, l)
    local a = ua + (k - (ns + 1) / 2) / ns * (half and 0.5 or 1.0) + R.sym(0.1)
    local sx, sy2 = P(-0.05 * r, 0)
    return sx + cos(a) * l, sy2 + sin(a) * l, sx, sy2
  end, sty))
  for _, sgn in ipairs({ -1, 1 }) do
    local pts = petal(r * 0.34, sgn * r * spread, r * 0.42, r * 0.3, sgn * (half and 0.35 or 0.6))
    bb = union(bb, axial_fill(ctx, pts, bx, by, tx, ty, stops, sty.rim, max(0.4, r * 0.12), sty.rima))
  end
  local front = petal(r * 0.26, R.sym(0.05 * r), r * 0.36, r * (half and 0.3 or 0.34), R.sym(0.15))
  bb = union(bb, axial_fill(ctx, front, bx, by, tx, ty, stops, sty.rim, max(0.4, r * 0.12), sty.rima))
  -- calyx: cup of sepals hugging the base
  local cal = {}
  for k = -1, 1 do
    local cu, cv = base + r * 0.08, k * r * 0.17
    cal[#cal + 1] = W:poly(U.ellipse_pts(select(1, P(cu, cv)), select(2, P(cu, cv)), r * 0.2, r * 0.13, ua + k * 0.5, 10), true)
  end
  bb = union(bb, W:fill(W:join(cal), sty.calyx, 0.95))
  return bb
end

--- Round bud with a dark calyx on the twig side (it.a points away from the twig).
function M.bud(ctx, it, sty)
  local W, R = ctx.pdf, ctx.rng
  local x, y, r, a = it.x, it.y, it.r, it.a or pi / 2
  local pts = U.ellipse_pts(x, y, r * 1.08, r * 0.95, a, 18, 0.03, R)
  local hx, hy = x + cos(a + 0.6) * r * 0.35, y + sin(a + 0.6) * r * 0.35
  local bb = graded_fill(ctx, U.ccw(pts), hx, hy, r * 1.5, { { 0, sty.bud1 }, { 0.6, sty.bud0 }, { 1, sty.bud0 } },
    sty.rim, max(0.3, r * 0.2), 0.2)
  -- sepals clasping the base
  local cal = {}
  for k = -1, 1 do
    local ca = a + pi + k * 0.75
    local cx, cy = x + cos(ca) * r * 0.72, y + sin(ca) * r * 0.72
    cal[#cal + 1] = W:poly(U.ellipse_pts(cx, cy, r * 0.42, r * 0.26, ca, 10), true)
  end
  bb = union(bb, W:fill(W:join(cal), sty.calyx, 0.95))
  -- tiny highlight (petal tips showing)
  W:fill(W:circle(hx, hy, r * 0.22), sty.c2, 0.35)
  return bb
end

-- painterly renderer (kacho-ink, florilegium glaze pipeline) ----------------
local INK = require("kacho-ink")

-- ink setup for a blossom style: hue of the tone ramp, depth alpha, and stamen colours
local function ink_style(ctx, sty)
  INK.begin(ctx.pdf, sty.hue or ctx.palette.color("momo"), { accent = sty.eye or ctx.palette.color("ume-centre"),
    chroma = sty.chroma, alpha = sty.alpha })
  INK.detail = (sty.alpha and sty.alpha < 0.55) and 0.45 or 1
end

--- Painted blossom (front, 3/4 tilted, or cupped side/half-open view) at it.x, it.y, radius it.r.
function M.ink_blossom(ctx, it, sty, opt)
  opt = opt or {}
  local R = ctx.rng
  ink_style(ctx, sty)
  local t = sty.tone or { 0.34, 0.50 }
  local t0 = R.range(t[1], t[2])
  if R.chance(0.22) then t0 = max(0.16, t[1] - R.range(0.04, 0.09))
  elseif R.chance(0.22) then t0 = min(0.78, t[2] + R.range(0.04, 0.08)) end
  local side = it.kind == "side" or it.kind == "half"
  INK.push()
  INK.translate(it.x, it.y)
  if side then
    local a = it.a or pi / 2
    INK.rotate(math.deg(a) - 90)
    INK.flower_side(R, it.r, { half = (it.kind == "half"), notch = opt.notch, tone = t0,
      w = opt.pw and opt.pw * 0.86 or 0.44, pool = sty.pool or 0.32, blush = sty.blush,
      blush_color = sty.blush_color, lift = sty.lift, sepal = sty.calyx,
      anther = sty.anther, anther2 = sty.anther2, filament = sty.filament, anther_r = 0.024 })
  else
    local sy = it.sy or (R.chance(0.42) and R.range(0.58, 0.82) or R.range(0.84, 1.0))
    INK.flower(R, it.r, { petals = opt.petals or 5, notch = opt.notch,
      sy = sy, tilt = R.range(0, 180), tone = t0,
      pool = sty.pool or 0.32, blush = sty.blush, blush_color = sty.blush_color,
      throat = sty.throat, calyx_dots = opt.calyx_dots, sepal = sty.calyx,
      lift = sty.lift, w = opt.pw and opt.pw * 0.86,
      stamens = opt.nstamens or R.int(16, 24), stamen_len = opt.stamen_len or 0.44,
      anther = sty.anther, anther2 = sty.anther2, filament = sty.filament, anther_r = 0.024 })
  end
  INK.pop()
  return INK.finish()
end

--- Painted round bud on its twig (it.a points away from the twig).
function M.ink_bud(ctx, it, sty)
  local R = ctx.rng
  ink_style(ctx, sty)
  local t = sty.bud_tone or { 0.24, 0.38 }
  INK.push()
  -- base sits toward the twig: back off along -a by 0.9 r
  local a = it.a or pi / 2
  INK.translate(it.x - cos(a) * it.r * 0.95, it.y - sin(a) * it.r * 0.95)
  INK.rotate(math.deg(a) - 90)
  INK.bud(R, it.r * 2.1, { tone = R.range(t[1], t[2]), w = 0.42, sepal = sty.calyx })
  INK.pop()
  return INK.finish()
end

local function draw_item(ctx, it, sty, opt)
  if not (opt and opt.vector) then
    if it.kind == "bud" then return M.ink_bud(ctx, it, sty) end
    return M.ink_blossom(ctx, it, sty, opt)
  end
  if it.kind == "bud" then return M.bud(ctx, it, sty) end
  if it.kind == "side" or it.kind == "half" then return M.blossom_side(ctx, it, sty, opt) end
  return M.blossom_open(ctx, it, sty, opt)
end

--- Place blossom clusters at twig nodes. Returns items (each with x,y,r,kind,
--- a = direction away from the twig, behind = drawn behind the twig).
--- P fields used: bloom_mindepth, site_p, cluster = {lo,hi}, tip_cluster,
--- kinds = {open, side, half, bud} weights, budr (bud radius / r).
local function place_clusters(st, tree, P, r, budget)
  local ctx, R = st.ctx, st.rng
  local items = {}
  local function ok_at(x, y, rr, cluster)
    if not U.free(ctx, x, y, rr * 1.14 + 0.8) then return false end
    for _, it in ipairs(items) do
      local f = (it.cluster == cluster) and 0.55 or 0.92
      if (it.x - x) ^ 2 + (it.y - y) ^ 2 < ((it.r + rr) * f) ^ 2 then return false end
    end
    return true
  end
  local wk = P.kinds or { open = 0.45, side = 0.15, half = 0.1, bud = 0.3 }
  local function pick_kind()
    local v = R.u() * (wk.open + wk.side + wk.half + wk.bud)
    if v < wk.open then return "open" end
    v = v - wk.open
    if v < wk.side then return "side" end
    v = v - wk.side
    if v < wk.half then return "half" end
    return "bud"
  end
  local ncl = 0
  local n_hero = 0
  local rw_reg = st.band_w or (ctx.region and (ctx.region.x1 - ctx.region.x0)) or st.size
  local hero_max = min(36, rw_reg * 0.28)
  local function cluster_at(br, s, n, tip)
    local x, y, w, h = eval_at(br, s)
    ncl = ncl + 1
    local placed = 0
    local side0 = R.chance(0.5) and 1 or -1
    for i = 1, n do
      if #items >= budget then break end
      local kind = (tip and i == 1 and R.chance(0.22)) and "bud" or pick_kind()
      local rr0
      if kind == "bud" then
        rr0 = r * (P.budr or 0.30) * R.range(0.82, 1.16)
      elseif not tip and i == 1 and kind == "open" and n_hero < 3 and br.depth <= 2 and R.chance(0.65) then
        -- Hero bloom tier (1.65x .. 2.20x base r)
        rr0 = min(hero_max, r * R.range(1.65, 2.20))
      elseif i == 1 or R.chance(0.48) then
        -- Medium blossom tier (0.95x .. 1.35x base r)
        rr0 = r * R.range(0.95, 1.35)
      else
        -- Small floret tier (0.55x .. 0.82x base r)
        rr0 = r * R.range(0.55, 0.82)
      end
      local sgn = (i % 2 == 0) and side0 or -side0
      local done = false
      for try = 1, 8 do
        local rr = (try > 4 and kind ~= "bud") and (rr0 * 0.84) or rr0
        -- direction away from the twig: mostly to one side, some forward
        local a = h + sgn * R.range(0.45, 1.6)
        if tip and R.chance(0.35) then a = h + R.sym(0.6) end
        local d
        if kind == "bud" then d = w / 2 + rr * 0.55
        elseif kind == "open" then d = R.range(0.12, 0.62) * rr + w * 0.25
        else d = w / 2 + rr * 0.25 end
        if try > 4 then d = d * 0.72 end
        -- slide along the twig, never past its tip
        local along = R.sym(0.6) * (kind == "bud" and rr * 1.5 or min(r, rr * 0.8))
        if tip then along = -abs(along) end
        along = clamp(along, -s, br.L - s)
        local px = x + cos(a) * d + cos(h) * along
        local py = y + sin(a) * d + sin(h) * along
        if ok_at(px, py, rr, ncl) then
          if rr >= r * 1.55 then n_hero = n_hero + 1 end
          local tier = (R.chance(0.24) and 1) or (R.chance(0.36) and 2) or 3
          items[#items + 1] = { x = px, y = py, r = rr, kind = kind, a = a, br = br, s = s, cluster = ncl,
            behind = (kind == "open" and R.chance(P.behind or 0.25)), tier = tier, ax = x, ay = y, aw = w }
          placed = placed + 1
          done = true
          break
        end
        sgn = -sgn
      end
      if not done and tip and placed == 0 then
        -- the twig tip never ends bare: try a small open blossom first, then a bud
        local ro = r * 0.74
        local ox, oy = x + cos(h) * ro * 0.35, y + sin(h) * ro * 0.35
        if ok_at(ox, oy, ro, ncl) then
          items[#items + 1] = { x = ox, y = oy, r = ro, kind = "open", a = h, br = br, s = s, cluster = ncl, tier = 3, ax = x, ay = y, aw = w }
          placed = 1
        else
          local rb = r * (P.budr or 0.3) * 0.85
          local px, py = x + cos(h) * rb * 0.6, y + sin(h) * rb * 0.6
          if U.free(ctx, px, py, rb * 1.18 + 0.8) then
            items[#items + 1] = { x = px, y = py, r = rb, kind = "bud", a = h, br = br, s = s, cluster = ncl, tier = 3, ax = x, ay = y, aw = w }
            placed = 1
          end
        end
      end
    end
    if placed > 0 then use(br, s) end
    return placed
  end
  local cl = P.cluster or { 2, 5 }
  -- tips first (every twig ends in a bud or a cluster)
  for _, br in ipairs(tree) do
    if br.depth >= (P.bloom_mindepth or 1) then
      cluster_at(br, br.L, R.int(2, P.tip_cluster or 3), true)
    end
  end
  -- then the nodes: irregular clusters with bare stretches between them
  for _, br in ipairs(tree) do
    if br.depth >= (P.bloom_mindepth or 1) or (P.bloom_trunk and br.depth == 0) then
      local last = -1e9
      local gap = r * (P.gap or 2.2)
      local s_min = (br.depth == 0) and (br.L * 0.16) or (br.L * 0.08)
      for _, nd in ipairs(br.nodes) do
        if nd.s > s_min and nd.s < br.L - r * 1.0 and nd.s - last > gap and (nd.knot or nd.s - last > gap * 1.35) then
          if R.chance((P.site_p or 0.6) * (0.55 + 0.9 * st.density)) then
            if cluster_at(br, nd.s, R.int(cl[1], cl[2]), false) > 0 then last = nd.s end
          end
        end
        if #items >= budget then break end
      end
    end
  end
  return items
end

local function bloom_budget(st, tree, r, k)
  local Lt = 0
  for _, br in ipairs(tree) do Lt = Lt + (br.depth >= 1 and br.L or 0.55 * br.L) end
  return max(8, floor((0.35 + st.density) * Lt / (2.0 * r) * (k or 1)))
end

-- draw blossom items in 3 opacity/depth tiers (ghost background, mid-ground, crisp foreground) and record them
local function draw_items(st, items, sty, opt, kindname)
  local ctx = st.ctx
  local W = ctx.pdf
  local bb
  -- buds first, then side views, then open flowers (hero open faces on top)
  local order = { bud = 1, half = 2, side = 3, open = 4 }
  table.sort(items, function(a, b)
    local ta, tb = a.tier or 3, b.tier or 3
    if ta ~= tb then return ta < tb end
    if order[a.kind] ~= order[b.kind] then return order[a.kind] < order[b.kind] end
    if a.r ~= b.r then return a.r < b.r end
    if a.y ~= b.y then return a.y > b.y end
    return a.x < b.x
  end)
  local paper = U.paper(ctx)
  local function fade_sty(k_fade, alpha_tier)
    local out = {}
    for k, v in pairs(sty) do
      out[k] = (type(v) == "table" and #v == 3 and type(v[1]) == "number") and lerp(v, paper, k_fade) or v
    end
    if sty.tone then
      out.tone = { min(0.92, sty.tone[1] + k_fade * 0.24), min(0.96, sty.tone[2] + k_fade * 0.24) }
    end
    out.alpha = alpha_tier
    return out
  end
  local sty_ghost = fade_sty(0.42, 0.38)
  local sty_mid   = fade_sty(0.18, 0.72)
  for _, it in ipairs(items) do
    local back = (it.br and it.br.z == -1) or (it.tier == 1)
    local mid  = (it.tier == 2) and not back
    local cur_sty = sty
    if back then
      W:layer(it.behind and 16.5 or 18)
      cur_sty = sty_ghost
    elseif mid then
      W:layer(it.behind and 20.5 or 28)
      cur_sty = sty_mid
    else
      W:layer(it.behind and 24 or 40)
      cur_sty = sty
    end
    local b = draw_item(ctx, it, cur_sty, opt)
    if b then
      U.rec(ctx, kindname .. (it.kind == "bud" and "-bud" or "-blossom"), b)
      bb = union(bb, b)
    end
  end
  return bb
end

---------------------------------------------------------------- WISPY SECONDARY BOTANICAL MOTIFS (ported from florilegium-flora.lua)
--- C^1 tangential cubic Bézier connecting stalk from a parent stem node to a secondary motif.
--- Supports both:
---   M.branch_path(p0, p1, a0, a1, rng)  (point/angle signature)
---   M.branch_path(rng, sx, sy, tx, ty, bx, by, ax, ay)  (florilegium 9-arg signature)
--- Returns polyline `pts` and cubic Bézier control points `bez`.
function M.branch_path(a1, a2, a3, a4, a5, a6, a7, a8, a9)
  local rng, sx, sy, tx, ty, bx, by, ax, ay
  if type(a1) == "table" and a1.range and type(a2) == "number" then
    -- 9-arg florilegium signature: (rng, sx, sy, tx, ty, bx, by, ax, ay)
    rng, sx, sy, tx, ty, bx, by, ax, ay = a1, a2, a3, a4, a5, a6, a7, a8, a9
  else
    -- 5-arg signature: (p0, p1, ang0, ang1, rng)
    local p0, p1, ang0, ang1 = a1, a2, a3 or 0, a4 or 0
    rng = a5
    sx = p0.x or p0[1]
    sy = p0.y or p0[2]
    bx = p1.x or p1[1]
    by = p1.y or p1[2]
    tx, ty = cos(ang0), sin(ang0)
    ax, ay = cos(ang1), sin(ang1)
  end
  local dx, dy = bx - sx, by - sy
  local d = sqrt(dx * dx + dy * dy)
  if d < 1e-3 then
    local pts = { { sx, sy }, { bx, by } }
    return pts, { { sx, sy }, { sx, sy }, { bx, by }, { bx, by } }
  end
  if tx * dx + ty * dy < 0 then tx, ty = -tx, -ty end
  local cross = tx * dy - ty * dx
  local side = (cross >= 0) and 1 or -1
  local dep = (rng and rng.range) and rng.range(0.48, 0.84) or 0.64 -- 28..48 deg
  local ca, sa = cos(side * dep), sin(side * dep)
  local lvx, lvy = tx * ca - ty * sa, tx * sa + ty * ca
  local c1x, c1y = sx + lvx * d * 0.42, sy + lvy * d * 0.42
  local c2x, c2y = bx - ax * d * 0.36, by - ay * d * 0.36
  local bez = { { sx, sy }, { c1x, c1y }, { c2x, c2y }, { bx, by } }
  local pts = {}
  local n = max(8, min(20, floor(d / 2.2) + 4))
  for i = 0, n do
    local px, py = B.bez(bez, i / n)
    pts[#pts + 1] = { px, py }
  end
  return pts, bez
end

--- Power-law tapered stem ribbon with tip-sharpening to < 0.35 bp hairline tips
--- (and optional bilateral dual-ended taper when tip == "both").
function M.stem_ribbon(ctx, pts, w0, w1, col, alpha, tip)
  if not pts or #pts < 2 then return nil end
  local W = ctx.pdf
  local segs = B.chain(pts, 1)
  local S = B.spine(segs, { step = 0.8 })
  w0 = w0 or 0.8
  w1 = w1 or 0.25
  local col_c = col or (U.hanga(ctx) and ctx.palette.color("kuri") or ctx.palette.color("sumi-dark"))
  local poly = B.outline(S, function(u)
    local w = lerp(w0, w1, u ^ 0.75)
    if tip ~= false and u > 0.72 then
      local s = (u - 0.72) / 0.28
      w = w * (1 - 0.58 * s * s)
    end
    if tip == "both" and u < 0.18 then
      local s = u / 0.18
      w = w * (0.22 + 0.78 * s ^ 0.65)
    end
    return max(0.18, w)
  end)
  return W:fill(W:poly(poly, true), col_c, alpha or 0.90)
end

-- Tiny glazed 5-petal floret or dot-bud used by cyme, umbel, and sprig
local function tiny_floret(ctx, x, y, r, a, sty, is_bud, alpha_mult)
  local W, R = ctx.pdf, ctx.rng
  local am = alpha_mult or 1
  local C = function(n) return ctx.palette.color(n) end
  local col_pet = (sty and sty.c1) or (U.hanga(ctx) and C("sakura-blush") or C("gofun"))
  local col_deep = (sty and sty.c0) or (U.hanga(ctx) and C("momo") or C("sumi-mid"))
  local col_cen = (sty and sty.anther) or C("yamabuki")
  local col_cal = (sty and sty.calyx) or (U.hanga(ctx) and C("matsuba") or C("sumi-dark"))
  if is_bud or r < 1.8 then
    local pts = U.ellipse_pts(x, y, r * 1.05, r * 0.72, a or pi / 2, 10, 0.04, R)
    local b = W:fill(W:poly(pts, true), col_deep, 0.90 * am)
    local cal = U.ellipse_pts(x - cos(a or 0) * r * 0.55, y - sin(a or 0) * r * 0.55, r * 0.55, r * 0.38, a or 0, 8)
    b = union(b, W:fill(W:poly(cal, true), col_cal, 0.88 * am))
    return b
  end
  local parts = {}
  local rot0 = R.range(0, TAU)
  for k = 0, 4 do
    local pa = rot0 + TAU * k / 5 + R.sym(0.08)
    local px, py = x + cos(pa) * r * 0.55, y + sin(pa) * r * 0.55
    parts[#parts + 1] = W:poly(U.ellipse_pts(px, py, r * 0.52, r * 0.36, pa, 10, 0.05, R), true)
  end
  local bb = W:fill(W:join(parts), col_pet, 0.92 * am)
  W:fill(W:circle(x, y, r * 0.26), col_deep, 0.85 * am)
  W:fill(W:circle(x, y, r * 0.14), col_cen, 0.95 * am)
  return bb
end

--- Scorpioid curling cyme (forget-me-not / cherry-spray / bugloss coil):
--- an arching axis that progressively curls into a tight spiral tip, bearing
--- alternating pedicelled florets opening from base to tip and tiny buds at the coil.
function M.cyme(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, y0 = spec.x or 100, spec.y or 100
  local a0 = spec.angle or pi / 2
  local s = spec.size or 28
  local side = spec.side or (R.chance(0.5) and 1 or -1)
  local alpha_m = spec.alpha or 1.0
  local stem_c = spec.stem_col or (U.hanga(ctx) and mix(ctx.palette.color("kuri"), ctx.palette.color("matsuba"), 0.45) or ctx.palette.color("sumi-mid"))
  W:layer(spec.layer or 32)
  local bb
  if spec.stalk_from then
    local spts = M.branch_path(spec.stalk_from, { x0, y0 }, spec.stalk_a0 or a0, a0, R)
    if U.free_pts(ctx, spts, 1.0) then
      bb = union(bb, M.stem_ribbon(ctx, spts, spec.w0 or 0.52, 0.32, stem_c, 0.88 * alpha_m, false))
    else
      return nil
    end
  end
  local function walk_coil(px, py, h0, L, turn, sgn, nsteps)
    local pts = { { px, py, h0 } }
    local dt = L / nsteps
    local x, y, h = px, py, h0
    for i = 1, nsteps do
      local t = i / nsteps
      h = h + sgn * turn * (t ^ 2.15) * (2.8 / nsteps) + R.sym(0.03)
      local nx, ny = x + cos(h) * dt, y + sin(h) * dt
      if not U.free(ctx, nx, ny, 2.5) then break end
      x, y = nx, ny
      pts[#pts + 1] = { x, y, h }
    end
    return pts
  end
  local main = walk_coil(x0, y0, a0, s * 1.15, R.range(2.2, 3.0), side, 18)
  if #main < 5 then return nil end
  bb = union(bb, M.stem_ribbon(ctx, main, 0.48, 0.22, stem_c, 0.90 * alpha_m, true))
  local arms = { { pts = main, sgn = side } }
  if #main >= 8 and R.chance(0.68) then
    local fi = R.int(4, min(7, #main - 2))
    local fp = main[fi]
    local sec = walk_coil(fp[1], fp[2], fp[3] - side * R.range(0.42, 0.68), s * 0.72, R.range(2.0, 2.7), -side, 12)
    if #sec >= 4 then
      bb = union(bb, M.stem_ribbon(ctx, sec, 0.38, 0.20, stem_c, 0.86 * alpha_m, true))
      arms[#arms + 1] = { pts = sec, sgn = -side }
    end
  end
  -- 1-2 small basal bract leaflets near the base of the cyme
  for k = 1, min(2, #main - 2) do
    local p = main[k + 1]
    local la = p[3] + (k % 2 == 0 and 1 or -1) * 1.05
    local ll = s * R.range(0.24, 0.34)
    local tipx, tipy = p[1] + cos(la) * ll, p[2] + sin(la) * ll
    if U.free(ctx, tipx, tipy, 1.5) then
      local lpoly = U.blade(p[1], p[2], la, ll, ll * 0.28, U.prof.lance, R.sym(0.08))
      bb = union(bb, W:fill(W:poly(lpoly, true), stem_c, 0.82 * alpha_m))
    end
  end
  -- Pedicelled florets along the outer convex side of each scorpioid coil
  for _, arm in ipairs(arms) do
    local pts, sgn = arm.pts, arm.sgn
    local n = #pts
    for i = 3, n, 2 do
      local f = (i - 2) / max(1, n - 2)
      local p = pts[i]
      local out_a = p[3] - sgn * (pi / 2) + R.sym(0.18)
      local ped = s * (0.16 * (1 - 0.62 * f))
      local fx, fy = p[1] + cos(out_a) * ped, p[2] + sin(out_a) * ped
      local fr = s * (0.115 * (1 - 0.52 * f))
      if U.free(ctx, fx, fy, fr + 1.0) then
        bb = union(bb, M.stem_ribbon(ctx, { { p[1], p[2] }, { fx, fy } }, 0.30, 0.18, stem_c, 0.82 * alpha_m, false))
        bb = union(bb, tiny_floret(ctx, fx, fy, fr, out_a, spec.sty, f > 0.68, alpha_m))
      end
    end
  end
  if bb then U.rec(ctx, spec.kind or "cyme", bb) end
  return bb
end

--- Delicate radiating umbel (yuki-yanagi snow-willow / kodemari / wild umbel):
--- 7..11 arched hairline rays from a hub with reflexed bracts, each ray ending
--- in a cluster of tiny starry/round florets.
function M.umbel(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, y0 = spec.x or 100, spec.y or 100
  local a0 = spec.angle or pi / 2
  local s = spec.size or 24
  local alpha_m = spec.alpha or 1.0
  local stem_c = spec.stem_col or (U.hanga(ctx) and mix(ctx.palette.color("kuri"), ctx.palette.color("matsuba"), 0.45) or ctx.palette.color("sumi-mid"))
  W:layer(spec.layer or 32)
  local bb
  if spec.stalk_from then
    local spts = M.branch_path(spec.stalk_from, { x0, y0 }, spec.stalk_a0 or a0, a0, R)
    if U.free_pts(ctx, spts, 1.0) then
      bb = union(bb, M.stem_ribbon(ctx, spts, spec.w0 or 0.50, 0.32, stem_c, 0.88 * alpha_m, false))
    else
      return nil
    end
  end
  -- Reflexed involucre bracts under the umbel hub
  for k = -2, 2 do
    if k ~= 0 then
      local ba = a0 + pi + k * 0.38 + R.sym(0.08)
      local bl = s * R.range(0.20, 0.28)
      if U.free(ctx, x0 + cos(ba) * bl, y0 + sin(ba) * bl, 1.2) then
        local bpoly = U.blade(x0, y0, ba, bl, bl * 0.24, U.prof.lance, 0)
        bb = union(bb, W:fill(W:poly(bpoly, true), stem_c, 0.80 * alpha_m))
      end
    end
  end
  local nrays = spec.rays or R.int(7, 10)
  local spread = R.range(1.15, 1.55)
  for i = 1, nrays do
    local u = (i - 1) / max(1, nrays - 1) * 2 - 1
    local ra = a0 + u * spread * 0.5 + R.sym(0.05)
    local rl = s * (0.58 + 0.36 * (1 - 0.52 * u * u)) * R.range(0.88, 1.08)
    local mx, my = x0 + cos(ra + u * 0.12) * rl * 0.52, y0 + sin(ra + u * 0.12) * rl * 0.52
    local ex, ey = x0 + cos(ra) * rl, y0 + sin(ra) * rl
    if U.free(ctx, ex, ey, s * 0.16 + 1.2) and U.free(ctx, mx, my, 1.5) then
      bb = union(bb, M.stem_ribbon(ctx, { { x0, y0 }, { mx, my }, { ex, ey } }, 0.36, 0.20, stem_c, 0.85 * alpha_m, false))
      -- Secondary umbellet of 3..4 tiny florets at ray tip
      local nf = R.int(3, 4)
      for j = 1, nf do
        local fa = ra + (j - (nf + 1) / 2) * 0.52 + R.sym(0.1)
        local pl = s * R.range(0.09, 0.15)
        local fx, fy = ex + cos(fa) * pl, ey + sin(fa) * pl
        local fr = s * R.range(0.075, 0.105)
        if U.free(ctx, fx, fy, fr + 0.8) then
          bb = union(bb, M.stem_ribbon(ctx, { { ex, ey }, { fx, fy } }, 0.24, 0.16, stem_c, 0.78 * alpha_m, false))
          bb = union(bb, tiny_floret(ctx, fx, fy, fr, fa, spec.sty, false, alpha_m))
        end
      end
    end
  end
  if bb then U.rec(ctx, spec.kind or "umbel", bb) end
  return bb
end

--- Recursive wiry forked spray (sprig) with tiny lancet leaflets at lower forks
--- and delicate florets/buds at the tips.
function M.sprig(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, y0 = spec.x or 100, spec.y or 100
  local a0 = spec.angle or pi / 2
  local s = spec.size or 26
  local alpha_m = spec.alpha or 1.0
  local stem_c = spec.stem_col or (U.hanga(ctx) and mix(ctx.palette.color("kuri"), ctx.palette.color("matsuba"), 0.45) or ctx.palette.color("sumi-mid"))
  W:layer(spec.layer or 31)
  local bb
  if spec.stalk_from then
    local spts = M.branch_path(spec.stalk_from, { x0, y0 }, spec.stalk_a0 or a0, a0, R)
    if U.free_pts(ctx, spts, 1.0) then
      bb = union(bb, M.stem_ribbon(ctx, spts, spec.w0 or 0.50, 0.32, stem_c, 0.88 * alpha_m, false))
    else
      return nil
    end
  end
  local function fork(x, y, a, len, w, depth)
    local bend = R.sym(0.16)
    local mx, my = x + cos(a + bend) * len * 0.52, y + sin(a + bend) * len * 0.52
    local ex, ey = x + cos(a) * len, y + sin(a) * len
    if not (U.free(ctx, mx, my, 1.5) and U.free(ctx, ex, ey, s * 0.14 + 1.0)) then return end
    bb = union(bb, M.stem_ribbon(ctx, { { x, y }, { mx, my }, { ex, ey } }, w, w * 0.62, stem_c, 0.88 * alpha_m, depth == 1))
    if depth > 1 then
      for _, sgn in ipairs({ -1, 1 }) do
        local la = a + sgn * R.range(0.68, 0.98)
        local ll = len * R.range(0.42, 0.58)
        if U.free(ctx, mx + cos(la) * ll, my + sin(la) * ll, 1.2) then
          local lpoly = U.blade(mx, my, la, ll, ll * 0.28, U.prof.lance, sgn * 0.08)
          bb = union(bb, W:fill(W:poly(lpoly, true), stem_c, 0.82 * alpha_m))
        end
      end
      local spread = R.range(0.36, 0.56)
      fork(ex, ey, a - spread + R.sym(0.06), len * R.range(0.64, 0.78), w * 0.68, depth - 1)
      fork(ex, ey, a + spread + R.sym(0.06), len * R.range(0.64, 0.78), w * 0.68, depth - 1)
    else
      local fr = s * R.range(0.095, 0.135)
      bb = union(bb, tiny_floret(ctx, ex, ey, fr, a, spec.sty, R.chance(0.28), alpha_m))
    end
  end
  fork(x0, y0, a0, s * 0.46, 0.46, spec.depth or 3)
  if bb then U.rec(ctx, spec.kind or "sprig", bb) end
  return bb
end

--- Clothoid / logarithmic curling tendril with optional tiny lancet leaflets
--- along the lead-in filament.
function M.tendril(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, y0 = spec.x or 100, spec.y or 100
  local a0 = spec.angle or pi / 2
  local s = spec.size or 22
  local side = spec.side or (R.chance(0.5) and 1 or -1)
  local alpha_m = spec.alpha or 1.0
  local col = spec.col or (U.hanga(ctx) and mix(ctx.palette.color("kuri"), ctx.palette.color("matsuba"), 0.5) or ctx.palette.color("sumi-mid"))
  W:layer(spec.layer or 33)
  local turns = spec.turns or R.range(1.55, 2.25)
  local lead = s * R.range(0.45, 0.70)
  local cx = x0 + cos(a0) * lead - sin(a0) * side * s * 0.38
  local cy = y0 + sin(a0) * lead + cos(a0) * side * s * 0.38
  local a_start = atan2(y0 + sin(a0) * lead - cy, x0 + cos(a0) * lead - cx)
  local pts = { { x0, y0 }, { x0 + cos(a0 + side * 0.12) * lead * 0.5, y0 + sin(a0 + side * 0.12) * lead * 0.5 } }
  local n = 34
  for i = 0, n do
    local t = i / n
    local a = a_start + side * turns * TAU * (t ^ 1.15)
    local rad = s * 0.38 * (1 - 0.90 * t) ^ 1.55
    local px, py = cx + cos(a) * rad, cy + sin(a) * rad
    if not U.free(ctx, px, py, 1.2) then break end
    pts[#pts + 1] = { px, py }
  end
  if #pts < 8 then return nil end
  local bb = M.stem_ribbon(ctx, pts, spec.w0 or 0.44, 0.18, col, 0.88 * alpha_m, true)
  if spec.leaflets ~= false and R.chance(0.65) then
    local mx, my = pts[2][1], pts[2][2]
    local la = a0 - side * 0.85
    local ll = s * 0.26
    if U.free(ctx, mx + cos(la) * ll, my + sin(la) * ll, 1.2) then
      local lpoly = U.blade(mx, my, la, ll, ll * 0.26, U.prof.lance, -side * 0.08)
      bb = union(bb, W:fill(W:poly(lpoly, true), col, 0.82 * alpha_m))
    end
  end
  if bb then U.rec(ctx, spec.kind or "tendril", bb) end
  return bb
end

--- V-pair of graceful curving veined leaves at a stem node.
function M.leaf_pair(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, y0 = spec.x or 100, spec.y or 100
  local a0 = spec.angle or pi / 2
  local L0 = spec.size or R.range(18, 30)
  local alpha_m = spec.alpha or 1.0
  local hanga = U.hanga(ctx)
  local lcol = spec.col or (hanga and ctx.palette.color("wakatake") or mix(ctx.palette.color("koke"), ctx.palette.color("sumi-mid"), 0.35))
  W:layer(spec.layer or 29)
  local bb
  for _, sgn in ipairs({ -1, 1 }) do
    local la = a0 + sgn * R.range(0.42, 0.78) + R.sym(0.08)
    local L = L0 * (sgn < 0 and 1.0 or R.range(0.76, 0.94))
    local ex, ey = x0 + cos(la) * L, y0 + sin(la) * L
    local mx, my = x0 + cos(la) * L * 0.5, y0 + sin(la) * L * 0.5
    if U.free(ctx, ex, ey, 3.0) and U.free(ctx, mx, my, L * 0.44) then
      INK.begin(W, lcol, { chroma = hanga and 1.12 or 0.28 })
      INK.detail = 1
      INK.push()
      INK.translate(x0, y0)
      INK.rotate(math.deg(la) - 90)
      INK.scale(L)
      INK.leaf(R, { depth = 0, w = R.range(0.24, 0.32), bend = sgn * R.range(0.10, 0.22), tone = R.range(0.38, 0.56), alpha = 0.92 * alpha_m })
      INK.pop()
      bb = union(bb, INK.finish())
    end
  end
  if bb then U.rec(ctx, spec.kind or "leaf-pair", bb) end
  return bb
end

--- Hairline C^1 stalk carrying a glazed INK.bud with clasping sepals.
function M.stalked_bud(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local x0, y0 = spec.x or 100, spec.y or 100
  local a0 = spec.angle or pi / 2
  local s = spec.size or 16
  local r_bud = spec.r or max(3.2, s * 0.28)
  local bx, by = x0 + cos(a0) * s, y0 + sin(a0) * s
  if not (U.free(ctx, bx, by, r_bud * 1.75 + 1.0) and U.free(ctx, (x0 + bx) / 2, (y0 + by) / 2, 2.2)) then return nil end
  W:layer(spec.layer or 34)
  local stem_c = spec.stem_col or (U.hanga(ctx) and ctx.palette.color("kuri") or ctx.palette.color("sumi-mid"))
  local spts = M.branch_path({ x0, y0 }, { bx, by }, spec.stalk_a0 or a0, a0, R)
  local bb = M.stem_ribbon(ctx, spts, 0.46, 0.28, stem_c, 0.88, false)
  local sty = spec.sty or blossom_colors(ctx, "pink")
  local b_bud = M.ink_bud(ctx, { x = bx + cos(a0) * r_bud * 0.45, y = by + sin(a0) * r_bud * 0.45, r = r_bud, a = a0 }, sty)
  bb = union(bb, b_bud)
  if bb then U.rec(ctx, spec.kind or "stalked-bud", bb) end
  return bb
end

--- Attach 10..15 wispy secondary botanical sprays (cymes, umbels, sprigs,
--- curling tendrils, graceful veined leaf pairs, and stalked buds) along a
--- tree's branches across 3 opacity depth tiers.
function M.add_wispy_sprays(st, tree, sty, opt)
  opt = opt or {}
  local ctx, R = st.ctx, st.rng
  local size = st.size or 260
  local rw = ctx.region and (ctx.region.x1 - ctx.region.x0) or size
  local s_base = clamp(min(size * 0.11, rw * 0.14), 14, 30)
  local target_n = opt.count or R.int(10, 14)
  local placed = 0
  local bb
  -- Collect candidate attachment sites along depth >= 0 branches
  local sites = {}
  for _, br in ipairs(tree) do
    if br.L > 18 then
      local n_s = max(2, min(5, floor(br.L / 38)))
      for k = 1, n_s do
        local s = br.L * (0.18 + 0.74 * (k - 0.5) / n_s)
        local x, y, w, h = eval_at(br, s)
        sites[#sites + 1] = { x = x, y = y, w = w, h = h, depth = br.depth, z = br.z or 1 }
      end
    end
  end
  -- Shuffle sites deterministically with ctx.rng
  for i = #sites, 2, -1 do
    local j = R.int(1, i)
    sites[i], sites[j] = sites[j], sites[i]
  end
  for idx, site in ipairs(sites) do
    if placed >= target_n then break end
    local sgn = (idx % 2 == 0) and 1 or -1
    local da = sgn * R.range(0.52, 1.05)
    local a_out = site.h + da
    local tier = (site.z < 0 or idx % 3 == 1) and 1 or ((idx % 3 == 2) and 2 or 3)
    local layer = (tier == 1) and 17 or ((tier == 2) and 25 or 35)
    local alpha_m = (tier == 1) and 0.42 or ((tier == 2) and 0.72 or 0.96)
    local reach = s_base * R.range(0.45, 0.78)
    local tx, ty = site.x + cos(a_out) * reach, site.y + sin(a_out) * reach
    local b
    local pick = idx % 6
    if pick == 0 then
      b = M.cyme(ctx, {
        stalk_from = { site.x, site.y }, stalk_a0 = site.h,
        x = tx, y = ty, angle = a_out, side = sgn,
        size = s_base * R.range(0.78, 1.08), sty = sty, layer = layer, alpha = alpha_m,
        kind = st.name .. "-cyme",
      })
    elseif pick == 1 then
      b = M.umbel(ctx, {
        stalk_from = { site.x, site.y }, stalk_a0 = site.h,
        x = tx, y = ty, angle = a_out,
        size = s_base * R.range(0.72, 0.98), sty = sty, layer = layer, alpha = alpha_m,
        kind = st.name .. "-umbel",
      })
    elseif pick == 2 then
      b = M.sprig(ctx, {
        stalk_from = { site.x, site.y }, stalk_a0 = site.h,
        x = tx, y = ty, angle = a_out,
        size = s_base * R.range(0.75, 1.05), sty = sty, layer = layer, alpha = alpha_m,
        kind = st.name .. "-sprig",
      })
    elseif pick == 3 then
      b = M.tendril(ctx, {
        x = site.x, y = site.y, angle = a_out, side = sgn,
        size = s_base * R.range(0.70, 0.96), layer = layer, alpha = alpha_m,
        kind = st.name .. "-tendril",
      })
    elseif pick == 4 then
      b = M.leaf_pair(ctx, {
        x = site.x, y = site.y, angle = a_out,
        size = clamp(s_base * R.range(0.82, 1.18), 18, 32), layer = layer, alpha = alpha_m,
        kind = st.name .. "-leaf",
      })
    else
      b = M.stalked_bud(ctx, {
        x = site.x, y = site.y, stalk_a0 = site.h, angle = a_out,
        size = s_base * R.range(0.55, 0.78), r = s_base * 0.22, sty = sty, layer = layer,
        kind = st.name .. "-bud",
      })
    end
    if b then
      bb = union(bb, b)
      placed = placed + 1
    end
  end
  return bb
end

---------------------------------------------------------------- ground / basal anchor (NO grass mounds!)
--- Basal botanical anchor at (x, y): replaces legacy oval grass mounds with a
--- florilegium-style bilateral basal leaf cluster + curling root tendril + tenko
--- moss dots (or a Kanga-e faceted rock shelf when opt.rock is true).
function M.earth(ctx, x, y, hw, name, opt)
  opt = opt or {}
  local R = ctx.rng
  local W = ctx.pdf
  local bb
  local s = clamp(hw * 0.55, 14, 28)
  -- Bilateral curving veined basal leaves + curling root tendril
  local b_lp = M.leaf_pair(ctx, {
    x = x, y = y + 2, angle = pi / 2 + R.sym(0.15),
    size = clamp(s * 0.85, 16, 28), layer = opt.layer or 26,
    kind = (name or "flora") .. "-leaf",
  })
  bb = union(bb, b_lp)
  for _, sgn in ipairs({ -1, 1 }) do
    local b_t = M.tendril(ctx, {
      x = x, y = y + 2, angle = pi / 2 + sgn * R.range(1.15, 1.65),
      side = -sgn, size = clamp(s * 0.72, 12, 22), layer = opt.layer or 25,
      kind = (name or "flora") .. "-tendril",
    })
    bb = union(bb, b_t)
  end
  -- 2-3 subtle tenko moss dots at the root junction
  local dots = {}
  for _ = 1, 3 do
    local dx, dy = x + R.sym(s * 0.35), y + R.range(0.5, 3.5)
    local r = R.range(0.8, 1.5)
    if U.free(ctx, dx, dy, r + 1.5) then
      dots[#dots + 1] = W:ellipse(dx, dy, r, r * 0.7, R.range(0, pi))
      bb = union(bb, { x0 = dx - r - 1, y0 = dy - r - 1, x1 = dx + r + 1, y1 = dy + r + 1 })
    end
  end
  if #dots > 0 then
    W:layer(opt.layer or 26)
    W:fill(W:join(dots), U.hanga(ctx) and ctx.palette.color("matsuba") or ctx.palette.color("sumi-noir"), 0.82)
  end
  if bb then U.rec(ctx, (name or "flora") .. "-earth", bb) end
  return bb
end

---------------------------------------------------------------- UME (plum)
M.UME = {
  len = { 0.95, 0.55, 0.3, 0.14 }, kids = { 5, 4, 3 },
  seg = { 0.07, 0.15 }, turn = { 0.25, 0.65 }, alt = 0.8, bias = 0.35,
  child_angle = { 0.45, 1.0 }, w0 = 0.05, wdecay = 0.42, wtip = 0.5, pw = 0.8,
  margin = 9, droop = 0, maxbranches = 48, flow = 0.55, press = 0.28, collar = 0.4, droop_p = 0.3,
  bloom_trunk = true, site_p = 0.92, cluster = { 3, 5 }, tip_cluster = 4, budr = 0.24, gap = 1.35, behind = 0.25,
  kinds = { open = 0.54, side = 0.18, half = 0.1, bud = 0.18 },
}

local function branch_colors(ctx, kind)
  local C = function(n) return ctx.palette.color(n) end
  local paper = U.paper(ctx)
  if U.hanga(ctx) then
    local tw = mix(C("kuri"), C("sumi-dark"), kind == "sakura" and 0.35 or 0.5)
    return { col = tw, body = mix(paper, C("kuri"), 0.72), drycol = C("sumi-dark"), dryalpha = 0.75,
      moss = C("matsuba"), halo = nil }
  end
  return { col = C("sumi-dark"), body = mix(paper, C("sumi-mid"), 0.8), drycol = C("sumi-noir"), dryalpha = 0.85,
    moss = C("sumi-noir"), halo = C("sumi-light") }
end

--- Bilateral origin sprouting & smooth dual-ended taper (florilegium architecture):
--- Never draws a green grass mound under a tree! Instead, sprouts a sibling
--- counter-bough / basal root-scroll in the opposite direction from the origin
--- node and tapers free trunk bases smoothly to a fine point so there is never
--- an abrupt flat geometric cut.
local function tree_base(st, tree, spec)
  local ctx, R = st.ctx, st.rng
  local name = st.name
  local bb
  st.fade_base = spec.fade_base
  if tree[1] and not tree[1].entering then
    local tr = tree[1]
    local n1 = tr.nodes[1]
    local w_orig = n1.w
    -- (1) Smooth calligraphic taper at the trunk origin (iri-fude / dual-ended taper)
    local s_tap = min(tr.L * 0.14, 26)
    for _, nd in ipairs(tr.nodes) do
      if nd.s < s_tap then
        local u = nd.s / max(1e-6, s_tap)
        nd.w = nd.w * (0.22 + 0.78 * sin(pi * 0.5 * u) ^ 0.42)
      end
    end
    -- (2) Smooth 24-sample C^1 S-curved cubic Bezier secondary basal bough in same bark color (z = 0)
    local s_fork = min(tr.L * 0.07, 12)
    local fx, fy, fw, fa = eval_at(tr, s_fork)
    local w_b0 = min(4.2, max(2.2, fw * 0.44))
    for _, sgn in ipairs(R.chance(0.5) and { 1, -1 } or { -1, 1 }) do
      local dep = sgn * R.range(0.48, 0.76)
      local L_b = clamp(st.size * R.range(0.17, 0.24), 54, 88)
      local a1 = fa + dep
      local a2 = fa + dep * 1.35
      local a3 = fa + dep * 0.75
      local bez = {
        { fx, fy },
        { fx + cos(a1) * L_b * 0.34, fy + sin(a1) * L_b * 0.34 },
        { fx + cos(a2) * L_b * 0.68, fy + sin(a2) * L_b * 0.68 },
        { fx + cos(a3) * L_b,        fy + sin(a3) * L_b },
      }
      local nodes, ok = {}, true
      local n_samp = 24
      local s_acc = 0
      for i = 0, n_samp do
        local t = i / n_samp
        local px, py = B.bez(bez, t)
        local wi = max(0.30, w_b0 * (1 - t) ^ 0.78)
        if i >= 1 and not U.free(ctx, px, py, wi * 0.5 + 2.5) then ok = false; break end
        if i > 0 then
          local prev = nodes[i]
          s_acc = s_acc + sqrt((px - prev.x) ^ 2 + (py - prev.y) ^ 2)
        end
        nodes[i + 1] = { x = px, y = py, w = wi, s = s_acc, a = a3 }
      end
      if ok and s_acc >= 38 then
        local br_sec = { nodes = nodes, L = s_acc, depth = 1, z = 0, parent = tr, attach_s = s_fork, item_used = s_acc }
        tree[#tree + 1] = br_sec
        local tip = nodes[#nodes]
        local mid = nodes[floor(n_samp * 0.62)]
        bb = union(bb, M.sprig(ctx, {
          x = mid.x, y = mid.y, angle = a2 + sgn * 0.42,
          size = clamp(st.size * 0.065, 16, 24), layer = 31, kind = name .. "-sprig",
        }))
        bb = union(bb, M.tendril(ctx, {
          x = tip.x, y = tip.y, angle = a3, side = sgn,
          size = clamp(st.size * 0.065, 14, 22), layer = 33, kind = name .. "-tendril",
        }))
        break
      end
    end
  end
  return bb
end


-- shared spray driver for blossoming trees (ume, sakura)
local function blossom_tree(ctx, spec, name, P, r, sty, bopt, extra)
  local st = new_state(ctx, spec, name, P)
  local tree = (spec.engine == "walk") and grow_tree(st, P, spec) or grow_sc(st, spec, name)
  if #tree == 0 then return nil, { perch = {} } end
  local items = place_clusters(st, tree, P, r, bloom_budget(st, tree, r, spec.bloom_k or 1))
  if extra and extra.spurs then extra.spurs(st, tree, items) end
  tree = prune(st, tree, P.prune_depth or 2)
  -- knots on zig-zag nodes of the trunk and limbs
  for _, br in ipairs(tree) do
    for i = 2, #br.nodes - 1 do if br.nodes[i].knot and st.rng.chance(0.3) then br.nodes[i].knotr = st.rng.range(1.0, 1.08) end end
  end
  local bc = branch_colors(ctx, name)
  local bb
  bb = union(bb, tree_base(st, tree, spec))
  bb = union(bb, draw_tree(st, tree, { col = bc.col, body = bc.body, drycol = bc.drycol, dryalpha = bc.dryalpha,
    drymin = 4.5, halo = bc.halo, halo_alpha = 0.1, dryness = 0.5 }))
  bark_marks(st, tree, { moss_col = bc.moss, moss = spec.moss or 1 })
  -- Wispy secondary sprays (cymes, umbels, sprigs, tendrils, veined leaves, stalked buds)
  bb = union(bb, M.add_wispy_sprays(st, tree, sty, { count = spec.wispy_count }))
  if extra and extra.after_tree then bb = union(bb, extra.after_tree(st, tree, items)) end
  bb = union(bb, draw_items(st, items, sty, bopt, name))
  if extra and extra.after_items then bb = union(bb, extra.after_items(st, tree, items)) end
  local info = { perch = perches(st, tree, items, spec.perch_clear), tree = tree, items = items,
    kinds = { name .. "-trunk", name .. "-branch", name .. "-twig", name .. "-blossom", name .. "-bud",
              name .. "-cyme", name .. "-umbel", name .. "-sprig", name .. "-tendril", name .. "-leaf" } }
  return bb, info
end

--- Ume (plum): zig-zag gnarled twigs with clusters of round 5-petal blossoms
--- and round buds at the nodes, short spurs ending in buds, wispy secondary
--- sprays, moss dots.
function M.ume(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local variant = spec.variant or (U.hanga(ctx) and (R.chance(0.25) and "red" or "pink") or (R.chance(0.6) and "white" or "pink"))
  local size = spec.size or 260
  local rw = spec.band_w or (ctx.region and (ctx.region.x1 - ctx.region.x0)) or size
  local rmax = (rw < 150) and min(13.5, rw * 0.145) or 14.5
  local r = clamp((spec.bloom or 0.042) * size, 6.5, rmax) * (spec.organ_scale or 1)
  spec.bloom_k = spec.bloom_k or ((rw < 150) and 1.65 or 1.25)
  local sty = blossom_colors(ctx, variant)
  local P = M.UME
  local bopt = { calyx_dots = (variant == "white"), pw = 0.55 }
  return blossom_tree(ctx, spec, "ume", P, r, sty, bopt, {
    spurs = function(st, tree, items)
      -- short spurs along the limbs, each ending in a blossom/bud cluster
      local nsp = {}
      for _, br in ipairs(tree) do
        if br.depth >= 1 or (rw < 150 and br.depth == 0) then
          local s = (br.depth == 0) and (br.L * 0.22) or (br.L * 0.15)
          local step_max = min(size * 0.075, 26)
          while s < br.L * 0.88 do
            if R.chance(0.38) then
              local x, y, w, h = eval_at(br, s)
              local a = h + (R.chance(0.5) and 1 or -1) * R.range(0.75, 1.35)
              local l = min(size * R.range(0.025, 0.045), rw * 0.16)
              local ex, ey = x + l * cos(a), y + l * sin(a)
              local is_open = R.chance(0.58)
              local rb = is_open and (r * R.range(0.74, 0.92)) or (r * P.budr * R.range(0.88, 1.12))
              local bx, by = ex + cos(a) * rb * 0.45, ey + sin(a) * rb * 0.45
              local ok = U.free(ctx, bx, by, rb * 1.16 + 0.8) and U.free(ctx, ex, ey, 2.0)
              for _, it in ipairs(items) do
                if ok and (it.x - bx) ^ 2 + (it.y - by) ^ 2 < ((it.r + rb) * 0.78) ^ 2 then ok = false end
              end
              if ok then
                local sw = min(w * 0.65, 1.45)
                local sp = { nodes = { { x = x, y = y, w = sw }, { x = ex, y = ey, w = 0.52 } }, depth = br.depth + 1,
                  parent = br, attach_s = s }
                sp.L = finalize(sp.nodes)
                sp.item_used = sp.L
                nsp[#nsp + 1] = sp
                items[#items + 1] = { x = bx, y = by, r = rb, kind = is_open and (R.chance(0.75) and "open" or "side") or "bud",
                  a = a, br = sp, s = sp.L, cluster = -1, tier = 3, ax = ex, ay = ey, aw = 0.52 }
                if is_open and R.chance(0.65) then
                  local rbud = r * P.budr * 0.9
                  local ab = a + (R.chance(0.5) and 1 or -1) * 1.1
                  local mx, my = x + (ex - x) * 0.55, y + (ey - y) * 0.55
                  local bx2, by2 = mx + cos(ab) * (rbud * 0.85), my + sin(ab) * (rbud * 0.85)
                  if U.free(ctx, bx2, by2, rbud * 1.2 + 0.8) then
                    items[#items + 1] = { x = bx2, y = by2, r = rbud, kind = "bud", a = ab, br = sp, s = sp.L * 0.55, cluster = -1, tier = 2, ax = mx, ay = my, aw = 0.65 }
                  end
                end
              end
            end
            s = s + step_max * R.range(0.55, 1.0)
          end
        end
      end
      for _, sp in ipairs(nsp) do tree[#tree + 1] = sp end
    end,
  })
end

---------------------------------------------------------------- SAKURA (cherry)
M.SAKURA = {
  len = { 0.95, 0.5, 0.26 }, kids = { 4, 3 }, seg = { 0.06, 0.12 }, turn = { 0.04, 0.22 }, alt = 0.6,
  bias = 0.35, droop = -0.18, child_angle = { 0.4, 0.85 }, w0 = 0.04, wdecay = 0.45, wtip = 0.6, pw = 0.9,
  margin = 12, smooth = 3, maxbranches = 22, flow = 0.3, press = 0.2, prune_depth = 0,
}

-- one umbel (pom-pom cluster) of cherry flowers on pedicels from a twig node,
-- with young bronze-green leaves at its base and 3x multi-scale hierarchy
local function sakura_umbel(st, br, s, R0, items, ncl, n, is_hero_site)
  local ctx, R = st.ctx, st.rng
  local x, y, w, h = eval_at(br, s)
  local res = { flowers = {}, peds = {}, leaves = {}, x = x, y = y, w = w, h = h }
  local base = h + (R.chance(0.5) and 1 or -1) * R.range(0.4, 1.2)
  base = base - 0.35 * angdiff(base, -pi / 2) * R.u()        -- clusters hang a little
  local rw_reg = st.band_w or (ctx.region and (ctx.region.x1 - ctx.region.x0)) or st.size
  local hero_cap = min(32, rw_reg * 0.26)
  for i = 1, n do
    local a = base + (i - (n + 1) / 2) * R.range(0.42, 0.7) + R.sym(0.2)
    local isbud = (i > 1) and R.chance(0.24)
    local rr
    if isbud then
      rr = R0 * R.range(0.32, 0.46)
    elseif is_hero_site and i == 1 then
      rr = min(hero_cap, R0 * R.range(1.62, 2.10))
    elseif i <= 2 then
      rr = R0 * R.range(0.95, 1.32)
    else
      rr = R0 * R.range(0.58, 0.84)
    end
    local done = false
    for _, lk in ipairs({ 1, 0.8, 0.62 }) do
      local l = max(R0, rr * 0.75) * R.range(0.85, 1.45) * lk
      local fx, fy = x + cos(a) * l, y + sin(a) * l
      local ok = U.free(ctx, fx, fy, rr * 1.14 + 0.8)
      if ok then
        for _, it in ipairs(items) do
          local f = it.cluster == ncl and 0.6 or 0.92
          if (it.x - fx) ^ 2 + (it.y - fy) ^ 2 < ((it.r + rr) * f) ^ 2 then ok = false; break end
        end
      end
      if ok then
        local tier = (R.chance(0.25) and 1) or (R.chance(0.35) and 2) or 3
        local it = { x = fx, y = fy, r = rr, kind = isbud and "bud" or (R.chance(0.2) and "side" or "open"),
          a = a, cluster = ncl, br = br, s = s, tier = tier, ped = { x, y, fx, fy, R.chance(0.5) and 1 or -1 } }
        if it.kind == "open" then it.sy = R.chance(0.35) and R.range(0.55, 0.78) or R.range(0.86, 1) end
        items[#items + 1] = it
        res.flowers[#res.flowers + 1] = it
        done = true
        break
      end
    end
    if not done and i == 1 then break end
  end
  if #res.flowers > 0 then
    -- 2-3 full, graceful curving veined leaves from the node (18..34 bp)
    for _ = 1, R.int(2, 3) do
      local a = base + R.sym(1.4)
      local L = clamp(R0 * R.range(1.75, 2.65), 18, 34)
      local ex, ey = x + cos(a) * L, y + sin(a) * L
      if U.free(ctx, ex, ey, 3.0) and U.free(ctx, x + cos(a) * L * 0.5, y + sin(a) * L * 0.5, L * 0.44) then
        res.leaves[#res.leaves + 1] = { x = x, y = y, a = a, L = L }
      end
    end
  end
  return res
end

--- Sakura (cherry): smooth drooping limbs with lenticel bands, pom-pom umbels
--- of notched pink blossoms on pedicels (3x scale range), wispy cymes/umbels/tendrils,
--- full veined bronze-green leaves, and drifting petals.
function M.sakura(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local size = spec.size or 260
  local rw = spec.band_w or (ctx.region and (ctx.region.x1 - ctx.region.x0)) or size
  local rmax = (rw < 150) and min(13.0, rw * 0.14) or 13.5
  local R0 = clamp((spec.bloom or 0.038) * size, 6.5, rmax) * (spec.organ_scale or 1)
  local sty = blossom_colors(ctx, (not spec.variant or spec.variant == "pink") and "sakura" or spec.variant)
  sty.centre = mix(ctx.palette.color("kigaki"), ctx.palette.color("beni"), 0.3)
  local P = M.SAKURA
  local st = new_state(ctx, spec, "sakura", P)
  local tree = (spec.engine == "walk") and grow_tree(st, P, spec) or grow_sc(st, spec, "sakura")
  if #tree == 0 then return nil, { perch = {} } end
  local items, umbels = {}, {}
  local budget = bloom_budget(st, tree, R0, spec.bloom_k or 1.25)
  local ncl = 0
  -- umbel sites: all twig tips, then nodes along twigs (with bare stretches)
  local sites = {}
  for _, br in ipairs(tree) do
    if br.depth >= 1 then sites[#sites + 1] = { br = br, s = br.L, tip = true } end
  end
  for _, br in ipairs(tree) do
    if br.depth >= 1 then
      local last = -1e9
      for _, nd in ipairs(br.nodes) do
        if nd.knot and nd.s > br.L * 0.3 and nd.s < br.L - R0 * 2 and nd.s - last > R0 * 3.2 and R.chance(0.45 + 0.3 * st.density) then
          sites[#sites + 1] = { br = br, s = nd.s }
          last = nd.s
        end
      end
    end
  end
  for idx, site in ipairs(sites) do
    if #items >= budget then break end
    ncl = ncl + 1
    local um = sakura_umbel(st, site.br, site.s, R0, items, ncl, R.int(3, 5), idx <= 3)
    if #um.flowers > 0 then umbels[#umbels + 1] = um; use(site.br, site.s) end
  end
  tree = prune(st, tree, 0)
  local bc = branch_colors(ctx, "sakura")
  local W = ctx.pdf
  local bb = tree_base(st, tree, spec)
  bb = union(bb, draw_tree(st, tree, { col = bc.col, body = bc.body, drycol = bc.drycol, dryalpha = 0.7, drymin = 4.5,
    dryness = 0.4 }))
  -- lenticels: subtle horizontal reddish-bark dashes across trunk and limbs
  local lent = {}
  for _, br in ipairs(tree) do
    if br.depth <= 1 and br.nodes[1].w > 2.5 then
      local s = br.L * 0.06
      while s < br.L * 0.85 do
        local x, y, w, h = eval_at(br, s)
        local l = w * R.range(0.12, 0.22)
        local off = w * R.sym(0.18)
        local nx, ny = -sin(h), cos(h)
        local cx, cy = x + nx * off, y + ny * off
        lent[#lent + 1] = W:poly({ { cx - nx * l, cy - ny * l }, { cx + nx * l, cy + ny * l } }, false)
        s = s + max(5, w * R.range(1.1, 1.9))
      end
    end
  end
  if #lent > 0 then
    W:layer(22)
    W:stroke(W:join(lent), mix(bc.col, ctx.palette.color("kuri"), 0.5), 0.45, 0.35)
  end
  -- Wispy secondary sprays (cymes, umbels, sprigs, tendrils, leaf pairs, stalked buds)
  bb = union(bb, M.add_wispy_sprays(st, tree, sty, { count = spec.wispy_count }))
  -- pedicels (one fill) and young leaves (behind flowers)
  local peds, knobs = {}, {}
  local pedc = U.hanga(ctx) and mix(ctx.palette.color("kuri"), ctx.palette.color("moegi"), 0.3) or ctx.palette.color("sumi-mid")
  for _, um in ipairs(umbels) do
    knobs[#knobs + 1] = W:circle(um.x, um.y, max(0.8, um.w * 0.5))
    for _, f in ipairs(um.flowers) do
      local p = f.ped
      local mx, my = (p[1] + p[3]) / 2, (p[2] + p[4]) / 2
      local dx, dy = p[3] - p[1], p[4] - p[2]
      local l = sqrt(dx * dx + dy * dy)
      local c1 = { mx - dy * 0.15 * p[5], my + dx * 0.15 * p[5] }
      local seg = { { p[1], p[2] }, { p[1] + (c1[1] - p[1]) * 0.7, p[2] + (c1[2] - p[2]) * 0.7 },
        { p[3] + (c1[1] - p[3]) * 0.7, p[4] + (c1[2] - p[4]) * 0.7 }, { p[3], p[4] } }
      local S = B.spine({ seg }, { step = 0.8 })
      local wp = clamp(l * 0.07, 0.45, 1.0)
      peds[#peds + 1] = W:poly(B.outline(S, function(u) return wp * (1 - 0.4 * u) end), true)
    end
  end
  W:layer(30)
  local pb = W:fill(W:join(peds), pedc, 0.92)
  W:fill(W:join(knobs), pedc, 0.92)
  bb = union(bb, pb)
  if pb then U.rec(ctx, "sakura-pedicel", pb) end
  local lc0 = ctx.palette.color("shu")
  local lc1 = U.hanga(ctx) and ctx.palette.color("moegi") or mix(ctx.palette.color("koke"), ctx.palette.color("sumi-mid"), 0.2)
  for _, um in ipairs(umbels) do
    for idx_lf, lf in ipairs(um.leaves) do
      local tier_lf = (idx_lf == 1 and R.chance(0.5)) and 1 or ((idx_lf == 2) and 2 or 3)
      local alpha_lf = (tier_lf == 1 and 0.42) or (tier_lf == 2 and 0.72) or 0.96
      W:layer((tier_lf == 1 and 18.5) or (tier_lf == 2 and 27) or 31)
      local lhue = R.chance(0.55) and mix(lc1, lc0, R.range(0.18, 0.36)) or mix(lc1, ctx.palette.color("yamabuki"), R.range(0.15, 0.32))
      INK.begin(W, lhue, { chroma = 1.15, alpha = alpha_lf })
      INK.detail = (tier_lf == 1) and 0.5 or 1
      INK.push()
      INK.translate(lf.x, lf.y)
      INK.rotate(math.deg(lf.a) - 90)
      INK.scale(lf.L)
      INK.leaf(R, { depth = (tier_lf == 1) and 1 or 0, w = R.range(0.24, 0.30), bend = R.sym(0.18), tone = R.range(0.42, 0.56) })
      INK.pop()
      local b = INK.finish()
      if b then U.rec(ctx, "sakura-leaf", b); bb = union(bb, b) end
    end
  end
  bb = union(bb, draw_items(st, items, sty, { notch = 0.14, pw = 0.5, smin = 0.42, smax = 0.7 }, "sakura"))
  -- drifting petals below the spray (painted with INK.petal watercolour glaze)
  local np = spec.petals or R.int(2, 5)
  if bb and np > 0 then
    local placed = 0
    for _ = 1, np * 6 do
      if placed >= np then break end
      local px = R.range(bb.x0 - 0.1 * size, bb.x1 + 0.1 * size)
      local py = R.range(bb.y0 - 0.25 * size, bb.y0 + 0.3 * (bb.y1 - bb.y0))
      local pr = R0 * R.range(0.48, 0.65)
      local ok = U.free(ctx, px, py, pr * 1.3)
      for _, it in ipairs(items) do if ok and (it.x - px) ^ 2 + (it.y - py) ^ 2 < (it.r * 1.8 + pr) ^ 2 then ok = false end end
      for _, br in ipairs(tree) do
        if ok then for _, nd in ipairs(br.nodes) do if (nd.x - px) ^ 2 + (nd.y - py) ^ 2 < (nd.w + pr * 2) ^ 2 then ok = false; break end end end
      end
      if ok then
        W:layer(40)
        ink_style(ctx, sty)
        INK.push()
        INK.translate(px, py)
        INK.rotate(R.range(0, 360))
        INK.scale(pr * 1.5, pr * 1.5 * R.range(0.55, 0.92))
        INK.translate(0, -0.5)
        INK.petal(R, { notch = 0.14, w = R.range(0.38, 0.46), tone = R.range(sty.tone[1], sty.tone[2]),
          heart = false, pool = sty.pool, blush = sty.blush })
        INK.pop()
        local b = INK.finish()
        if b then U.rec(ctx, "sakura-petal", b); bb = union(bb, b); placed = placed + 1 end
      end
    end
  end
  local info = { perch = perches(st, tree, items, spec.perch_clear), tree = tree, items = items,
    kinds = { "sakura-trunk", "sakura-branch", "sakura-twig", "sakura-blossom", "sakura-bud", "sakura-leaf", "sakura-petal",
              "sakura-cyme", "sakura-umbel", "sakura-sprig", "sakura-tendril" } }
  return bb, info
end

---------------------------------------------------------------- stalk / leaf / vine motifs
-- Ported from the explorer_m2_2 prototypes (bamboo, orchid, iris, wisteria,
-- narcissus, pine) onto the M1 writer: every leaf, flower and twig is built by
-- a parametric builder and growth-limited with fit_stroke (shorten, re-aim,
-- drop) before anything is painted.

local ROLES = {
  sumi = {
    culm = { "sumi-noir", 0.62 }, node = { "sumi-noir", 0.92 }, twig = { "sumi-noir", 0.85 },
    leaf = { "sumi-noir", 0.88 }, leaf2 = { "sumi-dark", 0.85 }, stem = { "sumi-noir", 0.80 },
    orchid_leaf = { "sumi-noir", 0.90 }, orchid_flower = { "sumi-mid", 0.55 }, orchid_heart = { "sumi-noir", 0.9 },
    iris_leaf = { "sumi-noir", 0.70 }, iris_petal = { "ai", 0.55 }, iris_vein = { "sumi-noir", 0.75 }, iris_signal = { "yamabuki", 0.8 },
    vine = { "sumi-noir", 0.82 }, raceme = { "fuji", 0.75 }, raceme_tip = { "fuji-pale", 0.8 }, raceme_bud = { "koke", 0.7 },
    wleaf = { "sumi-mid", 0.75 },
    strap = { "ai", 0.30 }, strap_line = { "sumi-noir", 0.75 }, tepal = { "gofun", 0.97 }, tepal_line = { "sumi-noir", 0.55 },
    cup = { "yamabuki", 0.9 }, cup_line = { "ume-centre", 0.8 }, spathe = { "kigaki", 0.5 },
    trunk = { "sumi-noir", 0.80 }, trunk_wash = { "kuri", 0.18 }, bark = { "sumi-noir", 0.45 },
    needle = { "sumi-noir", 0.82 }, pad = { "sumi-light", 0.10 },
  },
  hanga = {
    culm = { "wakatake", 0.95 }, node = { "matsuba", 0.9 }, twig = { "matsuba", 0.9 },
    leaf = { "matsuba", 0.92 }, leaf2 = { "wakatake", 0.90 }, stem = { "matsuba", 0.9 },
    orchid_leaf = { "matsuba", 0.92 }, orchid_flower = { "moegi", 0.85 }, orchid_heart = { "beni", 0.9 },
    iris_leaf = { "wakatake", 0.92 }, iris_petal = { "gunjo", 0.85 }, iris_vein = { "ai", 0.8 }, iris_signal = { "yamabuki", 0.95 },
    vine = { "kuri", 0.9 }, raceme = { "fuji", 0.85 }, raceme_tip = { "fuji-pale", 0.9 }, raceme_bud = { "moegi", 0.85 },
    wleaf = { "wakatake", 0.88 },
    strap = { "asagi", 0.85 }, strap_line = { "ai", 0.7 }, tepal = { "gofun", 1.0 }, tepal_line = { "sumi-dark", 0.5 },
    cup = { "yamabuki", 0.95 }, cup_line = { "ume-centre", 0.8 }, spathe = { "kigaki", 0.6 },
    trunk = { "kuri", 0.92 }, trunk_wash = { "kuri", 0.25 }, bark = { "sumi-noir", 0.40 },
    needle = { "matsuba", 0.92 }, pad = { "moegi", 0.2 },
  },
}
M.ROLES = ROLES

--- Colour and alpha of a role at ink depth (0 = front, 1 = far back): sumi
--- dilutes the ink (alpha), hanga mixes the colour toward the paper.
local function ink(ctx, role, depth)
  local pal = ctx.palette
  local r = ROLES[pal.name == "hanga" and "hanga" or "sumi"][role]
  depth = depth or 0
  local c = pal.color(r[1])
  if pal.name == "hanga" then return lerp(c, U.paper(ctx), 0.55 * depth), r[2] end
  return c, r[2] * (1 - 0.62 * depth)
end
M.ink = ink

local function leaf_seg(x, y, a, L, b, g)
  local dx, dy = cos(a), sin(a)
  local nx, ny = -dy, dx
  return { { { x, y },
    { x + dx * L * 0.36 + nx * b * L * 0.22, y + dy * L * 0.36 + ny * b * L * 0.22 },
    { x + dx * L * 0.72 + nx * b * L * 0.30, y + dy * L * 0.72 + ny * b * L * 0.30 - g * L * 0.45 },
    { x + dx * L * 0.98 + nx * b * L * 0.12, y + dy * L * 0.98 + ny * b * L * 0.12 - g * L } } }
end
U.leaf_seg = leaf_seg

local function spine_of(segs) return B.spine(segs, { step = 1.2 }) end

local function fits_S(ctx, S, wfn, skip_u)
  for _, p in ipairs(S) do
    if p.u >= (skip_u or 0) and not U.free(ctx, p.x, p.y, wfn(p.u) / 2 + 1.2) then return false end
  end
  return true
end

--- Growth-limited stroke: build(L) -> segs; shrink by 0.86 until the spine
--- with clearance wfn (or probe) fits; nil below Lmin.
local function fit_stroke(ctx, build, L, Lmin, wfn_of_L, skip_u, probe)
  while L >= Lmin do
    local segs = build(L)
    local S = spine_of(segs)
    local wfn = wfn_of_L(L)
    local test = probe and function(u) return probe(u, L) end or wfn
    if fits_S(ctx, S, test, skip_u) then return segs, S, wfn, L end
    L = L * 0.86
  end
  return nil
end
U.fit_stroke = fit_stroke
local function fit_stroke_dirs(ctx, buildA, dirs, L, Lmin, wfn_of_L, skip_u, probe)
  for _, a in ipairs(dirs) do
    local segs, S, wfn, Lf = fit_stroke(ctx, function(LL) return buildA(a, LL) end, L, Lmin, wfn_of_L, skip_u, probe)
    if segs then return segs, S, wfn, Lf end
  end
end

local function spine_eval(segs, t)
  local n = #segs
  t = clamp(t, 0, 1)
  local k = min(n, floor(t * n) + 1)
  local tt = t * n - (k - 1)
  local s = segs[k]
  local x, y = B.bez(s, tt)
  local dx, dy = B.bezd(s, tt)
  local l = max(1e-9, sqrt(dx * dx + dy * dy))
  return x, y, dx / l, dy / l
end
U.spine_eval = spine_eval

local function jitfn(ctx, amp, k)
  local f = ctx.rng.noise(2)
  local ph = ctx.rng.range(0, 50)
  return function(u, side) return amp * f(u * (k or 6) + side * 7 + ph) end
end

local function outline_of(ctx, S, wfn, jamp)
  return B.outline(S, wfn, { jitter = (jamp and jamp > 0) and jitfn(ctx, jamp) or nil })
end

-- pigment pooling inside a leaf (sumi)
local function pool(ctx, pts, rgb, alpha, w)
  local W = ctx.pdf
  local p = W:poly(pts, true)
  if not p then return end
  W:clip(p)
  W:stroke(p, rgb, w * 0.55, alpha * 0.22, { blend = "multiply" })
  W:stroke(p, rgb, w * 0.22, alpha * 0.30, { blend = "multiply" })
  W:unclip()
end

--- Soft fade for a bleed piece whose base (x,y) lies outside the safe box:
--- returns an ExtGState that fades from ~0 at the base to 1 at `len` along
--- direction a, or nil when the base is inside (no fade needed).
local function base_fade(ctx, x, y, a, len, bbox)
  if U.free(ctx, x, y, 0) and not ctx.force_fade then return nil end
  local W = ctx.pdf
  if not W.fade_axial then return nil end
  local big = bbox or { x0 = x - 2 * len - 400, y0 = y - 2 * len - 400, x1 = x + 2 * len + 400, y1 = y + 2 * len + 400 }
  return W:fade_axial(x, y, x + cos(a) * len, y + sin(a) * len, 0.04, 1, big)
end
U.base_fade = base_fade

local function with_fade(W, g, fn) if g then W:with_gs(g, fn) else fn() end end

local function pts_bb(list, pad)
  local bb
  for _, pts in ipairs(list) do bb = union(bb, U.bbox_pts(pts, pad)) end
  return bb
end

---------------------------------------------------------------- BAMBOO
local function bamboo_culm(ctx, x, y, a, H, w0, depth)
  local R = ctx.rng
  local W = ctx.pdf
  local r = ctx.region
  local m = 4 + w0
  local tx0, ty0 = x + cos(a) * H, y + sin(a) * H
  if ty0 > r.y1 - m then local k = (r.y1 - m - y) / max(1e-6, ty0 - y); tx0, ty0 = x + (tx0 - x) * k, r.y1 - m end
  tx0 = max(r.x0 + m, min(r.x1 - m, tx0))
  H = sqrt((tx0 - x) ^ 2 + (ty0 - y) ^ 2)
  a = atan2(ty0 - y, tx0 - x)
  local dx, dy = cos(a), sin(a)
  local nx, ny = -dy, dx
  local axis
  local lean = R.sym(0.03) * H
  local good = false
  for _ = 1, 40 do
    axis = { { x, y }, { x + dx * H * 0.33 + nx * lean * 0.2, y + dy * H * 0.33 + ny * lean * 0.2 },
      { x + dx * H * 0.66 + nx * lean * 0.7, y + dy * H * 0.66 + ny * lean * 0.7 },
      { x + dx * H + nx * lean, y + dy * H + ny * lean } }
    local ok, entered = true, false
    for k = 0, 24 do
      local px, py = B.bez(axis, k / 24)
      local inside = U.free(ctx, px, py, w0 * 0.7 + 1)
      if not U.clear(ctx, px, py, w0) then ok = false end
      if inside then entered = true elseif entered then ok = false end
      if not ok then break end
    end
    if ok and entered then good = true; break end
    if lean ~= 0 then lean = 0 else H = H * 0.95 end
  end
  if not good then return nil end
  local function A(t)
    local px, py = B.bez(axis, t)
    local tx, ty = B.bezd(axis, t)
    local l = sqrt(tx * tx + ty * ty)
    return px, py, tx / l, ty / l
  end
  local n = max(4, min(13, floor(H / (w0 * 8.5))))
  local wts, tot = {}, 0
  for i = 1, n do
    local t = (i - 0.5) / n
    wts[i] = (0.45 + sin(pi * min(1, t * 1.25)) * 0.75) * R.range(0.9, 1.1); tot = tot + wts[i]
  end
  local ts, acc = { 0 }, 0
  for i = 1, n do acc = acc + wts[i] / tot; ts[i + 1] = acc end
  local function wat(t) return w0 * (1 - 0.38 * t ^ 1.6) end
  local crgb, calpha = ink(ctx, "culm", depth)
  local nrgb, nalpha = ink(ctx, "node", depth)
  local parts, outs, shades, nodes, kasure = {}, {}, {}, {}, {}
  local gap = 0.035
  local hanga = U.hanga(ctx)
  for i = 1, n do
    local t0, t1 = ts[i], ts[i + 1]
    local ta, tb = t0 + (i > 1 and gap * w0 / H or 0), t1 - (i < n and gap * w0 / H or 0)
    local pts = {}
    for k = 0, 6 do local px, py = A(ta + (tb - ta) * k / 6); pts[#pts + 1] = { px, py } end
    local segs = B.chain(pts, 1)
    local wa, wb = wat(ta), wat(tb)
    local top = (i == n)
    local wfn = function(u)
      local w = wa + (wb - wa) * u
      if top then w = w * (1 - 0.7 * u ^ 2) end
      return w * (0.95 + 0.07 * abs(2 * u - 1) ^ 6)
    end
    local S = spine_of(segs)
    local out = outline_of(ctx, S, wfn, 0.025)
    parts[#parts + 1] = W:poly(out, true)
    outs[#outs + 1] = out
    if not hanga then
      for _ = 1, R.int(1, 3) do
        local o, u0 = R.range(-0.3, 0.3), R.range(0.5, 0.8)
        local bw = R.range(0.04, 0.09)
        local L_, R_ = {}, {}
        for _, p in ipairs(S) do
          if p.u >= u0 then
            local w = wfn(p.u)
            local loc = (p.u - u0) / (1 - u0)
            local h = w * bw * 0.5 * min(1, loc / 0.3) ^ 0.7 * (0.4 + 0.6 * abs(sin(loc * 9 + o * 5)))
            local cx, cy = p.x - p.ty * w * o, p.y + p.tx * w * o
            L_[#L_ + 1] = { cx - p.ty * h, cy + p.tx * h }; R_[#R_ + 1] = { cx + p.ty * h, cy - p.tx * h }
          end
        end
        if #L_ > 3 then for k = #R_, 1, -1 do L_[#L_ + 1] = R_[k] end; kasure[#kasure + 1] = W:poly(L_, true) end
      end
    else
      local shp, hl = {}, {}
      for _, p in ipairs(S) do
        local w = wfn(p.u)
        shp[#shp + 1] = { p.x + p.ty * w * 0.5, p.y - p.tx * w * 0.5 }
        hl[#hl + 1] = { p.x - p.ty * w * 0.24, p.y + p.tx * w * 0.24 }
      end
      for k = #S, 1, -1 do local p = S[k]; local w = wfn(p.u); shp[#shp + 1] = { p.x + p.ty * w * 0.18, p.y - p.tx * w * 0.18 } end
      shades[#shades + 1] = { shade = shp, hl = hl }
    end
    if i < n then
      local px, py, tx, ty = A(t1)
      local w = wat(t1) * 1.12
      local qx, qy = -ty, tx
      local d = 0.10 * w
      local nseg = { { { px - qx * w * 0.55 + tx * d, py - qy * w * 0.55 + ty * d },
        { px - qx * w * 0.2 - tx * d * 0.4, py - qy * w * 0.2 - ty * d * 0.4 },
        { px + qx * w * 0.2 - tx * d * 0.4, py + qy * w * 0.2 - ty * d * 0.4 },
        { px + qx * w * 0.55 + tx * d, py + qy * w * 0.55 + ty * d } } }
      local tw = w * R.range(0.16, 0.22)
      nodes[#nodes + 1] = W:poly(outline_of(ctx, spine_of(nseg), function(u) return tw * (0.35 + 0.65 * sin(pi * u) ^ 0.5) end, 0.08), true)
    end
  end
  local paint = function()
    local cu = W:join(parts)
    W:fill(cu, crgb, calpha)
    if not hanga then
      W:clip(cu)
      W:stroke(cu, crgb, w0 * 0.30, calpha * 0.35, { blend = "multiply" })
      W:stroke(cu, crgb, w0 * 0.12, calpha * 0.45, { blend = "multiply" })
      W:unclip()
      if #kasure > 0 then W:fill(W:join(kasure), U.paper(ctx), 0.5) end
    else
      for _, sd in ipairs(shades) do
        W:fill(W:poly(sd.shade, true), ctx.palette.color("matsuba"), 0.35 * (1 - 0.5 * depth))
        W:stroke(W:poly(sd.hl, false), ctx.palette.color("gofun"), max(0.6, w0 * 0.08), 0.35)
      end
    end
    if #nodes > 0 then W:fill(W:join(nodes), nrgb, nalpha) end
  end
  return { A = A, ts = ts, H = H, wat = wat, paint = paint, bb = pts_bb(outs, 1) }
end

local function bamboo_fan(ctx, x, y, dir, nleaf, Ll, depth, opts)
  local R = ctx.rng
  local W = ctx.pdf
  opts = opts or {}
  local down = -pi / 2
  local hang = opts.hang or R.range(0.25, 0.6)
  local dd = atan2(sin(down - dir), cos(down - dir))
  if abs(dd) > 2.6 and opts.side then dd = opts.side * abs(dd) end
  local cdir = dir + dd * hang
  local spread = R.range(0.9, 1.5)
  local outs, all = {}, {}
  for i = 1, nleaf do
    local f = nleaf == 1 and 0 or (i - 1) / (nleaf - 1) - 0.5
    local a = cdir + f * spread + R.sym(0.12)
    local L = Ll * R.range(0.75, 1.05) * (1 - 0.25 * abs(f))
    local b = R.sym(0.14)
    local g = R.range(0.05, 0.2) * abs(cos(a))
    local w = L * R.range(0.10, 0.125)
    local segs, S, wfn = fit_stroke(ctx, function(LL) return leaf_seg(x, y, a, LL, b, g) end, L, Ll * 0.4,
      function(LL) local ww = w * LL / L; return function(u) return ww * U.prof.bamboo(u) end end)
    if segs then
      local out = outline_of(ctx, S, wfn, 0.04)
      outs[#outs + 1] = { out = out, w = w, x0 = x, y0 = y, x1 = S[#S].x, y1 = S[#S].y, back = R.chance(0.3) }
      all[#all + 1] = out
    end
  end
  local role = R.chance(0.5) and "leaf" or "leaf2"
  local hanga = U.hanga(ctx)
  for _, pass_back in ipairs({ true, false }) do
    local d = pass_back and min(1, depth + 0.45) or depth
    local rgb, al = ink(ctx, pass_back and (role == "leaf" and "leaf2" or "leaf") or role, d)
    local fan_alpha = al * (pass_back and 0.48 or 0.94) * (1 - 0.42 * depth)
    INK.begin(W, rgb, { chroma = hanga and 1.10 or 0.22, alpha = max(0.20, min(0.98, fan_alpha)) })
    INK.detail = (d > 0.6) and 0.45 or 1
    for _, o in ipairs(outs) do
      if o.back == pass_back then
        INK.glaze_leaf(R, o.out, o.x0, o.y0, o.x1, o.y1, o.w, {
          tone = hanga and R.range(0.36, 0.54) or R.range(0.18 + 0.45 * d, 0.34 + 0.45 * d),
          alpha = al * R.range(0.92, 1.0),
          lateral_veins = false,
          vein_color = hanga and mix(ctx.palette.color("moegi"), { 1, 1, 1 }, 0.45) or U.paper(ctx),
        })
      end
    end
    INK.finish()
  end
  return pts_bb(all, 0.8), #all
end

--- Bamboo: 1-3 segmented culms with node rings (kind culm), zig-zag side twigs
--- carrying drooping leaf fans, a crown fan. spec.size = culm height,
--- spec.culms = 1..3, spec.width = culm width, spec.leaf = leaf length.
--- Culms may start off the region (bleed) and then fade into the paper.
function M.bamboo(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local H = spec.size or 400
  local reg = ctx.region
  local rw = reg.x1 - reg.x0
  local w0 = spec.width or min(H / 38, rw * 0.12)
  local nc = min(spec.culms or 3, max(1, floor(rw / (w0 * 2.1))))
  local density = spec.density or ctx.density or 0.5
  local a0 = spec.angle or pi / 2
  local culms = {}
  for c = 1, nc do
    local depth = (nc == 1) and 0 or (nc - c) / (nc - 1) * 0.88
    local off = (c - 1) * w0 * R.range(1.85, 2.85) * (c % 2 == 0 and 1 or -1)
    local wc = w0 * (1 - 0.38 * depth)
    local cx = spec.x + off
    if spec.x >= reg.x0 and spec.x <= reg.x1 then
      local lo, hi = reg.x0 + wc * 1.2 + 2, reg.x1 - wc * 1.2 - 2
      if cx < lo or cx > hi then cx = spec.x - off end
      cx = max(lo, min(hi, cx))
    end
    culms[#culms + 1] = { x = cx, y = spec.y, depth = depth, H = H * (c == nc and 1 or R.range(0.68, 0.92)),
      w = wc, a = a0 + R.sym(0.055) }
  end
  table.sort(culms, function(p, q) return p.depth > q.depth end)
  local bb
  for _, cu in ipairs(culms) do
    local cl = bamboo_culm(ctx, cu.x, cu.y, cu.a, cu.H, cu.w, cu.depth)
    if cl then
      local z_off = floor(cu.depth * 6)
      W:layer(20 - z_off)
      local fg = base_fade(ctx, cu.x, cu.y, cu.a, spec.fade or 80)
      with_fade(W, fg, cl.paint)
      U.rec(ctx, "bamboo-culm", cl.bb)
      bb = union(bb, cl.bb)
      local Hc, A, ts = cl.H, cl.A, cl.ts
      local Ll = (spec.leaf or Hc * 0.145) * (1 - 0.18 * cu.depth)
      local twrgb, twal = ink(ctx, "twig", cu.depth)
      local twparts, twouts, fans = {}, {}, {}
      local side = R.chance(0.5) and 1 or -1
      for i = 2, #ts - 1 do
        local t = ts[i]
        if t > 0.34 and R.chance(0.38 + 0.55 * density) then
          local px, py, tx, ty = A(t)
          local ca = atan2(ty, tx)
          local ta = ca + side * R.range(0.55, 0.85)
          side = -side
          local Lt = Hc * R.range(0.10, 0.2) * (1.1 - 0.4 * t)
          local tw = max(0.9, cu.w * 0.16)
          local kink = side * R.range(0.18, 0.35)
          local segs, S, wfn, Lfit = fit_stroke(ctx, function(L)
            local m1x, m1y = px + cos(ta) * L * 0.5, py + sin(ta) * L * 0.5
            return B.chain({ { px, py }, { m1x, m1y }, { m1x + cos(ta + kink) * L * 0.5, m1y + sin(ta + kink) * L * 0.5 - L * 0.03 } }, 0.5)
          end, Lt, Lt * 0.35, function() return function(u) return tw * (1 - 0.65 * u) end end, 0.08,
            function(u) return u > 0.9 and Ll * 0.6 or tw end)
          if segs then
            local out = outline_of(ctx, S, wfn, 0)
            twparts[#twparts + 1] = W:poly(out, true)
            twouts[#twouts + 1] = out
            twparts[#twparts + 1] = W:circle(px, py, tw * 0.75)
            local ex, ey, etx, ety = spine_eval(segs, 1)
            fans[#fans + 1] = { ex, ey, atan2(ety, etx), R.chance(0.6) and 5 or 4, scale = R.range(0.88, 1.14) }
            if R.chance(0.5 + 0.4 * density) then
              local mx, my, mtx, mty = spine_eval(segs, 0.55)
              local sa = atan2(mty, mtx) - side * R.range(0.5, 0.8)
              local Ls = Lfit * R.range(0.25, 0.4)
              local s2, S2, w2 = fit_stroke(ctx, function(L) return leaf_seg(mx, my, sa, L, 0, 0.05) end, Ls, Ls * 0.4,
                function() return function(u) return tw * 0.7 * (1 - 0.65 * u) end end)
              if s2 then
                local o2 = outline_of(ctx, S2, w2, 0)
                twparts[#twparts + 1] = W:poly(o2, true)
                twouts[#twouts + 1] = o2
                local fx, fy, ftx, fty = spine_eval(s2, 1)
                fans[#fans + 1] = { fx, fy, atan2(fty, ftx), 3, scale = R.range(0.75, 0.96) }
              end
            end
          end
        end
      end
      local tx_, ty_, ttx, tty = A(1)
      if not spec.exit then fans[#fans + 1] = { tx_, ty_, atan2(tty, ttx), 4, crown = true, scale = 0.85 } end
      W:layer(21 - z_off)
      if #twparts > 0 then
        W:fill(W:join(twparts), twrgb, twal * (1 - 0.35 * cu.depth))
        local tb = pts_bb(twouts, 1)
        U.rec(ctx, "bamboo-twig", tb)
        bb = union(bb, tb)
      end
      W:layer(30 - floor(cu.depth * 8))
      for _, fa in ipairs(fans) do
        local fb = bamboo_fan(ctx, fa[1], fa[2], fa[3], fa[4], Ll * (fa.scale or 1), cu.depth,
          { hang = fa.crown and 0.42 or nil, side = (fa[1] < (reg.x0 + reg.x1) / 2) and -1 or 1 })
        if fb then U.rec(ctx, "bamboo-leaf", fb); bb = union(bb, fb) end
      end
    end
  end
  return bb, { kinds = { "bamboo-culm", "bamboo-twig", "bamboo-leaf" }, perch = {} }
end

---------------------------------------------------------------- ORCHID
--- Orchid (ran): arching ribbon leaves with swell-thin-swell profile, the
--- crossing "phoenix eye", sheath strokes binding the clump, flower scapes with
--- side-facing flowers and heart dots, an earth wash at the base.
--- spec.size = longest leaf, spec.leaves (6..12), spec.flowers (scapes).
function M.orchid(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local Lmax = spec.size or 200
  local a0 = spec.angle or pi / 2
  local nl = spec.leaves or 9
  local w0 = spec.width or Lmax * 0.028
  local bb
  if spec.ground ~= false then bb = union(bb, M.earth(ctx, spec.x, spec.y + 1, Lmax * 0.28, "orchid")) end
  local front, back, pools, allf, allb = {}, {}, {}, {}, {}
  local plan = {}
  local lean = R.chance(0.5) and 1 or -1
  plan[1] = { a = a0 - lean * 0.45, b = lean * 0.95, L = 1.0, g = 0.32, depth = 0 }
  plan[2] = { a = a0 + lean * 0.35, b = -lean * 0.85, L = 0.85, g = 0.15, depth = 0 }
  plan[3] = { a = a0 - lean * 0.05, b = lean * 0.35, L = 0.62, g = 0.05, depth = 0.1 }
  for i = 4, nl do
    local s = (i % 2 == 0) and 1 or -1
    local spread = R.range(0.25, 1.1)
    plan[i] = { a = a0 + s * spread, b = s * R.range(0.3, 1.1), L = R.range(0.4, 0.9), g = R.range(0.1, 0.5) * spread,
      depth = R.chance(0.45) and R.range(0.6, 0.9) or R.range(0, 0.2) }
  end
  local bx, by = spec.x, spec.y
  W:layer(30)
  for _, p in ipairs(plan) do
    local x0, y0 = bx + R.sym(w0 * 1.2), by + R.sym(w0 * 0.2)
    local L = Lmax * p.L
    local w = w0 * R.range(0.85, 1.15) * (0.6 + 0.4 * p.L)
    local segs, S, wfn = fit_stroke(ctx, function(LL) return leaf_seg(x0, y0, p.a, LL, p.b, p.g) end, L, L * 0.35,
      function(LL) local ww = w * (0.5 + 0.5 * LL / L); return function(u) return ww * B.profile.orchid(u) end end, 0.0)
    if segs then
      local out = outline_of(ctx, S, wfn, 0.05)
      if p.depth > 0.5 then back[#back + 1] = W:poly(out, true); allb[#allb + 1] = out
      else front[#front + 1] = W:poly(out, true); allf[#allf + 1] = out; pools[#pools + 1] = { out, w } end
    end
  end
  if #back > 0 then local c, a = ink(ctx, "orchid_leaf", 0.7); W:fill(W:join(back), c, a) end
  if #front > 0 then local c, a = ink(ctx, "orchid_leaf", 0); W:fill(W:join(front), c, a) end
  if not U.hanga(ctx) then local c, a = ink(ctx, "orchid_leaf", 0); for _, q in ipairs(pools) do pool(ctx, q[1], c, a, q[2]) end end
  for _, o in ipairs(allb) do local b = U.bbox_pts(o, 0.5); U.rec(ctx, "orchid-leaf", b); bb = union(bb, b) end
  for _, o in ipairs(allf) do local b = U.bbox_pts(o, 0.5); U.rec(ctx, "orchid-leaf", b); bb = union(bb, b) end
  local sh, sho = {}, {}
  for _ = 1, 3 do
    local a = a0 + R.sym(0.6)
    local s = leaf_seg(bx + R.sym(w0), by + w0 * 0.2, a, w0 * R.range(2.2, 3.4), R.sym(0.3), 0)
    local S = spine_of(s)
    if fits_S(ctx, S, function() return w0 end) then
      local o = outline_of(ctx, S, function(u) return w0 * 1.1 * B.profile.nail(u) end, 0)
      sh[#sh + 1] = W:poly(o, true); sho[#sho + 1] = o
    end
  end
  if #sh > 0 then
    local sc, sa = ink(ctx, "orchid_leaf", 0)
    W:fill(W:join(sh), sc, sa)
    local b = pts_bb(sho, 0.5); U.rec(ctx, "orchid-leaf", b); bb = union(bb, b)
  end
  local nf = spec.flowers or 1
  for _ = 1, nf do
    local a = a0 + R.sym(0.35)
    local L = Lmax * R.range(0.45, 0.65)
    local sw = max(0.6, w0 * 0.22)
    local sb, sx = R.sym(0.25), bx + R.sym(w0)
    local segs, S, wfn = fit_stroke(ctx, function(LL) return leaf_seg(sx, by, a, LL, sb, 0.02) end, L, L * 0.4,
      function() return function(u) return sw * (1 - 0.4 * u) end end)
    if segs then
      local fc, fa = ink(ctx, "orchid_flower", 0)
      W:layer(31)
      local so = outline_of(ctx, S, wfn, 0)
      W:fill(W:poly(so, true), fc, min(1, fa * 1.3))
      local sbb = U.bbox_pts(so, 0.5)
      U.rec(ctx, "orchid-stem", sbb); bb = union(bb, sbb)
      local nfl = R.int(2, 4)
      W:layer(40)
      for k = 1, nfl do
        local t = 0.55 + 0.45 * (k - 1) / max(1, nfl - 1)
        local px, py, tx, ty = spine_eval(segs, min(1, t))
        local fdir = atan2(ty, tx) + (k % 2 == 0 and 1 or -1) * R.range(0.5, 1.0)
        local fl = Lmax * 0.06 * R.range(0.85, 1.15)
        local pq = leaf_seg(px, py, fdir, fl * 0.5, 0, 0.1)
        local ex, ey = pq[1][4][1], pq[1][4][2]
        if U.free(ctx, ex, ey, fl * 1.3) then
          local ped_o = outline_of(ctx, spine_of(pq), function() return sw * 0.8 end, 0)
          W:fill(W:poly(ped_o, true), fc, fa)
          local hc, ha = ink(ctx, "orchid_heart", 0)
          local tangs = { -1.35 + R.sym(0.2), -0.6 + R.sym(0.2), 0.1 + R.sym(0.2), 0.75 + R.sym(0.2), 1.45 + R.sym(0.2) }
          local fpts = { ped_o }
          INK.begin(W, fc, { accent = hc, chroma = U.hanga(ctx) and 1.15 or 0.25 })
          INK.detail = 1
          for j, da in ipairs(tangs) do
            local tl = fl * ((j == 1 or j == 5) and 1.05 or (j == 3 and 0.6 or 0.85)) * R.range(0.85, 1.1)
            local s = leaf_seg(ex, ey, fdir + da, tl, (da > 0 and 0.35 or -0.35) * R.range(0.3, 1), 0.1)
            local o = outline_of(ctx, spine_of(s), function(u) return fl * 0.32 * U.prof.petal(u) end, 0)
            local tip = s[1][4]
            INK.glaze_petal(R, o, ex, ey, tip[1], tip[2], fl * 0.32, {
              tone = (j == 3) and R.range(0.44, 0.56) or R.range(0.58, 0.72),
              alpha = min(0.95, fa * 1.08),
              blush = (j == 3),
              blush_color = hc,
              lift = 1.25,
            })
            fpts[#fpts + 1] = o
          end
          INK.finish()
          local dots = {}
          for d = 1, 3 do
            local dx_, dy_ = cos(fdir + 0.4 * (d - 2)), sin(fdir + 0.4 * (d - 2))
            dots[#dots + 1] = W:poly(U.ellipse_pts(ex + dx_ * fl * 0.22, ey + dy_ * fl * 0.22, fl * 0.07, fl * 0.045, fdir, 10), true)
          end
          W:fill(W:join(dots), hc, ha)
          local fb = pts_bb(fpts, 0.5)
          U.rec(ctx, "orchid-flower", fb); bb = union(bb, fb)
        end
      end
    end
  end
  return bb, { kinds = { "orchid-leaf", "orchid-stem", "orchid-flower", "orchid-earth" }, perch = {} }
end

---------------------------------------------------------------- IRIS
local function iris_petal(ctx, x, y, a, L, wd, curl, g)
  local segs = leaf_seg(x, y, a, L, curl, g or 0)
  local S = spine_of(segs)
  return B.outline(S, function(u) return wd * (u < 0.35 and (0.25 + 0.75 * (u / 0.35) ^ 1.2) or sin(pi * (0.5 + 0.5 * (u - 0.35) / 0.65)) ^ 0.6) end), segs
end

--- Iris (kakitsubata): flat fan of sword leaves from a rhizome line, flower
--- stems with 3 standards and 3 drooping falls (yellow signal, veins), buds.
--- spec.size = leaf height, spec.leaves, spec.flowers, spec.flower (head size).
function M.iris(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local H = spec.size or 240
  local a0 = spec.angle or pi / 2
  local nl = spec.leaves or 7
  local w0 = spec.width or H * 0.026
  local bb
  if spec.ground ~= false then bb = union(bb, M.earth(ctx, spec.x, spec.y + 1, w0 * nl * 1.1, "iris")) end
  local lc_b, la_b = ink(ctx, "iris_leaf", 0.65)
  local lc, la = ink(ctx, "iris_leaf", 0)
  local back, front, ribs, outs = {}, {}, {}, {}
  local order = {}
  for i = 1, nl do order[i] = i end
  for i = nl, 2, -1 do local j = R.int(1, i); order[i], order[j] = order[j], order[i] end
  W:layer(30)
  for ii = 1, nl do
    local i = order[ii]
    local s = (i - (nl + 1) / 2) / nl
    local a = a0 - s * 0.42 + R.sym(0.07)
    local L = H * R.range(0.62, 1.0) * (1 - 0.45 * abs(s))
    local b = -s * R.range(0.0, 0.18) + R.sym(0.06)
    local g = (R.chance(0.3) and R.range(0.10, 0.28) or 0.0) * (abs(s) > 0.12 and 1 or 0)
    local x0 = spec.x + s * w0 * 7 + R.sym(w0 * 0.8)
    local w = w0 * R.range(0.8, 1.15)
    local segs, S, wfn = fit_stroke(ctx, function(LL) return leaf_seg(x0, spec.y, a, LL, b, g) end, L, L * 0.4,
      function() return function(u) return w * U.prof.sword(u) end end, 0.0)
    if segs then
      local out = outline_of(ctx, S, wfn, 0.03)
      outs[#outs + 1] = out
      local depth = (i % 3 == 0) and 0.65 or 0
      if depth > 0 then back[#back + 1] = W:poly(out, true) else front[#front + 1] = W:poly(out, true) end
      local rib = {}
      for _, p in ipairs(S) do if p.u > 0.05 and p.u < 0.85 then rib[#rib + 1] = { p.x - p.ty * w * 0.12, p.y + p.tx * w * 0.12 } end end
      if #rib > 3 and depth == 0 then ribs[#ribs + 1] = rib end
    end
  end
  if #back > 0 then W:fill(W:join(back), lc_b, la_b) end
  if #front > 0 then W:fill(W:join(front), lc, la) end
  for _, rib in ipairs(ribs) do
    if U.hanga(ctx) then W:stroke(W:poly(rib, false), ctx.palette.color("moegi"), 0.6, 0.6)
    else W:stroke(W:poly(rib, false), U.paper(ctx), 0.5, 0.35) end
  end
  for _, o in ipairs(outs) do local b = U.bbox_pts(o, 0.6); U.rec(ctx, "iris-leaf", b); bb = union(bb, b) end
  local nf = spec.flowers or 2
  for f = 1, nf do
    local a = a0 + R.sym(0.08)
    local L = H * R.range(0.75, 1.05)
    local fs = spec.flower or H * 0.13
    local x0 = spec.x + R.sym(w0 * 2)
    local sw = max(0.9, w0 * 0.22)
    local sb = R.sym(0.04)
    local segs = fit_stroke_dirs(ctx, function(aa, LL) return leaf_seg(x0, spec.y, aa, LL, sb, 0) end, { a, a0 }, L, L * 0.45,
      function() return function() return sw end end, 0.0,
      function(u) return u > 0.93 and 2.3 * fs or sw end)
    if segs then
      W:layer(31)
      local so = outline_of(ctx, spine_of(segs), function(u) return sw * (1 - 0.3 * u) end, 0)
      W:fill(W:poly(so, true), lc, la)
      local px, py, tx, ty = spine_eval(segs, 1)
      local up = atan2(ty, tx)
      local sp = leaf_seg(px - tx * fs * 0.25, py - ty * fs * 0.25, up + 0.35, fs * 0.55, -0.2, 0)
      local spo = outline_of(ctx, spine_of(sp), function(u) return fs * 0.12 * U.prof.sword(u) end, 0)
      W:fill(W:poly(spo, true), lc, la)
      local sbb = union(U.bbox_pts(so, 0.5), U.bbox_pts(spo, 0.5))
      U.rec(ctx, "iris-stem", sbb); bb = union(bb, sbb)
      local pc, pa = ink(ctx, "iris_petal", 0)
      local rimc = ctx.palette.color("ai")
      local sc, sa = ink(ctx, "iris_signal", 0)
      W:layer(40)
      local fpts = {}
      local open = (f == 1) or R.chance(0.6)
      INK.begin(W, pc, { accent = sc, chroma = U.hanga(ctx) and 1.25 or 0.35 })
      INK.detail = 1
      if open then
        local stds, stdsegs, falls, fallsegs = {}, {}, {}, {}
        for k = 1, 3 do
          local da = (k - 2) * 0.32 + R.sym(0.06)
          local o, sg = iris_petal(ctx, px, py, up + da, fs * (k == 2 and 0.62 or 0.72), fs * 0.2, -(k - 2) * 0.35, 0)
          stds[#stds + 1] = o; stdsegs[#stdsegs + 1] = sg
        end
        for _, sd in ipairs({ -1, 1 }) do
          local o, sg = iris_petal(ctx, px, py, up + sd * R.range(1.55, 1.85), fs * R.range(0.92, 1.05), fs * 0.4, sd * 0.2, 0.55)
          falls[#falls + 1] = o; fallsegs[#fallsegs + 1] = sg
        end
        do
          local o, sg = iris_petal(ctx, px, py, up + pi + R.sym(0.15), fs * 0.72, fs * 0.42, R.sym(0.2), 0)
          falls[#falls + 1] = o; fallsegs[#fallsegs + 1] = sg
        end
        for idx, o in ipairs(stds) do
          local tip = stdsegs[idx][1][4]
          INK.glaze_petal(R, o, px, py, tip[1], tip[2], fs * 0.20, {
            tone = R.range(0.48, 0.62), alpha = min(0.95, pa * 0.92), pool = 0.26, lift = 1.25, vein = 1.3, vein_color = rimc,
          })
          fpts[#fpts + 1] = o
        end
        for idx, o in ipairs(falls) do
          local tip = fallsegs[idx][1][4]
          INK.glaze_petal(R, o, px, py, tip[1], tip[2], fs * 0.40, {
            tone = R.range(0.32, 0.46), alpha = min(0.98, pa * 1.05), pool = 0.32, lift = 1.30, vein = 1.6, vein_color = rimc,
            signal_color = sc,
          })
          fpts[#fpts + 1] = o
        end
        INK.finish()
        for _, sg in ipairs(fallsegs) do
          local Sx = spine_of(sg)
          local blaze = {}
          for _, p in ipairs(Sx) do if p.u > 0.16 and p.u < 0.54 then blaze[#blaze + 1] = { p.x, p.y } end end
          if #blaze > 2 then
            local bs = { { blaze[1], blaze[1], blaze[#blaze], blaze[#blaze] } }
            local bo = B.outline(spine_of(bs), function(u) return fs * 0.11 * sin(pi * u) ^ 0.8 end)
            W:fill(W:poly(bo, true), sc, sa)
          end
          local vv = {}
          for _, p in ipairs(Sx) do if p.u > 0.45 and p.u < 0.90 then vv[#vv + 1] = { p.x, p.y } end end
          if #vv > 2 then W:stroke(W:poly(vv, false), U.hanga(ctx) and ctx.palette.color("ai") or ctx.palette.color("sumi-noir"), 0.35, 0.45) end
        end
      else
        local o, sg = iris_petal(ctx, px, py, up, fs * 0.8, fs * 0.22, 0)
        local tip = sg[1][4]
        INK.glaze_petal(R, o, px, py, tip[1], tip[2], fs * 0.22, {
          tone = R.range(0.38, 0.52), alpha = min(0.96, pa), pool = 0.30, lift = 1.20, vein_color = rimc,
        })
        INK.finish()
        fpts[#fpts + 1] = o
      end
      local fb = pts_bb(fpts, 0.6)
      if fb then U.rec(ctx, "iris-flower", fb); bb = union(bb, fb) end
    end
  end
  return bb, { kinds = { "iris-leaf", "iris-stem", "iris-flower", "iris-earth" }, perch = {} }
end

---------------------------------------------------------------- WISTERIA
--- Wisteria (fuji): a wavy dry-brush vine (kind vine, may enter from the
--- region edge with a fade), a twining second vine, pinnate leaves, and long,
--- full pendant racemes: open purple florets at the top fading through pale
--- lilac to green buds at the tip, drawn back to front as overlapping dabs.
--- spec.size = vine length, spec.droop = longest raceme, spec.racemes.
function M.wisteria(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local Lv = spec.size or 400
  local a = spec.angle or 0
  local dx, dy = cos(a), sin(a)
  local nx, ny = -dy, dx
  local droop = spec.droop or Lv * 0.42
  local pts = { { spec.x, spec.y } }
  local nseg = 8
  local amp = Lv * 0.035
  local ph = R.range(0, TAU)
  for i = 1, nseg do
    local t = i / nseg
    local off0 = amp * sin(ph + t * 2.6 * pi) + R.sym(amp * 0.3)
    local placed = false
    for _, f in ipairs({ 1, 0.5, 0, -0.5, -1 }) do
      local off = off0 * f
      local x, y = spec.x + dx * Lv * t + nx * off, spec.y + dy * Lv * t + ny * off
      if U.free(ctx, x, y, 6) then pts[#pts + 1] = { x, y }; placed = true; break end
    end
    if not placed and i > 1 then break end
  end
  if #pts < 3 then return nil, { perch = {} } end
  local vsegs = B.chain(pts, 1)
  local vw = spec.width or max(2.4, Lv * 0.0095)
  local vc, va = ink(ctx, "vine", 0)
  local S = spine_of(vsegs)
  local vwfn = function(u) return vw * (1 - 0.7 * u) end
  local vout = B.outline(S, vwfn)
  local bb
  W:layer(20)
  local fg = base_fade(ctx, spec.x, spec.y, a, spec.fade or 60)
  with_fade(W, fg, function()
    if not U.hanga(ctx) then
      B.dry(ctx, vsegs, { w = vw, profile = function(u) return 1 - 0.7 * u end, rgb = vc, alpha = va, dryness = 0.3, bristles = 6, under = 0.45 })
    else
      W:fill(W:poly(vout, true), vc, va)
      W:clip(W:poly(vout, true))
      W:stroke(W:poly(vout, true), ctx.palette.color("sumi-dark"), vw * 0.3, 0.25, { blend = "multiply" })
      W:unclip()
    end
  end)
  local vbb = U.bbox_pts(vout, 1)
  U.rec(ctx, "wisteria-vine", vbb); bb = union(bb, vbb)
  -- twining vine starting ON the main vine
  local tw = {}
  for i = 2, #pts do
    local p = pts[i]
    local off = amp * 0.8 * sin(ph + 1.7 + i * 1.3)
    tw[#tw + 1] = { p[1] + nx * off, p[2] + ny * off }
  end
  local okpts = { { pts[2][1], pts[2][2] } }
  for i = 2, #tw do local p = tw[i]; if U.free(ctx, p[1], p[2], 3) then okpts[#okpts + 1] = p else break end end
  if #okpts >= 3 then
    local o2 = B.outline(spine_of(B.chain(okpts, 1)), function(u) return vw * 0.45 * (1 - 0.7 * u) end)
    W:fill(W:poly(o2, true), vc, va * 0.85)
    local b2 = U.bbox_pts(o2, 0.5); U.rec(ctx, "wisteria-vine", b2); bb = union(bb, b2)
  end
  -- pinnate leaves (behind racemes)
  local wc, wa = ink(ctx, "wleaf", 0)
  local nleaf = spec.leaves or 4
  W:layer(30)
  for k = 1, nleaf do
    local t = (k - 0.5) / nleaf * 0.85 + R.sym(0.05)
    local px, py, tx, ty = spine_eval(vsegs, max(0.05, min(0.95, t)))
    local la = atan2(ty, tx) + (R.chance(0.5) and 1 or -1) * R.range(0.4, 0.9)
    local Lr = droop * R.range(0.35, 0.5)
    local lb = R.sym(0.2)
    local rs, RS = fit_stroke(ctx, function(L) return leaf_seg(px, py, la, L, lb, 0.15) end, Lr, Lr * 0.4,
      function(L) return function() return L * 0.28 end end)
    if rs then
      local parts, outs = {}, {}
      local ro = B.outline(RS, function(u) return 0.8 * (1 - 0.6 * u) end)
      parts[#parts + 1] = W:poly(ro, true); outs[#outs + 1] = ro
      local np = R.int(4, 6)
      for j = 1, np do
        local tt = 0.2 + 0.8 * (j - 1) / np
        local qx, qy, qtx, qty = spine_eval(rs, tt)
        local qa = atan2(qty, qtx)
        local ll = Lr * 0.24 * (1 - 0.3 * tt)
        for sd = -1, 1, 2 do
          local s = leaf_seg(qx, qy, qa + sd * 0.95, ll, sd * 0.1, 0.05)
          local tip = s[1][4]
          if U.free(ctx, tip[1], tip[2], ll * 0.2 + 1) then
            local o = B.outline(spine_of(s), function(u) return ll * 0.36 * U.prof.leaflet(u) end)
            parts[#parts + 1] = W:poly(o, true); outs[#outs + 1] = o
          end
        end
      end
      local ex, ey, etx, ety = spine_eval(rs, 1)
      local s = leaf_seg(ex, ey, atan2(ety, etx), Lr * 0.22, 0, 0.04)
      if fits_S(ctx, spine_of(s), function() return 1 end) then
        local o = B.outline(spine_of(s), function(u) return Lr * 0.08 * U.prof.leaflet(u) end)
        parts[#parts + 1] = W:poly(o, true); outs[#outs + 1] = o
      end
      W:fill(W:join(parts), wc, wa)
      local lbb = pts_bb(outs, 0.5); U.rec(ctx, "wisteria-leaf", lbb); bb = union(bb, lbb)
    end
  end
  -- racemes: long and full
  local nr = spec.racemes or R.int(6, 9)
  local rc = ink(ctx, "raceme", 0)
  local tc = ink(ctx, "raceme_tip", 0)
  local bc = ink(ctx, "raceme_bud", 0)
  local deep = mix(rc, ctx.palette.color("ai"), 0.25)
  local fsz0 = spec.floret or clamp(droop * 0.035, 2.6, 5.5)
  local slots = {}
  for k = 1, nr do slots[k] = (k - 0.5) / nr * 0.92 + R.sym(0.035) end
  for k = 1, nr do
    local t = slots[k]
    local px, py = spine_eval(vsegs, max(0.04, min(0.97, t)))
    local Lr = droop * R.range(0.55, 1.0) * ((k % 3 == 0) and 0.75 or 1)
    local sway = R.sym(0.25)
    local fsz = fsz0 * R.range(0.9, 1.1)
    local segs, RS, _, Lfit = fit_stroke(ctx, function(L)
      return { { { px, py }, { px + sway * L * 0.1, py - L * 0.3 }, { px + sway * L * 0.45, py - L * 0.7 }, { px + sway * L * 0.5, py - L } } }
    end, Lr, Lr * 0.35, function(L) return function(u) return 2 * max(fsz * 2.2, L * 0.12) * (1 - 0.65 * u) + 2 end end, 0.05)
    if segs then
      W:layer(39)
      local ao = B.outline(RS, function(u) return 0.7 * (1 - 0.5 * u) end)
      W:fill(W:poly(ao, true), vc, va * 0.8)
      local nfl = max(8, floor(Lfit / (fsz * 0.55)))
      local fl = {}
      for j = 1, nfl do
        local u = 0.04 + 0.96 * (j - 1) / max(1, nfl - 1)
        local qx, qy, qtx, qty = spine_eval(segs, u)
        local hw = max(fsz * 1.5, Lfit * 0.11) * (1 - 0.68 * u) * (0.8 + 0.2 * sin(j * 2.3))
        local sd = (j % 2 == 0) and 1 or -1
        local off = hw * R.range(0.1, 0.9) * sd
        local cx, cy = qx - qty * off, qy + qtx * off
        local r = fsz * (1 - 0.55 * u) * R.range(0.85, 1.15) + 0.4
        fl[#fl + 1] = { x = cx, y = cy, r = r, u = u, sd = sd }
      end
      -- back to front: lower florets first so the upper (older, open) ones overlap
      table.sort(fl, function(p, q) return p.u > q.u end)
      local fpts = {}
      W:layer(40)
      local hanga = U.hanga(ctx)
      INK.begin(W, rc, { accent = ctx.palette.color("yamabuki"), chroma = hanga and 1.22 or 0.35 })
      INK.detail = 0.7
      for _, f in ipairs(fl) do
        if f.u > 0.85 then
          local p = U.ellipse_pts(f.x, f.y, f.r * 0.75, f.r * 0.55, -pi / 2 + R.sym(0.4), 10)
          INK.glaze_petal(R, p, f.x, f.y + f.r * 0.5, f.x, f.y - f.r * 0.6, f.r * 0.55, {
            tone = R.range(0.54, 0.68), alpha = 0.92, heart = false, streaks = 3, vein = false,
          })
          fpts[#fpts + 1] = p
        else
          -- standard banner petal (round, luminous centre, violet-lilac gradient) + darker keel below
          local ang = f.sd * 0.5 + R.sym(0.4)
          local p = U.ellipse_pts(f.x, f.y, f.r * 1.05, f.r * 0.82, ang, 14, 0.06, R)
          local t_ban = clamp(0.42 + 0.42 * f.u + R.sym(0.05), 0.36, 0.86)
          INK.glaze_petal(R, p, f.x, f.y - f.r * 0.65, f.x, f.y + f.r * 0.85, f.r * 0.85, {
            tone = t_ban, alpha = 0.92, heart = true, lift = 1.28, streaks = 5, vein = false,
          })
          local kx, ky = f.x + f.sd * f.r * 0.25, f.y - f.r * 0.45
          local kp = U.ellipse_pts(kx, ky, f.r * 0.52, f.r * 0.36, ang, 10)
          INK.glaze_petal(R, kp, f.x, f.y, kx, ky - f.r * 0.3, f.r * 0.40, {
            tone = clamp(t_ban - 0.20, 0.18, 0.64), alpha = 0.88, heart = false, streaks = 3, vein = false,
          })
          if f.u < 0.65 then
            W:fill(W:circle(f.x - f.sd * f.r * 0.14, f.y + f.r * 0.14, f.r * 0.22), ctx.palette.color("yamabuki"), 0.68)
          end
          fpts[#fpts + 1] = p
        end
      end
      INK.finish()
      local rb = union(pts_bb(fpts, 0.5), U.bbox_pts(ao, 0.5))
      U.rec(ctx, "wisteria-raceme", rb); bb = union(bb, rb)
    end
  end
  return bb, { kinds = { "wisteria-vine", "wisteria-leaf", "wisteria-raceme" }, perch = {} }
end

---------------------------------------------------------------- NARCISSUS
--- Narcissus (suisen): arching blue-green straps with outlines and twists,
--- scapes with a papery spathe and an umbel of white six-tepal flowers with
--- yellow cups. spec.size = leaf length, spec.leaves, spec.scapes, spec.flowers.
function M.narcissus(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local H = spec.size or 200
  local a0 = spec.angle or pi / 2
  local nl = spec.leaves or 6
  local w0 = spec.width or H * 0.034
  local bb
  if spec.ground ~= false then bb = union(bb, M.earth(ctx, spec.x, spec.y + 1, w0 * nl * 0.9, "narcissus")) end
  local fc, fa = ink(ctx, "strap", 0)
  local lc, la = ink(ctx, "strap_line", 0)
  local outlines = {}
  for i = 1, nl do
    local s = (i - (nl + 1) / 2) / nl
    local a = a0 - s * 0.9 + R.sym(0.1)
    local L = H * R.range(0.7, 1.0) * (1 - 0.3 * abs(s))
    local b = -s * R.range(0.5, 1.0) + R.sym(0.15)
    local g = abs(s) * R.range(0.5, 0.9)
    local x0 = spec.x + s * w0 * 2.0
    local w = w0 * R.range(0.85, 1.1)
    local tu, tk = R.range(0.35, 0.7), R.chance(0.6) and R.range(0.35, 0.6) or 0
    local function twist(u) return 1 - tk * math.exp(-((u - tu) / 0.09) ^ 2) end
    local segs, S, wfn = fit_stroke(ctx, function(LL) return leaf_seg(x0, spec.y, a, LL, b, g) end, L, L * 0.4,
      function() return function(u) return w * U.prof.strap(u) * twist(u) end end, 0.0)
    if segs then
      outlines[#outlines + 1] = { out = outline_of(ctx, S, wfn, 0.025), S = S, wfn = wfn, depth = (i % 2 == 0) and 0.4 or 0 }
    end
  end
  table.sort(outlines, function(p, q) return p.depth > q.depth end)
  W:layer(30)
  local ai = ctx.palette.color("ai")
  for _, o in ipairs(outlines) do
    local path = W:poly(o.out, true)
    if U.hanga(ctx) then
      W:fill(path, o.depth > 0 and ai or fc, fa)
      Wsh.rim(ctx, o.out, { rgb = ai, strength = 0.22, width = 1.4 })
    else
      W:fill(path, U.paper(ctx), 1)
      W:fill(path, fc, fa * (o.depth > 0 and 0.6 or 1))
    end
    W:stroke(path, lc, U.hanga(ctx) and 0.45 or 0.7, la)
    local v = {}
    for _, p in ipairs(o.S) do if p.u > 0.08 and p.u < 0.8 then v[#v + 1] = { p.x + p.ty * o.wfn(p.u) * 0.12, p.y - p.tx * o.wfn(p.u) * 0.12 } end end
    if #v > 3 then W:stroke(W:poly(v, false), lc, 0.4, la * 0.6) end
    local b = U.bbox_pts(o.out, 0.8); U.rec(ctx, "narcissus-leaf", b); bb = union(bb, b)
  end
  local nsc = spec.scapes or 1
  for _ = 1, nsc do
    local a = a0 + R.sym(0.15)
    local L = H * R.range(0.8, 1.0)
    local fs = spec.flower or H * 0.075
    local sw = max(1, w0 * 0.18)
    local sx, sb = spec.x + R.sym(w0 * 0.5), R.sym(0.15)
    local segs = fit_stroke_dirs(ctx, function(aa, LL) return leaf_seg(sx, spec.y, aa, LL, sb * (aa == a and 1 or 0), 0) end,
      { a, (a + a0) / 2, a0 }, L, L * 0.4, function() return function() return sw end end, 0.0,
      function(u) return u > 0.93 and 2 * fs * 2.6 or sw end)
    if segs then
      W:layer(31)
      local o = outline_of(ctx, spine_of(segs), function(u) return sw * (1 - 0.25 * u) end, 0)
      W:fill(W:poly(o, true), U.hanga(ctx) and ctx.palette.color("asagi") or fc, U.hanga(ctx) and 0.9 or min(1, fa * 1.6))
      W:stroke(W:poly(o, true), lc, 0.4, la)
      local ux, uy, utx, uty = spine_eval(segs, 1)
      local up = atan2(uty, utx)
      local sp = leaf_seg(ux, uy, up + 0.5, fs * 1.4, -0.25, 0.1)
      local spo = B.outline(spine_of(sp), function(u) return fs * 0.35 * U.prof.leaflet(u) end)
      local sc, sa = ink(ctx, "spathe", 0)
      local sbb = U.bbox_pts(o, 0.5)
      if U.free_pts(ctx, spo, 0.5) then W:fill(W:poly(spo, true), sc, sa); sbb = union(sbb, U.bbox_pts(spo, 0.5)) end
      U.rec(ctx, "narcissus-stem", sbb); bb = union(bb, sbb)
      local nfl = spec.flowers or R.int(3, 4)
      local heads = {}
      local peds = {}
      for k = 1, nfl do
        local fdir = up + (k - (nfl + 1) / 2) * 0.75 + R.sym(0.15)
        local pl = fs * R.range(1.3, 2.4)
        local pb = R.sym(0.3)
        local ps, ex, ey
        repeat
          ps = leaf_seg(ux, uy, fdir, pl, pb, 0.15)
          ex, ey = ps[1][4][1], ps[1][4][2]
          if U.free(ctx, ex, ey, fs * 1.15) then break end
          pl = pl * 0.8
        until pl < fs * 0.5
        if pl >= fs * 0.5 then
          peds[#peds + 1] = W:poly(B.outline(spine_of(ps), function() return 0.8 end), true)
          heads[#heads + 1] = { ex, ey, fdir }
        end
      end
      if #peds > 0 then W:fill(W:join(peds), U.hanga(ctx) and ctx.palette.color("asagi") or ctx.palette.color("sumi-noir"), 0.7) end
      local tc, ta = ink(ctx, "tepal", 0)
      local tlc, tla = ink(ctx, "tepal_line", 0)
      local cc, ca = ink(ctx, "cup", 0)
      local clc, cla = ink(ctx, "cup_line", 0)
      W:layer(40)
      for _, h in ipairs(heads) do
        local ex, ey = h[1], h[2]
        local rr = R.range(0, TAU)
        local tilt = R.range(0.45, 1.0)
        local tep, tp = {}, {}
        INK.begin(W, { 0.99, 0.97, 0.92 }, { accent = cc, chroma = 0.32 })
        INK.detail = 1
        for j = 0, 5 do
          local ang = rr + j * pi / 3 + R.sym(0.1)
          local tl = fs * R.range(0.85, 1.05)
          local tx_, ty_ = cos(ang), sin(ang) * tilt
          local l = sqrt(tx_ * tx_ + ty_ * ty_)
          local s = leaf_seg(ex, ey, atan2(ty_, tx_), tl * l, R.sym(0.15), 0)
          local o2 = B.outline(spine_of(s), function(u) return fs * 0.46 * sin(pi * min(1, u) ^ 0.65) ^ 0.75 end)
          local tip = s[1][4]
          INK.glaze_petal(R, o2, ex, ey, tip[1], tip[2], fs * 0.44, {
            tone = R.range(0.80, 0.92), alpha = ta, pool = 0.20, lift = 1.45,
          })
          tep[#tep + 1] = W:poly(o2, true); tp[#tp + 1] = o2
        end
        INK.finish()
        for _, t in ipairs(tep) do W:stroke(t, tlc, 0.32, tla * 0.85) end
        local cup = U.ellipse_pts(ex, ey, fs * 0.32, fs * 0.32 * tilt, rr, 18, 0.05, R)
        INK.begin(W, cc, { accent = clc, chroma = 1.25 })
        INK.glaze_petal(R, cup, ex, ey - fs * 0.25 * tilt, ex, ey + fs * 0.28 * tilt, fs * 0.32, {
          tone = R.range(0.56, 0.70), alpha = ca, pool = 0.28, lift = 1.25, streaks = 6, vein = false,
        })
        INK.finish()
        W:stroke(W:poly(cup, true), clc, 0.6, cla)
        W:fill(W:poly(U.ellipse_pts(ex, ey, fs * 0.13, fs * 0.13 * tilt, rr, 12), true), ctx.palette.color("ume-centre"), 0.65)
        local hb = pts_bb(tp, 0.6); U.rec(ctx, "narcissus-flower", hb); bb = union(bb, hb)
      end
    end
  end
  return bb, { kinds = { "narcissus-leaf", "narcissus-stem", "narcissus-flower", "narcissus-earth" }, perch = {} }
end

---------------------------------------------------------------- PINE
local function pine_bark(ctx, S, wfn, out, rgb, alpha)
  local R = ctx.rng
  local W = ctx.pdf
  W:clip(W:poly(out, true))
  local parts = {}
  for _ = 1, 16 do
    local f = R.noise(2)
    local base = R.range(-0.46, 0.46)
    local u0 = R.range(0, 0.82)
    local u1 = min(1, u0 + R.range(0.08, 0.32))
    local bw = R.range(0.06, 0.15)
    local left, right = {}, {}
    for _, p in ipairs(S) do
      if p.u >= u0 and p.u <= u1 then
        local w = wfn(p.u)
        local loc = (p.u - u0) / max(1e-6, u1 - u0)
        local h = w * bw * 0.5 * sin(pi * loc) ^ 0.7
        local off = (base + 0.14 * f(p.u * 4)) * w
        local cx, cy = p.x - p.ty * off, p.y + p.tx * off
        left[#left + 1] = { cx - p.ty * h, cy + p.tx * h }
        right[#right + 1] = { cx + p.ty * h, cy - p.tx * h }
      end
    end
    if #left > 3 then
      for k = #right, 1, -1 do left[#left + 1] = right[k] end
      parts[#parts + 1] = W:poly(left, true)
    end
  end
  if #parts > 0 then W:fill(W:join(parts), rgb, min(0.92, alpha * 0.72)) end
  local sp = {}
  local L = S[#S].s
  local n = floor(L / max(1.6, wfn(0.3) * 0.38))
  for _ = 1, n do
    local u = R.range(0.02, 0.94)
    local i = max(1, min(#S, floor(u * (#S - 1)) + 1))
    local p = S[i]
    local w = wfn(p.u)
    local off = R.sym(0.38) * w
    local cx, cy = p.x - p.ty * off, p.y + p.tx * off
    local ra, rb = w * R.range(0.18, 0.30), w * R.range(0.06, 0.11)
    local a0 = -pi / 2 - R.range(0.15, 0.55)
    local a1 = pi / 2 + R.range(0.15, 0.55)
    local pts = {}
    for k = 0, 12 do
      local t = a0 + (a1 - a0) * k / 12
      local lx, ly = cos(t) * rb, sin(t) * ra
      pts[#pts + 1] = { cx + p.tx * lx - p.ty * ly, cy + p.ty * lx + p.tx * ly }
    end
    local o2 = B.outline(B.spine(B.chain(pts, 1), { step = 0.5 }), function(uu) return max(0.35, w * 0.068) * B.profile.both(uu) end)
    sp[#sp + 1] = W:poly(o2, true)
  end
  if #sp > 0 then W:fill(W:join(sp), rgb, min(0.92, alpha * 0.68)) end
  W:unclip()
end

--- Pine (matsu): craggy tapered trunk (kind trunk) with plate-bark marks and
--- graded rims, tiered limbs, needle half-wheels over cloud-like pad washes.
--- spec.size = trunk length, spec.limbs (2..4), spec.pad = pad radius.
function M.pine(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local Lt = spec.size or 300
  local a = spec.angle or pi / 2
  local reg = ctx.region
  local rw = reg.x1 - reg.x0
  local w0 = spec.width or min(Lt * 0.058, rw * 0.16)
  local rad = min(spec.pad or Lt * 0.115, rw * 0.42)
  local Ln = rad * 0.58
  local pts = { { spec.x, spec.y } }
  local x, y = spec.x, spec.y
  local nseg = 7
  local turn = R.chance(0.5) and 1 or -1
  local entering = not U.free(ctx, x, y, 0)
  for _ = 1, nseg do
    local step = Lt / nseg * R.range(0.85, 1.15)
    local dh = turn * R.range(0.16, 0.52)
    if R.chance(0.7) then turn = -turn end
    local ok = false
    for _, k in ipairs({ 1, 0, -1, 2, -2 }) do
      local hh = a + dh * k
      local nx_, ny_ = x + cos(hh) * step, y + sin(hh) * step
      local good
      if entering then good = U.clear(ctx, nx_, ny_, w0) else good = U.free(ctx, nx_, ny_, w0 * 0.6 + 2) end
      if good then x, y = nx_, ny_; ok = true; break end
    end
    if not ok then break end
    pts[#pts + 1] = { x, y }
    if entering and U.free(ctx, x, y, w0 * 0.6 + 2) then entering = false end
  end
  if #pts < 3 or entering then return nil, { perch = {} } end
  local tsegs = B.chain(pts, 1.0)
  local S = spine_of(tsegs)
  local bulge = R.noise(2)
  local wfn = function(u)
    local tip = u > 0.86 and (1 - 0.75 * ((u - 0.86) / 0.14) ^ 1.5) or 1
    return w0 * (1 - 0.70 * u ^ 0.75) * (1 + 0.18 * bulge(u * 6)) * tip
  end
  local tc, ta = ink(ctx, "trunk", 0)
  local wc, wa = ink(ctx, "trunk_wash", 0)
  local out = outline_of(ctx, S, wfn, 0.10)
  local nlimb = spec.limbs or 3
  local side = R.chance(0.5) and 1 or -1
  local limbs = {}
  for k = 1, nlimb do
    local t = 0.30 + 0.58 * (k - 1) / max(1, nlimb - 1) + R.sym(0.03)
    local px, py = spine_eval(tsegs, min(0.94, t))
    local lw = wfn(t) * 0.66
    local lbulge = R.noise(2)
    local lwfn = function(u)
      return lw * (1 - 0.60 * u) * (1 + 0.18 * lbulge(u * 5)) * (u > 0.82 and (1 - 0.78 * ((u - 0.82) / 0.18) ^ 1.3) or 1)
    end
    for _, try_s in ipairs({ side, -side }) do
      local la = (try_s > 0 and 0 or pi) + R.range(-0.12, 0.22) * try_s
      local L = Lt * R.range(0.38, 0.54) * (1.18 - 0.38 * t)
      local dip = R.range(0.15, 0.24)
      local rise = R.range(0.06, 0.14)
      local segs, LS, _, Lf = fit_stroke(ctx, function(LL)
        local dx, dy = cos(la), sin(la)
        local e1x, e1y = px + dx * LL * 0.44, py + dy * LL * 0.44 - LL * dip
        local e2x, e2y = px + dx * LL * 0.74, py + dy * LL * 0.74 + LL * rise
        local e3x, e3y = px + dx * LL,        py + dy * LL + LL * (rise + 0.05)
        return {
          { { px, py }, { px + dx * LL * 0.18, py + dy * LL * 0.18 - LL * dip * 0.35 },
            { px + dx * LL * 0.32, py + dy * LL * 0.32 - LL * dip * 0.88 }, { e1x, e1y } },
          { { e1x, e1y }, { px + dx * LL * 0.54, py + dy * LL * 0.54 - LL * dip * 0.45 },
            { px + dx * LL * 0.64, py + dy * LL * 0.64 + LL * rise * 0.55 }, { e2x, e2y } },
          { { e2x, e2y }, { px + dx * LL * 0.83, py + dy * LL * 0.83 + LL * rise * 0.85 },
            { px + dx * LL * 0.92, py + dy * LL * 0.92 + LL * (rise + 0.03) }, { e3x, e3y } },
        }
      end, L, L * 0.28, function() return lwfn end, 0.12,
        function() return 2 * (Ln + 2) end)
      if segs then
        local lo = outline_of(ctx, LS, lwfn, 0.07)
        limbs[#limbs + 1] = { segs = segs, LS = LS, wfn = lwfn, out = lo, L = Lf, dir = la }
        -- Sprout a crooked secondary sub-branch from the elbow (u = 0.44)
        local ex, ey = spine_eval(segs, 0.42)
        local sw = lwfn(0.42) * 0.64
        local swfn = function(u) return sw * (1 - 0.65 * u) end
        local sla = la - try_s * R.range(0.32, 0.52)
        local sL = Lf * R.range(0.36, 0.48)
        local ssegs, sLS, _, sLf = fit_stroke(ctx, function(LL)
          local sdx, sdy = cos(sla), sin(sla)
          return {
            { { ex, ey }, { ex + sdx * LL * 0.35, ey + sdy * LL * 0.35 - LL * 0.08 },
              { ex + sdx * LL * 0.70, ey + sdy * LL * 0.70 + LL * 0.04 },
              { ex + sdx * LL, ey + sdy * LL + LL * 0.08 } },
          }
        end, sL, sL * 0.35, function() return swfn end, 0.10, function() return 2 * (Ln + 2) end)
        if ssegs then
          limbs[#limbs + 1] = { segs = ssegs, LS = sLS, wfn = swfn, out = outline_of(ctx, sLS, swfn, 0.06), L = sLf, dir = sla, is_sub = true }
        end
        side = -try_s
        break
      end
    end
  end
  local hubs, twigs = {}, {}
  -- Distinct umbrella clusters of semicircular matsuba fans at elbow & terminal forks,
  -- leaving exposed gnarled bark clearly visible between fan clusters.
  local function add_fan_cluster(px, py, nfans, spread_x)
    for m = 1, nfans do
      local f = (nfans == 1) and 0 or ((m - 1) / (nfans - 1) - 0.5)
      local ta_ = pi / 2 - f * 0.85 + R.sym(0.12)
      local tl = R.range(7, 14) * (1 - 0.25 * abs(f))
      local hx_, hy_ = px + f * spread_x + cos(ta_) * tl, py + sin(ta_) * tl * 0.65
      if U.free(ctx, hx_, hy_, Ln + 1.5) then
        twigs[#twigs + 1] = { { px, py }, { hx_, hy_ } }
        hubs[#hubs + 1] = { hx_, hy_, pi / 2 - f * 0.22 + R.sym(0.14) }
      end
    end
  end
  for _, lb in ipairs(limbs) do
    if lb.is_sub then
      local px, py = spine_eval(lb.segs, 0.94)
      add_fan_cluster(px, py, 2, Ln * 0.65)
    else
      -- Elbow cluster (u = 0.38) and terminal umbrella cluster (u = 0.86, 0.98) with bare bark between
      local ex, ey = spine_eval(lb.segs, 0.38)
      add_fan_cluster(ex, ey, 2, Ln * 0.62)
      local tx1, ty1 = spine_eval(lb.segs, 0.84)
      add_fan_cluster(tx1, ty1, 2, Ln * 0.70)
      local tx2, ty2 = spine_eval(lb.segs, 0.98)
      add_fan_cluster(tx2, ty2, 3, Ln * 0.85)
    end
  end
  -- Crown umbrella canopy at the top of the trunk
  for _, u in ipairs({ 0.86, 0.94, 1.0 }) do
    local px, py = spine_eval(tsegs, u)
    add_fan_cluster(px, py, u > 0.95 and 3 or 2, Ln * 0.82)
  end
  local bb
  if spec.ground then
    bb = union(bb, M.earth(ctx, spec.x, spec.y + 3, max(28, w0 * 3.8), "pine", { w = w0 * 1.4 }))
  end
  -- 1) pad washes (flattened irregular watercolour blots, under everything)
  local pc, pa = ink(ctx, "pad", 0)
  local nc, na = ink(ctx, "needle", 0)
  W:layer(12)
  for _, hb in ipairs(hubs) do
    local cx, cy = hb[1], hb[2] + Ln * 0.36
    if U.free(ctx, cx, cy, Ln * 1.25) then
      local b = Wsh.soft(ctx, cx, cy, Ln * 1.05, Ln * 0.55, { rgb = pc, alpha = min(0.55, pa * 2.4) })
      if b then U.rec(ctx, "pine-pad", b); bb = union(bb, b) end
    end
  end
  -- 2) trunk, limbs and twigs as one union with gnarled bark & dry-brush
  W:layer(20)
  local un = { W:poly(out, true) }
  for _, lb in ipairs(limbs) do un[#un + 1] = W:poly(lb.out, true) end
  local twouts = {}
  for _, t in ipairs(twigs) do
    local s = { { t[1], { t[1][1] + (t[2][1] - t[1][1]) * 0.33, t[1][2] + (t[2][2] - t[1][2]) * 0.33 },
      { t[1][1] + (t[2][1] - t[1][1]) * 0.66, t[1][2] + (t[2][2] - t[1][2]) * 0.66 }, t[2] } }
    local o = B.outline(B.spine(s, { step = 0.5 }), function(u) return 1.5 * (1 - 0.42 * u) end)
    un[#un + 1] = W:poly(o, true); twouts[#twouts + 1] = o
  end
  local up = W:join(un)
  local fg = base_fade(ctx, spec.x, spec.y, a, spec.fade or 90)
  if not fg and not spec.ground and W.fade_axial then
    local flen = spec.fade or min(85, Lt * 0.22)
    local big = { x0 = spec.x - 2 * Lt - 200, y0 = spec.y - 2 * Lt - 200, x1 = spec.x + 2 * Lt + 200, y1 = spec.y + 2 * Lt + 200 }
    fg = W:fade_axial(spec.x, spec.y, spec.x + cos(a) * flen, spec.y + sin(a) * flen, 0.0, 1.0, big)
  end
  with_fade(W, fg, function()
    W:fill(up, wc, min(0.95, wa * 1.4))
    W:fill(up, tc, min(0.95, ta * 0.68))
    local tp = un[1]
    W:clip(tp)
    for k, f in ipairs({ 0.44, 0.28, 0.16, 0.07 }) do W:stroke(tp, tc, w0 * f, ta * (0.12 + 0.05 * k), { blend = "multiply" }) end
    W:unclip()
    local noir = ctx.palette.color("sumi-noir")
    B.dry(ctx, tsegs, { w = w0, profile = function(u) return wfn(u) / w0 end,
      rgb = noir, alpha = 0.55, dryness = 0.52, bristles = 7, under = 0.08 })
    if #limbs > 0 then
      local lp = {}
      for k = 1, #limbs do lp[k] = un[k + 1] end
      local big = W:rect(-3000, -3000, 4000, 4000)
      W:clip(W:join(big, tp), true)
      W:clip(W:join(lp))
      for k, f in ipairs({ 0.28, 0.16, 0.08 }) do W:stroke(W:join(lp), tc, w0 * f, ta * (0.14 + 0.06 * k), { blend = "multiply" }) end
      W:unclip()
      W:unclip()
    end
    local _, ba = ink(ctx, "bark", 0)
    pine_bark(ctx, S, wfn, out, noir, ba * 1.65)
    for _, lb in ipairs(limbs) do
      pine_bark(ctx, lb.LS, lb.wfn, lb.out, noir, ba * 1.45)
    end
  end)
  local tbb = U.bbox_pts(out, 1)
  U.rec(ctx, "pine-trunk", tbb); bb = union(bb, tbb)
  for _, lb in ipairs(limbs) do local b = U.bbox_pts(lb.out, 1); U.rec(ctx, "pine-branch", b); bb = union(bb, b) end
  -- 3) needles: layered back/front semicircular matsu-ba fans + glazed fan wash + basal sheaths
  local back_needles, front_needles, sheaths, nouts = {}, {}, {}, {}
  local fan_washes = {}
  for _, hb in ipairs(hubs) do
    local span = R.range(2.6, 3.2)
    local Lh = Ln * R.range(0.88, 1.12)
    local hpts = {}
    -- back needle row (slightly shorter, denser mass)
    local nnb = R.int(12, 16)
    for k = 1, nnb do
      local f = (k - 1) / (nnb - 1)
      local na_ = hb[3] + span * 0.92 * (f - 0.5) + R.sym(0.05)
      local L = Lh * R.range(0.68, 0.92) * (0.72 + 0.28 * sin(pi * f))
      local ex, ey = hb[1] + cos(na_) * L, hb[2] + sin(na_) * L
      local s = { { hb[1], hb[2] }, { hb[1] + cos(na_) * L * 0.33, hb[2] + sin(na_) * L * 0.33 },
        { hb[1] + cos(na_) * L * 0.66, hb[2] + sin(na_) * L * 0.66 }, { ex, ey } }
      local o = B.outline(B.spine({ s }, { step = max(0.8, L / 7) }), function(u) return 0.88 * U.prof.needle(u) end)
      back_needles[#back_needles + 1] = W:poly(o, true)
    end
    -- front needle row (crisp radiating needles)
    local nn = R.int(18, 25)
    for k = 1, nn do
      local f = (k - 1) / (nn - 1)
      local na_ = hb[3] + span * (f - 0.5) + R.sym(0.045)
      local L = Lh * R.range(0.80, 1.05) * (0.72 + 0.28 * sin(pi * f))
      local ex, ey = hb[1] + cos(na_) * L, hb[2] + sin(na_) * L
      local s = { { hb[1], hb[2] }, { hb[1] + cos(na_) * L * 0.33, hb[2] + sin(na_) * L * 0.33 },
        { hb[1] + cos(na_) * L * 0.66, hb[2] + sin(na_) * L * 0.66 }, { ex, ey } }
      local o = B.outline(B.spine({ s }, { step = max(0.8, L / 7) }), function(u) return 0.78 * U.prof.needle(u) end)
      front_needles[#front_needles + 1] = W:poly(o, true)
      hpts[#hpts + 1] = { ex, ey }
    end
    hpts[#hpts + 1] = { hb[1], hb[2] }
    nouts[#nouts + 1] = hpts
    fan_washes[#fan_washes + 1] = W:poly(hpts, true)
    sheaths[#sheaths + 1] = W:circle(hb[1], hb[2], 1.35)
  end
  W:layer(29)
  if #fan_washes > 0 then
    local fcol = U.hanga(ctx) and mix(ctx.palette.color("moegi"), nc, 0.45) or mix(nc, U.paper(ctx), 0.55)
    W:fill(W:join(fan_washes), fcol, U.hanga(ctx) and 0.22 or 0.15)
  end
  W:layer(30)
  if #back_needles > 0 then
    local bnc = U.hanga(ctx) and mix(nc, ctx.palette.color("sumi-dark"), 0.28) or mix(nc, U.paper(ctx), 0.30)
    W:fill(W:join(back_needles), bnc, na * 0.78)
  end
  if #front_needles > 0 then
    W:fill(W:join(front_needles), nc, na)
    if #sheaths > 0 then
      W:fill(W:join(sheaths), U.hanga(ctx) and ctx.palette.color("kuri") or ctx.palette.color("sumi-noir"), 0.85)
    end
    for _, h in ipairs(nouts) do local b = U.bbox_pts(h, 1); U.rec(ctx, "pine-needles", b); bb = union(bb, b) end
  end
  if #twouts > 0 then local b = pts_bb(twouts, 0.8); U.rec(ctx, "pine-twig", b); bb = union(bb, b) end
  return bb, { kinds = { "pine-trunk", "pine-branch", "pine-twig", "pine-needles", "pine-pad" }, perch = {} }
end

---------------------------------------------------------------- MAPLE (momiji)
M.MAPLE = {
  len = { 0.9, 0.5, 0.25 }, kids = { 3, 2 }, seg = { 0.05, 0.1 }, turn = { 0.1, 0.35 }, alt = 0.85,
  bias = 0.35, droop = -0.12, child_angle = { 0.5, 0.9 }, w0 = 0.022, wdecay = 0.5, wtip = 0.45, pw = 0.8,
  margin = 14, smooth = 3, maxbranches = 14, flow = 0.3, prune_depth = 0,
}
local MAPLE7 = { lens = { 0.42, 0.74, 0.92, 1.0, 0.92, 0.74, 0.42 }, spread = 1.9 }
local MAPLE5 = { lens = { 0.6, 0.9, 1.0, 0.9, 0.6 }, spread = 1.45 }

--- Palmate maple leaf outline: union of serrated lanceolate lobes from a hub
--- plus a hub disc. Returns list of CCW polygons, tips, hub point.
function M.maple_shape(R, x, y, a, Rl, nl)
  local T = nl == 5 and MAPLE5 or MAPLE7
  local n = #T.lens
  local hub = 0.16 * Rl
  local hx0, hy0 = x + cos(a) * hub, y + sin(a) * hub
  local polys, tips = {}, {}
  for i = 1, n do
    local th = a - T.spread + 2 * T.spread * (i - 1) / (n - 1) + R.sym(0.06)
    local L = T.lens[i] * Rl * R.range(0.93, 1.05)
    local Wl = 0.2 * L
    local left, right = {}, {}
    local nseg = 22
    for k = 0, nseg do
      local t = k / nseg
      local hw = Wl * sin(pi * (0.12 + 0.88 * t)) ^ 0.85
      local tooth = (t > 0.28 and t < 0.94 and k % 2 == 1) and 0.03 * L or 0
      local ax, ay = hx0 + cos(th) * L * t, hy0 + sin(th) * L * t
      local nx, ny = -sin(th), cos(th)
      left[#left + 1] = { ax + nx * (hw + tooth), ay + ny * (hw + tooth) }
      right[#right + 1] = { ax - nx * (hw + tooth), ay - ny * (hw + tooth) }
    end
    local tip = { hx0 + cos(th) * L * 1.04, hy0 + sin(th) * L * 1.04 }
    local poly = {}
    for k = 1, #left do poly[#poly + 1] = left[k] end
    poly[#poly + 1] = tip
    for k = #right, 1, -1 do poly[#poly + 1] = right[k] end
    polys[#polys + 1] = U.ccw(poly)
    tips[#tips + 1] = { tip[1], tip[2], L }
  end
  polys[#polys + 1] = U.ccw(disc_pts(hx0, hy0, Rl * 0.15, 14))
  return polys, tips, hx0, hy0
end

-- leaf colour schemes (hub colour -> tip colour), like the soft momiji washes
local function maple_scheme(ctx, R, season)
  local C = function(n) return ctx.palette.color(n) end
  local red, shu, yel, grn = C("momiji"), C("shu"), C("yamabuki"), C("moegi")
  local org = mix(shu, yel, 0.44)
  local v = R.u()
  if season == "natsu" then return mix(grn, C("matsuba"), 0.25), mix(grn, yel, 0.28) end
  if v < 0.42 then return mix(red, shu, 0.35), mix(shu, red, 0.45)
  elseif v < 0.68 then return mix(shu, yel, 0.35), mix(org, yel, 0.52)
  elseif v < 0.88 then return mix(grn, yel, 0.42), mix(shu, red, 0.38)       -- turning: green-gold heart, crimson-orange tips
  else return mix(grn, yel, 0.22), mix(grn, org, 0.36) end
end

local function maple_leaf(ctx, x, y, a, Rl, scheme, opt)
  opt = opt or {}
  local W, R = ctx.pdf, ctx.rng
  local c0, c1 = scheme[1], scheme[2]
  if opt.alpha and opt.alpha < 0.90 then
    local paper = U.paper(ctx)
    local k_fade = (1 - opt.alpha) * 0.48
    c0 = lerp(c0, paper, k_fade)
    c1 = lerp(c1, paper, k_fade)
  end
  if opt.vector then
    local polys, tips, hx0, hy0 = M.maple_shape(R, x, y, a, Rl, R.chance(0.75) and 7 or 5)
    local parts = {}
    for _, p in ipairs(polys) do parts[#parts + 1] = W:poly(p, true) end
    local path = W:join(parts)
    local pat = W:radial(hx0, hy0, 0, Rl * 1.05, { { 0, c0 }, { 0.35, mix(c0, c1, 0.4) }, { 1, c1 } })
    local bb = W:fill_pattern(path, pat, U.hanga(ctx) and 0.97 or 0.9)
    W:clip(path)
    W:stroke(path, mix(c1, ctx.palette.color("sumi-dark"), 0.35), max(0.6, Rl * 0.07), 0.22, { blend = "multiply" })
    W:unclip()
    return bb
  end
  INK.begin(W, mix(c0, c1, 0.55), { chroma = 1.25, alpha = opt.alpha })
  INK.detail = (opt.alpha and opt.alpha < 0.55) and 0.45 or 1
  INK.push()
  INK.translate(x, y)
  INK.rotate(math.deg(a) - 90)
  local sy = opt.sy or R.range(0.78, 1.0)
  INK.scale(Rl, Rl * sy)
  INK.maple_leaf(R, {
    lobes = opt.lobes or (R.chance(0.78) and 7 or 5),
    tone = R.range(0.44, 0.58),
    alpha = U.hanga(ctx) and 0.96 or 0.92,
    stops = { { 0, c0 }, { 0.42, mix(c0, c1, 0.45) }, { 1, c1 } },
    flushes = { { c1, 0.18, true }, { c0, 0.16, false } },
    vein_color = mix({ 1, 1, 1 }, ctx.palette.color("yamabuki"), 0.22),
  })
  INK.pop()
  return INK.finish()
end
M.maple_leaf = maple_leaf

--- Maple (momiji): slender twigs with petioled palmate leaves in soft graded
--- watercolour (red, orange, turning green-red), and a few falling leaves.
--- spec.leaf = leaf radius fraction of size, spec.falling = falling leaves.
function M.maple(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local size = spec.size or 260
  local Rl = clamp((spec.leaf or 0.075) * size, 11, 24) * (spec.organ_scale or 1)
  local P = {}
  for k, v in pairs(M.MAPLE) do P[k] = v end
  P.margin = Rl * 0.6
  local st = new_state(ctx, spec, "maple", P)
  local tree = (spec.engine == "walk") and grow_tree(st, P, spec) or grow_sc(st, spec, "maple")
  if #tree == 0 then return nil, { perch = {} } end
  local leaves, items = {}, {}
  local maxl = bloom_budget(st, tree, Rl * 0.78, 1.35)
  local function clear_items(x, y, r, f)
    for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.y - y) ^ 2 < ((it.r + r) * f) ^ 2 then return false end end
    return true
  end
  local function try_leaf(br, s, x, y, a, w, scale_k)
    local sk = (scale_k or 1) * R.range(0.84, 1.14)
    local pl = Rl * R.range(0.42, 0.68) * sk
    local la = a + R.sym(0.32)
    local bx, by = x + cos(a) * pl, y + sin(a) * pl
    local lr = Rl * sk
    local cx, cy = bx + cos(la) * lr * 0.5, by + sin(la) * lr * 0.5
    if #leaves < maxl and U.free(ctx, cx, cy, lr * 1.15 + 1.0) and clear_items(cx, cy, lr * 0.52, 0.62) then
      items[#items + 1] = { x = cx, y = cy, r = lr * 0.52 }
      local tier = ((br.z == -1) or R.chance(0.24)) and 1 or (R.chance(0.38) and 2 or 3)
      leaves[#leaves + 1] = { x = bx, y = by, a = la, R = lr, px = x, py = y, pa = a, pl = pl, w = w, tier = tier }
      use(br, s)
      return true
    end
    return false
  end
  for _, br in ipairs(tree) do
    if br.depth >= 1 then
      local z = br.nodes[#br.nodes]
      -- terminal leaf fan at twig tip (1 main leaf + 1-2 smaller companion leaves)
      try_leaf(br, br.L, z.x, z.y, z.a + R.sym(0.18), z.w, 1.05)
      for _, sg in ipairs({ 1, -1 }) do
        if R.chance(0.82) then try_leaf(br, br.L, z.x, z.y, z.a + sg * R.range(0.52, 0.98), z.w, R.range(0.68, 0.86)) end
      end
      local s = br.L * 0.22
      while s < br.L * 0.92 do
        local x, y, w, h = eval_at(br, s)
        for _, sg in ipairs({ 1, -1 }) do
          if try_leaf(br, s, x, y, h + sg * R.range(0.62, 1.15), w, R.range(0.88, 1.08)) and R.chance(0.55) then
            try_leaf(br, s, x, y, h + sg * R.range(0.32, 0.72), w, R.range(0.64, 0.80))
          end
        end
        s = s + Rl * R.range(1.10, 1.75)
      end
    end
  end
  tree = prune(st, tree, 0)
  local bc = branch_colors(ctx, "maple")
  local bb = tree_base(st, tree, spec)
  bb = union(bb, draw_tree(st, tree, { col = bc.col, body = bc.body, drycol = bc.drycol, dryalpha = 0.75, drymin = 3.5, dryness = 0.45 }))
  -- petioles
  local pets = {}
  local petc = mix(ctx.palette.color("momiji"), ctx.palette.color("sumi-dark"), 0.35)
  for _, lf in ipairs(leaves) do
    local x, y, a, la, pl, bx, by = lf.px, lf.py, lf.pa, lf.a, lf.pl, lf.x, lf.y
    local seg = { { x, y }, { x + cos(a) * pl * 0.45, y + sin(a) * pl * 0.45 }, { bx - cos(la) * pl * 0.3, by - sin(la) * pl * 0.3 },
      { bx + cos(la) * lf.R * 0.15, by + sin(la) * lf.R * 0.15 } }
    local wp = max(0.45, min(1.1, lf.w * 0.5))
    pets[#pets + 1] = W:poly(B.outline(B.spine({ seg }, { step = 0.8 }), function(u) return wp * (1 - 0.35 * u) end), true)
  end
  W:layer(29)
  if #pets > 0 then local pb = W:fill(W:join(pets), petc, 0.9); U.rec(ctx, "maple-petiole", pb); bb = union(bb, pb) end
  local season = spec.season or ctx.season
  table.sort(leaves, function(a, b) return (a.tier or 3) < (b.tier or 3) end)
  for _, lf in ipairs(leaves) do
    local t_lf = lf.tier or 3
    W:layer((t_lf == 1 and 18) or (t_lf == 2 and 28) or 38)
    local a_lf = (t_lf == 1 and 0.38) or (t_lf == 2 and 0.70) or nil
    local b = maple_leaf(ctx, lf.x, lf.y, lf.a, lf.R, { maple_scheme(ctx, R, season) }, { alpha = a_lf })
    if b then U.rec(ctx, "maple-leaf", b); bb = union(bb, b) end
  end
  -- falling leaves near the spray (never far away)
  local nf = spec.falling or R.int(2, 4)
  if bb and nf > 0 then
    local got = 0
    for _ = 1, 300 do
      if got >= nf then break end
      local x = R.range(bb.x0 - 0.1 * size, bb.x1 + 0.1 * size)
      local y = R.range(bb.y0 - 0.3 * size, bb.y0 + 0.4 * (bb.y1 - bb.y0))
      local rl = Rl * R.range(0.65, 0.88)
      local ok = U.free(ctx, x, y, rl * 1.25 + 1.0) and clear_items(x, y, rl, 1.3)
      if ok then
        for _, br in ipairs(tree) do
          for _, nd in ipairs(br.nodes) do if (nd.x - x) ^ 2 + (nd.y - y) ^ 2 < (Rl * 1.5) ^ 2 then ok = false; break end end
          if not ok then break end
        end
      end
      if ok then
        local a = R.range(0, TAU)
        local bx, by = x - cos(a) * rl * 0.5, y - sin(a) * rl * 0.5
        local b = maple_leaf(ctx, bx, by, a, rl, { maple_scheme(ctx, R, season) })
        local seg = { { bx - cos(a + 0.15) * rl * 0.5, by - sin(a + 0.15) * rl * 0.5 }, { bx - cos(a + 0.1) * rl * 0.3, by - sin(a + 0.1) * rl * 0.3 },
          { bx - cos(a) * rl * 0.1, by - sin(a) * rl * 0.1 }, { bx + cos(a) * rl * 0.15, by + sin(a) * rl * 0.15 } }
        local po = B.outline(B.spine({ seg }, { step = 0.6 }), function(u) return 0.35 + 0.4 * u end)
        W:fill(W:poly(po, true), petc, 0.85)
        b = union(b, U.bbox_pts(po, 0.3))
        items[#items + 1] = { x = x, y = y, r = rl }
        U.rec(ctx, "maple-leaf", b); bb = union(bb, b)
        got = got + 1
      end
    end
  end
  return bb, { perch = perches(st, tree, items, spec.perch_clear), tree = tree,
    kinds = { "maple-trunk", "maple-branch", "maple-twig", "maple-leaf", "maple-petiole" } }
end
M.momiji = M.maple

---------------------------------------------------------------- OSMANTHUS (kinmokusei)
M.OSMANTHUS = {
  len = { 0.95, 0.45, 0.22 }, kids = { 4, 2 }, seg = { 0.06, 0.12 }, turn = { 0.03, 0.15 }, alt = 0.6,
  bias = 0.5, droop = 0, child_angle = { 0.42, 0.7 }, w0 = 0.02, wdecay = 0.6, wtip = 0.5, pw = 0.7,
  margin = 14, smooth = 3, maxbranches = 14,
}

--- Osmanthus: upright stems with dark lanceolate mokkotsu leaves (ink in
--- sumi, deep green in hanga) and clusters of tiny orange four-lobed florets in
--- the leaf axils (reference scroll 1, left).
function M.osmanthus(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local size = spec.size or 260
  local LL = clamp((spec.leaf or 0.13) * size, 20, 44) * (spec.organ_scale or 1)
  local P = {}
  for k, v in pairs(M.OSMANTHUS) do P[k] = v end
  P.margin = LL * 0.7
  local st = new_state(ctx, spec, "osmanthus", P)
  local tree = (spec.engine == "walk") and grow_tree(st, P, spec) or grow_sc(st, spec, "osmanthus")
  if #tree == 0 then return nil, { perch = {} } end
  local leaves, axils, items = {}, {}, {}
  local maxl = bloom_budget(st, tree, LL * 0.3, 1)
  local function clear_items(x, y, r, f)
    for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.y - y) ^ 2 < ((it.r + r) * f) ^ 2 then return false end end
    return true
  end
  for _, br in ipairs(tree) do
    local s = br.L * (br.depth == 0 and 0.45 or 0.2)
    local side = R.chance(0.5) and 1 or -1
    while s < br.L * 0.97 and #leaves < maxl do
      local x, y, _, h = eval_at(br, s)
      local nleaf = R.chance(0.35) and 2 or 1
      for _ = 1, nleaf do
        side = -side
        local a = h + side * R.range(0.5, 0.95)
        local L = LL * R.range(0.75, 1.1)
        local cx, cy = x + cos(a) * L * 0.55, y + sin(a) * L * 0.55
        if U.free(ctx, x + cos(a) * L, y + sin(a) * L, 4.0) and U.free(ctx, cx, cy, L * 0.55) and clear_items(cx, cy, L * 0.25, 0.8) then
          items[#items + 1] = { x = cx, y = cy, r = L * 0.25 }
          leaves[#leaves + 1] = { x = x, y = y, a = a, L = L, bend = -side * R.range(0.03, 0.1), tone = R.u() }
          use(br, s)
          if R.chance(0.7) then axils[#axils + 1] = { x = x, y = y, a = h + side * 0.25 } end
        end
      end
      s = s + LL * R.range(0.35, 0.6)
    end
    local z = br.nodes[#br.nodes]
    if br.depth >= 1 then
      local a = z.a + R.sym(0.12)
      local L = LL * R.range(0.55, 0.75)
      if U.free(ctx, z.x + cos(a) * L, z.y + sin(a) * L, 4.0) and U.free(ctx, z.x + cos(a) * L * 0.5, z.y + sin(a) * L * 0.5, L * 0.45) then
        leaves[#leaves + 1] = { x = z.x, y = z.y, a = a, L = L, bend = R.sym(0.05), tone = R.u() }
        use(br, br.L)
      end
    end
  end
  tree = prune(st, tree, 0)
  local hanga = U.hanga(ctx)
  local stem = hanga and mix(ctx.palette.color("kuri"), U.paper(ctx), 0.25) or ctx.palette.color("sumi-light")
  local bb = tree_base(st, tree, spec)
  bb = union(bb, draw_tree(st, tree, { col = stem, body = stem, drycol = ctx.palette.color("sumi-mid"), dryalpha = 0.5, drymin = 99, alpha = 0.92 }))
  W:layer(30)
  local noir = ctx.palette.color("sumi-noir")
  local leafc = hanga and ctx.palette.color("matsuba") or noir
  local paper = U.paper(ctx)
  INK.begin(W, leafc, { chroma = hanga and 1.12 or 0.22 })
  INK.detail = 1
  for _, lf in ipairs(leaves) do
    local pts = U.blade(lf.x, lf.y, lf.a, lf.L, lf.L * 0.33, U.prof.lance, lf.bend)
    local ex, ey = lf.x + cos(lf.a) * lf.L, lf.y + sin(lf.a) * lf.L
    INK.glaze_leaf(R, pts, lf.x, lf.y, ex, ey, lf.L * 0.17, {
      tone = hanga and R.range(0.32, 0.50) or R.range(0.16 + 0.35 * lf.tone, 0.32 + 0.35 * lf.tone),
      alpha = hanga and 0.96 or (0.62 + 0.34 * lf.tone),
      vein_color = hanga and mix(ctx.palette.color("moegi"), { 1, 1, 1 }, 0.45) or paper,
    })
    local b = U.bbox_pts(pts, 0.4); U.rec(ctx, "osmanthus-leaf", b); bb = union(bb, b)
  end
  INK.finish()
  local fr = clamp((spec.floret or 0.012) * size, 2.4, 4.2) * (spec.organ_scale or 1)
  local osm, osmc = ctx.palette.color("yamabuki"), ctx.palette.color("ume-centre")
  W:layer(40)
  INK.begin(W, osm, { accent = osmc, chroma = hanga and 1.25 or 0.45 })
  INK.detail = 0.6
  for _, ax in ipairs(axils) do
    local n = R.int(3, 8)
    local cb
    for _ = 1, n do
      local a = ax.a + R.sym(1.0)
      local d = fr * R.range(0.4, 2.0)
      local fx, fy = ax.x + cos(a) * d, ax.y + sin(a) * d
      if U.free(ctx, fx, fy, fr * 1.5 + 0.8) then
        local rr = fr * R.range(0.85, 1.15)
        local r0 = R.range(0, pi)
        local lob = {}
        local lpts = {}
        for k = 0, 3 do
          local la = r0 + k * pi / 2
          local ep = U.ellipse_pts(fx + cos(la) * rr * 0.55, fy + sin(la) * rr * 0.55, rr * 0.55, rr * 0.45, la, 10)
          lob[#lob + 1] = W:poly(ep, true)
          lpts[#lpts + 1] = ep
        end
        local jpath = W:join(lob)
        local b = W:fill(jpath, mix(osm, paper, R.range(0, 0.20)), 0.96)
        W:clip(jpath)
        W:stroke(jpath, osmc, rr * 0.28, 0.28, { blend = "multiply" })
        W:unclip()
        W:fill(W:circle(fx, fy, rr * 0.30), osmc, 0.92)
        W:fill(W:circle(fx, fy, rr * 0.14), { 1, 0.96, 0.82 }, 0.85)
        cb = union(cb, b)
      end
    end
    if cb then U.rec(ctx, "osmanthus-floret", cb); bb = union(bb, cb) end
  end
  INK.finish()
  return bb, { perch = perches(st, tree, items, spec.perch_clear), tree = tree,
    kinds = { "osmanthus-trunk", "osmanthus-branch", "osmanthus-twig", "osmanthus-leaf", "osmanthus-floret" } }
end

---------------------------------------------------------------- CAMELLIA (tsubaki)
M.CAMELLIA = {
  len = { 0.8, 0.42, 0.2 }, kids = { 3, 2 }, seg = { 0.07, 0.13 }, turn = { 0.1, 0.35 }, alt = 0.8,
  bias = 0.4, droop = 0, child_angle = { 0.45, 0.85 }, w0 = 0.03, wdecay = 0.55, wtip = 1.0, pw = 0.6,
  margin = 20, smooth = 2, maxbranches = 10,
}

local function camellia_flower(ctx, x, y, Rf, tilt)
  local W, R = ctx.pdf, ctx.rng
  local C = function(n) return ctx.palette.color(n) end
  local hanga = U.hanga(ctx)
  local cam = hanga and { 0.88, 0.20, 0.32 } or C("beni")
  local boss = C("yamabuki")
  local np = R.int(6, 8)
  local a0 = R.range(0, TAU)
  local sy = R.range(0.72, 0.92)
  local petals = {}
  for k = 0, np - 1 do
    local a = a0 + TAU * k / np + R.sym(0.14)
    local d = Rf * 0.44
    local lx, ly = cos(a) * d, sin(a) * d * sy
    local gx, gy = rot(lx, ly, tilt)
    petals[#petals + 1] = { x = x + gx, y = y + gy, ly = ly, a = a }
  end
  table.sort(petals, function(p, q) return p.ly > q.ly end)
  local bb
  INK.begin(W, cam, { accent = boss, chroma = hanga and 1.25 or 0.35 })
  INK.detail = 1
  for _, p in ipairs(petals) do
    local back = p.ly > 0
    local ang = atan2(p.y - y, p.x - x)
    local pts = U.ccw(U.ellipse_pts(p.x, p.y, Rf * 0.54, Rf * 0.48, ang, 24, 0.06, R))
    local tipx, tipy = p.x + cos(ang) * Rf * 0.52, p.y + sin(ang) * Rf * 0.52
    INK.glaze_petal(R, pts, x, y, tipx, tipy, Rf * 0.48, {
      tone = back and R.range(0.30, 0.42) or R.range(0.42, 0.56),
      alpha = 0.96,
      blush = true,
      pool = 0.28,
      lift = 1.22,
    })
    bb = union(bb, U.bbox_pts(pts, 0.5))
  end
  local by = y + Rf * 0.04
  INK.push()
  INK.translate(x, by)
  INK.heart(R, np, Rf * 0.68, {
    stamens = 24, stamen_len = 0.34, stamen_min = 0.52,
    filament = mix(C("gofun"), boss, 0.45),
    anther = boss, anther2 = C("ume-centre"), anther_r = 0.024,
  })
  INK.pop()
  INK.finish()
  return bb
end

--- Camellia: stiff branches with glossy dark leaves (lighter half, lifted
--- midrib), red cupped flowers with a golden stamen boss, round buds.
function M.camellia(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local size = spec.size or 260
  local Rf = clamp((spec.bloom or 0.075) * size, 13, 24) * (spec.organ_scale or 1)
  local LL = clamp((spec.leaf or 0.14) * size, 22, 44) * (spec.organ_scale or 1)
  local P = {}
  for k, v in pairs(M.CAMELLIA) do P[k] = v end
  P.margin = max(Rf, LL * 0.5)
  local st = new_state(ctx, spec, "camellia", P)
  local tree = (spec.engine == "walk") and grow_tree(st, P, spec) or grow_sc(st, spec, "camellia")
  if #tree == 0 then return nil, { perch = {} } end
  local items, leaves, flowers, buds = {}, {}, {}, {}
  local function clear_items(x, y, r, f)
    for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.y - y) ^ 2 < ((it.r + r) * f) ^ 2 then return false end end
    return true
  end
  local nflow = 0
  local maxf = spec.flowers or 3
  for _, br in ipairs(tree) do
    if br.depth >= 1 then
      local z = br.nodes[#br.nodes]
      if nflow < maxf and U.free(ctx, z.x, z.y, Rf * 1.18 + 1.0) and clear_items(z.x, z.y, Rf, 1.0) then
        flowers[#flowers + 1] = { x = z.x, y = z.y, tilt = R.sym(0.4) }
        use(br, br.L); items[#items + 1] = { x = z.x, y = z.y, r = Rf }; nflow = nflow + 1
      elseif U.free(ctx, z.x, z.y, Rf * 0.55) and clear_items(z.x, z.y, Rf * 0.3, 1.0) then
        buds[#buds + 1] = { x = z.x + cos(z.a) * Rf * 0.2, y = z.y + sin(z.a) * Rf * 0.2, a = z.a, r = Rf * 0.32, kind = "bud" }
        use(br, br.L); items[#items + 1] = { x = z.x, y = z.y, r = Rf * 0.3 }
      end
    end
  end
  for _, br in ipairs(tree) do
    local s = br.L * (br.depth == 0 and 0.4 or 0.15)
    local side = R.chance(0.5) and 1 or -1
    while s < br.L * 0.9 do
      local x, y, _, h = eval_at(br, s)
      side = -side
      local a = h + side * R.range(0.55, 0.95)
      local L = LL * R.range(0.8, 1.1)
      local cx, cy = x + cos(a) * L * 0.5, y + sin(a) * L * 0.5
      if U.free(ctx, x + cos(a) * L, y + sin(a) * L, 4.0) and U.free(ctx, cx, cy, L * 0.55) and clear_items(cx, cy, L * 0.25, 0.75) then
        leaves[#leaves + 1] = { x = x, y = y, a = a, L = L, bend = side * R.range(0.03, 0.08), tone = R.u() }
        items[#items + 1] = { x = cx, y = cy, r = L * 0.25 }
        use(br, s)
      end
      s = s + LL * R.range(0.4, 0.7)
    end
  end
  tree = prune(st, tree, 0)
  local bc = branch_colors(ctx, "camellia")
  local bb = tree_base(st, tree, spec)
  bb = union(bb, draw_tree(st, tree, { col = bc.col, body = bc.body, drycol = bc.drycol, dryalpha = 0.7, drymin = 5, dryness = 0.4 }))
  W:layer(30)
  local C = function(n) return ctx.palette.color(n) end
  local hanga = U.hanga(ctx)
  local leafc = hanga and mix(C("matsuba"), C("sumi-dark"), 0.20) or mix(C("matsuba"), C("sumi-noir"), 0.55)
  local light = hanga and mix(C("moegi"), { 1, 1, 1 }, 0.40) or U.paper(ctx)
  INK.begin(W, leafc, { chroma = hanga and 1.12 or 0.22 })
  INK.detail = 1
  for _, lf in ipairs(leaves) do
    local pts = U.blade(lf.x, lf.y, lf.a, lf.L, lf.L * 0.46, U.prof.petiole, lf.bend)
    local ex, ey = lf.x + cos(lf.a) * lf.L, lf.y + sin(lf.a) * lf.L
    INK.glaze_leaf(R, pts, lf.x, lf.y, ex, ey, lf.L * 0.23, {
      tone = hanga and R.range(0.30, 0.46) or R.range(0.18 + 0.30 * lf.tone, 0.34 + 0.30 * lf.tone),
      alpha = 0.96,
      vein_color = light,
    })
    local b = U.bbox_pts(pts, 0.5); U.rec(ctx, "camellia-leaf", b); bb = union(bb, b)
  end
  INK.finish()
  W:layer(40)
  local cam = hanga and { 0.88, 0.20, 0.32 } or C("beni")
  local sty = {
    hue = cam, bud_tone = { 0.30, 0.44 }, chroma = hanga and 1.25 or 0.35,
    bud0 = mix(cam, C("sumi-dark"), 0.3), bud1 = cam, c2 = mix(cam, C("gofun"), 0.3), rim = mix(cam, C("sumi-dark"), 0.4),
    calyx = leafc,
  }
  for _, b in ipairs(buds) do
    local r = M.ink_bud(ctx, b, sty)
    if r then U.rec(ctx, "camellia-bud", r); bb = union(bb, r) end
  end
  for _, f in ipairs(flowers) do
    local r = camellia_flower(ctx, f.x, f.y, Rf * R.range(0.9, 1.05), f.tilt)
    if r then U.rec(ctx, "camellia-flower", r); bb = union(bb, r) end
  end
  return bb, { perch = perches(st, tree, items, spec.perch_clear), tree = tree,
    kinds = { "camellia-trunk", "camellia-branch", "camellia-twig", "camellia-leaf", "camellia-flower", "camellia-bud" } }
end

---------------------------------------------------------------- CHRYSANTHEMUM (kiku)
--- Chrysanthemum: an upright stem with lobed leaves and 1-3 flower heads made
--- of rings of narrow spoon petals (outer rings first), golden or white.
function M.chrysanthemum(ctx, spec)
  spec = spec or {}
  ctx = U.with_region(ctx, spec.region)
  local R = ctx.rng
  local W = ctx.pdf
  local H = spec.size or 220
  local a0 = spec.angle or pi / 2
  local fs = spec.flower or clamp(H * 0.11, 12, 30)
  local C = function(n) return ctx.palette.color(n) end
  local hanga = U.hanga(ctx)
  local bb
  if spec.ground ~= false then bb = union(bb, M.earth(ctx, spec.x, spec.y + 1, fs * 2.2, "chrysanthemum")) end
  local stemc, stema = ink(ctx, "stem", 0)
  local leafc = hanga and C("matsuba") or C("sumi-mid")
  local nh = spec.flowers or R.int(1, 3)
  local heads = {}
  for k = 1, nh do
    local a = a0 + (k - (nh + 1) / 2) * 0.35 + R.sym(0.1)
    local L = H * R.range(0.7, 1.0) * (k == 1 and 1 or 0.85)
    local b = R.sym(0.2)
    local segs, S, wfn = fit_stroke(ctx, function(LL) return leaf_seg(spec.x + R.sym(2), spec.y, a, LL, b, 0) end, L, L * 0.4,
      function() return function() return 1.4 end end, 0, function(u) return u > 0.92 and 2.2 * fs or 1.4 end)
    if segs then
      W:layer(21)
      local so = B.outline(S, function(u) return max(0.9, H * 0.008) * (1 - 0.35 * u) end)
      W:fill(W:poly(so, true), stemc, stema)
      local sb = U.bbox_pts(so, 0.5); U.rec(ctx, "chrysanthemum-stem", sb); bb = union(bb, sb)
      -- lobed leaves along the stem
      W:layer(30)
      local side = R.chance(0.5) and 1 or -1
      for t = 0.2, 0.75, 0.18 + R.range(0, 0.06) do
        local px, py, tx, ty = spine_eval(segs, t)
        side = -side
        local la = atan2(ty, tx) + side * R.range(0.7, 1.1)
        local LLf = fs * R.range(1.2, 1.7)
        local cx, cy = px + cos(la) * LLf * 0.55, py + sin(la) * LLf * 0.55
        if U.free(ctx, cx, cy, LLf * 0.55) then
          local lobes = {}
          local lo = {}
          -- kiku leaf: an ovate blade with two pairs of rounded side lobes
          local ca, sa = cos(la), sin(la)
          local function at(t) return px + ca * LLf * t, py + sa * LLf * t end
          local mx, my = at(0.62)
          local main = U.ellipse_pts(mx, my, LLf * 0.36, LLf * 0.2, la, 16, 0.06, R)
          lobes[#lobes + 1] = W:poly(U.ccw(main), true); lo[#lo + 1] = main
          for _, t in ipairs({ 0.42, 0.68 }) do
            for sd = -1, 1, 2 do
              local bx, by = at(t)
              local aa = la + sd * 0.95
              local ll = LLf * (t < 0.5 and 0.22 or 0.18)
              local pts = U.ellipse_pts(bx + cos(aa) * ll * 0.8, by + sin(aa) * ll * 0.8, ll * 0.85, ll * 0.55, aa, 12, 0.08, R)
              lobes[#lobes + 1] = W:poly(U.ccw(pts), true); lo[#lo + 1] = pts
            end
          end
          local stalk = B.outline(B.spine(leaf_seg(px, py, la, LLf * 0.45, 0, 0), { step = 0.8 }), function() return 0.8 end)
          lobes[#lobes + 1] = W:poly(stalk, true); lo[#lo + 1] = stalk
          local jpath = W:join(lobes)
          W:fill(jpath, leafc, hanga and 0.92 or 0.65)
          local ex2, ey2 = at(0.92)
          W:clip(jpath)
          INK.begin(W, leafc, { chroma = hanga and 1.12 or 0.22 })
          INK.glaze_leaf(R, main, px, py, ex2, ey2, LLf * 0.28, {
            tone = hanga and R.range(0.36, 0.50) or R.range(0.28, 0.42),
            alpha = hanga and 0.92 or 0.68,
            vein_color = hanga and mix(C("moegi"), { 1, 1, 1 }, 0.45) or U.paper(ctx),
          })
          INK.finish()
          W:unclip()
          W:stroke(W:poly({ { px, py }, { ex2, ey2 } }, false), hanga and C("moegi") or C("sumi-wash"), 0.5, 0.6)
          local lb = pts_bb(lo, 0.5); U.rec(ctx, "chrysanthemum-leaf", lb); bb = union(bb, lb)
        end
      end
      local hx, hy = spine_eval(segs, 1)
      heads[#heads + 1] = { hx, hy }
    end
  end
  W:layer(40)
  local is_wht = (spec.variant == "white")
  local gold = is_wht and { 0.99, 0.97, 0.92 } or C("yamabuki")
  local deep = is_wht and mix(C("gofun"), C("kigaki"), 0.35) or mix(C("yamabuki"), C("kincha"), 0.6)
  for _, h in ipairs(heads) do
    local x, y = h[1], h[2]
    local hb
    local tilt = R.range(0.65, 0.95)
    INK.begin(W, gold, { accent = mix(deep, C("kincha"), 0.5), chroma = is_wht and 0.32 or 1.22 })
    INK.detail = 0.8
    for ring = 3, 1, -1 do
      local n = ({ 14, 20, 26 })[ring]
      local len = fs * ({ 0.45, 0.75, 1.0 })[ring]
      local pw = fs * ({ 0.12, 0.13, 0.14 })[ring]
      local pp = {}
      local off = R.range(0, TAU)
      local t_ring = is_wht and ({ 0.72, 0.80, 0.88 })[ring] or ({ 0.46, 0.58, 0.68 })[ring]
      for k = 1, n do
        local a = off + TAU * k / n + R.sym(0.08)
        local dx, dy = cos(a), sin(a) * tilt
        local l = sqrt(dx * dx + dy * dy)
        local s = leaf_seg(x, y, atan2(dy, dx), len * l * R.range(0.85, 1.05), R.sym(0.15), 0)
        local o = B.outline(B.spine(s, { step = 0.6 }),
          function(u) return pw * sin(pi * min(1, u * 0.95 + 0.05) ^ 0.8) ^ 0.6 end)
        local tip = s[1][4]
        INK.glaze_petal(R, o, x, y, tip[1], tip[2], pw, {
          tone = t_ring + R.sym(0.05), alpha = 0.95, pool = 0.22, lift = 1.25, streaks = 4, vein = false,
        })
        pp[#pp + 1] = o
      end
      hb = union(hb, pts_bb(pp, 0.4))
    end
    INK.push()
    INK.translate(x, y)
    INK.scale(1, tilt)
    INK.heart(R, 8, fs * 0.45, {
      stamens = 16, stamen_len = 0.32, stamen_min = 0.25,
      anther = mix(deep, C("kincha"), 0.4), anther2 = C("yamabuki"), anther_r = 0.032,
    })
    INK.pop()
    INK.finish()
    if hb then U.rec(ctx, "chrysanthemum-flower", hb); bb = union(bb, hb) end
  end
  return bb, { kinds = { "chrysanthemum-stem", "chrysanthemum-leaf", "chrysanthemum-flower" }, perch = {} }
end
M.kiku = M.chrysanthemum

M._internal = { grow_tree = grow_tree, prune = prune, place_clusters = place_clusters, new_state = new_state,
  draw_tree = draw_tree, perches = perches, petal_shape = petal_shape, eval_at = eval_at, bloom_budget = bloom_budget,
  draw_items = draw_items, branch_colors = branch_colors, bark_marks = bark_marks, finalize = finalize, use = use,
  densify = densify, branch_bbox = branch_bbox }

return M
