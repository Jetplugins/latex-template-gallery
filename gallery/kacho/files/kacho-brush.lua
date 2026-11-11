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
-- kacho-brush.lua: brush-stroke primitives for kacho (tapered stroke with curvature
-- clamp + loop removal, dry brush / kasure, orchid ribbon, fine outline, dots,
-- crotch fillets / compound branch forks, cubic Bézier utilities).
--
-- Portions adapted from florilegium (https://github.com/kevinraymond/florilegium),
-- florilegium-ink.lua (ribbon outline as left side forward + right side reversed,
-- arc-length sampling, blob-style edge noise).
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
--   * Cubic Bézier evaluation, derivatives, and de Casteljau subdivision (B.bez,
--     B.bezd, B.bezdd, B.split): Paul de Casteljau (1959); Gerald Farin, "Curves
--     and Surfaces for CAGD: A Practical Guide", 5th ed., Morgan Kaufmann, 2002.
--   * C1-continuous cardinal/Catmull-Rom cubic chain (B.chain): Edwin Catmull and
--     Raphael Rom, "A Class of Local Interpolating Splines", 1974.
--   * Variable-width skeletal stroke envelope with inner radius-of-curvature
--     clamping, C0/cusp corner fans, and local swallowtail delooping (B.outline,
--     B.deloop): inspired by Sara C. Hsu and Irene H. H. Lee, "Drawing and
--     Animation Using Skeletal Strokes", Proc. SIGGRAPH 94, pp. 109-118, and
--     florilegium-ink.lua ribbon outline (Kevin Raymond, 2026, MIT).
--   * Kasure dry-brush multi-bristle stochastic dropout (B.dry): inspired by
--     Strassmann, "Hairy Brushes", Proc. SIGGRAPH 86, pp. 225-232.
--
-- Pure Lua. Geometry in page bp. A *spine* is a chain of cubic Béziers
-- {{p0,p1,p2,p3}, ...} with points {x,y}; a single cubic {p0,p1,p2,p3} is also
-- accepted. Every painting function takes `ctx` first (ctx.pdf writer, ctx.rng
-- stream) and returns the bbox of what it painted (nil if nothing).
local B = {}

local sqrt, sin, cos, abs, pi, min, max, floor, atan2 =
  math.sqrt, math.sin, math.cos, math.abs, math.pi, math.min, math.max, math.floor, math.atan

--- Union of two bboxes (either may be nil).
function B.union(a, b)
  if not a then return b end
  if not b then return a end
  return { x0 = min(a.x0, b.x0), y0 = min(a.y0, b.y0), x1 = max(a.x1, b.x1), y1 = max(a.y1, b.y1) }
end

---------------------------------------------------------------- Bézier utils
function B.bez(sg, t)
  local p0, p1, p2, p3 = sg[1], sg[2], sg[3], sg[4]
  local u = 1 - t
  local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
  return a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1], a * p0[2] + b * p1[2] + c * p2[2] + d * p3[2]
end
function B.bezd(sg, t)
  local p0, p1, p2, p3 = sg[1], sg[2], sg[3], sg[4]
  local u = 1 - t
  return 3 * u * u * (p1[1] - p0[1]) + 6 * u * t * (p2[1] - p1[1]) + 3 * t * t * (p3[1] - p2[1]),
         3 * u * u * (p1[2] - p0[2]) + 6 * u * t * (p2[2] - p1[2]) + 3 * t * t * (p3[2] - p2[2])
end
function B.bezdd(sg, t)
  local p0, p1, p2, p3 = sg[1], sg[2], sg[3], sg[4]
  local u = 1 - t
  return 6 * u * (p2[1] - 2 * p1[1] + p0[1]) + 6 * t * (p3[1] - 2 * p2[1] + p1[1]),
         6 * u * (p2[2] - 2 * p1[2] + p0[2]) + 6 * t * (p3[2] - 2 * p2[2] + p1[2])
end
--- Split a cubic at t (de Casteljau); returns two cubics.
function B.split(sg, t)
  local function lerp(a, b) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t } end
  local p01, p12, p23 = lerp(sg[1], sg[2]), lerp(sg[2], sg[3]), lerp(sg[3], sg[4])
  local p012, p123 = lerp(p01, p12), lerp(p12, p23)
  local m = lerp(p012, p123)
  return { sg[1], p01, p012, m }, { m, p123, p23, sg[4] }
end

--- Accept a single cubic {p0,p1,p2,p3} or a chain; always returns a chain.
function B.normalize(segs)
  if type(segs) ~= "table" or #segs == 0 then return {} end
  if type(segs[1][1]) == "number" then return { segs } end
  return segs
