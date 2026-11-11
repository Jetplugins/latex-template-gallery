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
-- kacho-fauna.lua: birds of the kacho package (M2): perched robin (Koson
-- style), uguisu (bush warbler), sparrow (suzume), mejiro (white-eye), and the
-- swallow (tsubame) in flight.
--
-- ALGORITHMS & REFERENCES:
--   * draw_bird / M.bird / M.swallow: closed Catmull-Rom shapes in a local
--     frame (Catmull & Rom 1974, "A class of local interpolating splines");
--     shapes, paint order and page-space leg/toe placement adapted from the
--     team's explorer_m2_3 prototype (kfauna.lua), after Ohara Koson's
--     kachō-e prints (reference images). Mejiro shape and colours: own.
--   * trial: draw-then-commit growth limiting (own).
--   No external code copied.
--
-- Contract (tex/API.md section 3):
--   M.bird(ctx, {perch = info.perch[i], kind = "robin"|"uguisu"|"sparrow"|"mejiro",
--                size = body length bp, facing = +1|-1}) -> bbox, info
--   M.robin / M.uguisu / M.sparrow / M.mejiro (ctx, spec) are shorthands;
--   M.swallow(ctx, {x, y, size = wingspan, angle}) -> bbox.
-- A perch is a point on a branch: {cx, cy} on the centre line (or x, y),
-- angle (branch tangent) and w (branch width), as returned by the flora
-- motifs. Legs and toes are computed in page space from the perch, so the feet
-- always grip the branch top. The whole bird is drawn in a trial writer and
-- committed only if it fits ctx.region and clears ctx.exclude (otherwise the
-- other facing is tried, then nothing is drawn: returns nil).
-- Shapes and paint order follow the explorer_m2_3 prototype (kfauna.lua).
-- Pure Lua; randomness only from ctx.rng.
local M = {}

local B = require("kacho-brush")
local Wsh = require("kacho-wash")
local U = require("kacho-flora").util

local sin, cos, pi, abs, max, min, sqrt = math.sin, math.cos, math.pi, math.abs, math.max, math.min, math.sqrt
local union, mix = U.union, U.mix

