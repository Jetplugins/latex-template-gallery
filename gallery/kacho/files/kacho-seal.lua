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
-- kacho-seal.lua: procedural hanko (artist's seal) for the kacho package (M2).
--
-- ALGORITHMS & REFERENCES:
--   * M.glyph (seal-script-like glyph grammar), outline (superellipse rounded
--     square, Lamé curve, with fbm wobble and notches), hanko (paste texture,
--     speckle): adapted from the team's explorer_m2_3 prototype (kseal.lua);
--     inspired by Chinese/Japanese seal carving (zhuanwen, hakubun / shubun).
--   No external code copied.
--
--   M.hanko(ctx, {x, y, size, style = "hakubun"|"shubun", shape = "square"|
--     "oval"|"tall", glyphs = 1|2|4, angle, ground = rgb}) -> bbox, info
--   (M.seal is the same function.)
-- A seal-script-like glyph grammar fills each character cell with evenly
-- spaced blocky strokes (recursive radical splits + leaf components); the
-- outline is a rounded square / oval with fbm wobble and eroded notches; the
-- vermilion paste is uneven (pooled darker blobs, thin patches) and speckled.
-- hakubun (white characters): red block, glyphs knocked out in the ground
-- colour; shubun (red characters): red border ring and red glyph strokes.
-- Design and grammar follow the explorer_m2_3 prototype (kseal.lua).
-- The seal is growth-limited: it shrinks (down to 70 %) until it lies inside
-- ctx.region and clear of ctx.exclude, else nothing is drawn (nil).
-- Pure Lua; randomness only from ctx.rng.
local M = {}

local Wsh = require("kacho-wash")
local U = require("kacho-flora").util

local sin, cos, pi, max, min, abs, floor, sqrt = math.sin, math.cos, math.pi, math.max, math.min, math.abs, math.floor, math.sqrt

---------------------------------------------------------------- tenshotai / kaku-tensho kanji glyph dictionary
-- Authentic classical Japanese/Chinese square seal script (Kaku-tensho / 角篆)
-- stroke templates in normalized [0, 1] x [0, 1] cell coordinates (u = left->right,
-- v = bottom->top). Each entry is { "H", u0, u1, v } or { "V", u, v0, v1 }.
local KANJI_STROKES = {
  ["花"] = { -- Hana (Flower: 艹 grass + 化 change)
    { "H", 0.06, 0.94, 0.82 }, { "V", 0.28, 0.68, 0.98 }, { "V", 0.72, 0.68, 0.98 },
    { "H", 0.06, 0.38, 0.56 }, { "V", 0.24, 0.06, 0.56 },
    { "V", 0.56, 0.06, 0.60 }, { "H", 0.56, 0.90, 0.36 }, { "H", 0.56, 0.94, 0.06 }, { "V", 0.94, 0.06, 0.26 },
  },
  ["鳥"] = { -- Tori (Bird)
    { "V", 0.48, 0.86, 0.98 }, { "V", 0.20, 0.24, 0.86 }, { "H", 0.20, 0.84, 0.86 },
    { "V", 0.84, 0.56, 0.86 }, { "H", 0.20, 0.84, 0.71 }, { "H", 0.20, 0.84, 0.56 },
    { "H", 0.20, 0.78, 0.42 }, { "H", 0.20, 0.94, 0.26 }, { "V", 0.94, 0.04, 0.26 }, { "H", 0.70, 0.94, 0.04 },
    { "V", 0.12, 0.04, 0.16 }, { "V", 0.30, 0.04, 0.16 }, { "V", 0.48, 0.04, 0.16 }, { "V", 0.64, 0.04, 0.16 },
  },
  ["風"] = { -- Kaze (Wind: 几 + 虫)
    { "V", 0.08, 0.06, 0.94 }, { "H", 0.08, 0.88, 0.94 }, { "V", 0.88, 0.06, 0.94 }, { "H", 0.82, 0.96, 0.06 },
    { "H", 0.26, 0.72, 0.76 }, { "V", 0.49, 0.18, 0.76 },
    { "H", 0.26, 0.72, 0.58 }, { "H", 0.26, 0.72, 0.38 }, { "V", 0.26, 0.38, 0.58 }, { "V", 0.72, 0.38, 0.58 },
    { "H", 0.22, 0.76, 0.18 },
  },
  ["月"] = { -- Tsuki (Moon)
    { "V", 0.18, 0.06, 0.94 }, { "H", 0.18, 0.82, 0.94 }, { "V", 0.82, 0.06, 0.94 },
    { "H", 0.58, 0.82, 0.06 }, { "H", 0.18, 0.82, 0.64 }, { "H", 0.18, 0.82, 0.38 },
  },
  ["山"] = { -- Yama (Mountain)
    { "V", 0.50, 0.10, 0.96 }, { "V", 0.14, 0.10, 0.68 }, { "V", 0.86, 0.10, 0.68 },
    { "H", 0.14, 0.86, 0.10 },
  },
  ["水"] = { -- Mizu (Water: central stream + flanked eddies)
    { "V", 0.50, 0.04, 0.96 },
    { "V", 0.16, 0.58, 0.88 }, { "H", 0.16, 0.34, 0.58 }, { "H", 0.16, 0.34, 0.38 }, { "V", 0.16, 0.10, 0.38 },
    { "V", 0.84, 0.58, 0.88 }, { "H", 0.66, 0.84, 0.58 }, { "H", 0.66, 0.84, 0.38 }, { "V", 0.84, 0.10, 0.38 },
  },
  ["春"] = { -- Haru (Spring: 三 + 人 + 日)
    { "H", 0.12, 0.88, 0.90 }, { "H", 0.18, 0.82, 0.74 }, { "H", 0.06, 0.94, 0.58 },
    { "V", 0.50, 0.58, 0.98 }, { "V", 0.12, 0.32, 0.58 }, { "V", 0.88, 0.32, 0.58 },
    { "V", 0.28, 0.06, 0.44 }, { "V", 0.72, 0.06, 0.44 },
    { "H", 0.28, 0.72, 0.44 }, { "H", 0.28, 0.72, 0.25 }, { "H", 0.28, 0.72, 0.06 },
  },
  ["夏"] = { -- Natsu (Summer)
    { "H", 0.10, 0.90, 0.94 }, { "V", 0.50, 0.80, 0.94 },
    { "V", 0.22, 0.38, 0.80 }, { "V", 0.78, 0.38, 0.80 },
    { "H", 0.22, 0.78, 0.80 }, { "H", 0.22, 0.78, 0.66 }, { "H", 0.22, 0.78, 0.52 }, { "H", 0.22, 0.78, 0.38 },
    { "V", 0.38, 0.20, 0.38 }, { "H", 0.22, 0.76, 0.20 }, { "V", 0.76, 0.06, 0.20 }, { "H", 0.14, 0.88, 0.06 },
  },
  ["秋"] = { -- Aki (Autumn: 禾 grain + 火 fire)
    { "H", 0.06, 0.46, 0.88 }, { "H", 0.04, 0.46, 0.64 }, { "V", 0.26, 0.06, 0.88 },
    { "V", 0.08, 0.22, 0.64 }, { "V", 0.42, 0.28, 0.64 },
    { "V", 0.56, 0.50, 0.76 }, { "V", 0.92, 0.50, 0.76 }, { "V", 0.74, 0.28, 0.92 },
    { "H", 0.56, 0.92, 0.28 }, { "V", 0.56, 0.06, 0.28 }, { "V", 0.92, 0.06, 0.28 },
  },
  ["冬"] = { -- Fuyu (Winter)
    { "H", 0.22, 0.78, 0.92 }, { "V", 0.22, 0.52, 0.92 }, { "V", 0.78, 0.52, 0.92 },
    { "H", 0.08, 0.92, 0.52 }, { "V", 0.50, 0.52, 0.92 },
    { "H", 0.26, 0.74, 0.32 }, { "H", 0.16, 0.84, 0.12 },
  },
  ["松"] = { -- Matsu (Pine: 木 + 公)
    { "H", 0.04, 0.44, 0.68 }, { "V", 0.24, 0.06, 0.94 }, { "V", 0.08, 0.22, 0.68 }, { "V", 0.40, 0.28, 0.68 },
    { "V", 0.56, 0.56, 0.88 }, { "V", 0.90, 0.56, 0.88 },
    { "H", 0.54, 0.92, 0.42 }, { "V", 0.58, 0.12, 0.42 }, { "H", 0.58, 0.92, 0.12 }, { "V", 0.92, 0.06, 0.28 },
  },
  ["竹"] = { -- Take (Bamboo)
    { "H", 0.04, 0.46, 0.76 }, { "V", 0.14, 0.56, 0.94 }, { "V", 0.28, 0.06, 0.76 },
    { "H", 0.54, 0.96, 0.76 }, { "V", 0.64, 0.56, 0.94 }, { "V", 0.78, 0.06, 0.76 }, { "H", 0.62, 0.78, 0.06 },
  },
  ["梅"] = { -- Ume (Plum: 木 + 毎)
    { "H", 0.04, 0.44, 0.68 }, { "V", 0.24, 0.06, 0.94 }, { "V", 0.08, 0.24, 0.68 }, { "V", 0.40, 0.30, 0.68 },
    { "V", 0.56, 0.74, 0.94 }, { "H", 0.56, 0.94, 0.82 },
    { "V", 0.54, 0.10, 0.66 }, { "V", 0.90, 0.10, 0.66 }, { "V", 0.72, 0.10, 0.66 },
    { "H", 0.54, 0.90, 0.66 }, { "H", 0.48, 0.96, 0.38 }, { "H", 0.54, 0.90, 0.10 },
  },
  ["雅"] = { -- Miyabi (Elegance: 牙 + 隹)
    { "H", 0.06, 0.44, 0.88 }, { "V", 0.14, 0.56, 0.88 }, { "H", 0.04, 0.44, 0.56 },
    { "V", 0.34, 0.06, 0.88 }, { "H", 0.14, 0.34, 0.06 },
    { "V", 0.56, 0.06, 0.92 }, { "V", 0.74, 0.12, 0.84 },
    { "H", 0.56, 0.94, 0.84 }, { "H", 0.56, 0.92, 0.60 }, { "H", 0.56, 0.92, 0.36 }, { "H", 0.56, 0.96, 0.12 },
  },
  ["芳"] = { -- Kaori (Fragrant Blossom: 艹 + 方)
    { "H", 0.08, 0.92, 0.84 }, { "V", 0.30, 0.70, 0.96 }, { "V", 0.70, 0.70, 0.96 },
    { "V", 0.50, 0.58, 0.72 }, { "H", 0.08, 0.92, 0.58 },
    { "V", 0.34, 0.08, 0.58 }, { "H", 0.34, 0.78, 0.36 }, { "V", 0.78, 0.08, 0.36 }, { "H", 0.58, 0.78, 0.08 },
  },
  ["印"] = { -- In (Seal)
    { "V", 0.12, 0.10, 0.90 }, { "H", 0.12, 0.46, 0.90 }, { "H", 0.12, 0.44, 0.52 }, { "H", 0.12, 0.46, 0.14 },
    { "V", 0.58, 0.06, 0.90 }, { "H", 0.58, 0.90, 0.90 }, { "V", 0.90, 0.32, 0.90 }, { "H", 0.58, 0.90, 0.32 },
  },
}

local KANJI_LIST = { "花", "鳥", "風", "月", "春", "夏", "秋", "冬", "山", "水", "松", "竹", "梅", "雅", "芳", "印" }
local COMPOUNDS_2 = {
  { "花", "鳥" }, { "風", "月" }, { "山", "水" }, { "春", "秋" },
  { "松", "竹" }, { "風", "雅" }, { "芳", "印" }, { "梅", "月" },
}
local COMPOUNDS_4 = {
  { "花", "鳥", "風", "月" },
  { "春", "夏", "秋", "冬" },
  { "松", "竹", "梅", "雅" },
  { "山", "水", "風", "月" },
}
M.KANJI_STROKES = KANJI_STROKES

--- Glyph strokes (axis-aligned rects {x0,y0,x1,y1}) filling a cell with an authentic
--- Small Seal Script (Tenshotai / Kaku-tensho) kanji character.
function M.glyph(R, x0, y0, x1, y1, sw, depth, out, char_name)
  out = out or {}
  local w, h = x1 - x0, y1 - y0
  local ch = char_name or KANJI_LIST[R.int(1, #KANJI_LIST)]
  local tpl = KANJI_STROKES[ch] or KANJI_STROKES["花"]
  local s = min(sw, min(w, h) * (#tpl >= 10 and 0.105 or 0.125))
  local ws, hs = max(0, w - s), max(0, h - s)
  for _, st in ipairs(tpl) do
    if st[1] == "H" then
      local u0, u1, v = st[2], st[3], st[4]
      local ax = x0 + u0 * ws
      local bx = min(x1, x0 + u1 * ws + s)
      local ay = y0 + v * hs
      local by = min(y1, ay + s)
      out[#out + 1] = { ax, ay, bx, by }
    else
      local u, v0, v1 = st[2], st[3], st[4]
      local ax = x0 + u * ws
      local bx = min(x1, ax + s)
      local ay = y0 + v0 * hs
      local by = min(y1, y0 + v1 * hs + s)
      out[#out + 1] = { ax, ay, bx, by }
    end
  end
  return out
end

---------------------------------------------------------------- outline
local function outline(R, shape, hw, hh, n, wob, notches)
  local pts = {}
  local f = R.noise(3)
  local ph = R.range(0, 100)
  local nset = {}
  for i = 1, notches do nset[i] = { R.u(), R.range(0.006, 0.02) * hw * 4, R.range(0.02, 0.05) } end
  for i = 0, n - 1 do
    local t = i / n
    local a = 2 * pi * t
    local u, v, nu, nv
    if shape == "oval" then
      u, v = hw * cos(a), hh * sin(a)
      nu, nv = cos(a) / hw, sin(a) / hh
    else
      local p = 2 / 9
      local ca, sa = cos(a), sin(a)
      u = hw * (ca >= 0 and 1 or -1) * abs(ca) ^ p
      v = hh * (sa >= 0 and 1 or -1) * abs(sa) ^ p
      nu, nv = (ca >= 0 and 1 or -1) * abs(ca) ^ (2 - p), (sa >= 0 and 1 or -1) * abs(sa) ^ (2 - p)
    end
    local nl = sqrt(nu * nu + nv * nv)
    if nl < 1e-9 then nu, nv, nl = cos(a), sin(a), 1 end
    nu, nv = nu / nl, nv / nl
    local d = wob * f(t * 18 + ph)
    for _, nt in ipairs(nset) do
      local dt = abs(t - nt[1]); dt = min(dt, 1 - dt)
      if dt < nt[3] then d = d - nt[2] * (0.5 + 0.5 * cos(pi * dt / nt[3])) end
    end
    pts[#pts + 1] = { u + nu * d, v + nv * d }
  end
  return pts
end
M.outline = outline

local function rectpoly(R, r, jit)
  local x0, y0, x1, y1 = r[1], r[2], r[3], r[4]
  local P = {}
  local function edge(ax, ay, bx, by)
    local n = max(2, floor(sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / (jit * 8)) + 1)
    for i = 0, n - 1 do
      local t = i / n
      P[#P + 1] = { ax + (bx - ax) * t + R.sym(jit), ay + (by - ay) * t + R.sym(jit) }
    end
  end
  edge(x0, y0, x1, y0); edge(x1, y0, x1, y1); edge(x1, y1, x0, y1); edge(x0, y1, x0, y0)
  return P
end

--- The colour actually under the art: the page ground tint if one is set,
--- white paper otherwise (or spec.ground).
local function ground_color(ctx, spec)
  if spec and spec.ground then return spec.ground end
  return U.paper(ctx)
end

---------------------------------------------------------------- seal
function M.hanko(ctx, spec)
  spec = spec or {}
  local R = ctx.rng
  local W = ctx.pdf
  local size = spec.size or 28
  local shape = spec.shape or (R.chance(0.6) and "square" or (R.chance(0.5) and "oval" or "tall"))
  local style = spec.style or (R.chance(0.5) and "hakubun" or "shubun")
  local rot = spec.angle or R.sym(math.rad(2.5))
  local function extent(sz)
    local hw, hh = sz / 2, sz / 2
    if shape == "tall" then hh = sz / 2 * (spec.aspect or 1.7) end
    if shape == "oval" then hh = sz / 2 * (spec.aspect or 1.25) end
    return hw, hh
  end
  -- growth limiting: shrink to fit
  local ok = false
  for _ = 1, 4 do
    local hw, hh = extent(size)
    local r = sqrt(hw * hw + hh * hh) * 0.05
    local b = { x0 = spec.x - hw - r - 1, y0 = spec.y - hh - r - 1, x1 = spec.x + hw + r + 1, y1 = spec.y + hh + r + 1 }
    if U.fits_rect(ctx, b) then ok = true; break end
    size = size * 0.9
  end
  if not ok then return nil end
  local red = spec.color or ctx.palette.color("shu")
  local dark = ctx.palette.color("bengara")
  local ground = ground_color(ctx, spec)
  local hw, hh = extent(size)
  local cr, sr = cos(rot), sin(rot)
  local function P(u, v) return spec.x + u * cr - v * sr, spec.y + u * sr + v * cr end
  local function pts(list) local o = {} for i, q in ipairs(list) do local x, y = P(q[1], q[2]); o[i] = { x, y } end return o end
  local outerW = pts(outline(R, shape, hw, hh, 96, size * 0.006, R.int(3, 7)))
  local bb = U.bbox_pts(outerW, 0.5)
  local inset = (style == "hakubun") and 0.11 or 0.17
  local gx0, gy0, gx1, gy1 = -hw + size * inset, -hh + size * inset, hw - size * inset, hh - size * inset
  if shape == "oval" then
    local k = 0.70
    gx0, gx1, gy0, gy1 = -hw * k + size * 0.06, hw * k - size * 0.06, -hh * k + size * 0.06, hh * k - size * 0.06
  end
  local nch = spec.glyphs or ((shape == "square") and (R.chance(0.6) and 4 or 2) or (shape == "tall" and 2 or 1))
  local gap = size * (style == "hakubun" and 0.07 or 0.06)
  local cells, chars
  if nch == 4 then
    local xm, ym = (gx0 + gx1) / 2, (gy0 + gy1) / 2
    -- Traditional seal reading order: 1 top-right, 2 bottom-right, 3 top-left, 4 bottom-left
    cells = { { xm + gap / 2, ym + gap / 2, gx1, gy1 }, { xm + gap / 2, gy0, gx1, ym - gap / 2 },
              { gx0, ym + gap / 2, xm - gap / 2, gy1 }, { gx0, gy0, xm - gap / 2, ym - gap / 2 } }
    chars = COMPOUNDS_4[R.int(1, #COMPOUNDS_4)]
  elseif nch == 2 then
    if shape == "tall" or R.chance(0.5) then
      local ym = (gy0 + gy1) / 2
      cells = { { gx0, ym + gap / 2, gx1, gy1 }, { gx0, gy0, gx1, ym - gap / 2 } }
    else
      local xm = (gx0 + gx1) / 2
      cells = { { xm + gap / 2, gy0, gx1, gy1 }, { gx0, gy0, xm - gap / 2, gy1 } }
    end
    chars = COMPOUNDS_2[R.int(1, #COMPOUNDS_2)]
  else
    cells = { { gx0, gy0, gx1, gy1 } }
    chars = { KANJI_LIST[R.int(1, #KANJI_LIST)] }
  end
  local sw = size * ((style == "hakubun") and 0.065 or 0.045) * (nch == 1 and 1.22 or 1)
  local rects = {}
  for idx, c in ipairs(cells) do M.glyph(R, c[1], c[2], c[3], c[4], sw, (nch == 1) and 2 or 1, rects, chars[idx]) end
  local gparts = {}
  for _, r in ipairs(rects) do gparts[#gparts + 1] = W:poly(U.ccw(pts(rectpoly(R, r, sw * 0.08))), true) end
  local gpath = W:join(gparts)
  local alpha = spec.alpha or 0.92
  local outerP = W:poly(outerW, true)
  local function texture()
    for _ = 1, R.int(2, 4) do
      local x, y = P(R.sym(hw * 0.7), R.sym(hh * 0.7))
      W:fill(W:poly(Wsh.blob(R, x, y, size * R.range(0.12, 0.25), size * R.range(0.08, 0.18), 0.4, 28), true), dark, 0.10, { blend = "multiply" })
    end
    for _ = 1, R.int(1, 3) do
      local a = R.range(0, 2 * pi)
      local x, y = P(cos(a) * hw * 0.92, sin(a) * hh * 0.92)
      W:fill(W:poly(Wsh.blob(R, x, y, size * R.range(0.05, 0.10), size * R.range(0.03, 0.06), 0.5, 28, a), true), ground, 0.30)
    end
  end
  local function speckle()
    local nsp = floor(size * R.range(1.5, 2.5))
    local f = R.noise(2)
    local dots = {}
    for _ = 1, nsp do
      local u, v = R.sym(hw), R.sym(hh)
      if f(u / size * 6) + f(v / size * 6 + 40) > -0.1 then
        local x, y = P(u, v)
        local r = size * R.range(0.003, 0.012)
        dots[#dots + 1] = W:ellipse(x, y, r, r * R.range(0.5, 1), R.range(0, pi))
      end
    end
    if #dots > 0 then W:fill(W:join(dots), ground, 0.85) end
  end
  W:layer(spec.layer or 60)
  if style == "hakubun" then
    W:fill(outerP, red, alpha)
    W:clip(outerP); texture(); W:unclip()
    W:fill(gpath, ground, 1)
    W:clip(outerP); speckle(); W:unclip()
  else
    local bw = size * (0.055 + R.range(0, 0.02))
    local inner = pts(outline(R, shape, hw - bw, hh - bw, 96, size * 0.005, R.int(0, 2)))
    local ring = W:join(outerP, W:poly(inner, true))
    W:fill(ring, red, alpha, { evenodd = true })
    W:fill(gpath, red, alpha)
    W:clip(ring, true); texture(); speckle(); W:unclip()
    W:clip(gpath); texture(); speckle(); W:unclip()
  end
  U.rec(ctx, "seal", bb)
  return bb, { style = style, shape = shape, kinds = { "seal" } }
end
M.seal = M.hanko

return M