end

--- Straight segment as a cubic.
function B.line(p0, p1)
  return { p0, { p0[1] + (p1[1] - p0[1]) / 3, p0[2] + (p1[2] - p0[2]) / 3 },
           { p0[1] + 2 * (p1[1] - p0[1]) / 3, p0[2] + 2 * (p1[2] - p0[2]) / 3 }, p1 }
end

--- C1-continuous cubic chain through points (Catmull-Rom with collinear handles).
--- tension 1 = standard; lower = tighter. Optional start/end tangents {dx,dy}.
function B.chain(pts, tension, t0, t1)
  local n = #pts
  if n < 2 then return {} end
  local k = (tension or 1) / 6
  local segs = {}
  for i = 1, n - 1 do
    local p0, p1, p2, p3 = pts[max(1, i - 1)], pts[i], pts[i + 1], pts[min(n, i + 2)]
    local d1x, d1y = (p2[1] - p0[1]) * k, (p2[2] - p0[2]) * k
    local d2x, d2y = (p3[1] - p1[1]) * k, (p3[2] - p1[2]) * k
    if i == 1 and t0 then
      local L = sqrt((p2[1] - p1[1]) ^ 2 + (p2[2] - p1[2]) ^ 2) / 3
      local tl = max(1e-9, sqrt(t0[1] ^ 2 + t0[2] ^ 2))
      d1x, d1y = t0[1] / tl * L, t0[2] / tl * L
    end
    if i == n - 1 and t1 then
      local L = sqrt((p2[1] - p1[1]) ^ 2 + (p2[2] - p1[2]) ^ 2) / 3
      local tl = max(1e-9, sqrt(t1[1] ^ 2 + t1[2] ^ 2))
      d2x, d2y = t1[1] / tl * L, t1[2] / tl * L
    end
    segs[i] = { { p1[1], p1[2] }, { p1[1] + d1x, p1[2] + d1y }, { p2[1] - d2x, p2[2] - d2y }, { p2[1], p2[2] } }
  end
  return segs
end

local function seglen(sg)
  local a = sqrt((sg[2][1] - sg[1][1]) ^ 2 + (sg[2][2] - sg[1][2]) ^ 2)
  local b = sqrt((sg[3][1] - sg[2][1]) ^ 2 + (sg[3][2] - sg[2][2]) ^ 2)
  local c = sqrt((sg[4][1] - sg[3][1]) ^ 2 + (sg[4][2] - sg[3][2]) ^ 2)
  return a + b + c
end