---------------------------------------------------------------- local helpers
local function cr(pts, nper, closed)
  local n, out = #pts, {}
  nper = nper or 8
  local function at(i)
    if closed then return pts[(i - 1) % n + 1] end
    return pts[max(1, min(n, i))]
  end
  local last = closed and n or n - 1
  for i = 1, last do
    local p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
    for j = 0, nper - 1 do
      local t = j / nper
      local t2, t3 = t * t, t * t * t
      local function c(k)
        return 0.5 * ((2 * p1[k]) + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 +
          (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3)
      end
      out[#out + 1] = { c(1), c(2) }
    end
  end
  if not closed then out[#out + 1] = { pts[n][1], pts[n][2] } end
  return out
end

-- local frame: origin (ox,oy), scale s, rotation rot, mirror m (1 or -1 on u)
local function frame(ox, oy, s, rot, m)
  local c, sn = cos(rot), sin(rot)
  m = m or 1
  local F = {}
  function F.p(u, v)
    local x, y = u * s * m, v * s
    return ox + x * c - y * sn, oy + x * sn + y * c
  end
  function F.pts(list)
    local o = {}
    for i, q in ipairs(list) do local x, y = F.p(q[1], q[2]); o[i] = { x, y } end
    return o
  end
  return F
end

-- tapered stroke through control points; returns outline
local function stroke(W, ctrl, w0, prof, c, a, blend)
  local segs = B.chain(ctrl, 1)
  local S = B.spine(segs, { step = 0.5 })
  local out = B.outline(S, function(u) return w0 * prof(u) end)
  W:fill(W:poly(out, true), c, a, { blend = blend })
  return out
end
local both = B.profile.both

--- Draw fn(trial_ctx) into a scratch writer; commit when the returned bbox
--- fits ctx.region / clears ctx.exclude, else discard. Returns bbox or nil.
local function trial(ctx, fn)
  local W = ctx.pdf
  local scratch = W:sub()
  scratch.cur = W.cur
  local tc = {}
  for k, v in pairs(ctx) do tc[k] = v end
  tc.pdf = scratch
  local bb, info = fn(tc)
  if bb and U.fits_rect(ctx, bb) then
    W:merge(scratch)
    return bb, info
  end
  return nil
end
M.trial = trial

---------------------------------------------------------------- shapes
-- Bird faces +u, unit = body size s, origin = grip point; v up.
local SHAPE = {
  robin = {
    body = { {0.60,0.66},{0.53,0.76},{0.40,0.80},{0.26,0.76},{0.10,0.68},{-0.10,0.60},{-0.30,0.53},{-0.44,0.47},
             {-0.43,0.38},{-0.28,0.27},{-0.08,0.18},{0.12,0.16},{0.30,0.21},{0.44,0.31},{0.54,0.44},{0.61,0.55} },
    eye = { 0.50, 0.67 }, beak = { {0.60,0.68},{0.75,0.635},{0.61,0.60} },
    tail = { {-0.34,0.53},{-0.70,0.60},{-1.08,0.66},{-1.10,0.60},{-0.72,0.51},{-0.40,0.40} },
    wing = { {0.26,0.66},{0.10,0.69},{-0.12,0.64},{-0.38,0.55},{-0.66,0.48},{-0.52,0.43},{-0.28,0.37},{-0.04,0.36},{0.14,0.42},{0.24,0.53} },
    legs = { {0.04,0.19},{0.14,0.18} },
  },
  sparrow = {
    body = { {0.58,0.70},{0.52,0.84},{0.36,0.90},{0.20,0.86},{0.06,0.76},{-0.14,0.68},{-0.32,0.58},{-0.42,0.48},
             {-0.38,0.34},{-0.22,0.22},{0.00,0.15},{0.22,0.17},{0.40,0.27},{0.52,0.41},{0.59,0.54},{0.61,0.62} },
    eye = { 0.46, 0.73 }, beak = { {0.58,0.75},{0.72,0.69},{0.59,0.62} },
    tail = { {-0.32,0.56},{-0.56,0.58},{-0.80,0.58},{-0.80,0.50},{-0.56,0.45},{-0.38,0.40} },
    wing = { {0.22,0.68},{0.06,0.72},{-0.14,0.66},{-0.36,0.56},{-0.56,0.48},{-0.44,0.42},{-0.24,0.36},{-0.02,0.34},{0.14,0.40},{0.22,0.54} },
    legs = { {0.02,0.17},{0.13,0.16} },
  },
  -- mejiro: plump round body, short tail, small pointed beak
  mejiro = {
    body = { {0.56,0.70},{0.50,0.84},{0.36,0.92},{0.18,0.90},{0.02,0.80},{-0.16,0.70},{-0.32,0.58},{-0.40,0.46},
             {-0.34,0.30},{-0.18,0.17},{0.02,0.11},{0.24,0.14},{0.42,0.25},{0.54,0.40},{0.59,0.53},{0.59,0.62} },
    eye = { 0.42, 0.74 }, beak = { {0.56,0.74},{0.70,0.70},{0.57,0.65} },
    tail = { {-0.30,0.54},{-0.52,0.54},{-0.72,0.50},{-0.70,0.42},{-0.50,0.40},{-0.34,0.40} },
    wing = { {0.18,0.70},{0.02,0.74},{-0.18,0.66},{-0.38,0.54},{-0.54,0.44},{-0.42,0.38},{-0.22,0.33},{0.00,0.33},{0.12,0.42},{0.18,0.56} },
    legs = { {0.02,0.13},{0.12,0.12} },
  },
}
SHAPE.uguisu = SHAPE.robin

local function auto_face(angle)
  local tx, ty = cos(angle), sin(angle)
  if ty < 0 then tx = -tx end
  return (tx > 0) and -1 or 1
end

local function colors(ctx, kind)
  local C = function(n) return ctx.palette.color(n) end
  local slate, slate2 = mix(C("tsubame-navy"), C("sumi-dark"), 0.5), mix(C("tsubame-navy"), C("sumi-mid"), 0.45)
  local cream = mix(C("gofun"), C("torinoko"), 0.6)
  if kind == "robin" then
    return { back = slate, back2 = slate2, base = cream, breast = C("shu"), breast2 = C("yamabuki"),
      wing = slate, edge = C("gofun"), tail = slate, leg = C("sumi-mid"), beak = C("sumi-noir"), brow = C("gofun"),
      tertial = mix(C("torinoko"), C("kigaki"), 0.3) }
  elseif kind == "uguisu" then
    local ol = C("uguisu")
    return { back = ol, back2 = mix(ol, C("sumi-dark"), 0.25), base = mix(ol, C("gofun"), 0.6), wing = mix(ol, C("sumi-dark"), 0.25),
      edge = mix(ol, C("gofun"), 0.55), tail = mix(ol, C("sumi-dark"), 0.25), leg = mix(C("kuri"), C("gofun"), 0.25),
      beak = C("sumi-dark"), brow = mix(ol, C("gofun"), 0.7) }
  elseif kind == "mejiro" then
    local g = mix(C("wakatake"), C("moegi"), 0.45)
    return { back = g, back2 = mix(g, C("matsuba"), 0.45), base = mix(C("gofun"), C("sakura-pale"), 0.35),
      wing = mix(g, C("matsuba"), 0.5), edge = mix(C("moegi"), C("gofun"), 0.4), tail = mix(g, C("matsuba"), 0.55),
      leg = C("sumi-mid"), beak = C("sumi-dark"), throat = C("yamabuki"), flank = mix(C("momo"), C("kigaki"), 0.35) }
  end
  return { back = mix(C("kuri"), C("kigaki"), 0.3), back2 = C("kuri"), base = mix(C("sumi-wash"), C("torinoko"), 0.5),
    wing = C("kuri"), edge = mix(C("kigaki"), C("gofun"), 0.4), tail = C("kuri"), leg = mix(C("kuri"), C("gofun"), 0.25),
    beak = C("sumi-dark") }
end

---------------------------------------------------------------- perched bird
local function draw_bird(ctx, spec, face)
  local W, R = ctx.pdf, ctx.rng
  local C = function(n) return ctx.palette.color(n) end
  local kind = spec.kind or "robin"
  local Sh = SHAPE[kind] or SHAPE.robin
  local s = spec.size or 40
  local angle = spec.angle or 0
  local tilt = spec.tilt or (R.sym(0.06) + (kind == "robin" and 0.06 or 0))
  local bw = spec.branch_w or 3
  local drop = spec.drop or ((kind == "sparrow" or kind == "mejiro") and 0.07 or 0.10)
  local ox, oy = spec.x, spec.y + bw * 0.45 - drop * s
  local Fb = frame(ox, oy, s, tilt * face, face)
  local pal = colors(ctx, kind)
  local bb
  local function closed(ctrl, n) return U.ccw(Fb.pts(cr(ctrl, n or 6, true))) end
  local function fillc(ctrl, c, a, blend)
    local p = closed(ctrl)
    bb = union(bb, U.bbox_pts(p, 0.5))
    W:fill(W:poly(p, true), c, a, { blend = blend })
    return p
  end
  local function soft(u, v, rx, ry, c, a, blend)
    local x, y = Fb.p(u, v)
    Wsh.soft(ctx, x, y, rx * s, ry * s, { rgb = c, alpha = a, blend = blend })
  end
  local function st(ctrl, w, c, a) local o = stroke(W, Fb.pts(ctrl), w, both, c, a); bb = union(bb, U.bbox_pts(o, 0.3)) end
  -- 1. tail
  fillc(Sh.tail, pal.tail, 0.92)
  st({ { Sh.tail[1][1] - 0.02, (Sh.tail[1][2] + Sh.tail[6][2]) / 2 }, { Sh.tail[3][1] + 0.05, (Sh.tail[3][2] + Sh.tail[4][2]) / 2 } },
    s * 0.012, pal.edge, 0.35)
  -- 2. body
  local bodyp = closed(Sh.body)
  bb = union(bb, U.bbox_pts(bodyp, 0.5))
  local bodyP = W:poly(bodyp, true)
  W:fill(bodyP, pal.base, 0.97)
  W:clip(bodyP)
  if kind == "robin" then
    soft(0.36, 0.40, 0.30, 0.24, pal.breast2, 0.55)
    soft(0.44, 0.46, 0.24, 0.20, pal.breast, 0.85)
    soft(0.50, 0.54, 0.14, 0.12, pal.breast, 0.5)
  elseif kind == "uguisu" then
    soft(0.0, 0.60, 0.70, 0.30, pal.back, 0.9)
    soft(0.25, 0.30, 0.35, 0.16, C("gofun"), 0.35)
  elseif kind == "mejiro" then
    soft(0.0, 0.72, 0.75, 0.32, pal.back, 0.95)
    soft(-0.05, 0.62, 0.55, 0.16, pal.back, 0.6)
    soft(0.46, 0.58, 0.18, 0.14, pal.throat, 0.92)                -- bright yellow throat
    soft(0.12, 0.32, 0.28, 0.14, pal.flank, 0.42)                 -- rosy-buff flank wash
  else
    soft(0.15, 0.30, 0.40, 0.18, C("gofun"), 0.35)
  end
  local seam
  if kind == "robin" or kind == "uguisu" then
    seam = { {0.80,0.63},{0.60,0.625},{0.50,0.60},{0.38,0.56},{0.20,0.52},{0.0,0.48},{-0.3,0.42},{-0.6,0.36} }
  elseif kind == "mejiro" then
    seam = { {0.80,0.70},{0.56,0.69},{0.42,0.67},{0.28,0.62},{0.12,0.54},{-0.08,0.47},{-0.32,0.41},{-0.6,0.36} }
  elseif kind == "sparrow" then
    seam = { {0.80,0.80},{0.56,0.79},{0.40,0.80},{0.26,0.74},{0.14,0.66},{-0.05,0.58},{-0.3,0.48},{-0.6,0.40} }
  end
  if seam then
    for pass = 1, 2 do
      local poly = {}
      for i, p in ipairs(seam) do poly[i] = { p[1], p[2] + (pass - 1) * 0.035 } end
      poly[#poly + 1] = { -0.6, 1.3 }; poly[#poly + 1] = { 0.8, 1.3 }
      W:fill(W:poly(Fb.pts(poly), true), pal.back, pass == 1 and 0.55 or 0.78)
    end
  end
  if kind == "mejiro" then
    soft(0.46, 0.57, 0.17, 0.13, pal.throat, 0.88)
  end
  if kind == "robin" or kind == "uguisu" then
    soft(0.30, 0.78, 0.30, 0.12, C("sumi-noir"), 0.35, "multiply")
    for row = 1, 2 do
      for i = 1, 4 do
        local u = 0.20 - i * 0.11 - row * 0.04 + R.sym(0.015)
        local v = 0.70 - i * 0.045 - row * 0.05
        stroke(W, Fb.pts({ {u + 0.04, v + 0.02}, {u, v}, {u - 0.05, v - 0.005} }), s * 0.014, both, pal.edge, 0.28)
      end
    end
  end
  if kind == "sparrow" then
    W:fill(W:poly(closed({ {0.56,0.84},{0.44,0.93},{0.26,0.93},{0.12,0.84},{0.22,0.80},{0.40,0.82},{0.52,0.79} }), true), C("kuri"), 0.9)
    W:fill(W:poly(closed({ {0.50,0.74},{0.40,0.78},{0.24,0.76},{0.16,0.66},{0.26,0.56},{0.42,0.56},{0.52,0.64} }), true), C("gofun"), 0.92)
    local ex2, ey2 = Fb.p(0.33, 0.645)
    W:fill(W:ellipse(ex2, ey2, s * 0.055, s * 0.045, 0.3), C("sumi-noir"), 0.85)
    W:fill(W:poly(closed({ {0.62,0.62},{0.54,0.58},{0.50,0.48},{0.54,0.40},{0.60,0.50} }), true), C("sumi-noir"), 0.85)
    for i = 1, 7 do
      local u, v = -0.32 + i * 0.07 + R.sym(0.02), 0.56 + R.sym(0.04) + i * 0.012
      local a = R.sym(0.2) - 0.35
      stroke(W, Fb.pts({ {u, v}, {u - 0.07 * cos(a), v + 0.07 * sin(a)} }), s * 0.03, both, C("sumi-noir"), 0.55)
    end
  end
  W:unclip()
  -- 3. wing
  local wingp = closed(Sh.wing)
  local wingP = W:poly(wingp, true)
  W:fill(wingP, pal.wing, 0.9)
  W:clip(wingP)
  for row = 1, 3 do
    local n = 5 - row
    for i = 1, n do
      local t = (i - 0.5) / n
      local u = 0.18 + (-0.30 - 0.18) * t - row * 0.10
      local v = 0.62 + (0.50 - 0.62) * t - row * 0.06 + 0.02
      stroke(W, Fb.pts({ {u + 0.05, v + 0.035}, {u, v - 0.01}, {u - 0.07, v - 0.03} }), s * 0.018, both, pal.edge, 0.55)
    end
  end
  for i = 1, 5 do
    local v0 = 0.50 - i * 0.025
    stroke(W, Fb.pts({ {-0.10, v0 + 0.02}, {-0.35, v0 - 0.02}, {-0.62, v0 - 0.05 + i * 0.008} }), s * 0.012, both, pal.edge, 0.6)
  end
  local tert = pal.tertial or pal.edge
  stroke(W, Fb.pts({ {0.20, 0.47}, {0.02, 0.39}, {-0.26, 0.40}, {-0.55, 0.45} }), s * 0.03, both, tert, 0.55)
  stroke(W, Fb.pts({ {0.10, 0.52}, {-0.10, 0.45}, {-0.36, 0.45} }), s * 0.016, both, tert, 0.45)
  if kind == "sparrow" then
    for _, v in ipairs({ 0.60, 0.50 }) do
      stroke(W, Fb.pts({ {0.18, v}, {0.0, v - 0.03}, {-0.18, v - 0.08} }), s * 0.03, both, C("gofun"), 0.7)
    end
  end
  W:unclip()
  W:stroke(wingP, pal.back2, s * 0.006, 0.35)
  -- 4. head: brow, eye (mejiro: the broad white eye ring)
  if pal.brow then
    stroke(W, Fb.pts({ {0.58, 0.705}, {0.50, 0.725}, {0.40, 0.725}, {0.30, 0.70} }), s * 0.032, both, pal.brow, kind == "robin" and 0.95 or 0.7)
  end
  local ex, ey = Fb.p(Sh.eye[1], Sh.eye[2])
  if kind == "mejiro" then W:fill(W:circle(ex, ey, s * 0.075), C("gofun"), 0.97) end
  W:fill(W:circle(ex, ey, s * 0.042), C("gofun"), 0.8)
  W:fill(W:circle(ex, ey, s * 0.030), C("sumi-noir"), 0.95)
  local hx, hy = Fb.p(Sh.eye[1] + 0.01, Sh.eye[2] + 0.012)
  W:fill(W:circle(hx, hy, s * 0.008), C("gofun"), 0.95)
  -- 5. beak
  local bk = Sh.beak
  local bp = Fb.pts({ bk[1], { (bk[1][1] + bk[2][1]) / 2, (bk[1][2] + bk[2][2]) / 2 + 0.008 }, bk[2],
                      { (bk[3][1] + bk[2][1]) / 2, (bk[3][2] + bk[2][2]) / 2 - 0.004 }, bk[3] })
  bb = union(bb, U.bbox_pts(bp, 0.3))
  W:fill(W:poly(bp, true), pal.beak, 0.92)
  -- 6. belly texture + soft outline
  W:clip(bodyP)
  for _ = 1, 9 do
    local u, v = R.range(-0.30, 0.35), R.range(0.18, 0.36)
    stroke(W, Fb.pts({ {u, v}, {u - 0.06, v - 0.012} }), s * 0.010, both, C("sumi-mid"), 0.18)
  end
  W:unclip()
  W:stroke(bodyP, C("sumi-dark"), s * 0.006, 0.22)
  -- 7. legs + toes in page space: feet exactly on the branch top
  local tx, ty = cos(angle), sin(angle)
  if (tx * face) < 0 then tx, ty = -tx, -ty end
  local nx, ny = -ty, tx
  if ny < 0 then nx, ny = -nx, -ny end
  local feet = {}
  for i, lg in ipairs(Sh.legs) do
    local hx2, hy2 = Fb.p(lg[1], lg[2] + 0.04)
    local d = (i == 1 and -1 or 1) * s * (0.015 + 0.03 * abs(cos(angle)))
    local fx, fy = spec.x + tx * d, spec.y + ty * d
    local topx, topy = fx + nx * bw * 0.5, fy + ny * bw * 0.5
    feet[i] = { topx, topy }
    local o = stroke(W, { { hx2, hy2 }, { (hx2 + topx) / 2, (hy2 + topy) / 2 }, { topx, topy } }, s * 0.03,
      function(u) return 1 - 0.45 * u end, pal.leg, 0.95)
    bb = union(bb, U.bbox_pts(o, 0.3))
    local function toe(dir, len, curl)
      local p0 = { topx, topy }
      local p1 = { topx + tx * dir * len * 0.6 + nx * bw * 0.05, topy + ty * dir * len * 0.6 + ny * bw * 0.05 }
      local p2 = { topx + tx * dir * len - nx * bw * curl, topy + ty * dir * len - ny * bw * curl }
      local to = stroke(W, { p0, p1, p2 }, s * 0.02, function(u) return 1 - 0.7 * u end, pal.leg, 0.95)
      bb = union(bb, U.bbox_pts(to, 0.3))
    end
    toe(1, s * 0.09, 0.55)
    toe(1, s * 0.07, 0.75)
    toe(-1, s * 0.06, 0.6)
  end
  return bb, { face = face, feet = feet }
end

--- Perched bird. spec.perch (from a flora motif's info.perch) or x, y, angle,
--- branch_w; spec.kind; spec.size (body length, default 44); spec.facing.
--- Returns bbox, {face, feet, kind} or nil when it does not fit.
function M.bird(ctx, spec)
  spec = spec or {}
  local p = spec.perch
  local sp = {}
  for k, v in pairs(spec) do sp[k] = v end
  if p then
    sp.x, sp.y = p.cx or p.x, p.cy or p.y
    sp.angle = p.angle or 0
    sp.branch_w = p.w or sp.branch_w
  end
  if not sp.x then return nil end
  sp.kind = sp.kind or "robin"
  ctx.pdf:layer(spec.layer or 50)
  local f0 = spec.facing or spec.face or auto_face(sp.angle or 0)
  for _, face in ipairs({ f0, -f0 }) do
    local bb, info = trial(ctx, function(tc) return draw_bird(tc, sp, face) end)
    if bb then
      local kind = sp.kind == "mejiro" and "mejiro-bird" or sp.kind
      U.rec(ctx, kind, bb)
      info.kind = kind
      return bb, info
    end
  end
  return nil
end

function M.robin(ctx, spec) local s = spec or {}; s.kind = "robin"; return M.bird(ctx, s) end
function M.uguisu(ctx, spec) local s = spec or {}; s.kind = "uguisu"; return M.bird(ctx, s) end
function M.sparrow(ctx, spec) local s = spec or {}; s.kind = "sparrow"; return M.bird(ctx, s) end
function M.mejiro(ctx, spec) local s = spec or {}; s.kind = "mejiro"; return M.bird(ctx, s) end

--- Pick perches for up to n birds of size s from a flora info.perch list:
--- well apart from each other. Returns a list of perches.
function M.pick_perches(perch, n, s)
  local out = {}
  for _, p in ipairs(perch or {}) do
    if #out >= n then break end
    local ok = true
    for _, q in ipairs(out) do
      if ((p.cx or p.x) - (q.cx or q.x)) ^ 2 + ((p.cy or p.y) - (q.cy or q.y)) ^ 2 < (s * 1.1) ^ 2 then ok = false; break end
    end
    if ok then out[#out + 1] = p end
  end
  return out
end

---------------------------------------------------------------- swallow
local function draw_swallow(ctx, spec)
  local W, R = ctx.pdf, ctx.rng
  local C = function(n) return ctx.palette.color(n) end
  local s = (spec.size or 60) / 2
  local face = spec.face or 1
  local Fb = frame(spec.x, spec.y, s, spec.angle or 0, face)
  local flap = spec.flap or R.range(0.3, 0.8)
  local body = { {0.42,0.02},{0.34,0.08},{0.10,0.09},{-0.22,0.06},{-0.40,0.03},{-0.40,-0.03},{-0.22,-0.07},{0.10,-0.09},{0.34,-0.07} }
  local up = 0.85 + 0.25 * flap
  local wingA = { {0.14,0.05},{0.14,0.30 * up},{0.02,0.62 * up},{-0.22,0.90 * up},{-0.58,1.06 * up},{-0.34,0.82 * up},{-0.20,0.56 * up},{-0.12,0.28 * up},{-0.12,0.05} }
  local dn = 0.75 - 0.25 * flap
  local wingB = { {0.14,-0.05},{0.14,-0.30 * dn},{0.02,-0.62 * dn},{-0.22,-0.90 * dn},{-0.58,-1.06 * dn},{-0.34,-0.82 * dn},{-0.20,-0.56 * dn},{-0.12,-0.28 * dn},{-0.12,-0.05} }
  local tail = { {-0.36,0.03},{-0.62,0.10},{-0.96,0.22},{-0.66,0.04},{-0.62,0.0},{-0.66,-0.04},{-0.98,-0.16},{-0.62,-0.08},{-0.36,-0.03} }
  local parts, bb = {}, nil
  for _, ctrl in ipairs({ body, wingA, wingB }) do
    local p = U.ccw(Fb.pts(cr(ctrl, 6, true)))
    bb = union(bb, U.bbox_pts(p, 0.5))
    parts[#parts + 1] = W:poly(p, true)
  end
  local tp = U.ccw(Fb.pts(tail))
  bb = union(bb, U.bbox_pts(tp, 0.5))
  parts[#parts + 1] = W:poly(tp, true)
  W:fill(W:join(parts), C("tsubame-navy"), 0.92)
  W:fill(W:poly(Fb.pts(cr({ {0.40,-0.01},{0.30,-0.06},{0.22,-0.04},{0.26,0.01},{0.34,0.03} }, 5, true)), true), C("shu"), 0.9)
  W:fill(W:poly(Fb.pts(cr({ {0.18,-0.06},{-0.05,-0.075},{-0.30,-0.045},{-0.05,-0.035} }, 5, true)), true), mix(C("gofun"), C("torinoko"), 0.5), 0.85)
  local ex, ey = Fb.p(0.33, 0.035)
  W:fill(W:circle(ex, ey, s * 0.018), C("gofun"), 0.6)
  return bb
end

--- Swallow in flight: navy crescent wings, forked tail, red throat.
--- spec: x, y (centre), size = wingspan, angle (flight direction), face, flap.
function M.swallow(ctx, spec)
  spec = spec or {}
  ctx.pdf:layer(spec.layer or 50)
  local bb = trial(ctx, function(tc) return draw_swallow(tc, spec) end)
  if bb then U.rec(ctx, "swallow", bb) end
  return bb, { kinds = { "swallow" } }
end
M.tsubame = M.swallow

return M
