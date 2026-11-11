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
-- kacho-wash.lua: watercolour wash primitives for kacho (irregular blobs, soft
-- glazes, nijimi layered bleed, soft radial wash, bokashi gradient, mokkotsu
-- boneless fill, rim darkening, tarashikomi bloom, granulation mottle, lifted
-- streaks).
--
-- Portions adapted from florilegium (https://github.com/kevinraymond/florilegium),
-- florilegium-ink.lua (harmonic blob outline) and florilegium-flora.lua (mottle
-- granulation: darker multiply blotches + lighter blotches + fine specks; outline
-- pooling stroked under a clip; lifted light streaks).
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
--   * Harmonic + fbm irregular outline (Wsh.blob): adapted from florilegium
--     florilegium-ink.lua `blob` (Kevin Raymond, 2026, MIT).
--   * Granulation mottle: dark/light blotches + specks (Wsh.mottle): adapted
--     from florilegium florilegium-flora.lua `mottle` (MIT); here the blotches
--     are soft-masked spots instead of hard-edged fills.
--   * Watercolour effect vocabulary -- glazing in thin layers, edge darkening
--     (pooling, Wsh.rim), backruns (Wsh.tarashikomi), granulation, lifted
--     pigment: inspired by C. J. Curtis, S. E. Anderson, J. E. Seims,
--     K. W. Fleischer, D. H. Salesin, "Computer-Generated Watercolor",
--     Proc. SIGGRAPH 97, pp. 421-430 (effects taxonomy only; no fluid
--     simulation is implemented).
--   * Step-bounded layering (Wsh.step_alpha, Wsh.glaze): per-layer alpha
--     limited so one hard layer edge changes the rendered grey level by fewer
--     than ~4.5/255, using Rec. ITU-R BT.601 luma weights (0.299, 0.587,
--     0.114); stochastic radial ramp from many jittered layers. Own design.
--   * Point in polygon (Wsh.inside): standard crossing-number (even-odd) test.
--   * Smoothstep feathers / soft masks: native PDF shadings via kacho-pdf.
--
-- Pure Lua. Every painting function takes ctx first (ctx.pdf writer, ctx.rng,
-- ctx.palette) and returns the bbox of what it painted. Anti-banding rules:
-- layers have independently noisy, crossing edges; every hard-edged layer has
-- alpha <= min(0.12, step_alpha(colour)) so no single edge is a visible step;
-- gradients and spots use native PDF shadings / soft masks (continuous).
local Wsh = {}

local sin, cos, pi, min, max, sqrt, abs, log, ceil =
  math.sin, math.cos, math.pi, math.min, math.max, math.sqrt, math.abs, math.log, math.ceil

local function union(a, b)
  if not a then return b end
  if not b then return a end
  return { x0 = min(a.x0, b.x0), y0 = min(a.y0, b.y0), x1 = max(a.x1, b.x1), y1 = max(a.y1, b.y1) }
end
Wsh.union = union

local function paper(ctx)
  return (ctx.palette and ctx.palette.paper) or { 0.953, 0.933, 0.863 }
end

---------------------------------------------------------------- step bound
local function luma(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end
Wsh.luma = luma

--- Visible change of one hard-edged layer of colour c at alpha 1 over bg,
--- as a fraction of full scale: luma difference, floored by 0.6 x the largest
--- channel difference (so equal-luma colour steps still count). multiply:
--- the layer darkens bg to bg*c.
function Wsh.contrast(c, bg, blend)
  local d, dc
  if blend == "multiply" then
    local m = { bg[1] * c[1], bg[2] * c[2], bg[3] * c[3] }
    d = abs(luma(bg) - luma(m))
    dc = max(abs(bg[1] - m[1]), abs(bg[2] - m[2]), abs(bg[3] - m[3]))
  else
    d = abs(luma(c) - luma(bg))
    dc = max(abs(c[1] - bg[1]), abs(c[2] - bg[2]), abs(c[3] - bg[3]))
  end
  return max(d, 0.6 * dc)
end

--- Largest per-layer alpha (<= 0.12) whose hard edge changes the rendered
--- grey level by fewer than `levels` of 255 over bg (default 3.2).
function Wsh.step_alpha(c, bg, levels, blend)
  local d = max(Wsh.contrast(c, bg, blend), Wsh.contrast(c, { 1, 1, 1 }, blend))
  if d < 1e-3 then return 0.12 end
  return max(0.005, min(0.12, (levels or 3.2) / (255 * d)))
end

---------------------------------------------------------------- outlines
--- Irregular closed outline around (cx,cy): radii rx, ry modulated by low
--- harmonics (2, 3, 5) and fbm. rough ~0.1..0.5, n points (>= 12), rot radians.
function Wsh.blob(rng, cx, cy, rx, ry, rough, n, rot)
  n = max(12, n or 32)
  rough = rough or 0.25
  rot = rot or rng.range(0, 2 * pi)
  local f = rng.noise(3)
  local ph = { rng.range(0, 2 * pi), rng.range(0, 2 * pi), rng.range(0, 2 * pi) }
  local amp = { rng.range(0.4, 1), rng.range(0.2, 0.6), rng.range(0.1, 0.4) }
  local fo = rng.range(0, 40)
  local out = {}
  local cr, sr = cos(rot), sin(rot)
  for i = 0, n - 1 do
    local a = 2 * pi * i / n
    -- noise sampled on a circle so the outline closes seamlessly
    local nz = f(fo + 1.5 * cos(a)) * 0.5 + f(fo + 7 + 1.5 * sin(a)) * 0.5
    local k = 1 + rough * (0.45 * amp[1] * sin(2 * a + ph[1]) + 0.35 * amp[2] * sin(3 * a + ph[2])
      + 0.25 * amp[3] * sin(5 * a + ph[3]) + 0.5 * nz)
    k = max(0.35, k)   -- clamp: never fold through the centre (no spikes/self-intersection)
    local px, py = rx * k * cos(a), ry * k * sin(a)
    out[#out + 1] = { cx + px * cr - py * sr, cy + px * sr + py * cr }
  end
  return out
end

--- Resolve a shape spec: {x=,y=,rx=,ry=,rot=} ellipse or a point list.
local function shape_params(shape)
  if shape.x then return shape.x, shape.y, shape.rx or shape.r, shape.ry or shape.r or shape.rx, shape.rot end
  -- polygon: use its bbox
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(shape) do
    x0, y0, x1, y1 = min(x0, p[1]), min(y0, p[2]), max(x1, p[1]), max(y1, p[2])
  end
  return (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2, 0
end

--- Copy of a closed outline with each point moved radially (from the bbox
--- centre) by a smooth closed noise of relative amplitude `amp`, then scaled
--- by s and shifted by (ox, oy). Neighbouring points move together, so the
--- edge wanders instead of zig-zagging.
local function perturb(rng, pts, amp, s, ox, oy)
  local cx, cy = shape_params(pts)
  local f = rng.noise(2)
  local fo = rng.range(0, 60)
  local n = #pts
  local q = {}
  for k, p in ipairs(pts) do
    local a = 2 * pi * (k - 1) / n
    local j = 1 + amp * (f(fo + 1.3 * cos(a)) + f(fo + 9 + 1.3 * sin(a)))
    q[k] = { cx + (p[1] - cx) * s * j + (ox or 0), cy + (p[2] - cy) * s * j + (oy or 0) }
  end
  return q
end
Wsh.perturb = perturb

---------------------------------------------------------------- soft spots
--- Soft elliptical spot: a rect under a rotated radial soft mask (continuous,
--- no edge). Paint stays inside the mask form BBox (1.6 r) -- rect corners at
--- 1.42 r. Returns the visible bbox (mask ellipse, axis-aligned).
local function spot(W, x, y, rx, ry, rot, c, a, o)
  o = o or {}
  local g = W:fade_radial(x, y, rx, ry, o.inner or 0, o.power or 1.4, rot)
  if not g then return nil end
  local k = 1.0                            -- half-size of the painted square in mask units
  local cr, sr = cos(rot or 0), sin(rot or 0)
  local pts = {}
  for _, u in ipairs({ { -k, -k }, { k, -k }, { k, k }, { -k, k } }) do
    local px, py = u[1] * rx, u[2] * ry
    pts[#pts + 1] = { x + px * cr - py * sr, y + px * sr + py * cr }
  end
  W:with_gs(g, function() W:fill(W:poly(pts, true), c, a, { blend = o.blend }) end)
  local ex = sqrt((rx * cr) ^ 2 + (ry * sr) ^ 2)
  local ey = sqrt((rx * sr) ^ 2 + (ry * cr) ^ 2)
  return { x0 = x - ex, y0 = y - ey, x1 = x + ex, y1 = y + ey }
end
Wsh.spot = spot

---------------------------------------------------------------- glaze
--- Soft glaze: `n` blob layers with independent noisy edges whose scale runs
--- from s_out (largest, first) down to s_in, each at a small alpha bounded by
--- step_alpha, so the wash is saturated at the core and fades to transparent
--- at a noisy edge without any visible contour step.
--- o = { rgb, alpha = 0.45 (opacity reached where all layers overlap),
---   s_in = 0.4, s_out = 1.0, rough = 0.3, drift = 0 (how far the small core
---   layers shift toward `flow`, fraction of the radius), flow = angle,
---   rot, n = auto (6..nmax), nmax = 24, levels = 3.2, np = 44, blend }
--- Returns the bbox (control-point hull of every layer).
function Wsh.glaze(ctx, cx, cy, rx, ry, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local c = o.rgb or (ctx.palette and ctx.palette.role("wash")) or { 0.6, 0.6, 0.6 }
  local amax = Wsh.step_alpha(c, paper(ctx), o.levels, o.blend)
  local target = max(0.02, min(0.92, o.alpha or 0.45))
  local nmax = o.nmax or 24
  local n = o.n or ceil(log(1 - target) / log(1 - amax))
  n = max(6, min(nmax, n))
  local a = min(amax, 1 - (1 - target) ^ (1 / n))
  local s_in, s_out = o.s_in or 0.4, o.s_out or 1.0
  local rough = o.rough or 0.3
  local rot = o.rot or rng.range(0, 2 * pi)
  local flow = o.flow or rng.range(0, 2 * pi)
  local drift = o.drift or 0
  local fx, fy = cos(flow), sin(flow)
  local bb
  for i = 1, n do
    local t = (i - 1) / max(1, n - 1)
    local s = s_out - (s_out - s_in) * t ^ 0.85
    local d = drift * t
    local pts = Wsh.blob(rng, cx + fx * rx * d + rng.sym(0.04 * rx), cy + fy * ry * d + rng.sym(0.04 * ry),
      rx * s, ry * s * rng.range(0.92, 1.05), rough, o.np or 44, rot + rng.sym(0.3))
    bb = union(bb, W:fill(W:smooth(pts, true), c, a * rng.range(0.85, 1.0), { blend = o.blend }))
  end
  return bb, a, n
end

---------------------------------------------------------------- nijimi
--- Nijimi / watercolour wash: an irregular blot that reads as wet pigment on
--- paper, not as a vector disc.
--- shape = {x=,y=,rx=,ry=,rot=} (or a point list, whose bbox is used).
--- o = { rgb, body = 0.36 (core opacity of the body glaze, <= 0.6),
---   fringe = 10 (bleed layers), falpha = per-fringe-layer alpha (auto,
---   always <= step_alpha), flow = angle (radians) toward which the wash
---   bleeds and pigment settles (random if nil), rough = 0.32 (edge
---   irregularity), rim = 0.10 (pooled dark edge strength; false = none),
---   grain = true (soft granulation blotches + specks), lift = 2 (soft
---   paper-coloured lighter patches), bloom = 0 (tarashikomi backruns), blend }
--- Construction: body = a soft glaze whose small core layers drift toward
--- `flow`; fringe = low-alpha layers growing out on the flow side only, each
--- with its own rotation and noise so edges cross, never nest; lifts and
--- granulation are soft-masked spots clipped to the body.
--- Returns the bbox (control-point hull; contains every painted point).
function Wsh.nijimi(ctx, shape, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local cx, cy, rx, ry, rot = shape_params(shape)
  rot = rot or rng.range(0, 2 * pi)
  local c = o.rgb or (ctx.palette and ctx.palette.role("wash")) or { 0.6, 0.6, 0.6 }
  local amax = Wsh.step_alpha(c, paper(ctx), o.levels, o.blend)
  local nf = o.fringe or 10
  local falpha = o.falpha
  if not falpha then
    local pal = package.loaded["kacho-palette"]
    falpha = pal and pal.layer_alpha(c, paper(ctx)) * 1.1 or 0.03
  end
  falpha = min(amax, falpha)
  local rough = o.rough or 0.32
  local flow = o.flow or rng.range(0, 2 * pi)
  local fx, fy = cos(flow), sin(flow)
  -- body: soft glaze, saturated core settled toward the flow side
  local bb = Wsh.glaze(ctx, cx, cy, rx, ry, { rgb = c, alpha = min(0.6, o.body or 0.36), s_in = 0.32, s_out = 0.95,
    rough = rough * 0.85, drift = 0.14, flow = flow, rot = rot, blend = o.blend, levels = o.levels, np = 44 })
  local main = Wsh.blob(rng, cx + fx * rx * 0.04, cy + fy * ry * 0.04, rx * 0.95, ry * 0.95, rough * 0.8, 44, rot + rng.sym(0.08))
  -- one-sided bleed into wet paper
  for i = 1, nf do
    local t = (i / nf) ^ 0.8
    local s = 0.88 + 0.20 * t
    local d = 0.04 + 0.16 * t
    local pts = Wsh.blob(rng, cx + fx * rx * d + rng.sym(0.03 * rx), cy + fy * ry * d + rng.sym(0.03 * ry),
      rx * s, ry * s * rng.range(0.9, 1.05), rough, 48, rot + rng.sym(0.3))
    bb = union(bb, W:fill(W:smooth(pts, true), c, falpha * rng.range(0.55, 0.95), { blend = o.blend }))
  end
  local mainpath = W:smooth(main, true)
  if mainpath then bb = union(bb, mainpath.bbox) end
  -- lighter patches (paper showing through): soft spots inside the body
  local nl = o.lift or 2
  if nl > 0 and mainpath then
    W:clip(mainpath)
    for _ = 1, nl do
      -- two offset soft spots (each <= 0.06) well inside main so the clip never slices them
      local s = rng.range(0.20, 0.34)
      local lx, ly = cx - fx * rx * 0.18 + rng.sym(0.22 * rx), cy - fy * ry * 0.18 + rng.sym(0.22 * ry)
      local lr = rng.range(0, pi)
      spot(W, lx, ly, rx * s, ry * s * rng.range(0.55, 0.8), lr, paper(ctx), 0.06)
      spot(W, lx + rng.sym(0.22 * rx * s), ly + rng.sym(0.22 * ry * s), rx * s * 0.6, ry * s * 0.45,
        lr + rng.sym(0.6), paper(ctx), rng.range(0.04, 0.06))
    end
    W:unclip()
  end
  -- pooled pigment at the drying edge (uneven, wide & soft on part of the outline)
  if o.rim ~= false then
    bb = union(bb, Wsh.rim(ctx, main, { rgb = c, strength = min(0.06, o.rim or 0.06), width = max(2.2, min(rx, ry) * 0.16), partial = true }))
  end
  -- granulation
  if o.grain ~= false then
    bb = union(bb, Wsh.mottle(ctx, main, { dark = c, n = 7, size = min(rx, ry) * 0.22, specks = math.floor(8 + rx * ry / 120) }))
  end
  if (o.bloom or 0) > 0 then
    bb = union(bb, Wsh.tarashikomi(ctx, main, { rgb = c, n = o.bloom, size = min(rx, ry) * 0.32 }))
  end
  return bb
end

--- Soft wash (airbrush ellipse): a plain rectangle painted through an elliptical
--- radial soft mask, so the mask alone defines a continuous edge (haze, kasumi
--- puffs, glows). The painted rectangle (1.0 r) covers the entire non-zero mask
--- ellipse while staying well inside the mask form's BBox (1.6 r).
--- o = { rgb, alpha = 0.35, inner = 0.1, power = 1.6, blend }
function Wsh.soft(ctx, cx, cy, rx, ry, o)
  o = o or {}
  local W = ctx.pdf
  local c = o.rgb or (ctx.palette and ctx.palette.role("mist")) or { 0.8, 0.8, 0.8 }
  local g = W:fade_radial(cx, cy, rx, ry, o.inner or 0.1, o.power)
  if not g then return nil end
  local k = 1.0
  W:with_gs(g, function()
    W:fill(W:rect(cx - rx * k, cy - ry * k, cx + rx * k, cy + ry * k), c, o.alpha or 0.35, { blend = o.blend })
  end)
  -- visible extent is bounded by the mask ellipse (alpha 0 at the rim)
  return { x0 = cx - rx, y0 = cy - ry, x1 = cx + rx, y1 = cy + ry }
end

--- Bokashi: native axial gradient c0 -> c1 across a rect, painted through a
--- rectangular feather mask (W:fade_box) so no edge of the rect is hard unless
--- requested. rect = {x0,y0,x1,y1}; o = { dir = "down"|"up"|"left"|"right"
--- (direction from c0 to c1, default "down"), alpha = 1,
--- fx = {left, right}, fy = {bottom, top}: feather widths as fractions of the
--- rect (default: 0.15 on the sides, fully faded toward the c1 end),
--- fade = false: no mask (crisp rect, e.g. inside a framed panel), blend }
function Wsh.bokashi(ctx, rect, c0, c1, o)
  o = o or {}
  local W = ctx.pdf
  local dir = o.dir or "down"
  local x0, y0, x1, y1
  if dir == "down" then x0, y0, x1, y1 = rect.x0, rect.y1, rect.x0, rect.y0
  elseif dir == "up" then x0, y0, x1, y1 = rect.x0, rect.y0, rect.x0, rect.y1
  elseif dir == "left" then x0, y0, x1, y1 = rect.x1, rect.y0, rect.x0, rect.y0
  else x0, y0, x1, y1 = rect.x0, rect.y0, rect.x1, rect.y0 end
  local pat = W:axial(x0, y0, x1, y1, { { 0, c0 }, { 1, c1 } })
  local path = o.path or W:rect(rect.x0, rect.y0, rect.x1, rect.y1)
  if o.fade == false then
    return W:fill_pattern(path, pat, o.alpha or 1, { blend = o.blend })
  end
  local fx, fy = o.fx, o.fy
  if not fx or not fy then
    local side, far = 0.15, 0.85
    if dir == "down" then fx, fy = fx or { side, side }, fy or { far, 0.04 }
    elseif dir == "up" then fx, fy = fx or { side, side }, fy or { 0.04, far }
    elseif dir == "left" then fx, fy = fx or { far, 0.04 }, fy or { side, side }
    else fx, fy = fx or { 0.04, far }, fy or { side, side } end
  end
  local g = W:fade_box(rect, fx, fy)
  local bb
  W:with_gs(g, function() bb = W:fill_pattern(path, pat, o.alpha or 1, { blend = o.blend }) end)
  return bb
end

--- Point-in-polygon (even-odd rule).
function Wsh.inside(poly, x, y)
  local c = false
  local n = #poly
  local j = n
  for i = 1, n do
    local a, b = poly[i], poly[j]
    if ((a[2] > y) ~= (b[2] > y)) and (x < (b[1] - a[1]) * (y - a[2]) / (b[2] - a[2]) + a[1]) then c = not c end
    j = i
  end
  return c
end

local function area2(pts)
  local a = 0
  for i = 1, #pts do local p, q = pts[i], pts[i % #pts + 1]; a = a + p[1] * q[2] - q[1] * p[2] end
  return a
end

--- Rim darkening (pigment pooling at the drying edge), always inside the shape.
--- pts = closed outline points. o = { rgb, strength = 0.12 (total, <= 0.3),
--- width = 2.0, partial = false }
--- The pool is built from several passes, each at an alpha bounded by
--- step_alpha (Multiply), so the inner edge of the pool is a graded ramp, not
--- a contour line.
--- Full: the outline is stroked at decreasing widths under a clip.
--- partial = true: broken pooling as filled tapered ribbons just inside random
--- runs of the outline; each ribbon is repeated at decreasing widths.
function Wsh.rim(ctx, pts, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local c = o.rgb or { 0.3, 0.3, 0.3 }
  local strength = min(0.3, o.strength or 0.12)
  local width = o.width or 2.0
  local full = W:smooth(pts, true)
  if not full then return nil end
  local amax = Wsh.step_alpha(c, paper(ctx), 4.5, "multiply")
  local passes = max(2, min(6, ceil(strength / amax)))
  local a = min(0.12, strength / passes)
  W:clip(full)
  if o.partial then
    local n = #pts
    local sgn = area2(pts) >= 0 and 1 or -1          -- inward normal side
    local wn = rng.noise(2)
    local runs = {}
    local i = rng.int(1, n)
    local remaining = n
    while remaining > 0 do
      local len = rng.int(max(3, n // 6), max(4, n // 2))
      if rng.chance(0.7) then
        local run = {}
        for k = 0, len do
          local p = pts[(i + k - 1) % n + 1]
          local pp = pts[(i + k - 2) % n + 1]
          local pn = pts[(i + k) % n + 1]
          local tx, ty = pn[1] - pp[1], pn[2] - pp[2]
          local tl = sqrt(tx * tx + ty * ty)
          if tl > 1e-9 then
            local t = k / len
            run[#run + 1] = { p = p, nx = -ty / tl * sgn, ny = tx / tl * sgn,
              w = width * (1.1 + 0.6 * wn(i * 0.37 + k * 0.3)) * sin(pi * t) ^ 0.7 }
          end
        end
        if #run > 3 then runs[#runs + 1] = run end
      end
      local gap = rng.int(2, max(3, n // 5))
      i = i + len + gap
      remaining = remaining - len - gap
    end
    for pss = 1, passes do
      local f = 1 - (pss - 1) / passes              -- full width .. narrow
      local parts = {}
      for _, run in ipairs(runs) do
        local poly = {}
        for k = 1, #run do local r = run[k]; poly[#poly + 1] = { r.p[1] - r.nx * 0.3, r.p[2] - r.ny * 0.3 } end
        for k = #run, 1, -1 do local r = run[k]; poly[#poly + 1] = { r.p[1] + r.nx * r.w * f, r.p[2] + r.ny * r.w * f } end
        parts[#parts + 1] = W:smooth(poly, true)
      end
      if #parts > 0 then W:fill(W:join(parts), c, a, { blend = "multiply" }) end
    end
  else
    for pss = 1, passes do
      local f = 1 - (pss - 1) / passes
      W:stroke(full, c, width * 2.2 * f, a, { blend = "multiply" })
    end
  end
  W:unclip()
  return { x0 = full.bbox.x0, y0 = full.bbox.y0, x1 = full.bbox.x1, y1 = full.bbox.y1 }
end

--- Watercolour band (ground wash, mist, sky stroke) -- explorer_m2_3's
--- wash_band design: layers with independent long-wavelength noisy edges and
--- a shared thickness envelope, ends dissolved by a rectangular feather mask
--- and a smooth end taper (no seam, no stripes), optional rim pooling that
--- follows the *outer envelope* of all layers (never a mid-wash contour),
--- clustered granulation kept inside the wash.
--- spec = { x0, x1, y (centre line), height = 20, rgb, alpha = 0.35,
---   layers = auto (>= 10, enough that each layer stays under step_alpha,
---   <= 24), pool = true, gran = 0.6 (0..1), fade = {0.2, 0.2} (end feathers
---   as fractions), darken = rgb for pooling/granulation, wavelength,
---   flat_bottom = false, blend }
--- Returns the bbox (the mask box: nothing paints outside it).
function Wsh.band(ctx, spec)
  local W, R = ctx.pdf, ctx.rng
  local x0, x1, y = spec.x0, spec.x1, spec.y
  local hh = (spec.height or 20) / 2
  local col = spec.rgb or (ctx.palette and ctx.palette.role("wash")) or { 0.7, 0.6, 0.4 }
  local alpha = min(0.6, spec.alpha or 0.35)
  local amax = Wsh.step_alpha(col, paper(ctx), 4.5, spec.blend)
  local nl = spec.layers or max(10, min(24, ceil(alpha * 1.5 / amax)))
  local span = x1 - x0
  if span <= 2 or hh <= 0.5 then return nil end
  local lam = spec.wavelength or max(30, span / 6)
  local dk = spec.darken or col
  local bb = { x0 = x0 - 2, y0 = y - hh * 1.8, x1 = x1 + 2, y1 = y + hh * 1.8 }
  local g = W:fade_box(bb, spec.fade or { 0.2, 0.2 }, { 0, 0 })
  local np = max(24, math.floor(span / 4))
  local tops = {}               -- per layer: {a0, a1, top points}
  local envpoly
  W:with_gs(g, function()
    local env = R.noise(2)
    local eph = R.range(0, 100)
    for L = 1, nl do
      local ft, fb = R.noise(3), R.noise(3)
      local ph = R.range(0, 100)
      local sc = 0.75 + 0.4 * ((L - 1) / max(1, nl - 1)) ^ 0.8
      local dy = R.sym(hh * 0.12)
      local a0, a1 = x0 + R.range(0, 0.06) * span, x1 - R.range(0, 0.06) * span
      local top, bot = {}, {}
      for i = 0, np do
        local t = i / np
        local x = a0 + (a1 - a0) * t
        -- smooth end taper over ~14% of the layer (no near-vertical ends)
        local q = min(t, 1 - t) / 0.14
        local taper = q >= 1 and 1 or (q * q * (3 - 2 * q)) ^ 0.6
        local e = max(0.35, 1 + 0.6 * env(x / (span / 2.5) + eph))
        local ht = hh * sc * taper * e * (1 + 0.7 * ft(x / lam + ph))
        local hb = hh * sc * taper * e * (1 + 0.35 * fb(x / lam + ph + 9))
        top[#top + 1] = { x, min(y + hh * 1.75, y + dy + max(0, ht)) }
        bot[#bot + 1] = { x, max(y - hh * 1.75, y + dy - max(0, hb) * (spec.flat_bottom and 0.4 or 1)) }
      end
      local poly = {}
      for i = 1, #bot do poly[#poly + 1] = bot[i] end
      for i = #top, 1, -1 do poly[#poly + 1] = top[i] end
      local a = min(amax, alpha / nl * R.range(0.7, 1.3) * (1.5 - 0.6 * (L - 1) / max(1, nl - 1)))
      W:fill(W:poly(poly, true), col, a, { blend = spec.blend })
      tops[#tops + 1] = { a0 = a0, a1 = a1, top = top, bot = bot }
    end
    -- outer envelope of all layers on a common grid (max top / min bottom)
    local et, eb = {}, {}
    for i = 0, np do
      local x = x0 + span * i / np
      local yt, yb
      for _, Ly in ipairs(tops) do
        if x >= Ly.a0 and x <= Ly.a1 then
          local u = (x - Ly.a0) / max(1e-9, Ly.a1 - Ly.a0) * np
          local k = min(np, math.floor(u))
          local f = u - k
          local k2 = min(np, k + 1)
          local vt = Ly.top[k + 1][2] + (Ly.top[k2 + 1][2] - Ly.top[k + 1][2]) * f
          local vb = Ly.bot[k + 1][2] + (Ly.bot[k2 + 1][2] - Ly.bot[k + 1][2]) * f
          yt = yt and max(yt, vt) or vt
          yb = yb and min(yb, vb) or vb
        end
      end
      if yt then et[#et + 1] = { x, yt }; eb[#eb + 1] = { x, yb } end
    end
    if #et >= 4 then
      envpoly = {}
      for i = 1, #eb do envpoly[#envpoly + 1] = eb[i] end
      for i = #et, 1, -1 do envpoly[#envpoly + 1] = et[i] end
    end
    if spec.pool ~= false and envpoly then
      -- graded pooling hanging from the envelope's upper edge, clipped to the
      -- envelope: several passes at a step-bounded alpha, widths shrinking
      local pa = Wsh.step_alpha(dk, paper(ctx), 2.5, "multiply")
      local passes = 4
      local a = min(0.022, pa * 0.6, alpha * 0.22 / passes)
      local w0 = max(2.8, min(7.0, hh * 0.25))
      local wn = R.noise(2)
      local runs, i = {}, 1
      while i < #et do
        local len = R.int(8, 22)
        if R.chance(0.55) then
          local j1 = min(#et, i + len)
          if j1 - i >= 3 then runs[#runs + 1] = { i, j1 } end
        end
        i = i + len + R.int(4, 14)
      end
      W:clip(W:poly(envpoly, true))
      for pss = 1, passes do
        local f = 1 - (pss - 1) / passes
        local parts = {}
        for _, rn in ipairs(runs) do
          local up, dn = {}, {}
          for k = rn[1], rn[2] do
            local t = (k - rn[1]) / max(1, rn[2] - rn[1])
            local w = w0 * (0.75 + 0.45 * wn(k * 0.2)) * sin(pi * t) ^ 0.65 * f
            up[#up + 1] = { et[k][1], et[k][2] + 0.4 }
            dn[#dn + 1] = { et[k][1], et[k][2] - w }
          end
          local poly = {}
          for k = 1, #dn do poly[#poly + 1] = dn[k] end
          for k = #up, 1, -1 do poly[#poly + 1] = up[k] end
          parts[#parts + 1] = W:smooth(poly, true)
        end
        if #parts > 0 then W:fill(W:join(parts), dk, a, { blend = "multiply" }) end
      end
      W:unclip()
    end
    local gr = spec.gran or 0.6
    if gr > 0 and envpoly then
      local f = R.noise(2)
      local dots = {}
      local nd = math.floor(span * hh / 12 * gr)
      for _ = 1, nd do
        local x, yy = R.range(x0, x1), y + R.sym(hh * 0.9)
        if f(x / 25) + 0.5 * f(yy / 9 + 50) > 0.05 and Wsh.inside(envpoly, x, yy) then
          local r = R.range(0.25, 0.6)
          dots[#dots + 1] = W:ellipse(x, yy, r, r * R.range(0.5, 1), R.range(0, pi))
        end
      end
      if #dots > 0 then W:fill(W:join(dots), dk, min(0.03, amax * 0.7, alpha * 0.16), { blend = "multiply" }) end
    end
  end)
  return bb
end

--- Mokkotsu (boneless) fill: no outline. `layers` copies of the outline, each
--- with its own smooth radial edge noise (+-3%), so the edge is one soft,
--- slightly ragged boundary rather than nested rings; pigment pooling toward
--- `side` is a soft-masked spot clipped to the shape; optional rim.
--- pts = closed outline; o = { rgb, alpha = 0.12 per layer (<= 0.12),
---   layers = 7, side = angle (radians) toward which pigment pools,
---   pool = 0.10 (alpha of the pooling spot; false = none),
---   rim = 0.1 (strength or false), rim_width }
function Wsh.mokkotsu(ctx, pts, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local c = o.rgb or { 0.4, 0.4, 0.4 }
  local cx, cy, rx, ry = shape_params(pts)
  local side = o.side or rng.range(0, 2 * pi)
  local nl = o.layers or 7
  local a = min(0.12, o.alpha or 0.12)
  local bb
  for _ = 1, nl do
    local q = perturb(rng, pts, 0.015, rng.range(0.975, 1.0), rng.sym(0.01 * rx), rng.sym(0.01 * ry))
    bb = union(bb, W:fill(W:smooth(q, true), c, a * rng.range(0.85, 1.0), { blend = o.blend }))
  end
  local path = W:smooth(pts, true)
  if path then bb = union(bb, path.bbox) end
  if o.pool ~= false and path then
    W:clip(path)
    spot(W, cx + cos(side) * rx * 0.45, cy + sin(side) * ry * 0.45, rx * 0.75, ry * 0.75, side, c,
      min(0.12, o.pool or 0.10), { blend = "multiply" })
    W:unclip()
  end
  if o.rim ~= false then
    bb = union(bb, Wsh.rim(ctx, pts, { rgb = c, strength = o.rim or 0.1, width = o.rim_width or max(0.6, min(rx, ry) * 0.12), partial = true }))
  end
  return bb
end

--- Tarashikomi: pigment dropped into a wet wash; ragged blooms with a darker
--- backrun ring and a paler core, clipped to the shape. The ring is several
--- low-alpha (<= step_alpha, Multiply) jittered even-odd annuli, the core a
--- soft paper-coloured spot: every layer <= 0.12 and no hard contour.
--- pts = outline; o = { rgb, n = 4, size = auto }
function Wsh.tarashikomi(ctx, pts, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local c = o.rgb or { 0.35, 0.4, 0.3 }
  local cx, cy, rx, ry = shape_params(pts)
  local size = o.size or min(rx, ry) * 0.45
  local path = W:smooth(pts, true)
  if not path then return nil end
  local amax = Wsh.step_alpha(c, paper(ctx), 2.5, "multiply")
  local ra = min(0.022, amax * 0.65)
  W:clip(path)
  for i = 1, (o.n or 4) do
    local x, y
    if i % 2 == 0 then
      local a = rng.range(0, 2 * pi)
      local d = rng.range(0.35, 0.58)
      x, y = cx + cos(a) * rx * d, cy + sin(a) * ry * d
    else
      x, y = cx + rng.sym(rx * 0.42), cy + rng.sym(ry * 0.42)
    end
    local r = size * rng.range(0.68, 1.15)
    local rot = rng.range(0, 2 * pi)
    -- body of the bloom: a soft darker spot
    spot(W, x, y, r, r * 0.8, rot, c, min(0.06, 1.6 * amax), { blend = "multiply", power = 2 })
    -- backrun ring: 5 jittered annuli with wide radial spread, each very faint
    for k = 1, 5 do
      local t = (k - 1) / 4
      local ro = 0.88 + 0.20 * t + rng.sym(0.04)
      local ri = 0.58 + 0.18 * (1 - t) + rng.sym(0.04)
      local outer = Wsh.blob(rng, x + rng.sym(0.06 * r), y + rng.sym(0.06 * r), r * ro, r * ro * 0.82, 0.45, 48, rot + rng.sym(0.25))
      local inner = Wsh.blob(rng, x + rng.sym(0.08 * r), y + rng.sym(0.08 * r), r * ri, r * ri * 0.78, 0.45, 48, rot + rng.sym(0.3))
      W:fill(W:join(W:smooth(outer, true), W:smooth(inner, true)), c, ra, { blend = "multiply", evenodd = true })
    end
    -- paler core where the dropped water pushed the pigment out
    spot(W, x, y, r * 0.48, r * 0.36, rot, paper(ctx), 0.06, { power = 1.6 })
  end
  W:unclip()
  return { x0 = path.bbox.x0, y0 = path.bbox.y0, x1 = path.bbox.x1, y1 = path.bbox.y1 }
end

--- Granulation mottle inside an outline (florilegium mottle, adapted): darker
--- multiply blotches, lighter blotches, then fine specks. Blotches are
--- soft-masked rotated ellipses (no hard edge). o = { dark, light, n = 8,
--- size = auto, specks = 12 }
function Wsh.mottle(ctx, pts, o)
  o = o or {}
  local W, rng = ctx.pdf, ctx.rng
  local path = W:smooth(pts, true)
  if not path then return nil end
  local b = path.bbox
  local size = o.size or min(b.x1 - b.x0, b.y1 - b.y0) * 0.25
  local dark = o.dark or { 0.3, 0.3, 0.3 }
  local light = o.light or paper(ctx)
  W:clip(path)
  for _ = 1, (o.n or 8) do
    local x, y = rng.range(b.x0, b.x1), rng.range(b.y0, b.y1)
    local r = size * rng.range(0.6, 1.5)
    local ry = r * rng.range(0.5, 1)
    if rng.chance(0.6) then spot(W, x, y, r, ry, rng.range(0, pi), dark, rng.range(0.04, 0.07), { blend = "multiply" })
    else spot(W, x, y, r, ry, rng.range(0, pi), light, rng.range(0.04, 0.07)) end
  end
  local sp = {}
  for _ = 1, (o.specks or 12) do
    local x, y, r, a = rng.range(b.x0, b.x1), rng.range(b.y0, b.y1), size * rng.range(0.03, 0.07), rng.range(0, pi)
    local c, s = cos(a), sin(a)
    sp[#sp + 1] = W:poly({ { x + r * c, y + r * s }, { x - 0.6 * r * s, y + 0.6 * r * c }, { x - r * c, y - r * s }, { x + 0.6 * r * s, y - 0.6 * r * c } }, true)
  end
  if #sp > 0 then W:fill(W:join(sp), dark, rng.range(0.025, 0.045), { blend = "multiply" }) end
  W:unclip()
  return { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 }
end

--- Lifted streak: light (paper/gofun) tapered stroke over a wash, as when the
--- painter lifts wet pigment. segs = spine; o = { w = 1.2, alpha = 0.35, rgb = paper }
function Wsh.lift(ctx, segs, o)
  o = o or {}
  local brush = ctx.brush or require("kacho-brush")
  return brush.stroke(ctx, segs, { w = o.w or 1.2, profile = o.profile or "both", rgb = o.rgb or paper(ctx),
    alpha = o.alpha or 0.35, jitter = 0.08 })
end

--- Approximate radius helper for layouts: distance between two points.
function Wsh.dist(x0, y0, x1, y1) return sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) end

return Wsh
