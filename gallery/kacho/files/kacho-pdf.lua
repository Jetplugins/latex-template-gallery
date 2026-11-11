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
-- kacho-pdf.lua: PDF content-stream writer for kacho (paths, fills, strokes, clips,
-- opacity/blend ExtGStates, native shadings, soft-mask fades, transparency groups).
--
-- Portions adapted from florilegium (https://github.com/kevinraymond/florilegium),
-- florilegium-ink.lua (numbered layers + flush, ExtGState registration naming and
-- caching, Catmull-Rom "smooth" path builder).
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
--   * Numbered layer buffers, ExtGState alpha/blend quantization & deduplication,
--     and Catmull-Rom spline to cubic Bézier conversion (W:smooth, k = tension/6):
--     adapted from florilegium-ink.lua (Kevin Raymond, 2026, MIT); see Edwin
--     Catmull and Raphael Rom, "A Class of Local Interpolating Splines", Computer
--     Aided Geometric Design, Academic Press, pp. 317-326, 1974.
--   * 4-arc cubic Bézier circle/ellipse approximation (W:ellipse): kappa =
--     (4/3)*(sqrt(2)-1) ≈ 0.5522847498; Tor Dokken, Morten Dæhlen, Tom Lyche,
--     and Knut Mørken, "Good Approximation of Circles by Curvature-Continuous
--     Bézier Curves", Computer Aided Geometric Design 7(1-4), pp. 33-41, 1990.
--   * Native PDF shadings and luminosity soft-mask XObjects (W:axial, W:radial,
--     W:fade_axial, W:fade_box, W:fade_radial): PDF Reference 1.7 / ISO 32000-1
--     §8.7.4.5.3-8.7.4.5.4 (ShadingType 2/3, FunctionType 2/3) and §11.6.5.2
--     (Soft-Mask Dictionaries, /S /Luminosity).
--
-- Pure Lua: all contact with LuaTeX goes through a *backend* table supplied by
-- kacho.lua (or a fake one in unit tests):
--   backend.extgs(name, dict)        register "/name << dict >>" as an ExtGState page resource
--   backend.pattern(name, objnum)    register "/name objnum 0 R" as a Pattern page resource
--   backend.obj(dict)       -> objnum   write an immediate PDF object
--   backend.stream(dict, data) -> objnum write an immediate stream object
--
-- Coordinates are page bp (origin bottom-left). Points are {x, y} arrays.
-- Colours are {r, g, b} in 0..1. A *path* is a table {s = "<pdf path ops>",
-- bbox = rect} built with the W:poly / W:smooth / W:circle / ... builders.
local M = {}

local fmt, concat = string.format, table.concat
local floor, min, max, sin, cos, huge = math.floor, math.min, math.max, math.sin, math.cos, math.huge

local function finite(x) return type(x) == "number" and x == x and x ~= huge and x ~= -huge end
M.finite = finite

--- Compact number formatting: 2 decimals, trailing zeros stripped, no "-0".
--- Extreme values are clamped to [-1e5, 1e5] so PDF streams remain valid.
local function num(x)
  if not finite(x) then return "0" end
  x = max(-1e5, min(1e5, x))
  local s = fmt("%.2f", x)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  if s == "-0" then s = "0" end
  return s
end
M.num = num
local function P(x, y) return num(x) .. " " .. num(y) end
--- Colour component sanitiser: non-finite -> 0, clamped to [0,1] (a NaN or
--- inf must never reach the content stream; challenger_m1i2_2 F4).
local function cc(v) if not finite(v) then return 0 end return max(0, min(1, v)) end
M.color_component = cc
local function col(c)
  if type(c) ~= "table" then c = { 0, 0, 0 } end
  return fmt("%.3f %.3f %.3f", cc(c[1]), cc(c[2]), cc(c[3]))
end

local function bbox_add(b, x, y)
  if not b then return { x0 = x, y0 = y, x1 = x, y1 = y } end
  if x < b.x0 then b.x0 = x end
  if x > b.x1 then b.x1 = x end
  if y < b.y0 then b.y0 = y end
  if y > b.y1 then b.y1 = y end
  return b
end
local function bbox_union(a, b)
  if not a then return b and { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 } end
  if not b then return a end
  return { x0 = min(a.x0, b.x0), y0 = min(a.y0, b.y0), x1 = max(a.x1, b.x1), y1 = max(a.y1, b.y1) }
end
M.bbox_union = bbox_union

local BLEND = { normal = false, multiply = "Multiply", screen = "Screen", darken = "Darken",
                lighten = "Lighten", overlay = "Overlay" }
M.ALPHA_STEPS = 200      -- alpha quantization (1/200)
M.MASK_MARGIN = 2        -- bp of soft-mask form BBox beyond the area to paint

---------------------------------------------------------------- registry
-- Document-wide resource registry (ExtGStates, patterns, shading cache).
function M.registry(backend)
  local R = { backend = backend, gs = {}, shade = {}, n_pat = 0, n_mask = 0, count = { extgs = 0, pattern = 0, obj = 0 } }
  function R.extgs(name, dict)
    if not R.gs[name] then
      R.gs[name] = dict
      R.count.extgs = R.count.extgs + 1
      if backend and backend.extgs then backend.extgs(name, dict) end
    end
    return name
  end
  function R.obj(dict)
    R.count.obj = R.count.obj + 1
    if backend and backend.obj then return backend.obj(dict) end
    return R.count.obj
  end
  function R.stream(dict, data)
    R.count.obj = R.count.obj + 1
    if backend and backend.stream then return backend.stream(dict, data) end
    return R.count.obj
  end
  function R.pattern(name, objnum)
    R.count.pattern = R.count.pattern + 1
    if backend and backend.pattern then backend.pattern(name, objnum) end
    return name
  end
  return R
end

--- Name of the ExtGState for (alpha, blend); nil when nothing needs setting.
function M.gs_name(R, alpha, blend)
  alpha = alpha or 1
  if not finite(alpha) then alpha = 1 end
  local a = floor(max(0, min(1, alpha)) * M.ALPHA_STEPS + 0.5)
  local bm = BLEND[blend or "normal"]
  if bm == nil then error("kacho-pdf: unknown blend mode '" .. tostring(blend) .. "'", 3) end
  if a >= M.ALPHA_STEPS and not bm then return nil end
  local name = fmt("kc%s%d", bm and bm:sub(1, 2) or "N", a)
  local v = a / M.ALPHA_STEPS
  R.extgs(name, fmt("/ca %.3f /CA %.3f%s", v, v, bm and (" /BM /" .. bm) or ""))
  return name
end

---------------------------------------------------------------- shading functions
-- stops: {{t, rgb}, ...} sorted by t in [0,1]  (or two colours c0, c1)
local function color_function(R, stops, ncomp)
  local function cstr(c)
    if ncomp == 1 then return fmt("%.4f", cc(type(c) == "table" and c[1] or c)) end
    if type(c) ~= "table" then c = { 0, 0, 0 } end
    return fmt("%.4f %.4f %.4f", cc(c[1]), cc(c[2]), cc(c[3]))
  end
  if #stops == 2 then
    return R.obj(fmt("<< /FunctionType 2 /Domain [0 1] /C0 [%s] /C1 [%s] /N 1 >>", cstr(stops[1][2]), cstr(stops[2][2])))
  end
  local fns, bounds, enc = {}, {}, {}
  for i = 1, #stops - 1 do
    fns[#fns + 1] = R.obj(fmt("<< /FunctionType 2 /Domain [0 1] /C0 [%s] /C1 [%s] /N 1 >>", cstr(stops[i][2]), cstr(stops[i + 1][2]))) .. " 0 R"
    if i > 1 then bounds[#bounds + 1] = fmt("%.4f", stops[i][1]) end
    enc[#enc + 1] = "0 1"
  end
  return R.obj(fmt("<< /FunctionType 3 /Domain [0 1] /Functions [%s] /Bounds [%s] /Encode [%s] >>",
    concat(fns, " "), concat(bounds, " "), concat(enc, " ")))
end
local function norm_stops(stops)
  local raw = {}
  for i, s in ipairs(stops) do raw[i] = { cc(s[1]), s[2] } end
  table.sort(raw, function(a, b) return a[1] < b[1] end)
  if raw[1][1] > 0 then table.insert(raw, 1, { 0, raw[1][2] }) end
  if raw[#raw][1] < 1 then raw[#raw + 1] = { 1, raw[#raw][2] } end
  local out = {}
  for _, s in ipairs(raw) do
    if #out == 0 or s[1] > out[#out][1] + 1e-5 then out[#out + 1] = s end
  end
  if #out == 1 then out[2] = { 1, out[1][2] } end
  out[#out][1] = 1
  return out
end

---------------------------------------------------------------- writer
local W = {}
W.__index = W

--- New page writer. `R` is a registry from M.registry(backend).
function M.new(R)
  local self = setmetatable({ R = R or M.registry(nil), layers = {}, cur = 20, depth = 0, bbox = nil }, W)
  return self
end

--- Child writer sharing the registry (used for transparency groups).
function W:sub()
  local w = M.new(self.R)
  w.cur = 0
  return w
end

--- Select numbered layer (lower numbers paint first). Convention: 10 background
--- washes, 20 stems/branches, 30 leaves, 40 flowers, 50 birds, 60 seal, 70 overlays.
function W:layer(n)
  if self.depth ~= 0 then error("kacho-pdf: cannot change layer inside an open clip/save", 2) end
  self.cur = n or 20
  return self
end

function W:put(s)
  local L = self.layers[self.cur]
  if not L then L = {}; self.layers[self.cur] = L end
  L[#L + 1] = s
end

function W:extend(b) self.bbox = bbox_union(self.bbox, b) end

---------------------------------------------------------------- path builders
--- Polyline path. Returns nil when there are <2 points or a non-finite coordinate.
function W:poly(pts, closed)
  local n = #pts
  if n < 2 then return nil end
  local out, b = {}, nil
  for i = 1, n do
    local p = pts[i]
    if not (finite(p[1]) and finite(p[2])) then return nil end
    b = bbox_add(b, p[1], p[2])
    out[i] = P(p[1], p[2]) .. (i == 1 and " m" or " l")
  end
  if closed then out[#out + 1] = "h" end
  return { s = concat(out, " "), bbox = b }
end

--- Smooth path through pts: Catmull-Rom spline converted to cubic Béziers
--- (florilegium "smooth"). tension 1 = standard Catmull-Rom.
function W:smooth(pts, closed, tension)
  local n = #pts
  if n < 3 then return self:poly(pts, closed) end
  for i = 1, n do if not (finite(pts[i][1]) and finite(pts[i][2])) then return nil end end
  local k = (tension or 1) / 6
  local function at(i)
    if closed then return pts[(i - 1) % n + 1] end
    return pts[max(1, min(n, i))]
  end
  local out, b = { P(pts[1][1], pts[1][2]) .. " m" }, bbox_add(nil, pts[1][1], pts[1][2])
  local last = closed and n or n - 1
  for i = 1, last do
    local p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
    local c1x, c1y = p1[1] + (p2[1] - p0[1]) * k, p1[2] + (p2[2] - p0[2]) * k
    local c2x, c2y = p2[1] - (p3[1] - p1[1]) * k, p2[2] - (p3[2] - p1[2]) * k
    b = bbox_add(b, c1x, c1y); b = bbox_add(b, c2x, c2y); b = bbox_add(b, p2[1], p2[2])
    out[#out + 1] = P(c1x, c1y) .. " " .. P(c2x, c2y) .. " " .. P(p2[1], p2[2]) .. " c"
  end
  if closed then out[#out + 1] = "h" end
  return { s = concat(out, " "), bbox = b }
end

--- Path from cubic Bézier segments {{p0,p1,p2,p3}, ...} (joined, p0 of each
--- segment after the first is assumed equal to the previous p3).
function W:bezier(segs, closed)
  if #segs == 0 then return nil end
  local out, b = {}, nil
  for i, sg in ipairs(segs) do
    for j = 1, 4 do
      if not (finite(sg[j][1]) and finite(sg[j][2])) then return nil end
      b = bbox_add(b, sg[j][1], sg[j][2])
    end
    if i == 1 then out[1] = P(sg[1][1], sg[1][2]) .. " m" end
    out[#out + 1] = P(sg[2][1], sg[2][2]) .. " " .. P(sg[3][1], sg[3][2]) .. " " .. P(sg[4][1], sg[4][2]) .. " c"
  end
  if closed then out[#out + 1] = "h" end
  return { s = concat(out, " "), bbox = b }
end

--- Ellipse (4 Bézier arcs), optional rotation in radians.
function W:ellipse(cx, cy, rx, ry, rot)
  if not (finite(cx) and finite(cy) and finite(rx) and finite(ry)) or rx <= 0 or ry <= 0 then return nil end
  rot = rot or 0
  local k = 0.5522847498
  local cr, sr = cos(rot), sin(rot)
  local function T(x, y) return { cx + x * cr - y * sr, cy + x * sr + y * cr } end
  local segs = {
    { T(rx, 0), T(rx, k * ry), T(k * rx, ry), T(0, ry) },
    { T(0, ry), T(-k * rx, ry), T(-rx, k * ry), T(-rx, 0) },
    { T(-rx, 0), T(-rx, -k * ry), T(-k * rx, -ry), T(0, -ry) },
    { T(0, -ry), T(k * rx, -ry), T(rx, -k * ry), T(rx, 0) },
  }
  return self:bezier(segs, true)
end
function W:circle(cx, cy, r) return self:ellipse(cx, cy, r, r, 0) end

function W:rect(x0, y0, x1, y1)
  if type(x0) == "table" then x0, y0, x1, y1 = x0.x0, x0.y0, x0.x1, x0.y1 end
  if not (finite(x0) and finite(y0) and finite(x1) and finite(y1)) then return nil end
  return { s = fmt("%s %s %s re", P(x0, y0), num(x1 - x0), num(y1 - y0)),
           bbox = { x0 = min(x0, x1), y0 = min(y0, y1), x1 = max(x0, x1), y1 = max(y0, y1) } }
end

--- Concatenate several paths into one compound path (nil entries skipped).
function W:join(...)
  local parts, b = {}, nil
  local args, n = { ... }, select("#", ...)
  if n == 1 and type(args[1]) == "table" and args[1].s == nil then
    args = args[1]
    n = 0
    for k in pairs(args) do if type(k) == "number" and k > n then n = k end end
  end
  for i = 1, n do
    local p = args[i]
    if p and p.s then parts[#parts + 1] = p.s; b = bbox_union(b, p.bbox) end
  end
  if #parts == 0 then return nil end
  return { s = concat(parts, " "), bbox = b }
end

---------------------------------------------------------------- painting
--- Return ExtGState name for alpha/blend (registers it once per document).
function W:gs(alpha, blend) return M.gs_name(self.R, alpha, blend) end

--- Fill a path. opts: {blend=, evenodd=}. Returns the painted bbox (or nil).
function W:fill(path, rgb, alpha, opts)
  if not path then return nil end
  opts = opts or {}
  local g = self:gs(alpha, opts.blend)
  local op = opts.evenodd and "f*" or "f"
  self:put("q " .. (g and ("/" .. g .. " gs ") or "") .. col(rgb) .. " rg " .. path.s .. " " .. op .. " Q")
  self:extend(path.bbox)
  return { x0 = path.bbox.x0, y0 = path.bbox.y0, x1 = path.bbox.x1, y1 = path.bbox.y1 }
end

--- Stroke a path. opts: {blend=, cap=0|1|2, join=0|1|2}. Returns painted bbox.
function W:stroke(path, rgb, width, alpha, opts)
  if not path or not finite(width) or width <= 0 then return nil end
  opts = opts or {}
  local g = self:gs(alpha, opts.blend)
  self:put(fmt("q %s%s RG %s w %d J %d j %s S Q", g and ("/" .. g .. " gs ") or "", col(rgb), num(width),
    opts.cap or 1, opts.join or 1, path.s))
  local h = width / 2
  local b = { x0 = path.bbox.x0 - h, y0 = path.bbox.y0 - h, x1 = path.bbox.x1 + h, y1 = path.bbox.y1 + h }
  self:extend(b)
  return b
end

--- Push a clip (balanced with W:unclip). Painting outside the path is suppressed.
function W:clip(path, evenodd)
  if not path then path = { s = "0 0 0 0 re" } end
  self.depth = self.depth + 1
  self:put("q " .. path.s .. (evenodd and " W* n" or " W n"))
end
function W:unclip()
  if self.depth <= 0 then error("kacho-pdf: unclip without clip", 2) end
  self.depth = self.depth - 1
  self:put("Q")
end
--- Run fn with an ExtGState applied (e.g. a soft-mask fade from W:fade_*).
--- A nil name (a mask that could not be built from non-finite input) runs fn
--- without any graphics-state change.
function W:with_gs(name, fn)
  if not name then return fn(self) end
  self.depth = self.depth + 1
  self:put("q /" .. name .. " gs")
  local ok, err = pcall(fn, self)
  self.depth = self.depth - 1
  self:put("Q")
  if not ok then error(err, 0) end
end

---------------------------------------------------------------- shadings
local function shade_key(...) local t = { ... } for i, v in ipairs(t) do t[i] = tostring(v) end return concat(t, "|") end

--- Axial (linear) shading pattern in page space from (x0,y0) to (x1,y1).
--- stops = {{t, rgb}, ...}. Returns the pattern name.
function W:axial(x0, y0, x1, y1, stops, extend)
  if not (finite(x0) and finite(y0) and finite(x1) and finite(y1)) or #stops == 0 then return nil end
  stops = norm_stops(stops)
  local parts = {}
  for _, s in ipairs(stops) do parts[#parts + 1] = fmt("%.3f:%s", s[1], col(s[2])) end
  local key = shade_key("ax", num(x0), num(y0), num(x1), num(y1), concat(parts, ","), extend ~= false)
  local R = self.R
  if R.shade[key] then return R.shade[key] end
  local fn = color_function(R, stops, 3)
  local e = extend == false and "false" or "true"
  local sh = R.obj(fmt("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [%s %s] /Function %d 0 R /Extend [%s %s] >>",
    P(x0, y0), P(x1, y1), fn, e, e))
  local pat = R.obj(fmt("<< /PatternType 2 /Shading %d 0 R >>", sh))
  R.n_pat = R.n_pat + 1
  local name = "kcP" .. R.n_pat
  R.pattern(name, pat)
  R.shade[key] = name
  return name
end

--- Radial shading pattern: circle (cx,cy,r0) to (cx,cy,r1); optional y-scale for
--- ellipses via opts.sy (pattern /Matrix). Returns the pattern name.
function W:radial(cx, cy, r0, r1, stops, opts)
  opts = opts or {}
  if not (finite(cx) and finite(cy) and finite(r0) and finite(r1)) or r1 <= 0 or #stops == 0 then return nil end
  if opts.sy ~= nil and (not finite(opts.sy) or opts.sy <= 0) then return nil end
  r0 = max(0, r0)
  stops = norm_stops(stops)
  local parts = {}
  for _, s in ipairs(stops) do parts[#parts + 1] = fmt("%.3f:%s", s[1], col(s[2])) end
  local sy = opts.sy or 1
  local key = shade_key("rad", num(cx), num(cy), num(r0), num(r1), num(sy), concat(parts, ","))
  local R = self.R
  if R.shade[key] then return R.shade[key] end
  local fn = color_function(R, stops, 3)
  local sh = R.obj(fmt("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [0 0 %s 0 0 %s] /Function %d 0 R /Extend [true true] >>",
    num(r0), num(r1), fn))
  local pat = R.obj(fmt("<< /PatternType 2 /Shading %d 0 R /Matrix [1 0 0 %s %s %s] >>", sh, num(sy), num(cx), num(cy)))
  R.n_pat = R.n_pat + 1
  local name = "kcP" .. R.n_pat
  R.pattern(name, pat)
  R.shade[key] = name
  return name
end

--- Fill a path with a shading pattern (optionally at constant alpha).
function W:fill_pattern(path, patname, alpha, opts)
  if not path or not patname then return nil end
  opts = opts or {}
  local g = self:gs(alpha, opts.blend)
  self:put("q " .. (g and ("/" .. g .. " gs ") or "") .. "/Pattern cs /" .. patname .. " scn " .. path.s ..
    (opts.evenodd and " f*" or " f") .. " Q")
  self:extend(path.bbox)
  return { x0 = path.bbox.x0, y0 = path.bbox.y0, x1 = path.bbox.x1, y1 = path.bbox.y1 }
end

--- Luminosity soft mask fading along an axis: gray g0 at (x0,y0) -> g1 at (x1,y1)
--- (1 = opaque, 0 = transparent). bbox = rect covering the area to paint.
--- Returns an ExtGState name; use with W:with_gs(name, fn).
function W:fade_axial(x0, y0, x1, y1, g0, g1, bbox)
  local R = self.R
  if not (finite(x0) and finite(y0) and finite(x1) and finite(y1) and bbox and finite(bbox.x0) and finite(bbox.y0)
    and finite(bbox.x1) and finite(bbox.y1)) then return nil end
  g0, g1 = cc(g0), cc(g1)
  local key = shade_key("fa", num(x0), num(y0), num(x1), num(y1), num(g0), num(g1), num(bbox.x0), num(bbox.y0), num(bbox.x1), num(bbox.y1))
  if R.shade[key] then return R.shade[key] end
  local fn = R.obj(fmt("<< /FunctionType 2 /Domain [0 1] /C0 [%.4f] /C1 [%.4f] /N 1 >>", g0, g1))
  local sh = R.obj(fmt("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [%s %s] /Function %d 0 R /Extend [true true] >>",
    P(x0, y0), P(x1, y1), fn))
  -- the form BBox must enclose all paint with margin: paint crossing it leaves a
  -- hairline seam in poppler (explorer_m2_3 P1)
  local form = R.stream(fmt("/Type /XObject /Subtype /Form /BBox [%s %s %s %s] /Group << /S /Transparency /CS /DeviceGray >> /Resources << /Shading << /S0 %d 0 R >> >>",
    num(bbox.x0 - M.MASK_MARGIN), num(bbox.y0 - M.MASK_MARGIN), num(bbox.x1 + M.MASK_MARGIN), num(bbox.y1 + M.MASK_MARGIN), sh), "/S0 sh")
  R.n_mask = R.n_mask + 1
  local name = "kcF" .. R.n_mask
  R.extgs(name, fmt("/SMask << /S /Luminosity /G %d 0 R >>", form))
  R.shade[key] = name
  return name
end

-- gray ramp stops 0 -> 1 -> 1 -> 0 across [0,1] with smoothstep feathers of
-- width a (left) and b (right); a zero width gives a constant 1 on that side
local function feather_stops(a, b)
  local st = {}
  local function smooth(t) return t * t * (3 - 2 * t) end
  a, b = max(0, min(0.5, a or 0)), max(0, min(0.5, b or 0))
  if a > 0 then
    for i = 0, 6 do st[#st + 1] = { a * i / 6, smooth(i / 6) } end
  else st[#st + 1] = { 0, 1 } end
  if b > 0 then
    for i = 6, 0, -1 do st[#st + 1] = { 1 - b * i / 6, smooth(i / 6) } end
  else st[#st + 1] = { 1, 1 } end
  -- drop duplicate positions (keeps the stitching function well formed)
  local out = {}
  for _, s in ipairs(st) do
    if #out == 0 or s[1] > out[#out][1] + 1e-6 then out[#out + 1] = s end
  end
  if #out == 1 then out[2] = { 1, out[1][2] } end
  return out
end
M.feather_stops = feather_stops

--- Rectangular feather soft mask: opaque in the middle of rect, fading smoothly
--- to transparent over fx = {left, right} and fy = {bottom, top} fractions of the
--- rect (product of two smoothstep ramps inside the mask group). Paint only inside
--- `rect`. Returns an ExtGState name for W:with_gs.
function W:fade_box(rect, fx, fy)
  local R = self.R
  if not (rect and finite(rect.x0) and finite(rect.y0) and finite(rect.x1) and finite(rect.y1)) then return nil end
  fx, fy = fx or { 0.15, 0.15 }, fy or { 0.15, 0.15 }
  local function fr(v) return finite(v) and v or 0.15 end
  fx, fy = { fr(fx[1]), fr(fx[2]) }, { fr(fy[1]), fr(fy[2]) }
  local key = shade_key("fb", num(rect.x0), num(rect.y0), num(rect.x1), num(rect.y1), num(fx[1]), num(fx[2]), num(fy[1]), num(fy[2]))
  if R.shade[key] then return R.shade[key] end
  local function ramp(stops)
    local s = {}
    for i, st in ipairs(stops) do s[i] = { st[1], st[2] } end
    return color_function(R, s, 1)
  end
  local fh = ramp(feather_stops(fx[1], fx[2]))
  local fv = ramp(feather_stops(fy[1], fy[2]))
  local shh = R.obj(fmt("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [%s %s] /Function %d 0 R /Extend [true true] >>",
    P(rect.x0, rect.y0), P(rect.x1, rect.y0), fh))
  local shv = R.obj(fmt("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [%s %s] /Function %d 0 R /Extend [true true] >>",
    P(rect.x0, rect.y0), P(rect.x0, rect.y1), fv))
  local m = M.MASK_MARGIN
  local form = R.stream(fmt("/Type /XObject /Subtype /Form /BBox [%s %s %s %s] /Group << /S /Transparency /CS /DeviceGray >> /Resources << /Shading << /S0 %d 0 R /S1 %d 0 R >> /ExtGState << /GM << /BM /Multiply >> >> >>",
    num(rect.x0 - m), num(rect.y0 - m), num(rect.x1 + m), num(rect.y1 + m), shh, shv), "/S0 sh q /GM gs /S1 sh Q")
  R.n_mask = R.n_mask + 1
  local name = "kcF" .. R.n_mask
  R.extgs(name, fmt("/SMask << /S /Luminosity /G %d 0 R >>", form))
  R.shade[key] = name
  return name
end

--- Elliptical radial luminosity soft mask centred at (cx,cy) with radii rx, ry:
--- opaque inside `inner` (fraction of radius), falling smoothly to 0 at the rim.
--- `power` (default 1.6) shapes the falloff; `rot` (radians, default 0) turns
--- the ellipse. Returns an ExtGState name, or nil for non-finite/degenerate input.
function W:fade_radial(cx, cy, rx, ry, inner, power, rot)
  local R = self.R
  if not (finite(cx) and finite(cy) and finite(rx) and finite(ry)) or rx <= 0 or ry <= 0 then return nil end
  inner = finite(inner) and max(0, min(0.99, inner)) or 0
  power = finite(power) and max(0.1, power) or 1.6
  rot = finite(rot) and rot or 0
  local cr, sr = cos(rot), sin(rot)
  local key = shade_key("fr", num(cx), num(cy), num(rx), num(ry), num(inner), num(power), fmt("%.3f", rot))
  if R.shade[key] then return R.shade[key] end
  local fn = R.obj(fmt("<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N %s >>", num(power)))
  local sh = R.obj(fmt("<< /ShadingType 3 /ColorSpace /DeviceGray /Coords [0 0 %s 0 0 1] /Function %d 0 R /Extend [true true] >>",
    num(inner), fn))
  local form = R.stream(fmt("/Type /XObject /Subtype /Form /BBox [-1.6 -1.6 1.6 1.6] /Matrix [%s %s %s %s %s %s] /Group << /S /Transparency /CS /DeviceGray >> /Resources << /Shading << /S0 %d 0 R >> >>",
    fmt("%.4f", rx * cr), fmt("%.4f", rx * sr), fmt("%.4f", -ry * sr), fmt("%.4f", ry * cr), num(cx), num(cy), sh), "/S0 sh")
  R.n_mask = R.n_mask + 1
  local name = "kcF" .. R.n_mask
  R.extgs(name, fmt("/SMask << /S /Luminosity /G %d 0 R >>", form))
  R.shade[key] = name
  return name
end

---------------------------------------------------------------- groups
--- Paint `fn(subwriter)` into an isolated transparency group, composited at
--- `alpha` (and blend). Overlaps inside the group do not double-darken.
--- Returns the group's bbox.
function W:group(fn, alpha, blend)
  if self.depth ~= 0 then error("kacho-pdf: groups cannot be nested inside clips", 2) end
  local sub = self:sub()
  fn(sub)
  if sub.depth ~= 0 then error("kacho-pdf: unbalanced clip inside group", 2) end
  if not sub.bbox then return nil end
  local body = sub:body()
  local L = self.layers[self.cur]
  if not L then L = {}; self.layers[self.cur] = L end
  L[#L + 1] = { group = true, data = body, gs = self:gs(alpha or 1, blend), bbox = sub.bbox }
  self:extend(sub.bbox)
  return { x0 = sub.bbox.x0, y0 = sub.bbox.y0, x1 = sub.bbox.x1, y1 = sub.bbox.y1 }
end

--- Append everything painted into writer `other` (e.g. a scratch writer used
--- for a trial fit) into this writer, layer by layer.
function W:merge(other)
  if other.depth ~= 0 then error("kacho-pdf: merge of a writer with an open clip", 2) end
  local keys = {}
  for k in pairs(other.layers) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local L = self.layers[k]
    if not L then L = {}; self.layers[k] = L end
    for _, item in ipairs(other.layers[k]) do L[#L + 1] = item end
  end
  self:extend(other.bbox)
  return self
end

---------------------------------------------------------------- output
local function sorted_layers(self)
  local keys = {}
  for k in pairs(self.layers) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

--- Ordered output pieces: {kind="literal", data=...} and {kind="group", data=ops, gs=name, bbox=rect}.
--- Consecutive literal strings are merged.
function W:pieces()
  if self.depth ~= 0 then error("kacho-pdf: unbalanced q/Q (open clip) at flush", 2) end
  local out, buf = {}, {}
  local function flushbuf()
    if #buf > 0 then out[#out + 1] = { kind = "literal", data = concat(buf, "\n") }; buf = {} end
  end
  for _, k in ipairs(sorted_layers(self)) do
    for _, item in ipairs(self.layers[k]) do
      if type(item) == "string" then buf[#buf + 1] = item
      else flushbuf(); out[#out + 1] = { kind = "group", data = item.data, gs = item.gs, bbox = item.bbox } end
    end
  end
  flushbuf()
  return out
end

--- Flattened content (groups inlined as "q /gs gs ... Q"; for nested groups and tests).
function W:body()
  local t = {}
  for _, p in ipairs(self:pieces()) do
    if p.kind == "literal" then t[#t + 1] = p.data
    else t[#t + 1] = "q " .. (p.gs and ("/" .. p.gs .. " gs ") or "") .. "\n" .. p.data .. "\nQ" end
  end
  return concat(t, "\n")
end

function W:is_empty() return next(self.layers) == nil end

--- Check that q/Q operators in a content string are balanced (never negative).
function M.balanced(s)
  local d = 0
  for tok in s:gmatch("%S+") do
    if tok == "q" then d = d + 1 elseif tok == "Q" then d = d - 1; if d < 0 then return false end end
  end
  return d == 0
end

return M