--- Sample a spine. Returns S (array of {x,y,tx,ty,k,s,u}) and total length L.
--- opt.step = target spacing in bp (default 1.5); 12..80 samples per segment.
function B.spine(segs, opt)
  segs = B.normalize(segs)
  opt = opt or {}
  local step = opt.step or 1.5
  local S = {}
  for si, sg in ipairs(segs) do
    local n = max(12, min(80, floor(seglen(sg) / step + 0.5)))
    for i = 0, n do
      local t = i / n
      local x, y = B.bez(sg, t)
      local dx, dy = B.bezd(sg, t)
      local sp = sqrt(dx * dx + dy * dy)
      if sp < 1e-9 then   -- degenerate handle: nudge t
        dx, dy = B.bezd(sg, t < 0.5 and t + 1e-3 or t - 1e-3)
        sp = sqrt(dx * dx + dy * dy)
        if sp < 1e-12 then dx, dy, sp = 1, 0, 1 end
      end
      local tx, ty = dx / sp, dy / sp
      local ddx, ddy = B.bezdd(sg, t)
      local k = (dx * ddy - dy * ddx) / (sp * sp * sp)   -- signed curvature (+ = turning left)
      if i == 0 and si > 1 then
        local prev = S[#S]
        if prev and (prev.tx * tx + prev.ty * ty) < 0.98 then
          S[#S + 1] = { x = x, y = y, tx = tx, ty = ty, k = k }
        end
      else
        S[#S + 1] = { x = x, y = y, tx = tx, ty = ty, k = k }
      end
    end
  end
  local L = 0
  if #S == 0 then return S, 0 end
  S[1].s = 0
  for i = 2, #S do
    L = L + sqrt((S[i].x - S[i - 1].x) ^ 2 + (S[i].y - S[i - 1].y) ^ 2)
    S[i].s = L
  end
  for i = 1, #S do S[i].u = L > 0 and S[i].s / L or 0 end
  return S, L
end

--- Point at arc-length fraction u on sampled spine S: x, y, tx, ty.
function B.at(S, u)
  local n = #S
  if n == 0 then return nil end
  if u <= 0 then return S[1].x, S[1].y, S[1].tx, S[1].ty end
  if u >= 1 then return S[n].x, S[n].y, S[n].tx, S[n].ty end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if S[mid].u <= u then lo = mid else hi = mid end
  end
  local a, b = S[lo], S[hi]
  local t = (b.u > a.u) and (u - a.u) / (b.u - a.u) or 0
  local tx, ty = a.tx + (b.tx - a.tx) * t, a.ty + (b.ty - a.ty) * t
  local tl = sqrt(tx * tx + ty * ty)
  if tl < 1e-12 then tx, ty, tl = a.tx, a.ty, 1 end
  return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, tx / tl, ty / tl
end

--- Point at arc-length fraction u of a spine (convenience; samples the spine).
function B.eval(segs, u)
  local S = B.spine(segs)
  return B.at(S, u)
end

---------------------------------------------------------------- outline
local function seg_cross(a, b, c, d)
  local rx, ry, sx, sy = b[1] - a[1], b[2] - a[2], d[1] - c[1], d[2] - c[2]
  local den = rx * sy - ry * sx
  if abs(den) < 1e-12 then return nil end
  local t = ((c[1] - a[1]) * sy - (c[2] - a[2]) * sx) / den
  local u = ((c[1] - a[1]) * ry - (c[2] - a[2]) * rx) / den
  if t > 0 and t < 1 and u > 0 and u < 1 then return { a[1] + t * rx, a[2] + t * ry } end
  return nil
end
B.seg_cross = seg_cross

--- Remove loops from an open polyline: if segment i crosses a later segment j
--- (within `window` segments), splice in the crossing point and drop the points
--- in between. Optional predicate `allow(i, j)` gates whether a crossing between
--- segment i and j is a local offset swallowtail rather than a genuine spine loop.
function B.deloop(pts, window, allow)
  window = window or 60
  local out, i, n = {}, 1, #pts
  while i <= n do
    out[#out + 1] = pts[i]
    local jumped = false
    if i < n then
      for j = min(n - 1, i + window), i + 2, -1 do   -- farthest crossing first
        local x = seg_cross(pts[i], pts[i + 1], pts[j], pts[j + 1])
        if x and (not allow or allow(i, j, pts)) then
          x.idx = pts[j + 1].idx; x.h = pts[j + 1].h
          out[#out + 1] = x
          i = j + 1
          jumped = true
          break
        end
      end
    end
    if not jumped then i = i + 1 end
  end
  return out
end

--- Twice the signed area of a closed polygon (positive = counter-clockwise).
function B.area2(pts)
  local a = 0
  for i = 1, #pts do
    local p, q = pts[i], pts[i % #pts + 1]
    a = a + p[1] * q[2] - q[1] * p[2]
  end
  return a
end

--- Count self-intersections of a closed polygon (O(n^2); for tests/diagnostics).
function B.self_crossings(pts)
  local n, c = #pts, 0
  for i = 1, n do
    local a, b = pts[i], pts[i % n + 1]
    for j = i + 2, n do
      if not (i == 1 and j == n) then
        if seg_cross(a, b, pts[j], pts[j % n + 1]) then c = c + 1 end
      end
    end
  end
  return c
end

--- Closed outline of a variable-width stroke along sampled spine S.
--- wfn(u) = full width (bp) at arc fraction u. opt: kmax (0.85) curvature clamp,
--- jitter = function(u, side) -> relative width wobble, asym = {l=, r=} factors,
--- nodeloop = true to skip loop removal (testing only).
--- Returns a counter-clockwise point list.
function B.outline(S, wfn, opt)
  opt = opt or {}
  local kmax = opt.kmax or 0.85
  local al, ar = (opt.asym and opt.asym.l) or 1, (opt.asym and opt.asym.r) or 1
  local n = #S
  if n < 2 or (S[n].s or 0) < 1e-2 then return {} end

  -- Cumulative turning angle and sharp single-step turn (C0 join / cusp) detection
  local ang, da1, cusp = { 0 }, { 0 }, { 0 }
  for i = 2, n do
    local p0, p1 = S[i - 1], S[i]
    local dot = p0.tx * p1.tx + p0.ty * p1.ty
    local crs = p0.tx * p1.ty - p0.ty * p1.tx
    local da = atan2(crs, dot)
    da1[i] = da
    ang[i] = ang[i - 1] + da
    cusp[i] = cusp[i - 1] + (abs(da) > 0.45 and 1 or 0)
  end

  -- Windowed chord curvature (smooth across C1 segment joins) blended with analytic p.k
  local ks = {}
  for i = 1, n do
    local i0, i1 = max(1, i - 2), min(n, i + 2)
    local ds = (S[i1].s or 0) - (S[i0].s or 0)
    local da = ang[i1] - ang[i0]
    local kw = ds > 1e-6 and (da / ds) or S[i].k
    if cusp[i1] > cusp[i0] then
      ks[i] = kw
    else
      ks[i] = 0.65 * kw + 0.35 * S[i].k
    end
  end

  local hl, hr = {}, {}
  for i, p in ipairs(S) do
    local h = max(0, wfn(p.u)) / 2
    local a, b = h * al, h * ar
    local k = ks[i]
    if abs(k) > 1e-9 then
      local rho = 1 / abs(k)
      if k > 0 then a = min(a, kmax * rho) else b = min(b, kmax * rho) end
    end
    if abs(p.k) > 1e-9 and cusp[min(n, i + 1)] == cusp[max(1, i - 1)] then
      local rho = 1 / abs(p.k)
      if p.k > 0 then a = min(a, (kmax + 0.1) * rho) else b = min(b, (kmax + 0.1) * rho) end
    end
    for _, step_da in ipairs({ da1[i] or 0, da1[i + 1] or 0 }) do
      if abs(step_da) > 0.35 then
        local cf = max(0.05, cos(min(pi * 0.47, abs(step_da) * 0.85)))
        if step_da > 0 then a = min(a, h * al * cf) else b = min(b, h * ar * cf) end
      end
    end
    hl[i], hr[i] = a, b
  end

  -- Smooth half-widths across 6 passes so C1 segment joins never produce sawtooth spikes
  for _ = 1, 6 do
    local nl, nr = { hl[1] }, { hr[1] }
    for i = 2, n - 1 do
      if cusp[i + 1] > cusp[i - 1] then
        nl[i], nr[i] = hl[i], hr[i]
      else
        nl[i] = 0.25 * hl[i - 1] + 0.5 * hl[i] + 0.25 * hl[i + 1]
        nr[i] = 0.25 * hr[i - 1] + 0.5 * hr[i] + 0.25 * hr[i + 1]
      end
    end
    nl[n], nr[n] = hl[n], hr[n]
    hl, hr = nl, nr
  end

  local left, right = {}, {}
  for i, p in ipairs(S) do
    local jl = opt.jitter and opt.jitter(p.u, 1) or 0
    local jr = opt.jitter and opt.jitter(p.u, -1) or 0
    local a, b = max(0, hl[i] * (1 + jl)), max(0, hr[i] * (1 + jr))
    -- Round the outer side of sharp C0 corners or tight cusps with an arc fan
    if i > 1 and abs(da1[i]) > 0.45 then
      local p0 = S[i - 1]
      local a0 = atan2(p0.ty, p0.tx)
      local da = da1[i]
      local m = max(2, floor(abs(da) / 0.4))
      for k = 1, m - 1 do
        local th = a0 + da * (k / m)
        local nx, ny = -sin(th), cos(th)
        if da > 0 then
          right[#right + 1] = { p0.x - nx * b, p0.y - ny * b, idx = i, h = b }
        else
          left[#left + 1] = { p0.x + nx * a, p0.y + ny * a, idx = i, h = a }
        end
      end
    end
    local nx, ny = -p.ty, p.tx
    local Lp = { p.x + nx * a, p.y + ny * a, idx = i, h = a }
    local Rp = { p.x - nx * b, p.y - ny * b, idx = i, h = b }
    local has_cusp = (i > 1 and cusp[i] > cusp[i - 1]) or (i < n and cusp[i + 1] > cusp[i])
    local pl = left[#left]
    if not pl or has_cusp or ((Lp[1] - pl[1]) * p.tx + (Lp[2] - pl[2]) * p.ty) > -0.05 * a or i == n then
      left[#left + 1] = Lp
    end
    local pr = right[#right]
    if not pr or has_cusp or ((Rp[1] - pr[1]) * p.tx + (Rp[2] - pr[2]) * p.ty) > -0.05 * b or i == n then
      right[#right + 1] = Rp
    end
  end

  local function spine_crosses(i0, i1)
    i0, i1 = max(1, i0 - 1), min(n - 1, i1 + 1)
    for a = i0, i1 - 2 do
      local p1, p2 = S[a], S[a + 1]
      for b = a + 2, i1 do
        local q1, q2 = S[b], S[b + 1]
        if seg_cross({ p1.x, p1.y }, { p2.x, p2.y }, { q1.x, q1.y }, { q2.x, q2.y }) then
          return true
        end
      end
    end
    return false
  end

  local function allow_side(side)
    return function(i, j, pts)
      local ia, ib = pts[i].idx or i, pts[j + 1].idx or (j + 1)
      local da = (ang[ib] or 0) - (ang[ia] or 0)
      local inner_turn = (side * da) > 0.15
      local no_cusp = (cusp[ib] or 0) == (cusp[ia] or 0)
      local maxh = max(pts[i].h or 0, pts[j + 1].h or 0)
      local dspine = sqrt((S[ib].x - S[ia].x) ^ 2 + (S[ib].y - S[ia].y) ^ 2)
      return inner_turn and no_cusp and abs(da) <= 1.12 * pi and dspine <= 2.4 * maxh + 2.0 and not spine_crosses(ia, ib)
    end
  end

  if not opt.nodeloop then
    left = B.deloop(left, 60, allow_side(1))
    right = B.deloop(right, 60, allow_side(-1))
  end
  local out = {}
  for i = 1, #left do out[#out + 1] = { left[i][1], left[i][2] } end
  for i = #right, 1, -1 do out[#out + 1] = { right[i][1], right[i][2] } end
  if B.area2(out) < 0 then
    local rev = {}
    for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
    out = rev
  end
  return out
end

---------------------------------------------------------------- profiles
-- Full width as a fraction of w0, u in [0,1] along the stroke.
B.profile = {
  both = function(u) return sin(pi * u) ^ 0.6 end,                    -- tapered at both ends
  nail = function(u)                                                  -- kihitsu entry, long taper (bamboo leaf)
    local e = u < 0.08 and (0.55 + 0.45 * sin(pi / 2 * u / 0.08)) or 1
    return e * (1 - u) ^ 0.7
  end,
  orchid = function(u)                                                -- swell-thin-swell, pointed ends
    local env = min(1, u / 0.06) ^ 0.7 * (1 - u) ^ 0.8
    return env * (0.28 + 0.72 * abs(sin(1.5 * pi * (u * 0.92 + 0.04))))
  end,
  branch = function(u)                                                -- blunt base, thinning with rounded tip
    local tip = u > 0.96 and sqrt(max(0, 1 - ((u - 0.96) / 0.04) ^ 2)) or 1
    return (1 - 0.75 * u) * tip
  end,
  twig = function(u) return (1 - 0.85 * u) * min(1, 0.6 + u / 0.05 * 0.4) end,
  taper = function(u) return (1 - u) ^ 0.8 end,                      -- full start, pointed end
  even = function(u) return min(1, u / 0.04, (1 - u) / 0.04) ^ 0.5 end,
  line = function(u) return 0.35 + 0.65 * sin(pi * u) ^ 0.5 end,      -- fine outline (kōroku)
}

local function profile_fn(p)
  if type(p) == "function" then return p end
  local f = B.profile[p or "both"]
  if not f then error("kacho-brush: unknown profile '" .. tostring(p) .. "'", 3) end
  return f
end

-- brush-pressure modulation: width multiplier 1 + amp * smooth noise(u)
local function pressure_fn(ctx, amp, freq)
  if not amp or amp == 0 or not ctx.rng then return nil end
  local f = ctx.rng.noise(2)
  local ph = ctx.rng.range(0, 50)
  freq = freq or 2.5
  return function(u) return max(0.2, 1 + amp * f(u * freq + ph)) end
end
B.pressure_fn = pressure_fn

local function jitter_fn(ctx, amp)
  if not amp or amp == 0 or not ctx.rng then return nil end
  local f = ctx.rng.noise(3)
  local ph = ctx.rng.range(0, 50)
  return function(u, side) return amp * f(u * 5 + ph + (side > 0 and 0 or 23)) end
end

--- Build the compound PDF path of a tapered brush stroke WITHOUT filling it.
--- Same geometry options as B.stroke: w, profile, jitter, kmax, pressure, pfreq,
--- asym, joints, cap, step, nodeloop.
--- Returns path, S (sampled spine), outline points, wfn.
function B.outline_path(ctx, segs, o)
  o = o or {}
  local W = ctx.pdf
  local S = B.spine(segs, { step = o.step })
  if #S < 2 then return nil, S end
  local w = o.w or 2
  local pf = profile_fn(o.profile)
  local pr = pressure_fn(ctx, o.pressure, o.pfreq)
  local wfn = pr and function(u) return w * pf(u) * pr(u) end or function(u) return w * pf(u) end
  local out = B.outline(S, wfn, { kmax = o.kmax, jitter = jitter_fn(ctx, o.jitter or 0.05), asym = o.asym, nodeloop = o.nodeloop })
  if #out < 3 then return nil, S end
  local parts = { W:poly(out, true) }
  if o.cap then
    local r = wfn(0) / 2
    if r > 0.05 then parts[#parts + 1] = W:circle(S[1].x, S[1].y, r) end
  end
  for _, j in ipairs(o.joints or {}) do
    if j[3] and j[3] > 0.05 then parts[#parts + 1] = W:circle(j[1], j[2], j[3]) end
  end
  return W:join(parts), S, out, wfn
end

--- Tapered brush stroke along a spine.
--- o = { w = max width (bp), profile = name|fn, rgb =, alpha = 1, blend =,
---       jitter = 0.05 (relative edge wobble), kmax = 0.85,
---       pressure = 0 (thick-thin brush-pressure amplitude, ~0.15..0.35), pfreq = 2.5,
---       joints = {{x,y,r}, ...} discs unioned into the same fill (knots at twig joins),
---       cap = true adds a round cap at the start (for blunt branch profiles),
---       layer = optional layer number }
--- Returns bbox, S (sampled spine), outline points.
function B.stroke(ctx, segs, o)
  o = o or {}
  local W = ctx.pdf
  local path, S, out = B.outline_path(ctx, segs, o)
  if not path then return nil, S end
  if o.layer then W:layer(o.layer) end
  local bb = W:fill(path, o.rgb or { 0, 0, 0 }, o.alpha or 1, { blend = o.blend })
  return bb, S, out
end

--- Orchid ribbon leaf (swell-thin-swell profile). Same options as B.stroke.
function B.ribbon(ctx, segs, o)
  o = o or {}
  local oo = {}
  for k, v in pairs(o) do oo[k] = v end
  oo.profile = o.profile or "orchid"
  return B.stroke(ctx, segs, oo)
end

--- Fine outline stroke (kōroku): thin, width varying ±40%, slightly tapered ends.
function B.outline_stroke(ctx, segs, o)
  o = o or {}
  local oo = {}
  for k, v in pairs(o) do oo[k] = v end
  oo.w = o.w or 0.45
  oo.profile = o.profile or "line"
  oo.jitter = o.jitter or 0.25
  return B.stroke(ctx, segs, oo)
end

--- Dry brush (kasure): a pale unbroken under-silhouette plus bristle sub-ribbons
--- with gaps where the brush runs dry (toward the tail and the edges); all
--- bristle runs are one compound fill.
--- o = { w, profile, rgb, alpha, blend, pressure, pfreq, bristles = 7, dryness = 0.45 (clamped to
---       0.05..0.6), under = 0.3 (under-layer alpha fraction), joints, cap }
function B.dry(ctx, segs, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local S = B.spine(segs, { step = o.step })
  if #S < 2 then return nil, S end
  local w = o.w or 4
  local pf = profile_fn(o.profile or "branch")
  local pr = pressure_fn(ctx, o.pressure, o.pfreq)
  local wfn = pr and function(u) return w * pf(u) * pr(u) end or function(u) return w * pf(u) end
  local alpha = o.alpha or 1
  local dryness = max(0.05, min(0.6, o.dryness or 0.45))
  local nb = o.bristles or 7
  if o.layer then W:layer(o.layer) end
  -- unbroken pale silhouette
  local under = B.outline(S, wfn, { jitter = jitter_fn(ctx, 0.04) })
  local uparts = { W:poly(under, true) }
  if o.cap then uparts[#uparts + 1] = W:circle(S[1].x, S[1].y, wfn(0) / 2) end
  for _, j in ipairs(o.joints or {}) do uparts[#uparts + 1] = W:circle(j[1], j[2], j[3]) end
  local bb = W:fill(W:join(uparts), o.rgb or { 0, 0, 0 }, alpha * (o.under or 0.3), { blend = o.blend })
  local parts = {}
  for b = 1, nb do
    local off = (b - 0.5) / nb - 0.5 + rng.sym(0.25 / nb)
    local bw = rng.range(0.9, 1.6) / nb
    local noise = rng.noise(3)
    local ph, fr = rng.range(0, 100), rng.range(5, 11)
    local edge = abs(off) * 2
    local run = {}
    local function flush_run()
      if #run >= 3 then
        local s0, s1 = run[1].s, run[#run].s
        local left, right = {}, {}
        for _, p in ipairs(run) do
          local ww = wfn(p.u)
          local loc = (p.s - s0) / max(1e-6, s1 - s0)
          local taper = min(1, loc / 0.15, (1 - loc) / 0.15) ^ 0.5
          local h = ww * bw * 0.5 * (0.35 + 0.65 * taper)
          local cx, cy = p.x - p.ty * ww * off, p.y + p.tx * ww * off
          left[#left + 1] = { cx - p.ty * h, cy + p.tx * h }
          right[#right + 1] = { cx + p.ty * h, cy - p.tx * h }
        end
        local poly = left
        for i = #right, 1, -1 do poly[#poly + 1] = right[i] end
        if B.area2(poly) < 0 then
          local rev = {}
          for i = #poly, 1, -1 do rev[#rev + 1] = poly[i] end
          poly = rev
        end
        parts[#parts + 1] = W:poly(poly, true)
      end
      run = {}
    end
    for _, p in ipairs(S) do
      local thr = -0.9 + 1.6 * dryness * (0.35 + 0.65 * p.u) * (0.6 + 0.6 * edge)
      if noise(p.u * fr + ph) * 1.6 > thr then run[#run + 1] = p else flush_run() end
    end
    flush_run()
  end
  local jb = W:join(parts)
  if jb then bb = B.union(bb, W:fill(jb, o.rgb or { 0, 0, 0 }, alpha, { blend = o.blend })) end
  return bb, S
end

--- Spine for a side branch that flows out of a parent: starts exactly on the
--- parent's sampled spine S at arc fraction u, leaves along a direction blended
--- between the parent tangent and the target angle (flow = 0.55: how much the
--- start follows the parent), then bends toward `ang` (radians) over length
--- `len`. bend = extra sideways bow (fraction of len, signed).
--- Returns segs (one cubic), start point {x,y}, end point {x,y}.
function B.offshoot(S, u, ang, len, flow, bend)
  local x, y, tx, ty = B.at(S, u)
  if not x then return nil end
  flow = flow or 0.55
  local dx, dy = cos(ang), sin(ang)
  local ix, iy = tx * flow + dx * (1 - flow), ty * flow + dy * (1 - flow)
  local il = sqrt(ix * ix + iy * iy)
  if il < 1e-9 then ix, iy, il = dx, dy, 1 end
  ix, iy = ix / il, iy / il
  local ex, ey = x + dx * len, y + dy * len
  local b = (bend or 0) * len
  local nx, ny = -dy, dx
  local seg = { { x, y }, { x + ix * len * 0.38, y + iy * len * 0.38 },
                { ex - dx * len * 0.3 + nx * b, ey - dy * len * 0.3 + ny * b }, { ex, ey } }
  return { seg }, { x, y }, { ex, ey }
end

--- Concave crotch fillet path bridging a parent spine `parentS` at fraction `u`
--- and a child spine `childS` leaving from `u`. `pw` is the parent width at `u`
--- (number or function `pw(u)`), `cw` is the child base width (number or function).
--- Returns a counter-clockwise PDF path (fillet web + joint knot disc) suitable
--- for joining with `B.outline_path` in a single compound fill.
function B.crotch(W, parentS, u, pw, childS, cw, scale)
  if not parentS or #parentS < 2 or not childS or #childS < 2 then return nil end
  local jx, jy, ptx, pty = B.at(parentS, u)
  local _, _, ctx_, cty_ = B.at(childS, min(1, 0.12))
  if not jx or not ctx_ then return nil end
  local pw0 = type(pw) == "function" and pw(u) or (pw or 4)
  local cw0 = type(cw) == "function" and cw(0) or (cw or pw0 * 0.65)
  local pL = max(1e-3, parentS[#parentS].s or 1)
  local cL = max(1e-3, childS[#childS].s or 1)
  local crs = ptx * cty_ - pty * ctx_
  local side = crs >= 0 and 1 or -1
  local sc = scale or 1.0
  local up = min(1, u + (pw0 * 1.15 * sc + cw0 * 0.6) / pL)
  local uc = min(1, (pw0 * 0.9 + cw0 * 1.1 * sc) / cL)
  local px, py, ptx2, pty2 = B.at(parentS, up)
  local cx, cy, ctx2, cty2 = B.at(childS, uc)
  local pwh = (type(pw) == "function" and pw(up) or pw0) * 0.48
  local cwh = (type(cw) == "function" and cw(uc) or cw0) * 0.48
  -- Parent flank on the child's side; child flank facing the parent ahead of u
  local ax, ay = px + side * (-pty2) * pwh, py + side * ptx2 * pwh
  local bx, by = cx - side * (-cty2) * cwh, cy - side * ctx2 * cwh
  -- Concave control point pulled inward toward the crotch apex
  local mx, my = (ax + bx) * 0.5, (ay + by) * 0.5
  local vx, vy = ptx + ctx2, pty + cty2
  local vl = sqrt(vx * vx + vy * vy)
  if vl > 1e-6 then vx, vy = vx / vl, vy / vl else vx, vy = ptx, pty end
  local apex_x = jx + vx * (pw0 * 0.38 + cw0 * 0.28)
  local apex_y = jy + vy * (pw0 * 0.38 + cw0 * 0.28)
  local cpx, cpy = mx * 0.35 + apex_x * 0.65, my * 0.35 + apex_y * 0.65
  local poly = { { jx, jy }, { ax, ay } }
  for k = 1, 5 do
    local t = k / 6
    local omt = 1 - t
    poly[#poly + 1] = {
      omt * omt * ax + 2 * omt * t * cpx + t * t * bx,
      omt * omt * ay + 2 * omt * t * cpy + t * t * by,
    }
  end
  poly[#poly + 1] = { bx, by }
  if B.area2(poly) < 0 then
    local rev = {}
    for i = #poly, 1, -1 do rev[#rev + 1] = poly[i] end
    poly = rev
  end
  return W:join(W:poly(poly, true), W:circle(jx, jy, max(pw0, cw0) * 0.46))
end

--- Paint or build a compound branch + offshoots hierarchy with smooth crotch
--- fillets in a single fill (no double-darkening X-blotches at joints).
--- `parent`: spine `segs` or `{ segs = ..., w = ..., profile = ..., ... }`.
--- `children`: array of `{ u = 0.55, segs = ... (or angle = ..., len = ..., flow = ..., bend = ...), w = ..., profile = ... }`.
--- `o`: stroke/fill options (`w`, `profile`, `rgb`, `alpha`, `blend`, `cap`, `nofill`, `layer`, `fillet`).
--- Returns `bb, compound_path, parentS, child_spines`.
function B.fork(ctx, parent, children, o)
  o = o or {}
  local W = ctx.pdf
  local pspec = (type(parent) == "table" and parent.segs) and parent or { segs = parent }
  local po = {}
  for k, v in pairs(o) do po[k] = v end
  for k, v in pairs(pspec) do if k ~= "segs" then po[k] = v end end
  po.profile = po.profile or "branch"
  local ppath, pS, _, pwfn = B.outline_path(ctx, pspec.segs, po)
  if not ppath then return nil, nil, pS, {} end
  local parts = { ppath }
  local cspines = {}
  for _, ch in ipairs(children or {}) do
    local u = ch.u or 0.5
    local csegs = ch.segs
    if not csegs and ch.angle and ch.len then
      csegs = B.offshoot(pS, u, ch.angle, ch.len, ch.flow, ch.bend)
    end
    if csegs then
      local co = {}
      for k, v in pairs(po) do co[k] = v end
      for k, v in pairs(ch) do if k ~= "segs" then co[k] = v end end
      co.w = ch.w or (pwfn(u) * (ch.scale or 0.72))
      co.profile = ch.profile or "branch"
      co.cap = ch.cap ~= false
      local cpath, cS, _, cwfn = B.outline_path(ctx, csegs, co)
      if cpath then
        parts[#parts + 1] = cpath
        if o.fillet ~= false and ch.fillet ~= false then
          parts[#parts + 1] = B.crotch(W, pS, u, pwfn, cS, cwfn, ch.fillet)
        end
        cspines[#cspines + 1] = cS
      end
    end
  end
  local compound = W:join(parts)
  if o.nofill then return compound and compound.bbox or nil, compound, pS, cspines end
  if o.layer then W:layer(o.layer) end
  local bb = W:fill(compound, o.rgb or { 0, 0, 0 }, o.alpha or 1, { blend = o.blend })
  return bb, compound, pS, cspines
end

--- Ink dot (ten): small rotated ellipse. o = {rgb, alpha, blend, aspect=0.7, rot}
function B.dot(ctx, x, y, r, o)
  o = o or {}
  local rot = o.rot or (ctx.rng and ctx.rng.range(0, pi) or 0)
  return ctx.pdf:fill(ctx.pdf:ellipse(x, y, r, r * (o.aspect or 0.7), rot), o.rgb or { 0, 0, 0 }, o.alpha or 1, { blend = o.blend })
end

return B
