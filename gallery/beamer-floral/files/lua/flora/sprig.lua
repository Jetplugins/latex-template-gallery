-- Line-work plants: stems, tendrils, umbels, forget-me-not cymes and
-- baby's-breath sprays. Strokes are collected into width buckets and painted
-- in a few batched scopes.

local G = require("flora.geom")
local F = require("flora.flower")
local Paint = require("flora.paint")
local Color = require("flora.color")
local Dist = require("flora.dist")
local Tune = require("flora.tune")
local pal = Paint.palette

local S = {}
local pi = math.pi

-- Collects stems and florets, then paints them in batches.
local Batch = {}
Batch.__index = Batch

function S.batch()
  return setmetatable({ ribbons = {}, lines = { {}, {}, {} }, florets = {}, buds = {}, stars = {}, growth = {}, tokens = {}, supports = {} }, Batch)
end

-- A tapered stem from w0 to w1 (full widths, pt), filled as a ribbon.
function Batch:stem(pts, w0, w1, support)
  self.ribbons[#self.ribbons + 1] = G.smooth(G.ribbon(pts, function(t)
    return (w0 + (w1 - w0) * t) / 2
  end), true)
  local path=self.ribbons[#self.ribbons]
  local token={pts=pts,growth_parent=support and support.parent,growth_t=support and support.t}
  self.growth[path],self.tokens[path]=pts,token
  return token
end

-- A stem whose full width at fraction t is w(t).
function Batch:stem_by(pts, w, token)
  self.ribbons[#self.ribbons + 1] = G.smooth(G.ribbon(pts, function(t) return w(t) / 2 end), true)
  local path=self.ribbons[#self.ribbons]
  token=token or {pts=pts}
  self.growth[path],self.tokens[path]=pts,token
  return token
end

-- A hairline; `class` 1-3 selects 0.32, 0.22 or 0.14 pt.
function Batch:line(pts, class, support)
  local bucket = self.lines[class or 2]
  bucket[#bucket + 1] = G.smooth(pts, false)
  local path=bucket[#bucket]
  local token={pts=pts,growth_parent=support and support.parent,growth_t=support and support.t}
  self.growth[path],self.tokens[path]=pts,token
  return token
end

-- A five-petalled floret; `soft` paints it as baby's breath (F.florets).
function Batch:floret(x, y, r, rot, tint, soft, support)
  self.florets[#self.florets + 1] = { x, y, r, rot, tint, soft }
  self.supports[self.florets[#self.florets]]=support
end

function Batch:bud(x, y, ang, len, support)
  self.buds[#self.buds + 1] = { x, y, ang, len }
  self.supports[self.buds[#self.buds]]=support
end

-- Four-point sparkle used as a floret substitute in the sprays.
function Batch:star(x, y, r, support)
  self.stars[#self.stars + 1] = { x, y, r }
  self.supports[self.stars[#self.stars]]=support
end

-- Call fn(x, y, r) for every vertex (r = 0) and every floret, bud and star
-- (r = its radius or length), so callers can validate a spray's extent.
function Batch:each_point(fn)
  local function cmds(list)
    for _, c in ipairs(list) do
      for _, op in ipairs(c) do
        if op[1] == "m" or op[1] == "l" then fn(op[2], op[3], 0)
        elseif op[1] == "c" then fn(op[6], op[7], 0) end
      end
    end
  end
  cmds(self.ribbons)
  for i = 1, 3 do cmds(self.lines[i]) end
  for _, f in ipairs(self.florets) do fn(f[1], f[2], f[3]) end
  for _, b in ipairs(self.buds) do fn(b[1], b[2], b[4]) end
  for _, s in ipairs(self.stars) do fn(s[1], s[2], s[3]) end
end

-- Append everything collected in `other`.
function Batch:merge(other)
  local function append(dst, src)
    for _, v in ipairs(src) do dst[#dst + 1] = v end
  end
  for _,name in ipairs({"growth","tokens","supports"}) do
    for k,v in pairs(other[name]) do self[name][k]=v end
  end
  append(self.ribbons, other.ribbons)
  for i = 1, 3 do append(self.lines[i], other.lines[i]) end
  append(self.florets, other.florets)
  append(self.buds, other.buds)
  append(self.stars, other.stars)
end

-- Only the items already born on a growth clock (clock.lua), when one is
-- set on the painter: each pops in when the front reaches its first point.
function Batch:born(clock)
  local b = S.batch()
  local function first(c)
    local op = c[1]
    return op and clock:born(op[2], op[3])
  end
  for _, c in ipairs(self.ribbons) do if first(c) then b.ribbons[#b.ribbons + 1] = c end end
  for i = 1, 3 do
    for _, c in ipairs(self.lines[i]) do if first(c) then b.lines[i][#b.lines[i] + 1] = c end end
  end
  for _, name in ipairs({ "florets", "buds", "stars" }) do
    for _, it in ipairs(self[name]) do
      if clock:born(it[1], it[2]) then b[name][#b[name] + 1] = it end
    end
  end
  return b
end

function Batch:paint(pt, ink)
  local rec, clock = pt.progression, pt.growth_clock
  if rec and clock and not rec.active and not rec.suspended then
    local Progression = require("flora.progression")
    rec:alternate(pt, function()
      local function part(b, at, stem, kind, token, support)
        support=support or (token and {parent=token.growth_parent,t=token.growth_t}) or {}
        if support.parent then at=G.at(support.parent.pts,support.t or 1) end
        local birth = clock:birth(at[1], at[2]) / clock.reach * 0.7
        local duration = stem and math.max(0.01, G.length(stem) / clock.reach * 0.7) or 0.05
        Progression.part(pt, kind, at, birth, duration, function() b:paint(pt, ink) end, stem,
          {token=token,parent=support.parent,t=support.t})
      end
      for _,c in ipairs(self.ribbons) do
        local b=S.batch(); b.ribbons={c}; local pts=self.growth[c]
        part(b, pts[1], pts, "stem", self.tokens[c])
      end
      for i=1,3 do for _,c in ipairs(self.lines[i]) do
        local b=S.batch(); b.lines[i]={c}; local pts=self.growth[c]
        part(b, pts[1], pts, "spray-stem", self.tokens[c])
      end end
      for _,name in ipairs({"buds", "florets", "stars"}) do for _,it in ipairs(self[name]) do
        local b=S.batch(); b[name]={it}; part(b, it, nil, name, nil, self.supports[it])
      end end
    end, function() self:paint(pt, ink) end)
    return
  end
  if pt.clock then
    local clock = pt.clock
    pt.clock = nil
    self:born(clock):paint(pt, ink)
    pt.clock = clock
    return
  end
  -- palette.sprays recolours the sprays' line work, buds and stars.
  local tint = Color.part_ink("sprays")
  ink = Color.recolor(ink or pal.ink, tint)
  if #self.ribbons > 0 then
    pt:fill(self.ribbons, ink, 0.92, { many = true, blend = "multiply" })
  end
  local widths = { 0.32, 0.22, 0.14 }
  for i = 1, 3 do
    if #self.lines[i] > 0 then
      pt:stroke(self.lines[i], ink, widths[i], 0.85, { many = true, blend = "multiply" })
    end
  end
  for _, b in ipairs(self.buds) do F.bud(pt, b[1], b[2], b[3], b[4], tint and Color.recolor(pal.deep, tint)) end
  if #self.florets > 0 then F.florets(pt, self.florets) end
  if #self.stars > 0 then
    local paths = {}
    for _, s in ipairs(self.stars) do
      local x, y, r = s[1], s[2], s[3]
      local k = r * 0.22
      paths[#paths + 1] = {
        { "m", x, y + r }, { "l", x + k, y + k }, { "l", x + r, y }, { "l", x + k, y - k },
        { "l", x, y - r }, { "l", x - k, y - k }, { "l", x - r, y }, { "l", x - k, y + k }, { "z" },
      }
    end
    pt:fill(paths, Color.recolor(pal.deep, tint), 0.85, { many = true, blend = "multiply" })
  end
end

-- A tendril: a gentle arc whose curvature rises as t^2.5, so it winds into
-- a volute of about 1.3 turns without a seam. Returns its points.
-- The innermost turn is held to a 4 pt radius so the eye of the volute
-- stays open and round, as the reference's curls are (about 9 pt radius
-- at the 90th percentile of curvature).
function S.tendril(p, ang, len, dir)
  local c = G.curl_coefficient(len, 1.05, 2.5)
  return (G.flow(p, ang, len, function(t)
    return dir * math.min(0.25 / len + c * t ^ 2.5, 1 / 4)
  end))
end

-- A flourish: the stem swings through one open loop, straightens, then
-- curls the other way into a volute, the cursive figure the margin ornament
-- is built from. Returns its points.
function S.flourish(p, ang, len, dir)
  local split = 0.55
  local loop = 2 * pi * 1.05 * 2 / (split * len)  -- sin^2 averages 1/2
  local curl = G.curl_coefficient((1 - split) * len, 1.2, 2.5)
  return (G.flow(p, ang, len, function(t)
    if t < split then
      return dir * loop * math.sin(pi * t / split) ^ 2
    end
    return -dir * math.min(curl * ((t - split) / (1 - split)) ^ 2.5, 1 / 4)
  end))
end

-- Queen Anne's lace: rays from one point forming a dome of umbellets.
function S.umbel(b, rng, base, ang, R, support)
  local m = rng:int(13, 19)
  local spread = rng:range(2.0, 2.6)
  for j = 1, m do
    local u = (j - 0.5) / m
    local a = ang - spread / 2 + spread * u + rng:jit(0.05)
    local len = R * (0.72 + 0.28 * math.cos((u - 0.5) * pi)) * rng:range(0.9, 1.05)
    local ray = G.curve(base, a, len, (u - 0.5) * 0.35, 0, 6)
    local ray_token=b:line(ray, 3, support)
    local tip = ray[#ray]
    local k = rng:int(4, 7)
    for i = 1, k do
      local a2 = a - 1.1 + 2.2 * (i - 0.5) / k + rng:jit(0.08)
      local sub = G.curve(tip, a2, R * rng:range(0.13, 0.22), rng:jit(0.3), 0, 3)
      local sub_token=b:line(sub, 3, {parent=ray_token,t=1})
      local e = sub[#sub]
      b:floret(e[1], e[2], R * rng:range(0.020, 0.030), rng:range(0, 2 * pi), rng:chance(0.6) and 2 or 3, nil, {parent=sub_token,t=1})
    end
  end
end

-- A scorpioid cyme (forget-me-not): an axis that coils at its tip, with
-- florets shrinking toward the coil and buds inside it.
function S.cyme(b, rng, base, ang, len, dir, support)
  local axis = S.tendril(base, ang, len, dir)
  local axis_token=b:line(axis, 2, support)
  local n = #axis
  local count = rng:int(7, 11)
  for i = 1, count do
    local t = (i - 0.5) / count
    local idx = math.max(2, math.floor(t * (n - 1)) + 1)
    local p, q = axis[idx - 1], axis[idx]
    local a = G.angle(p, q) + ((i % 2 == 0) and 1 or -1) * rng:range(0.6, 1.1)
    local size = len * 0.075 * (1.15 - 0.8 * t)
    local ped = G.curve(q, a, size * 1.4, rng:jit(0.4), 0, 3)
    local ped_token=b:line(ped, 3, {parent=axis_token,t=G.fraction(axis,idx)})
    local e = ped[#ped]
    if t < 0.72 then
      b:floret(e[1], e[2], size, rng:range(0, 2 * pi), rng:chance(0.35) and 3 or 2, nil, {parent=ped_token,t=1})
    else
      b:bud(e[1], e[2], a, size * 1.5, {parent=ped_token,t=1})
    end
  end
  return axis
end

-- Baby's breath: a recursive dichasium that ends in clouds of tiny florets.
-- Forks get wider and stalks shorter toward the tips, so the spray opens
-- into a dome; one or two florets per tip keep the cloud open.
function S.gypsophila(b, rng, base, ang, len, depth, support)
  local function branch(p, a, l, d, parent)
    local pts = G.curve(p, a, l, rng:jit(0.3), 0, 4)
    local token=b:line(pts, d >= depth - 1 and 2 or 3, parent)
    local e = pts[#pts]
    local ea = G.angle(pts[#pts - 1], e)
    if d == 0 then
      -- Mostly one soft floret per tip, mid-blue to pale, so the cloud
      -- stays open; an occasional tiny star.
      local n = rng:chance(0.7) and 1 or 2
      for k = 1, n do
        local q = k == 1 and e or G.polar(e, ea + rng:jit(1.6), rng:range(2.8, 3.8))
        if rng:chance(0.08) then
          b:star(q[1], q[2], rng:range(0.7, 1.1), {parent=token,t=1})
        else
          b:floret(q[1], q[2], rng:range(0.9, 1.5), rng:range(0, 2 * pi),
            rng:weighted({ [1] = 0.4, [2] = 3, [3] = 5 }), true, {parent=token,t=1})
        end
      end
      return
    end
    local spread = 0.25 + 0.45 * (1 - d / depth)
    local kids = rng:chance(0.4) and 3 or 2
    for k = 1, kids do
      local off = (kids == 2) and ((k == 1) and -1 or 1) * spread * rng:range(0.7, 1.2)
        or (k - 2) * spread * rng:range(0.8, 1.2)
      branch(e, ea + off, l * rng:range(0.55, 0.72), d - 1, {parent=token,t=1})
    end
    if d <= 2 and rng:chance(0.5) then
      local q = G.polar(G.mix(p, e, 0.6), ea + rng:jit(1.2), rng:range(1.5, 2.5))
      b:floret(q[1], q[2], rng:range(0.5, 0.8), 0, 3, true, {parent=token,t=0.6})
    end
  end
  branch(base, ang, len, depth, support)
end

-- Paired leaflets along a stem, as items for leaf.leaflets, sized from
-- tune.sizes.leaflet around `len`.
-- `every` is the gap between leaflets in pt, or a {min, max} range picked
-- per gap.
function S.leaflet_items(rng, pts, every, len)
  local items = {}
  local L = G.length(pts)
  local lo, hi = every, every
  if type(every) == "table" then lo, hi = every[1], every[2] end
  local d = 0
  local i = 0
  while true do
    d = d + rng:range(lo, hi)
    if d > L - lo * 0.3 then break end
    i = i + 1
    local t=(d + rng:jit(0.2) * lo) / L
    local p, a = G.at(pts, t)
    local side = (i % 2 == 0) and 1 or -1
    items[#items + 1] = { p[1], p[2], a + side * rng:range(0.5, 0.9), len * Dist.sample(rng, Tune.sizes.leaflet), stem_t=t }
  end
  return items
end

return S
