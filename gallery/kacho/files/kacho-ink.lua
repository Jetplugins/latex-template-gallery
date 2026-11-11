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
-- kacho-ink.lua: painterly organ renderer of the kacho package (M2) -- petals,
-- flowers, buds and leaves painted as stacked watercolour glazes.
--
-- Adapted from florilegium (https://github.com/kevinraymond/florilegium):
-- florilegium-ink.lua (local-frame affine transforms, OKLCH tone ramp, blade /
-- blob / taper / ribbon geometry, fbm noise) and florilegium-flora.lua
-- (petal, flower heart, bud, leaf, leaflet, mottle, streaks: a flat wash,
-- darker blotches multiplied over it, pooling at the edges, pale streaks
-- lifted out, fine veins, almost no outlines). Output goes through the kacho
-- page writer (kacho-pdf) instead of a TeX literal, the tone ramp follows any
-- hue (sakura pink, maple red, wisteria violet...), and the flower takes
-- Japanese petal shapes (notched sakura, round ume) and foreshortening.
--
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
--   * I.petal, I.flower, I.flower_side, I.heart, I.bud, I.leaf, I.maple_leaf,
--     I.leaflet, I.mottle, I.streak3, I.blade, I.blob, I.taper: adapted from
--     florilegium-flora.lua and florilegium-ink.lua (Kevin Raymond 2026, MIT)
--     -- layered watercolour glazing after Curtis, Anderson, Seims, Fleischer
--     & Salesin 1997, "Computer-Generated Watercolor", SIGGRAPH '97 (inspired
--     by: edge darkening, granulation, glazing; no fluid simulation).
--   * I.set_ink / tone ramp: OKLCH (Björn Ottosson 2020, "A perceptual color
--     space for image processing", public domain), adapted from florilegium.
--   * I.organ, I.maple_leaf (palmate serrated momiji glazing), sakura cleft
--     notch / ume petal shapes, side-cupped blossoms, foreshortening: own.
--
-- Usage (all coordinates in a local frame; the frame starts as page bp):
--   local I = require("kacho-ink")
--   I.begin(ctx.pdf, rgb_hue, {accent = rgb})  -- writer, hue of the tone ramp
--   I.push() I.translate(x, y) I.rotate(deg) I.scale(s) ... I.pop()
--   I.flower(rng, s, {petals=5, notch=0.12, sy=0.8, tone=0.4})
--   local bb = I.finish()   -- bbox (page bp) of everything painted since begin
local I = {}

local fmt, floor, sqrt, sin, cos, atan, pi, abs, max, min = string.format, math.floor, math.sqrt, math.sin, math.cos, math.atan, math.pi, math.abs, math.max, math.min
local rad = pi / 180

---------------------------------------------------------------- noise
function I.noise1(rng)
  local g = {}
  for i = 0, 255 do g[i] = rng.sym(1) end
  return function(x)
    local i = floor(x); local f = x - i
    local a, b = g[i & 255] * f, g[(i + 1) & 255] * (f - 1)
    local u = f * f * (3 - 2 * f)
    return 2 * (a + (b - a) * u)
  end
end
function I.fbm1(rng, oct)
  local ns = {}
  for k = 1, oct do ns[k] = I.noise1(rng) end
  return function(x)
    local v, a, f = 0, 1, 1
    for k = 1, oct do v = v + a * ns[k](x * f + 17 * k); a = a * 0.5; f = f * 2 end
    return v
  end
end

---------------------------------------------------------------- colour ramp (OKLCH)
local function srgb_dec(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function srgb_enc(c) return c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055 end
local function cbrt(x) return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3) end
local function rgb_to_oklch(r, g, b)
  r, g, b = srgb_dec(r), srgb_dec(g), srgb_dec(b)
  local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  local L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
  local A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
  local B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  return L, sqrt(A * A + B * B), atan(B, A) / rad
end
local function oklch_to_rgb(L, C, h)
  local A, B = C * cos(h * rad), C * sin(h * rad)
  local l = (L + 0.3963377774 * A + 0.2158037573 * B) ^ 3
  local m = (L - 0.1055613458 * A - 0.0638541728 * B) ^ 3
  local s = (L - 0.0894841775 * A - 1.2914855480 * B) ^ 3
  local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  if r < -1e-4 or g < -1e-4 or b < -1e-4 or r > 1.0001 or g > 1.0001 or b > 1.0001 then return nil end
  local function c(x) return srgb_enc(min(1, max(0, x))) end
  return c(r), c(g), c(b)
end
local function oklch_clamped(L, C, h)
  local r, g, b = oklch_to_rgb(L, C, h)
  if r then return r, g, b end
  local lo, hi = 0, C
  for _ = 1, 18 do local mid = (lo + hi) / 2; if oklch_to_rgb(L, mid, h) then lo = mid else hi = mid end end
  return oklch_to_rgb(L, lo, h)
end
local STOPS = {
  { 0.00, 0.25, 0.105, 6 }, { 0.18, 0.35, 0.150, 3 }, { 0.38, 0.48, 0.175, 0 },
  { 0.58, 0.64, 0.155, -2 }, { 0.78, 0.83, 0.110, -4 }, { 1.00, 0.975, 0.035, -6 },
}
local REF_C = 0.175
local ramps = {}
local ramp
local function build_ramp(hue, chroma_k, lift_l)
  local key = fmt("%.1f %.3f %.3f", hue, chroma_k, lift_l or 0)
  if ramps[key] then return ramps[key] end
  local rr = {}
  for i = 0, 100 do
    local t = i / 100
    local k = 1
    while STOPS[k + 1][1] < t do k = k + 1 end
    local a, b = STOPS[k], STOPS[k + 1]
    local u = (t - a[1]) / (b[1] - a[1])
    local L = a[2] + (b[2] - a[2]) * u
    L = L + (1 - L) * (lift_l or 0)
    local C = (a[3] + (b[3] - a[3]) * u) * chroma_k
    local h = hue + a[4] + (b[4] - a[4]) * u
    local r, g, bb = oklch_clamped(L, C, h)
    rr[i] = { r, g, bb }
  end
  ramps[key] = rr
  return rr
end
--- Set the hue of the tone ramp from a colour; opts.chroma scales saturation.
function I.set_ink(rgb, chroma, lift_extra)
  local L_in, C, h = rgb_to_oklch(rgb[1], rgb[2], rgb[3])
  local lift_l = lift_extra or 0
  local ref_c = REF_C
  if L_in > 0.88 and C < 0.04 then
    -- High-key ivory/white ink (e.g. hakubai white plum): lift ramp so shadows are warm ivory, not grey
    lift_l = max(lift_l, 0.56)
    ref_c = 0.09
  elseif L_in > 0.66 then
    -- Pastel ink (e.g. sakura blush): normalize chroma against high-L gamut and lift ramp lightness
    ref_c = REF_C * max(0.38, (1.02 - L_in) / 0.52)
    lift_l = min(0.48, (L_in - 0.66) * 0.85 + (lift_extra or 0))
  end
  ramp = build_ramp(h, max(0.15, min(1.35, C / ref_c)) * (chroma or 1), min(0.68, lift_l))
end
function I.tone(t)
  local i = max(0, min(100, floor(t * 100 + 0.5)))
  return ramp[i]
end
I.white = { 1, 1, 1 }
local accent = { 0.71, 0.40, 0.18 }
function I.set_accent(c) accent = c end
function I.accent(k)
  k = k or 0
  if k >= 0 then return { accent[1] + (1 - accent[1]) * k, accent[2] + (1 - accent[2]) * k, accent[3] + (1 - accent[3]) * k } end
  return { accent[1] * (1 + k), accent[2] * (1 + k), accent[3] * (1 + k) }
end

---------------------------------------------------------------- transforms + output
local W                      -- kacho-pdf writer
local T = { 1, 0, 0, 1, 0, 0 }
local stack = {}
local path, pbb = {}, nil
local total_bb
I.detail = 1                 -- 0..1 level of fine detail (veins, specks)
local alpha_scale = 1.0

function I.begin(writer, rgb, opts)
  opts = opts or {}
  W = writer
  T = { 1, 0, 0, 1, 0, 0 }
  stack, path, pbb, total_bb = {}, {}, nil, nil
  alpha_scale = opts.alpha or 1.0
  local lift_extra = opts.lift or (alpha_scale < 0.95 and (1 - alpha_scale) * 0.28 or 0)
  I.set_ink(rgb or { 0.85, 0.55, 0.62 }, opts.chroma, lift_extra)
  if opts.accent then accent = opts.accent end
end
function I.finish() local b = total_bb; total_bb = nil; alpha_scale = 1.0; return b end
function I.push() stack[#stack + 1] = T end
function I.pop() T = table.remove(stack) end
function I.translate(x, y) T = { T[1], T[2], T[3], T[4], T[1] * x + T[3] * y + T[5], T[2] * x + T[4] * y + T[6] } end
function I.rotate(deg)
  local c, s = cos(deg * rad), sin(deg * rad)
  T = { T[1] * c + T[3] * s, T[2] * c + T[4] * s, -T[1] * s + T[3] * c, -T[2] * s + T[4] * c, T[5], T[6] }
end
function I.scale(sx, sy) sy = sy or sx; T = { T[1] * sx, T[2] * sx, T[3] * sy, T[4] * sy, T[5], T[6] } end
--- bp per local unit
function I.unit() return sqrt(abs(T[1] * T[4] - T[2] * T[3])) end
function I.to_page(x, y) return T[1] * x + T[3] * y + T[5], T[2] * x + T[4] * y + T[6] end

local function num(x)
  local s = fmt("%.2f", x)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  if s == "-0" then s = "0" end
  return s
end
local function P(x, y)
  local px, py = T[1] * x + T[3] * y + T[5], T[2] * x + T[4] * y + T[6]
  if not pbb then pbb = { x0 = px, y0 = py, x1 = px, y1 = py }
  else
    if px < pbb.x0 then pbb.x0 = px end
    if px > pbb.x1 then pbb.x1 = px end
    if py < pbb.y0 then pbb.y0 = py end
    if py > pbb.y1 then pbb.y1 = py end
  end
  return num(px) .. " " .. num(py)
end
function I.moveto(x, y) path[#path + 1] = P(x, y) .. " m" end
function I.lineto(x, y) path[#path + 1] = P(x, y) .. " l" end
function I.poly(pts, closed)
  path[#path + 1] = P(pts[1][1], pts[1][2]) .. " m"
  for i = 2, #pts do path[#path + 1] = P(pts[i][1], pts[i][2]) .. " l" end
  if closed then path[#path + 1] = "h" end
end
function I.smooth(pts, closed, tension)
  local n = #pts
  if n < 3 then return I.poly(pts, closed) end
  local k = (tension or 1) / 6
  local function at(i)
    if closed then return pts[(i - 1) % n + 1] end
    return pts[max(1, min(n, i))]
  end
  path[#path + 1] = P(pts[1][1], pts[1][2]) .. " m"
  local last = closed and n or n - 1
  for i = 1, last do
    local p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
    path[#path + 1] = P(p1[1] + (p2[1] - p0[1]) * k, p1[2] + (p2[2] - p0[2]) * k) .. " " ..
      P(p2[1] - (p3[1] - p1[1]) * k, p2[2] - (p3[2] - p1[2]) * k) .. " " .. P(p2[1], p2[2]) .. " c"
  end
  if closed then path[#path + 1] = "h" end
end
function I.circle(x, y, r)
  local k = 0.5523 * r
  path[#path + 1] = P(x + r, y) .. " m " .. P(x + r, y + k) .. " " .. P(x + k, y + r) .. " " .. P(x, y + r) .. " c " ..
    P(x - k, y + r) .. " " .. P(x - r, y + k) .. " " .. P(x - r, y) .. " c " ..
    P(x - r, y - k) .. " " .. P(x - k, y - r) .. " " .. P(x, y - r) .. " c " ..
    P(x + k, y - r) .. " " .. P(x + r, y - k) .. " " .. P(x + r, y) .. " c h"
end
local function take()
  local p = { s = table.concat(path, " "), bbox = pbb }
  path, pbb = {}, nil
  return p
end
local function grow_total(b)
  if not b then return end
  if not total_bb then total_bb = { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 }
  else
    total_bb.x0, total_bb.y0 = min(total_bb.x0, b.x0), min(total_bb.y0, b.y0)
    total_bb.x1, total_bb.y1 = max(total_bb.x1, b.x1), max(total_bb.y1, b.y1)
  end
end
local clipdepth = 0
function I.fill(c, op, mult)
  local p = take()
  if not p.bbox then return end
  local b = W:fill(p, c, (op or 1) * alpha_scale, { blend = mult and "multiply" or nil })
  if clipdepth == 0 then grow_total(b) end
end
function I.stroke(c, w, op, mult)
  local p = take()
  if not p.bbox then return end
  local b = W:stroke(p, c, w, (op or 1) * alpha_scale, { blend = mult and "multiply" or nil })
  if clipdepth == 0 then grow_total(b) end
end
function I.clip() local p = take(); clipdepth = clipdepth + 1; W:clip(p) end
function I.unclip() clipdepth = clipdepth - 1; W:unclip() end
function I.discard() path, pbb = {}, nil end
function I.flood(c, x0, y0, x1, y1, op, mult)
  I.poly({ { x0, y0 }, { x1, y0 }, { x1, y1 }, { x0, y1 } }, true)
  I.fill(c, op, mult)
end

---------------------------------------------------------------- geometry
local function normals(pts)
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
function I.sample(f, n, v0, v1)
  v0, v1 = v0 or 0, v1 or 1
  local out = {}
  for i = 0, n do local x, y = f(v0 + (v1 - v0) * i / n); out[#out + 1] = { x, y } end
  return out
end
function I.bezier3(x0, y0, x1, y1, x2, y2, x3, y3)
  return function(v)
    local u = 1 - v
    local a, b, c, d = u * u * u, 3 * u * u * v, 3 * u * v * v, v * v * v
    return a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3
  end
end
function I.ribbon(pts, width)
  local nrm = normals(pts)
  local s, acc = { 0 }, 0
  for i = 2, #pts do acc = acc + sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2); s[i] = acc end
  local left, right = {}, {}
  for i, p in ipairs(pts) do
    local w = width(acc > 0 and s[i] / acc or 0) / 2
    left[#left + 1] = { p[1] + nrm[i][1] * w, p[2] + nrm[i][2] * w }
    right[#right + 1] = { p[1] - nrm[i][1] * w, p[2] - nrm[i][2] * w }
  end
  for i = #right, 1, -1 do left[#left + 1] = right[i] end
  return left
end
function I.taper(x0, y0, x1, y1, x2, y2, x3, y3, w0, w1)
  local function nrm(dx, dy) local L = sqrt(dx * dx + dy * dy); if L < 1e-9 then return 0, 0 end return -dy / L, dx / L end
  local n0x, n0y = nrm(x1 - x0, y1 - y0)
  local n1x, n1y = nrm(x2 - x0, y2 - y0)
  local n2x, n2y = nrm(x3 - x1, y3 - y1)
  local n3x, n3y = nrm(x3 - x2, y3 - y2)
  local h0, h1, h2, h3 = w0 / 2, (2 * w0 + w1) / 6, (w0 + 2 * w1) / 6, w1 / 2
  path[#path + 1] = P(x0 + n0x * h0, y0 + n0y * h0) .. " m " ..
    P(x1 + n1x * h1, y1 + n1y * h1) .. " " .. P(x2 + n2x * h2, y2 + n2y * h2) .. " " .. P(x3 + n3x * h3, y3 + n3y * h3) .. " c " ..
    P(x3 - n3x * h3, y3 - n3y * h3) .. " l " ..
    P(x2 - n2x * h2, y2 - n2y * h2) .. " " .. P(x1 - n1x * h1, y1 - n1y * h1) .. " " .. P(x0 - n0x * h0, y0 - n0y * h0) .. " c h"
end
function I.blade(spine, n, wl, wr, edge)
  local c = I.sample(spine, n)
  local nrm = normals(c)
  local left, right = {}, {}
  for i = 1, n + 1 do
    local v = (i - 1) / n
    local el, er = 0, 0
    if edge then el, er = edge(v, 1), edge(v, -1) end
    local a, b = max(0, wl(v) + el), max(0, wr(v) + er)
    left[i] = { c[i][1] + nrm[i][1] * a, c[i][2] + nrm[i][2] * a }
    right[i] = { c[i][1] - nrm[i][1] * b, c[i][2] - nrm[i][2] * b }
  end
  local out = {}
  for i = 1, n + 1 do out[#out + 1] = left[i] end
  for i = n, 2, -1 do out[#out + 1] = right[i] end
  return out, c, nrm
end
function I.blob(rng, x, y, rx, ry, rough, n)
  n = n or 9
  local ph, ph2, rot = rng.range(0, 2 * pi), rng.range(0, 2 * pi), rng.range(0, 2 * pi)
  local out = {}
  for i = 0, n - 1 do
    local a = 2 * pi * i / n
    local k = 1 + rough * (0.6 * sin(2 * a + ph) + 0.4 * sin(3 * a + ph2)) + rough * 0.5 * rng.sym(1)
    local px, py = rx * k * cos(a), ry * k * sin(a)
    out[#out + 1] = { x + px * cos(rot) - py * sin(rot), y + px * sin(rot) + py * cos(rot) }
  end
  return out
end

---------------------------------------------------------------- washes
local tone, white = I.tone, I.white
local function lerp(a, b, t) return a + (b - a) * t end
local function fine() return I.unit() > 9.5 and I.detail > 0.3 end
local function speck(x, y, r, a)
  local c, s = cos(a), sin(a)
  I.poly({ { x + r * c, y + r * s }, { x - 0.6 * r * s, y + 0.6 * r * c }, { x - r * c, y - r * s }, { x + 0.6 * r * s, y - 0.6 * r * c } }, true)
end
--- granulated watercolour inside the current clip: darker / lighter blotches, specks
function I.mottle(rng, x0, y0, x1, y1, n, size, dark, light, specks)
  for _ = 1, n do
    local x, y = rng.range(x0, x1), rng.range(y0, y1)
    local r = size * rng.range(0.5, 1.4)
    I.smooth(I.blob(rng, x, y, r, r * rng.range(0.5, 1), 0.35, 7), true)
    if rng.chance(0.6) then I.fill(tone(dark + rng.sym(0.06)), rng.range(0.10, 0.22), true)
    else I.fill(tone(light + rng.sym(0.06)), rng.range(0.12, 0.26)) end
  end
  if specks and specks > 0 and fine() then
    for _ = 1, specks do speck(rng.range(x0, x1), rng.range(y0, y1), size * rng.range(0.03, 0.08), rng.range(0, pi)) end
    I.fill(tone(dark - 0.08), rng.range(0.3, 0.5), true)
  end
end
function I.streak3(x0, y0, x1, y1, x2, y2, x3, y3, w0, w1, c, op, mult)
  I.taper(x0, y0, x1, y1, x2, y2, x3, y3, w0, w1)
  I.fill(c, op, mult)
end
function I.streak(f, n, w0, w1, c, op, mult)
  local pts = I.sample(f, n)
  I.smooth(I.ribbon(pts, function(u) return lerp(w0, w1, u) * (u < 0.12 and (0.4 + 5 * u) or 1) end), true)
  I.fill(c, op, mult)
end
local streak3 = I.streak3

---------------------------------------------------------------- petal
local function round_half(W0)
  return function(v)
    local m = 0.62
    if v < m then return W0 * (0.16 + 0.84 * sin(pi / 2 * v / m) ^ 1.3) end
    local q = (v - m) / (1 - m)
    return W0 * sqrt(max(0, 1 - q * q))
  end
end
I.round_half = round_half

--- One petal, base at the origin pointing +y, length 1. o: w (half-width),
--- tone, notch (0 = none; sakura ~0.14), streaks, bend, heart (pale base),
--- pointed, pool (edge pooling opacity).
function I.petal(rng, o)
  o = o or {}
  local pointed = o.shape == "pointed"
  local W0 = o.w or (pointed and rng.range(0.15, 0.2) or rng.range(0.40, 0.48))
  local bend = o.bend or rng.sym(0.08)
  local ubp = I.unit()
  local ucm = ubp / 28.3465
  local sk = min(1, max(0.28, (ubp - 4.0) / 14.0))
  local t0 = min(0.92, (o.tone or rng.range(0.34, 0.42)) + (1 - sk) * 0.14)
  local fn = fine()
  local wave = I.fbm1(rng, 3)
  local notch = o.notch or ((not pointed and rng.chance(0.4)) and rng.range(0.03, 0.06) or 0)
  local spine = function(v) return bend * v * v, v end
  local half = pointed and function(v) return W0 * 2 * sin(pi * v ^ 0.8) ^ 0.85 * (1 - 0.3 * v) end or round_half(W0)
  local edge = function(v, side)
    return (pointed and 0.012 or 0.03) * wave(v * 6 + (side > 0 and 0 or 40)) * v
  end
  local nseg = ubp > 14 and 22 or (ubp > 8 and 14 or 10)
  local outline = I.blade(spine, nseg, half, half, edge)
  if notch > 0 then
    -- Build a crisp heart-shaped cleft at the tip (sakura bilobed apex)
    local tip_i = nseg + 1
    local tx, ty = spine(1)
    local cleft_y = ty - notch * 1.15
    local lobe_w = W0 * (notch > 0.08 and 0.24 or 0.14)
    local rebuilt = {}
    for i = 1, tip_i - 2 do rebuilt[#rebuilt + 1] = outline[i] end
    rebuilt[#rebuilt + 1] = { tx - lobe_w, ty - notch * 0.08 }
    rebuilt[#rebuilt + 1] = { tx - lobe_w * 0.28, cleft_y + notch * 0.32 }
    rebuilt[#rebuilt + 1] = { tx, cleft_y }
    rebuilt[#rebuilt + 1] = { tx, cleft_y }
    rebuilt[#rebuilt + 1] = { tx + lobe_w * 0.28, cleft_y + notch * 0.32 }
    rebuilt[#rebuilt + 1] = { tx + lobe_w, ty - notch * 0.08 }
    for i = tip_i + 2, #outline do rebuilt[#rebuilt + 1] = outline[i] end
    outline = rebuilt
  end
  I.smooth(outline, true)
  I.clip()
    I.flood(tone(t0), -1, -0.1, 1, 1.2)
    if o.heart ~= false then
      local nh = ubp > 12 and 5 or 3
      local ha = (0.10 + 0.05 * (1 - sk)) * (8 / nh) * 0.85
      for k = 1, nh do
        local u = k / nh
        I.smooth(I.blob(rng, 0, 0, W0 * (0.25 + 0.80 * u), 0.06 + 0.52 * u, 0.28, 8), true)
        I.fill(o.heart_color or white, ha)
      end
    end
    if o.blush then
      -- a deeper flush toward the base (sakura / ume): multiplied blobs
      local nb = ubp > 12 and 3 or 2
      for k = 1, nb do
        I.smooth(I.blob(rng, 0, 0.05, W0 * (0.35 + 0.15 * k), 0.12 + 0.1 * k, 0.3, 8), true)
        I.fill(o.blush_color or tone(max(0.12, t0 - 0.22)), 0.14 * sk * (3 / nb) * 0.9, true)
      end
    end
    if notch > 0.05 or t0 > 0.68 then
      -- Soft luminous tip wash (sakura & white plum fade toward creamy-white tips)
      local nt = ubp > 12 and 3 or 2
      for k = 1, nt do
        I.smooth(I.blob(rng, 0, 0.72 + 0.08 * k, W0 * (0.85 - 0.12 * k), 0.24 - 0.03 * k, 0.22, 8), true)
        I.fill(white, 0.18 + 0.06 * k)
      end
    end
    local hi_k = max(0.38, 1 - max(0, (t0 - 0.55) * 1.30))
    local dark_t = max(0.10, t0 - 0.15 * sk * hi_k)
    local pool_t = o.pool_tone or max(0.10, t0 - 0.19 * sk * hi_k)
    local vein_t = max(0.12, t0 - 0.20 * sk * hi_k)
    local nmot = max(2, floor((fn and 8 or 3) * sk * hi_k))
    I.mottle(rng, -W0 * 1.2, 0.12, W0 * 1.2, 1.05, nmot, pointed and 0.06 or 0.12, dark_t, min(0.98, t0 + 0.18), (ubp > 18 and t0 < 0.58) and 8 or 0)
    if fn and ubp > 13 then
      local nstr = max(2, floor(rng.int(4, 6) * sk * hi_k))
      for _ = 1, nstr do
        local f = rng.sym(0.95)
        local v0, v1 = rng.range(0.15, 0.4), rng.range(0.7, 1.0 - notch * 0.8)
        local x0, x1 = f * half(v0) * 0.8 + bend * v0 * v0, f * half(v1) * 0.9 + bend * v1 * v1
        I.taper(x0, v0, x0 + (x1 - x0) * 0.3, lerp(v0, v1, 0.35), x1 * 0.95, lerp(v0, v1, 0.7), x1, v1,
          rng.range(0.03, 0.07), 0.005)
      end
      I.fill(tone(max(0.10, t0 - 0.16 * sk * hi_k)), 0.15 * sk * hi_k, true)
    end
    -- pooling: the outline restroked wide and soft, only its inner half shows
    I.smooth(outline, true)
    I.stroke(tone(pool_t), min(ubp * 0.055, max(0.22, 1.6 * ucm)), (o.pool or 0.26) * (0.45 + 0.55 * sk) * hi_k, true)
    local ns = o.streaks or (pointed and rng.int(3, 4) or (ubp < 12 and rng.int(4, 5) or rng.int(6, 8)))
    local lift_k = (o.lift or 1) * (1.10 - 0.10 * sk)
    for k = 1, ns do
      local f = (k - 0.5) / ns * 2 - 1 + rng.sym(0.05)
      local len = (pointed and rng.range(0.4, 0.82) or rng.range(0.34, 0.74)) * (1 - 0.35 * f * f)
      if pointed and k == (ns + 1) // 2 then f, len = 0, rng.range(0.78, 0.90) end
      local x1 = f * half(len) * 0.85 + bend * len * len
      local mx = f * half(len * 0.5) * 0.6 + rng.sym(0.02) + bend * len * len * 0.3
      I.taper(f * 0.03, 0.04, mx * 0.5, len * 0.32, mx, len * 0.62, x1, len,
        (pointed and 0.6 or 1) * rng.range(0.016, 0.032), 0.002)
    end
    I.fill(white, min(0.56, 0.32 * lift_k))
    if fn and ubp > 13 then
      local nv = max(2, floor(rng.int(3, 5) * sk))
      for _ = 1, nv do
        local f = rng.sym(0.85)
        local v0, v1 = rng.range(0.2, 0.35), rng.range(0.75, 0.95 - notch * 0.7)
        local x0, x1 = f * half(v0) * 0.7 + bend * v0 * v0, f * half(v1) * 0.9 + bend * v1 * v1
        I.smooth(I.sample(I.bezier3(x0, v0, x0 + (x1 - x0) * 0.2, lerp(v0, v1, 0.4), x1 * 0.97, lerp(v0, v1, 0.75), x1, v1), 4), false)
      end
      I.stroke(tone(vein_t), min(ubp * 0.015, max(0.11, 0.16 * max(0.75, ucm))), 0.19 * (o.vein or 1) * sk * hi_k, true)
    end
  I.unclip()
  -- the petal's silhouette counts toward the painted bbox
  I.smooth(outline, true)
  local p = take()
  grow_total(p.bbox)
  return outline
end

---------------------------------------------------------------- flowers
--- white star heart, stamens (accent pollen), at the origin; r = radius scale
function I.heart(rng, np, r, o)
  o = o or {}
  local ubp = I.unit() * r
  local sk = min(1, max(0.35, (ubp - 4.0) / 14.0))
  for k = 1, 2 * np do
    local a = (k - 0.5) * 360 / (2 * np) + rng.sym(8)
    I.push() I.rotate(a)
    I.taper(0, 0, 0.01, 0.08 * r, -0.01, 0.16 * r, 0, rng.range(0.16, 0.25) * r, 0.045 * r, 0.003 * r)
    I.pop()
  end
  I.fill(white, 0.36)
  I.circle(0, 0, 0.11 * r) I.fill(white, 0.42)
  if o.throat then
    for k = 1, np do
      local a = (k - 0.5) * 360 / np + rng.sym(6)
      I.push() I.rotate(a)
      I.taper(0, 0.02 * r, 0, 0.08 * r, 0, 0.14 * r, 0, rng.range(0.16, 0.24) * r, 0.05 * r, 0.004 * r)
      I.pop()
    end
    I.fill(o.throat, 0.36 * (0.55 + 0.45 * sk), true)
  end
  local ns = max(6, floor((o.stamens or 14) * (0.45 + 0.55 * sk)))
  local smax = o.stamen_len or 0.12
  local smin = o.stamen_min or 0.45
  local r0 = smax > 0.22 and 0.05 * r or 0
  local tips = {}
  for k = 1, ns do
    local a, d = rng.range(0, 2 * pi), rng.range(smin, 1) * smax * r
    local ca, sa = cos(a), sin(a)
    local bend = rng.sym(0.08 * d)
    I.smooth(I.sample(I.bezier3(r0 * ca, r0 * sa, 0.45 * d * ca - bend * sa, 0.45 * d * sa + bend * ca,
      0.8 * d * ca - 0.5 * bend * sa, 0.8 * d * sa + 0.5 * bend * ca, d * ca, d * sa), 4), false)
    tips[k] = { d * ca, d * sa, (o.anther_r or 0.020) * r * (1.22 - 0.22 * sk) * rng.range(0.88, 1.18) }
  end
  I.stroke(o.filament or tone(0.24), min(ubp * 0.014, max(0.10, 0.011 * ubp)), 0.48 + 0.24 * sk)
  local c_anther = o.anther or I.accent(0.1)
  if o.anther2 then
    for k = 1, ns do
      I.circle(tips[k][1], tips[k][2], tips[k][3])
      I.fill(rng.chance(0.28) and o.anther2 or c_anther, 0.96)
    end
  else
    for k = 1, ns do I.circle(tips[k][1], tips[k][2], tips[k][3]) end
    I.fill(c_anther, 0.96)
  end
  I.circle(0, 0, 0.042 * r) I.fill(I.accent(-0.12))
  I.circle(0, 0, 0.022 * r) I.fill(I.accent(0.32))
end

--- A flower of np broad petals seen from the front (sy < 1: foreshortened,
--- seen at a tilt). s = petal length (local units); centre at the origin.
--- o: petals, tone, notch, sy, w, stamens, stamen_len, pool, blush.
function I.flower(rng, s, o)
  o = o or {}
  I.push()
  I.scale(s)
  if o.sy and o.sy < 1 then I.rotate(o.tilt or 0); I.scale(1, o.sy) end
  I.rotate(rng.range(0, 72))
  local np = o.petals or 5
  local t0 = o.tone or (rng.chance(0.25) and rng.range(0.2, 0.28) or rng.range(0.3, 0.46))
  o.tone = t0
  if o.calyx_dots and o.sepal then
    for k = 0, np - 1 do
      I.push()
      I.rotate((k + 0.5) * 360 / np + rng.sym(5))
      I.translate(0, 0.56)
      I.scale(0.09, 0.22)
      I.smooth(I.blade(function(v) return 0, v end, 8, function(v) return sin(pi * v ^ 0.65) end, function(v) return sin(pi * v ^ 0.65) end), true)
      I.fill(o.sepal, 0.88)
      I.pop()
    end
  end
  for k = 0, np - 1 do
    I.push()
    I.rotate(k * 360 / np + rng.sym(6))
    I.scale(rng.range(0.9, 1.06))
    I.translate(0, 0.04)
    I.petal(rng, { tone = t0 + rng.sym(0.075), notch = o.notch, w = o.w and o.w * rng.range(0.92, 1.08), pool = o.pool,
      blush = o.blush, blush_color = o.blush_color, lift = o.lift, heart_color = o.heart_color })
    I.pop()
  end
  I.heart(rng, np, 1, o)
  I.pop()
end

--- Cupped side-view or half-open blossom, base at the origin pointing +y,
--- radius scale s. Uses I.petal glazes for back/front petals, protruding
--- stamens, and a dark calyx cup clasping the base.
function I.flower_side(rng, s, o)
  o = o or {}
  local half = o.half
  local t0 = o.tone or rng.range(0.32, 0.46)
  local w0 = o.w or 0.42
  I.push()
  I.scale(s)
  local ubp = I.unit()
  local sk = min(1, max(0.35, (ubp - 4.0) / 14.0))
  I.translate(0, -0.22)
  -- 1. Back petals (seen inside the cup: slightly darker tone)
  local back_ang = half and { -14, 14 } or { -26, 0, 26 }
  for _, a in ipairs(back_ang) do
    I.push()
    I.translate(0, 0.06)
    I.rotate(a + rng.sym(4))
    I.scale(half and 0.72 or 0.88, half and 0.85 or 0.96)
    I.petal(rng, { tone = max(0.18, t0 - 0.06 * sk + rng.sym(0.03)), notch = o.notch, w = w0 * 0.85,
      pool = o.pool, blush = o.blush, blush_color = o.blush_color, lift = (o.lift or 1) * 0.85 })
    I.pop()
  end
  -- 2. Stamen tuft emerging from the cup
  local ns = max(4, floor((half and rng.int(5, 8) or rng.int(9, 14)) * (0.5 + 0.5 * sk)))
  local spread = half and 22 or 38
  local tips = {}
  for k = 1, ns do
    local a = ((k - (ns + 1) / 2) / max(1, ns - 1) * 2 * spread + rng.sym(5)) * rad
    local d = rng.range(half and 0.48 or 0.58, half and 0.75 or 0.95)
    local sx, sy = rng.sym(0.04), 0.14
    local ex, ey = sx - sin(a) * d, sy + cos(a) * d
    I.smooth(I.sample(I.bezier3(sx, sy, sx - sin(a) * d * 0.4, sy + cos(a) * d * 0.45,
      ex * 0.9, sy + (ey - sy) * 0.78, ex, ey), 4), false)
    tips[k] = { ex, ey, (o.anther_r or 0.022) * (1.2 - 0.2 * sk) * rng.range(0.85, 1.15) }
  end
  I.stroke(o.filament or tone(0.24), min(ubp * 0.014, max(0.10, 0.011 * ubp)), 0.50 + 0.24 * sk)
  local c_anther = o.anther or I.accent(0.1)
  if o.anther2 then
    for k = 1, ns do
      I.circle(tips[k][1], tips[k][2], tips[k][3])
      I.fill(rng.chance(0.28) and o.anther2 or c_anther, 0.95)
    end
  else
    for k = 1, ns do I.circle(tips[k][1], tips[k][2], tips[k][3]) end
    I.fill(c_anther, 0.95)
  end
  -- 3. Front / side petals cupping the flower
  local front_ang = half and { -22, 6, 24 } or { -42, -14, 16, 42 }
  for i, a in ipairs(front_ang) do
    I.push()
    I.translate(sin(a * rad) * 0.05, 0.02)
    I.rotate(a + rng.sym(4))
    local sc = (i == 1 or i == #front_ang) and (half and 0.78 or 0.92) or (half and 0.74 or 0.85)
    I.scale(sc * 0.85, sc)
    I.petal(rng, { tone = min(0.92, t0 + 0.05 + rng.sym(0.03)), notch = o.notch, w = w0 * 0.92,
      pool = o.pool, blush = o.blush, blush_color = o.blush_color, lift = o.lift })
    I.pop()
  end
  -- 4. Calyx sepals clasping the base
  for k = -1, 1 do
    local a = k * 28 + rng.sym(5)
    I.push() I.translate(k * 0.06, -0.02) I.rotate(a) I.scale(0.08, k == 0 and 0.24 or 0.32)
    I.smooth(I.blade(function(v) return -k * 0.35 * v * v, v end, 8, function(v) return sin(pi * v ^ 0.6) end, function(v) return sin(pi * v ^ 0.6) end), true)
    I.pop()
  end
  I.fill(o.sepal or tone(0.12), 0.92)
  I.pop()
end

--- Closed bud: teardrop with three sepals; base at the origin, +y; s = length.
function I.bud(rng, s, o)
  o = o or {}
  I.push() I.scale(s)
  local ubp = I.unit()
  local sk = min(1, max(0.35, (ubp - 3.5) / 12.0))
  local bend = rng.sym(0.1)
  local wd = o.w or 0.3
  local outline = I.blade(function(v) return bend * v * v, v end, 18,
    function(v) return wd * sin(pi * v ^ 0.6) ^ 0.8 end, function(v) return wd * sin(pi * v ^ 0.6) ^ 0.8 end)
  local t0 = min(0.88, (o.tone or rng.range(0.3, 0.42)) + (1 - sk) * 0.12)
  I.smooth(outline, true) I.fill(tone(t0))
  I.smooth(outline, true) I.clip()
    I.mottle(rng, -0.3, 0, 0.3, 1, max(3, floor(6 * sk)), 0.11, max(0.10, t0 - 0.16 * sk), min(0.96, t0 + 0.18), ubp > 16 and 5 or 0)
    streak3(-0.08, 0.05, -0.1, 0.35, -0.05, 0.65, bend * 0.8, 0.95, 0.06, 0.005, white, 0.72)
    I.smooth(outline, true) I.stroke(tone(max(0.10, t0 - 0.20 * sk)), min(ubp * 0.06, max(0.22, 1.4 * ubp / 28.35)), 0.24 * (0.5 + 0.5 * sk), true)
  I.unclip()
  for k = -1, 1 do
    local a = k * 24 + rng.sym(6)
    I.push() I.translate(k * 0.05, -0.02) I.rotate(a) I.scale(0.065, k == 0 and 0.24 or 0.34)
    I.smooth(I.blade(function(v) return -k * 0.4 * v * v, v end, 8, function(v) return sin(pi * v ^ 0.6) end, function(v) return sin(pi * v ^ 0.6) end), true)
    I.pop()
  end
  I.fill(o.sepal or tone(0.14), 0.92)
  I.pop()
end

---------------------------------------------------------------- foliage
--- Paint any closed outline (local coords) with the leaf glaze: flat wash
--- (or a native gradient o.grad = {x0,y0,x1,y1,{{t,rgb},...}}), the darker
--- half on one side of the axis (o.axis = {x0,y0,x1,y1}), mottle, pooling,
--- veins lifted in white (o.veins = {{x0,y0,x1,y1}, ...}).
function I.organ(rng, outline, o)
  o = o or {}
  local t0 = o.tone or 0.35
  local bb = { math.huge, math.huge, -math.huge, -math.huge }
  for _, p in ipairs(outline) do
    bb[1], bb[2], bb[3], bb[4] = min(bb[1], p[1]), min(bb[2], p[2]), max(bb[3], p[1]), max(bb[4], p[2])
  end
  local sz = max(bb[3] - bb[1], bb[4] - bb[2])
  I.smooth(outline, true, 0.8)
  if o.grad then
    local g = o.grad
    local x0, y0 = I.to_page(g[1], g[2])
    local x1, y1 = I.to_page(g[3], g[4])
    local p = take()
    local pat = W:radial(x0, y0, 0, max(1, sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)), g[5])
    grow_total(W:fill_pattern(p, pat, (o.alpha or 1) * alpha_scale))
  else
    I.fill(tone(t0), o.alpha)
  end
  I.smooth(outline, true, 0.8)
  I.clip()
    if o.axis then
      local a = o.axis
      local sd = rng.chance(0.5) and 1 or -1
      local dx, dy = a[3] - a[1], a[4] - a[2]
      local L = sqrt(dx * dx + dy * dy)
      local nx, ny = -dy / L * sd, dx / L * sd
      I.poly({ { a[1] - dx, a[2] - dy }, { a[3] + dx, a[4] + dy }, { a[3] + dx + nx * L * 2, a[4] + dy + ny * L * 2 },
        { a[1] - dx + nx * L * 2, a[2] - dy + ny * L * 2 } }, true)
      I.fill(tone(max(0.10, t0 - 0.18)), 0.22, true)
    end
    I.mottle(rng, bb[1], bb[2], bb[3], bb[4], fine() and 13 or 6, sz * 0.11, max(0.08, t0 - 0.18), min(0.96, t0 + 0.20), fine() and 12 or 0)
    I.smooth(outline, true, 0.8)
    I.stroke(tone(max(0.08, t0 - 0.22)), max(0.5, 1.3 * I.unit() / 28.35 * (o.pool_k or 1)), 0.25, true)
    for _, vn in ipairs(o.veins or {}) do
      local x0, y0, x1, y1 = vn[1], vn[2], vn[3], vn[4]
      local mx, my = (x0 + x1) / 2 + rng.sym(0.02 * sz), (y0 + y1) / 2 + rng.sym(0.02 * sz)
      streak3(x0, y0, mx, my, mx + (x1 - mx) * 0.5, my + (y1 - my) * 0.5, x1, y1, vn[5] or sz * 0.025, sz * 0.003, white, rng.range(0.5, 0.75))
    end
  I.unclip()
end

--- Leaf pointing +y, length 1 (florilegium leaf): bent midrib, darker half,
--- veins lifted in white; depth > 0 gives pointed lobes. o: w, lobes, depth, bend, tone.
function I.leaf(rng, o)
  o = o or {}
  local W0 = o.w or rng.range(0.20, 0.27)
  local bend = o.bend or rng.sym(0.25)
  local lobes = o.lobes or rng.int(3, 5)
  local depth = o.depth or rng.range(0.3, 0.7)
  local t0 = o.tone or rng.range(0.36, 0.50)
  local spine = function(v) return bend * v * v - 0.3 * bend * v, v end
  local function tangent(v)
    local x0, y0 = spine(max(0, v - 0.01)); local x1, y1 = spine(min(1, v + 0.01))
    local dx, dy = x1 - x0, y1 - y0; local L = sqrt(dx * dx + dy * dy)
    return dx / L, dy / L
  end
  local function envelope(v) return W0 * 2.3 * v ^ 0.55 * (1 - v) ^ 0.95 end
  local teeth = function(v) return 0.006 * (1 - abs(2 * ((v * 9) % 1) - 1)) end
  local veins = {}
  local bodyw = depth > 0 and (1 - 0.75 * depth) or 1
  local hb = function(v) return envelope(v) * bodyw end
  local outline = I.blade(spine, 30, hb, hb, function(v) return (depth > 0 and 0 or 1) * teeth(v * 3) end)
  local shapes = { outline }
  if depth > 0 then
    for side = -1, 1, 2 do
      for k = 1, lobes do
        local v = 0.1 + 0.72 * (k - (side > 0 and 0.25 or 0.75)) / lobes
        local x0, y0 = spine(v)
        local tx, ty = tangent(v)
        local reach = envelope(min(0.95, v + 0.08)) * rng.range(0.95, 1.15)
        local ang = rng.range(38, 58) * rad
        local c, sn = cos(ang), sin(ang) * side
        local dx, dy = tx * c - ty * sn, tx * sn + ty * c
        local L = reach / sin(ang) * 0.95
        local lb = rng.sym(0.25) - side * 0.15
        local function ls(t) return x0 + dx * L * t - dy * lb * L * t * t, y0 + dy * L * t + dx * lb * L * t * t end
        local lwk = rng.range(0.26, 0.3)
        local lw = function(t) return L * lwk * sin(pi * t ^ 0.62) ^ 0.75 end
        shapes[#shapes + 1] = I.blade(ls, 11, lw, lw, function(t) return t > 0.2 and teeth(t * 1.4 + k) * L * 4 or 0 end)
        local mx, my = ls(0.45)
        local ex, ey = ls(0.92)
        veins[#veins + 1] = { x0, y0, mx, my, ex, ey }
      end
    end
  end
  local function trace() for _, sh in ipairs(shapes) do I.smooth(sh, true, 0.8) end end
  trace() I.fill(tone(t0))
  trace() I.clip()
    local sd = rng.chance(0.5) and 1 or -1
    local hp = {}
    for i = 0, 30 do local x, y = spine(i / 30); hp[#hp + 1] = { x, y } end
    hp[#hp + 1] = { sd * 2, 1 } hp[#hp + 1] = { sd * 2, 0 }
    I.poly(hp, true)
    I.fill(tone(max(0.12, t0 - 0.18)), 0.24, true)
    I.mottle(rng, -W0 * 2.5, 0, W0 * 2.5, 1, fine() and 13 or 6, 0.11, max(0.10, t0 - 0.18), min(0.96, t0 + 0.20), fine() and 12 or 0)
    trace()
    I.stroke(tone(max(0.10, t0 - 0.22)), max(0.5, 1.3 * I.unit() / 28.35), 0.22, true)
    I.streak(spine, 10, 0.024, 0.0025, white, 0.68)
    for _, vn in ipairs(veins) do
      streak3(vn[1], vn[2], vn[3], vn[4], vn[3] + (vn[5] - vn[3]) * 0.5, vn[4] + (vn[6] - vn[4]) * 0.5, vn[5], vn[6], 0.015, 0.002, white, rng.range(0.45, 0.68))
    end
    if depth == 0 or #veins == 0 then
      for k = 1, 9 do
        local v = (k - 0.3) / 10 * 0.9
        local sg = (k % 2 == 0) and 1 or -1
        local x0, y0 = spine(v)
        local tx, ty = tangent(v)
        local nx, ny = -ty * sg, tx * sg
        local L = hb(v) * rng.range(0.75, 0.95)
        streak3(x0, y0, x0 + nx * L * 0.4, y0 + ny * L * 0.4, x0 + nx * L * 0.75 + tx * L * 0.3, y0 + ny * L * 0.75 + ty * L * 0.3,
          x0 + nx * L * 0.95 + tx * L * 0.6, y0 + ny * L * 0.95 + ty * L * 0.6, 0.012, 0.002, white, rng.range(0.42, 0.64))
      end
    end
  I.unclip()
  trace()
  if depth == 0 then I.stroke(tone(max(0.10, t0 - 0.24)), max(0.14, 0.18 * min(1.5, I.unit() / 28.35)), 0.35) else grow_total(take().bbox) end
end

--- Palmate Japanese maple leaf (iroha-momiji), 5 or 7 deeply incised serrated
--- lobes radiating from (0, 0.08) along +y, radius scale 1. Painted with the
--- full florilegium watercolour glaze pipeline: multi-hue autumn wash,
--- per-lobe half-axis shadow, granulation mottle + specks, edge pooling, and
--- lifted palmate primary + lateral veins.
function I.maple_leaf(rng, o)
  o = o or {}
  local nl = o.lobes or (rng.chance(0.78) and 7 or 5)
  local t0 = o.tone or rng.range(0.42, 0.56)
  local fn = fine()
  local wave = I.fbm1(rng, 3)
  local teeth = function(v) return 0.011 * (1 - abs(2 * ((v * 7) % 1) - 1)) end
  local angles7 = { -114, -74, -37, 0, 37, 74, 114 }
  local lens7   = { 0.44, 0.74, 0.93, 1.04, 0.93, 0.74, 0.44 }
  local angles5 = { -82, -40, 0, 40, 82 }
  local lens5   = { 0.62, 0.90, 1.04, 0.90, 0.62 }
  local angs = nl == 5 and angles5 or angles7
  local lens = nl == 5 and lens5 or lens7
  local hx, hy = 0, 0.06
  local shapes, lobes_info = {}, {}
  -- central palmate web joining the lobe sinuses
  shapes[1] = I.blob(rng, hx, hy + 0.05, 0.18, 0.16, 0.12, 12)
  for idx = 1, #angs do
    local a0 = (angs[idx] + rng.sym(4.5)) * rad
    local L = lens[idx] * rng.range(0.93, 1.06)
    local dx, dy = -sin(a0), cos(a0)
    local nx, ny = -dy, dx
    local lb = rng.sym(0.08) - (angs[idx] > 0 and 0.04 or (angs[idx] < 0 and -0.04 or 0))
    local function ls(t)
      local c = lb * t * t * (1 - 0.3 * t)
      return hx + (dx * t + nx * c) * L, hy + (dy * t + ny * c) * L
    end
    local wmax = L * (idx == (#angs + 1) // 2 and 0.22 or 0.20) * rng.range(0.92, 1.08)
    local function lw(t)
      if t < 0.12 then return wmax * (0.48 + 0.52 * (t / 0.12)) end
      return wmax * sin(pi * ((t - 0.05) / 0.95) ^ 0.68) ^ 0.88
    end
    local function ledge(t, side)
      local wv = 0.012 * L * wave(t * 5 + idx * 13 + (side > 0 and 0 or 30)) * t
      local th = (t > 0.18 and t < 0.93) and teeth(t * 1.15 + idx * 0.3) * L * (1.2 - 0.5 * t) or 0
      return wv + th
    end
    shapes[#shapes + 1] = I.blade(ls, fn and 22 or 14, lw, lw, ledge)
    lobes_info[#lobes_info + 1] = { ls = ls, lw = lw, L = L, dx = dx, dy = dy, nx = nx, ny = ny }
  end
  local function trace() for _, sh in ipairs(shapes) do I.smooth(sh, true, 0.82) end end
  -- 1. Base wash (native radial autumn gradient if o.stops provided, else tone(t0))
  trace()
  if o.stops then
    local p = take()
    if p.bbox then
      local gx, gy = I.to_page(hx, hy)
      local ex, ey = I.to_page(hx, hy + 1.05)
      local gr = max(1, sqrt((ex - gx) ^ 2 + (ey - gy) ^ 2))
      local pat = W:radial(gx, gy, 0, gr, o.stops)
      grow_total(W:fill_pattern(p, pat, (o.alpha or 0.95) * alpha_scale))
    end
  else
    I.fill(tone(t0), o.alpha or 0.95)
  end
  -- 2. Clipped watercolour glazes: per-lobe half-shading, autumn flushes, mottle, pooling, veins
  trace() I.clip()
    local sd = rng.chance(0.5) and 1 or -1
    for i, lb in ipairs(lobes_info) do
      local sdi = (i % 2 == 0) and sd or -sd
      local hp = {}
      for k = 0, 12 do local x, y = lb.ls(k / 12); hp[#hp + 1] = { x, y } end
      local ex, ey = lb.ls(1)
      hp[#hp + 1] = { ex + lb.nx * sdi * 0.45, ey + lb.ny * sdi * 0.45 }
      hp[#hp + 1] = { hx + lb.nx * sdi * 0.45, hy + lb.ny * sdi * 0.45 }
      I.poly(hp, true)
      I.fill(tone(max(0.16, t0 - 0.18)), 0.18, true)
    end
    if o.flushes then
      for _, fl in ipairs(o.flushes) do
        I.smooth(I.blob(rng, rng.sym(0.55), rng.range(0.1, 0.8), rng.range(0.28, 0.52), rng.range(0.25, 0.48), 0.35, 8), true)
        I.fill(fl[1], fl[2] or 0.22, fl[3])
      end
    end
    I.mottle(rng, -0.95, -0.35, 0.95, 1.05, fn and 16 or 7, 0.13, max(0.14, t0 - 0.18), min(0.96, t0 + 0.20), fn and 14 or 0)
    trace()
    I.stroke(tone(max(0.14, t0 - 0.22)), max(0.5, 1.35 * I.unit() / 28.35), 0.22, true)
    local vc = o.vein_color or { 1.0, 0.96, 0.86 }
    for _, lb in ipairs(lobes_info) do
      I.streak(lb.ls, 10, 0.015 * lb.L, 0.002, vc, 0.58)
      if fn then
        for k = 1, 5 do
          local v = 0.22 + 0.62 * (k - 0.3) / 5
          local sg = (k % 2 == 0) and 1 or -1
          local x0, y0 = lb.ls(v)
          local reach = lb.lw(v) * rng.range(0.72, 0.92)
          local vx, vy = lb.nx * sg * 0.75 + lb.dx * 0.65, lb.ny * sg * 0.75 + lb.dy * 0.65
          streak3(x0, y0, x0 + vx * reach * 0.4, y0 + vy * reach * 0.4,
            x0 + vx * reach * 0.75, y0 + vy * reach * 0.75,
            x0 + vx * reach, y0 + vy * reach, 0.008 * lb.L, 0.0015, vc, rng.range(0.38, 0.55))
        end
      end
    end
  I.unclip()
  trace()
  I.stroke(tone(max(0.12, t0 - 0.24)), max(0.12, 0.16 * min(1.5, I.unit() / 28.35)), 0.28, true)
end

--- Small entire leaf, +y, length 1: wash, darker half, white midrib.
function I.leaflet(rng, o)
  o = o or {}
  local W0 = o.w or rng.range(0.16, 0.24)
  local bend = o.bend or rng.sym(0.2)
  local t0 = o.tone or rng.range(0.2, 0.34)
  local spine = function(v) return bend * v * v, v end
  local half = function(v) return W0 * 2.2 * v ^ 0.5 * (1 - v) ^ 0.9 end
  local outline, c, nrm = I.blade(spine, 18, half, half)
  I.smooth(outline, true) I.fill(tone(t0), o.alpha)
  I.smooth(outline, true) I.clip()
    local sd = rng.chance(0.5) and 1 or -1
    local hp = {}
    for i = 1, #c do hp[#hp + 1] = c[i] end
    for i = #c, 1, -1 do hp[#hp + 1] = { c[i][1] + sd * nrm[i][1], c[i][2] + sd * nrm[i][2] } end
    I.poly(hp, true) I.fill(tone(0.08), 0.3, true)
    I.streak(spine, 10, 0.03, 0.003, white, 0.65)
  I.unclip()
end

--- Glaze a pre-fitted petal/tepal/floret polygon `pts` (in current I coords)
--- oriented from base (x0,y0) to tip (x1,y1) with half-width wmax.
function I.glaze_petal(rng, pts, x0, y0, x1, y1, wmax, o)
  if not pts or #pts < 3 then return end
  o = o or {}
  local dx, dy = x1 - x0, y1 - y0
  local L = max(1.5, sqrt(dx * dx + dy * dy))
  local W0 = min(0.65, max(0.12, (wmax or (L * 0.35)) / L))
  local ubp = I.unit() * L
  local sk = min(1, max(0.30, (ubp - 3.5) / 14.0))
  local t0 = min(0.92, (o.tone or rng.range(0.38, 0.54)) + (1 - sk) * 0.12)
  local hi_k = max(0.38, 1 - max(0, (t0 - 0.55) * 1.30))
  local dark_t = max(0.10, t0 - 0.15 * sk * hi_k)
  local pool_t = o.pool_tone or max(0.10, t0 - 0.19 * sk * hi_k)
  local vein_t = max(0.12, t0 - 0.20 * sk * hi_k)
  I.poly(pts, true)
  I.clip()
    I.push()
    I.translate(x0, y0)
    I.rotate(atan(dy, dx) / rad - 90)
    I.scale(L)
    I.flood(tone(t0), -1.8, -0.3, 1.8, 1.4, o.alpha)
    if o.heart ~= false then
      local ha = (0.09 + 0.05 * (1 - sk)) * (o.alpha or 1)
      for k = 1, 5 do
        I.smooth(I.blob(rng, 0, 0.04, W0 * (0.28 + 0.12 * k), 0.08 + 0.07 * k, 0.26, 8), true)
        I.fill(o.heart_color or white, ha)
      end
    end
    if o.blush then
      for k = 1, 3 do
        I.smooth(I.blob(rng, 0, 0.06, W0 * (0.35 + 0.15 * k), 0.12 + 0.10 * k, 0.28, 8), true)
        I.fill(o.blush_color or tone(max(0.12, t0 - 0.22)), 0.14 * sk, true)
      end
    end
    local nmot = max(2, floor((ubp > 14 and 9 or 4) * sk * hi_k))
    I.mottle(rng, -W0 * 1.1, 0.1, W0 * 1.1, 0.98, nmot, 0.11, dark_t, min(0.98, t0 + 0.18), (ubp > 18 and t0 < 0.58) and 6 or 0)
    local ns = o.streaks or (ubp < 10 and rng.int(3, 5) or rng.int(5, 8))
    local lift_k = (o.lift or 1) * (1.14 - 0.14 * sk) * (o.alpha or 1)
    for k = 1, ns do
      local f = (k - 0.5) / ns * 2 - 1 + rng.sym(0.05)
      local len = rng.range(0.42, 0.84) * (1 - 0.32 * f * f)
      local x_end = f * W0 * 0.85
      local mx = f * W0 * 0.50 + rng.sym(0.02)
      I.taper(f * 0.03, 0.02, mx * 0.5, len * 0.3, mx, len * 0.6, x_end, len,
        rng.range(0.024, 0.046), 0.002)
    end
    I.fill(o.streak_color or white, min(0.94, 0.66 * lift_k))
    if o.signal_color then
      streak3(0, 0.10, rng.sym(0.02), 0.26, rng.sym(0.02), 0.42, 0, 0.58,
        W0 * 0.36, 0.01, o.signal_color, 0.88 * (o.alpha or 1))
    end
    if ubp > 9 and o.vein ~= false then
      local nv = max(2, floor(rng.int(3, 5) * sk))
      local vc = o.vein_color or tone(vein_t)
      local vmult = (o.vein_color == nil)
      for _ = 1, nv do
        local f = rng.sym(0.82)
        local v0, v1 = rng.range(0.18, 0.34), rng.range(0.72, 0.94)
        local xa, xb = f * W0 * 0.55, f * W0 * 0.88
        I.smooth(I.sample(I.bezier3(xa, v0, xa + (xb - xa) * 0.25, lerp(v0, v1, 0.4), xb * 0.96, lerp(v0, v1, 0.75), xb, v1), 4), false)
      end
      I.stroke(vc, min(ubp * 0.015, max(0.11, 0.15 * ubp / 28.35)), 0.22 * (o.vein or 1) * sk, vmult)
    end
    I.pop()
    I.poly(pts, true)
    I.stroke(tone(pool_t), min(ubp * 0.055, max(0.22, 1.4 * ubp / 28.3465)), (o.pool or 0.24) * (0.45 + 0.55 * sk) * hi_k, true)
  I.unclip()
  I.poly(pts, true)
  local p = take()
  grow_total(p.bbox)
end

--- Glaze a pre-fitted leaf polygon `pts` oriented from base (x0,y0) to tip (x1,y1).
function I.glaze_leaf(rng, pts, x0, y0, x1, y1, wmax, o)
  if not pts or #pts < 3 then return end
  o = o or {}
  local dx, dy = x1 - x0, y1 - y0
  local L = max(2, sqrt(dx * dx + dy * dy))
  local W0 = min(0.55, max(0.08, (wmax or (L * 0.25)) / L))
  local ubp = I.unit() * L
  local sk = min(1, max(0.32, (ubp - 5.0) / 18.0))
  local t0 = o.tone or rng.range(0.36, 0.52)
  I.poly(pts, true)
  I.clip()
    I.push()
    I.translate(x0, y0)
    I.rotate(atan(dy, dx) / rad - 90)
    I.scale(L)
    I.flood(tone(t0), -1.8, -0.3, 1.8, 1.4, o.alpha)
    local sd = rng.chance(0.5) and 1 or -1
    I.poly({ { 0, -0.1 }, { 0, 1.1 }, { sd * 1.5, 1.1 }, { sd * 1.5, -0.1 } }, true)
    I.fill(tone(max(0.10, t0 - 0.18)), 0.22 * sk, true)
    local nmot = max(2, floor((ubp > 18 and 8 or 4) * sk))
    I.mottle(rng, -W0 * 1.4, 0.05, W0 * 1.4, 0.98, nmot, 0.11, max(0.10, t0 - 0.18), min(0.96, t0 + 0.20), ubp > 24 and 6 or 0)
    if o.veins ~= false and ubp > 11 then
      local vc = o.vein_color or white
      local va = (o.vein_alpha or 0.52) * (o.alpha or 1)
      streak3(0, 0.04, 0, 0.32, 0, 0.62, 0, 0.90, max(0.010, W0 * 0.07), 0.002, vc, va)
      if o.lateral_veins ~= false and W0 > 0.14 and ubp > 16 then
        for k = 1, 6 do
          local v = (k - 0.3) / 7 * 0.85
          local sg = (k % 2 == 0) and 1 or -1
          local reach = W0 * sin(pi * v ^ 0.6) * 0.85
          streak3(0, v, sg * reach * 0.4, v + reach * 0.15, sg * reach * 0.75, v + reach * 0.35,
            sg * reach, v + reach * 0.55, 0.009, 0.0018, vc, va * 0.75)
        end
      end
    end
    I.pop()
    I.poly(pts, true)
    I.stroke(tone(max(0.10, t0 - 0.22)), min(ubp * 0.045, max(0.24, 1.25 * ubp / 28.3465)), (o.pool or 0.22) * sk, true)
  I.unclip()
  I.poly(pts, true)
  local p = take()
  grow_total(p.bbox)
end

return I

