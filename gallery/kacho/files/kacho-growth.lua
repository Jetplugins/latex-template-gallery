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
-- kacho-growth.lua: tree growth engine of the kacho package (M2).
--
-- ALGORITHMS & REFERENCES:
--   * G.grow, G.attractors: space colonization -- adapted from Runions, Lane &
--     Prusinkiewicz 2007, "Modeling Trees with a Space Colonization Algorithm",
--     Eurographics Workshop on Natural Phenomena (attractors, influence and kill
--     radii, mean-direction growth). Grid hash for nearest-node queries: own.
--   * G.finish (pipe-model widths): adapted from Shinozaki, Yoda, Hozumi & Kira
--     1964, "A quantitative analysis of plant form -- the pipe model theory",
--     Japanese Journal of Ecology 14; da Vinci's rule of branch cross-sections
--     (exponent ~2-2.5, cf. Eloy 2011, Physical Review Letters 107).
--   * G.grow / G.finish (orders, branching angles, apical dominance, sympodial
--     elbows, tropism): inspired by Prusinkiewicz & Lindenmayer 1990, "The
--     Algorithmic Beauty of Plants", Springer (ch. 2-3: branching structures,
--     tropisms); organic stem/branch curvature inspired by florilegium-grow.lua
--     (Kevin Raymond 2026, MIT License).
--   * growth limiting around page content: inspired by Wong, Zongker & Salesin
--     1998, "Computer-Generated Floral Ornament", SIGGRAPH '98.
--
-- Grows a branching skeleton by SPACE COLONIZATION (Runions, Lane &
-- Prusinkiewicz, "Modeling Trees with a Space Colonization Algorithm",
-- Eurographics Workshop on Natural Phenomena 2007): attractor points are
-- scattered inside an envelope (clipped to ctx.region and kept clear of
-- ctx.exclude, so the crown grows around the text instead of being clipped);
-- every iteration each attractor pulls its nearest node within the influence
-- radius, nodes grow one step toward the mean pull (plus tropism and
-- inertia), and attractors reached within the kill radius are removed.
--
-- Botanical rules layered on top (cf. Prusinkiewicz & Lindenmayer, "The
-- Algorithmic Beauty of Plants", 1990; Wong, Zongker & Salesin, "Computer-
-- Generated Floral Ornament", SIGGRAPH 1998, for growth-limited ornament):
--   * hierarchy: the leader continues a branch; a second shoot at a node starts
--     a lateral of the next order (max_order 3..5); branching angles are
--     clamped to 25..60 degrees and the leader kinks slightly away at a fork;
--   * apical dominance: laterals are capped in length (shorter toward the tip
--     of their parent), some laterals end as short spurs or broken stubs;
--   * tropism: phototropism (curving up) or gravity droop (weeping), applied
--     every step so curvature is integrated smoothly; sympodial species (ume)
--     instead zig-zag with sharp elbows;
--   * pipe model (da Vinci rule): at every fork w_parent^p = sum w_child^p
--     (p ~ 2.4), and along a branch the width grows monotonically toward the
--     base, so trunk -> limbs -> twigs taper continuously and no thin twig
--     springs from a thick trunk.
--
-- API
--   local G = require("kacho-growth")
--   local skel = G.grow(ctx, {
--       origins    = {{x=, y=, angle=}},       -- trunk start(s)
--       attractors = {{x,y},...} | nil,        -- default: sampled in an envelope
--       envelope   = {cx=,cy=,rx=,ry=,rot=} | nil,  -- default from origin/angle/size
--       size = 300, density = 0.5, species = G.SPECIES.ume | {...} })
--   skel.nodes    : {x, y, w, order, parent=node|nil, children={...}}
--   skel.branches : {{nodes={...}, order, parent=branch|nil, attach=node}} where
--                   branch.nodes[1] IS the fork node on the parent (exact start)
--   G.to_branches(skel) -> list in kacho-flora's format {nodes={{x,y,w,s,a}},
--                   depth, parent, attach_s, L}
--   G.check(skel) -> report of the invariants (pipe ratio, attachment, taper)
-- Pure Lua (no TeX); randomness only from ctx.rng.
local G = {}

local sin, cos, pi, abs, max, min, sqrt, floor = math.sin, math.cos, math.pi, math.abs, math.max, math.min, math.sqrt, math.floor
local function atan2(y, x) return math.atan(y, x) end

---------------------------------------------------------------- species presets
-- step/influence/kill are fractions of size; photo > 0 bends up, droop > 0 down;
-- sympodial = zig-zag elbow amplitude (rad) per step; smooth = smoothing passes
G.SPECIES = {
  ume = { step = 0.03, influence = 0.17, kill = 0.045, attractors = 420, inertia = 0.7, photo = 0.1, droop = 0,
    sympodial = 0.5, elbow_every = 3, smooth = 0, max_order = 4, angle_min = 25, angle_max = 60, kink = 0.18, w0 = 0.055,
    wtip = 0.55, pipe = 2.4, taper = 1.3, lateral_cap = 0.62, stub_p = 0.06, envelope = { 0.55, 0.62, 0.42 } },
  sakura = { step = 0.03, influence = 0.24, kill = 0.05, attractors = 340, inertia = 0.55, photo = 0.02, droop = 0.18,
    sympodial = 0, smooth = 3, max_order = 4, angle_min = 25, angle_max = 55, kink = 0.12, w0 = 0.05,
    wtip = 0.6, pipe = 2.4, taper = 1.2, lateral_cap = 0.7, stub_p = 0.03, envelope = { 0.55, 0.62, 0.48 } },
  maple = { step = 0.03, influence = 0.2, kill = 0.05, attractors = 300, inertia = 0.55, photo = 0.08, droop = 0.04,
    sympodial = 0.08, smooth = 2, max_order = 3, angle_min = 30, angle_max = 60, kink = 0.12, w0 = 0.032,
    wtip = 0.5, pipe = 2.3, taper = 1.0, lateral_cap = 0.7, stub_p = 0.02, envelope = { 0.55, 0.6, 0.45 } },
  osmanthus = { step = 0.028, influence = 0.18, kill = 0.045, attractors = 300, inertia = 0.6, photo = 0.15, droop = 0,
    sympodial = 0, smooth = 2, max_order = 3, angle_min = 25, angle_max = 45, kink = 0.1, w0 = 0.03,
    wtip = 0.6, pipe = 2.4, taper = 0.9, lateral_cap = 0.75, stub_p = 0, envelope = { 0.42, 0.55, 0.5 } },
  camellia = { step = 0.035, influence = 0.22, kill = 0.07, attractors = 120, inertia = 0.55, photo = 0.08, droop = 0,
    sympodial = 0.12, smooth = 1, max_order = 3, angle_min = 30, angle_max = 60, kink = 0.15, w0 = 0.04,
    wtip = 0.9, pipe = 2.3, taper = 1.0, lateral_cap = 0.65, stub_p = 0.03, envelope = { 0.5, 0.55, 0.45 } },
  pine = { step = 0.035, influence = 0.25, kill = 0.06, attractors = 200, inertia = 0.6, photo = 0.0, droop = 0.05,
    sympodial = 0.15, smooth = 1, max_order = 3, angle_min = 45, angle_max = 80, kink = 0.15, w0 = 0.06,
    wtip = 0.9, pipe = 2.3, taper = 1.4, lateral_cap = 0.8, stub_p = 0.05, envelope = { 0.55, 0.6, 0.5 }, tiers = true },
}

---------------------------------------------------------------- helpers
local function norm(x, y)
  local l = sqrt(x * x + y * y)
  if l < 1e-12 then return 0, 0, 0 end
  return x / l, y / l, l
end
local function angdiff(a, b)
  local d = (a - b) % (2 * pi)
  if d > pi then d = d - 2 * pi end
  return d
end

local function free(ctx, x, y, r)
  if ctx.__free then return ctx.__free(ctx, x, y, r) end
  local R = ctx.region
  r = r + 1
  if x - r < R.x0 or x + r > R.x1 or y - r < R.y0 or y + r > R.y1 then return false end
  for _, e in ipairs(ctx.exclude or {}) do
    if x + r > e.x0 and x - r < e.x1 and y + r > e.y0 and y - r < e.y1 then return false end
  end
  return true
end
local function clear(ctx, x, y, r)
  for _, e in ipairs(ctx.exclude or {}) do
    if x + r > e.x0 and x - r < e.x1 and y + r > e.y0 and y - r < e.y1 then return false end
  end
  return true
end

-- uniform grid hash for nearest-node queries
local function grid(cell)
  local g = { cell = cell, cells = {} }
  local function key(ix, iy) return ix * 100003 + iy end
  function g.add(n)
    local ix, iy = floor(n.x / cell), floor(n.y / cell)
    local k = key(ix, iy)
    local c = g.cells[k]
    if not c then c = {}; g.cells[k] = c end
    c[#c + 1] = n
  end
  -- nearest node within radius r (deterministic: ties broken by node id)
  function g.nearest(x, y, r)
    local best, bd = nil, r * r
    local ix, iy = floor(x / cell), floor(y / cell)
    local span = math.ceil(r / cell)
    for dx = -span, span do
      for dy = -span, span do
        local c = g.cells[key(ix + dx, iy + dy)]
        if c then
          for _, n in ipairs(c) do
            local d = (n.x - x) ^ 2 + (n.y - y) ^ 2
            if d < bd or (d == bd and best and n.id < best.id) then best, bd = n, d end
          end
        end
      end
    end
    return best, sqrt(bd)
  end
  function g.any_within(x, y, r)
    local ix, iy = floor(x / cell), floor(y / cell)
    local span = math.ceil(r / cell)
    local r2 = r * r
    for dx = -span, span do
      for dy = -span, span do
        local c = g.cells[key(ix + dx, iy + dy)]
        if c then for _, n in ipairs(c) do if (n.x - x) ^ 2 + (n.y - y) ^ 2 < r2 then return true end end end
      end
    end
    return false
  end
  return g
end

--- Attractors scattered in an ellipse envelope, kept only where free.
function G.attractors(ctx, rng, env, n, margin)
  local out = {}
  local cr, sr = cos(env.rot or 0), sin(env.rot or 0)
  local tries = 0
  while #out < n and tries < n * 12 do
    tries = tries + 1
    local a = rng.range(0, 2 * pi)
    local rr = sqrt(rng.u())
    local u, v = cos(a) * rr * env.rx, sin(a) * rr * env.ry
    local x, y = env.cx + u * cr - v * sr, env.cy + u * sr + v * cr
    if free(ctx, x, y, margin or 4) then out[#out + 1] = { x, y } end
  end
  return out
end

---------------------------------------------------------------- growth
function G.grow(ctx, opts)
  opts = opts or {}
  local rng = opts.rng or ctx.rng
  local P = opts.species or G.SPECIES.ume
  if type(P) == "string" then P = G.SPECIES[P] end
  local size = opts.size or 300
  local density = opts.density or ctx.density or 0.5
  local D = P.step * size
  local di, dk = P.influence * size, P.kill * size
  local origins = opts.origins or { { x = 0, y = 0, angle = pi / 2 } }
  local o1 = origins[1]
  local a0 = o1.angle or pi / 2
  local env = opts.envelope
  if not env then
    local e = P.envelope
    env = { cx = o1.x + cos(a0) * e[2] * size, cy = o1.y + sin(a0) * e[2] * size, rx = e[1] * size, ry = e[3] * size, rot = a0 }
  end
  local attr = opts.attractors or G.attractors(ctx, rng, env, floor(P.attractors * (0.6 + 0.8 * density)), opts.margin or 6)
  local nodes, g = {}, grid(max(di / 2, 4))
  local nid = 0
  local function add(x, y, parent, order, dir)
    nid = nid + 1
    local n = { id = nid, x = x, y = y, parent = parent, children = {}, order = order, dir = dir, len = parent and (parent.len + D) or 0 }
    nodes[#nodes + 1] = n
    if parent then parent.children[#parent.children + 1] = n end
    g.add(n)
    return n
  end
  -- 1. roots: grow straight (with tropism) until an attractor is in range
  local roots = {}
  for _, o in ipairs(origins) do
    local entering = not free(ctx, o.x, o.y, 0)
    local n = add(o.x, o.y, nil, 0, o.angle or pi / 2)
    n.entering = entering
    roots[#roots + 1] = n
    local guard = 0
    while guard < 400 do
      guard = guard + 1
      local near = false
      for _, a in ipairs(attr) do if (a[1] - n.x) ^ 2 + (a[2] - n.y) ^ 2 < di * di then near = true; break end end
      if near and not n.entering then break end
      local dx, dy = cos(n.dir), sin(n.dir)
      local x, y = n.x + dx * D, n.y + dy * D
      if not (n.entering and clear(ctx, x, y, 2) or free(ctx, x, y, 4)) then break end
      local m = add(x, y, n, 0, n.dir)
      m.entering = n.entering and not free(ctx, x, y, 2)
      n = m
      if #nodes > 2000 then break end
    end
  end
  -- 2. space colonization iterations
  local alive = {}
  for i, a in ipairs(attr) do alive[i] = true end
  local maxn = opts.max_nodes or floor(900 + 600 * density)
  local zig = {}
  for iter = 1, (opts.iterations or 220) do
    local pull = {}
    local any = false
    for i, a in ipairs(attr) do
      if alive[i] then
        local n = g.nearest(a[1], a[2], di)
        if n then
          local dx, dy = norm(a[1] - n.x, a[2] - n.y)
          local p = pull[n]
          if not p then p = { 0, 0, 0 }; pull[n] = p end
          p[1], p[2], p[3] = p[1] + dx, p[2] + dy, p[3] + 1
          any = true
        end
      end
    end
    if not any then break end
    -- deterministic order: by node id
    local grow_list = {}
    for n, p in pairs(pull) do grow_list[#grow_list + 1] = { n, p } end
    table.sort(grow_list, function(a, b) return a[1].id < b[1].id end)
    local added = 0
    for _, np in ipairs(grow_list) do
      local n, p = np[1], np[2]
      local dx, dy = norm(p[1], p[2])
      -- inertia (follow the parent direction) and tropism
      local ix, iy = cos(n.dir), sin(n.dir)
      dx, dy = dx * (1 - P.inertia) + ix * P.inertia, dy * (1 - P.inertia) + iy * P.inertia
      local ord = n.order
      dy = dy + (P.photo or 0) * (1 + 0.3 * ord) - (P.droop or 0) * (0.4 + 0.4 * ord)
      dx, dy = norm(dx, dy)
      local na = atan2(dy, dx)
      local lateral = #n.children > 0
      local order = ord
      local ok = true
      if lateral then
        -- a second shoot: lateral of the next order, angle clamped to 25..60 deg
        order = ord + 1
        if order > P.max_order or #n.children >= 2 then ok = false end
        if ok then
          local lead = n.children[1]
          local ld = atan2(lead.y - n.y, lead.x - n.x)
          local dev = angdiff(na, ld)
          local side = dev >= 0 and 1 or -1
          local amin, amax = math.rad(P.angle_min), math.rad(P.angle_max)
          local adev = max(amin, min(amax, abs(dev)))
          na = ld + side * adev
          -- apical dominance: no laterals right at the very tip of the leader,
          -- and a lateral never exceeds a share of its parent's remaining room
          n.lat_side = side
        end
      elseif P.sympodial and P.sympodial > 0 and ((n.seg or 0) % (P.elbow_every or 3) == 0) then
        -- sympodial zig-zag: an elbow every few steps, alternating sides, with
        -- straight runs in between (ume)
        local s = zig[n] or ((n.parent and zig[n.parent]) and -zig[n.parent] or (rng.chance(0.5) and 1 or -1))
        zig[n] = s
        na = na + s * P.sympodial * rng.range(0.7, 1.3)
      end
      if ok then
        local x, y = n.x + cos(na) * D, n.y + sin(na) * D
        local r_clear = (order <= 1) and max(4.5, P.w0 * size * 0.52 + 1.2) or 3.2
        if free(ctx, x, y, r_clear) and not g.any_within(x, y, D * 0.45) then
          local m = add(x, y, n, order, na)
          m.seg = lateral and 1 or ((n.seg or 0) + 1)
          if lateral then m.lateral = true end
          if P.sympodial and P.sympodial > 0 and not lateral then
            if (n.seg or 0) % (P.elbow_every or 3) == 0 then zig[m] = -(zig[n] or 1) else zig[m] = zig[n] end
          end
          added = added + 1
        end
      end
      if #nodes >= maxn then break end
    end
    -- kill reached attractors
    for i, a in ipairs(attr) do
      if alive[i] and g.any_within(a[1], a[2], dk) then alive[i] = false end
    end
    if added == 0 or #nodes >= maxn then break end
  end
  local skel = { nodes = nodes, roots = roots, step = D, size = size, species = P }
  G.finish(skel, rng, P, size)
  return skel
end

---------------------------------------------------------------- post-processing
-- branches, leaders, kinks, smoothing, stubs, pipe-model widths
function G.finish(skel, rng, P, size)
  local nodes = skel.nodes
  -- subtree tip counts (for leader choice)
  for i = #nodes, 1, -1 do
    local n = nodes[i]
    local t = 0
    for _, c in ipairs(n.children) do t = t + c.tips end
    n.tips = max(1, t)
    if #n.children == 0 then n.tips = 1 end
  end
  -- leader = child with the most tips (ties: straighter continuation)
  for _, n in ipairs(nodes) do
    if #n.children > 1 then
      table.sort(n.children, function(a, b)
        if a.tips ~= b.tips then return a.tips > b.tips end
        local da = abs(angdiff(atan2(a.y - n.y, a.x - n.x), n.dir))
        local db = abs(angdiff(atan2(b.y - n.y, b.x - n.x), n.dir))
        if da ~= db then return da < db end
        return a.id < b.id
      end)
    end
  end
  -- orders follow the hierarchy: leader keeps order, others +1
  for _, n in ipairs(nodes) do
    for k, c in ipairs(n.children) do c.order = (k == 1) and n.order or n.order + 1 end
  end
  -- parent kinks slightly away from a lateral at each fork
  if (P.kink or 0) > 0 then
    for _, n in ipairs(nodes) do
      if #n.children > 1 then
        local lead, lat = n.children[1], n.children[2]
        local la = atan2(lat.y - n.y, lat.x - n.x)
        local ld = atan2(lead.y - n.y, lead.x - n.x)
        local side = angdiff(la, ld) >= 0 and 1 or -1
        local a = ld - side * P.kink
        local d = sqrt((lead.x - n.x) ^ 2 + (lead.y - n.y) ^ 2)
        lead.x, lead.y = n.x + cos(a) * d, n.y + sin(a) * d
      end
    end
  end
  -- smoothing of interior nodes (forks keep their place, so children stay attached)
  for _ = 1, (P.smooth or 0) do
    local nx, ny = {}, {}
    for i, n in ipairs(nodes) do
      if n.parent and #n.children == 1 then
        local c = n.children[1]
        nx[i] = (n.parent.x + 2 * n.x + c.x) / 4
        ny[i] = (n.parent.y + 2 * n.y + c.y) / 4
      end
    end
    for i, n in ipairs(nodes) do if nx[i] then n.x, n.y = nx[i], ny[i] end end
  end
  -- decompose into branches (each branch: fork node + its chain)
  local branches = {}
  local function walk(start_node, first, order, parent_branch)
    local br = { nodes = { start_node }, order = order, parent = parent_branch, attach = start_node }
    branches[#branches + 1] = br
    local n = first
    while n do
      br.nodes[#br.nodes + 1] = n
      for k = 2, #n.children do walk(n, n.children[k], order + 1, br) end
      n = n.children[1]
    end
    return br
  end
  for _, r in ipairs(skel.roots) do
    local br = { nodes = { r }, order = 0, attach = nil }
    branches[#branches + 1] = br
    local n = r
    while true do
      for k = 2, #n.children do walk(n, n.children[k], 1, br) end
      local nxt = n.children[1]
      if not nxt then break end
      br.nodes[#br.nodes + 1] = nxt
      n = nxt
    end
  end
  -- apical dominance: cap lateral length relative to the parent's remaining length;
  -- a few laterals become broken stubs
  local function chain_len(list, i0)
    local L = 0
    for i = (i0 or 1) + 1, #list do L = L + sqrt((list[i].x - list[i - 1].x) ^ 2 + (list[i].y - list[i - 1].y) ^ 2) end
    return L
  end
  local removed = {}
  local function cut_after(br, keep)
    for i = keep + 1, #br.nodes do removed[br.nodes[i]] = true end
    for i = #br.nodes, keep + 1, -1 do br.nodes[i] = nil end
  end
  for _, br in ipairs(branches) do
    if br.parent and not removed[br.attach] then
      local pn = br.parent.nodes
      local idx
      for i, n in ipairs(pn) do if n == br.attach then idx = i; break end end
      local rem = idx and chain_len(pn, idx) or 0
      local cap = max(skel.step * 3, rem * P.lateral_cap + skel.step * 4)
      local L, keep = 0, #br.nodes
      for i = 2, #br.nodes do
        L = L + sqrt((br.nodes[i].x - br.nodes[i - 1].x) ^ 2 + (br.nodes[i].y - br.nodes[i - 1].y) ^ 2)
        if L > cap then keep = i - 1; break end
      end
      if br.order >= 2 and rng.chance(P.stub_p or 0) and #br.nodes > 4 then keep = min(keep, 3); br.stub = true end
      if keep < #br.nodes then cut_after(br, max(2, keep)) end
    end
  end
  -- drop branches whose attach node was removed, and fix child lists
  local live = {}
  for _, br in ipairs(branches) do
    if not (br.attach and removed[br.attach]) and #br.nodes >= 2 then live[#live + 1] = br
    elseif not br.attach and #br.nodes >= 1 then live[#live + 1] = br end
  end
  branches = live
  local kept = {}
  for _, n in ipairs(nodes) do
    if not removed[n] then
      local ch = {}
      for _, c in ipairs(n.children) do if not removed[c] then ch[#ch + 1] = c end end
      n.children = ch
      kept[#kept + 1] = n
    end
  end
  nodes = kept
  skel.nodes = nodes
  -- also drop branches whose first real node got removed (attach kept but chain gone)
  live = {}
  for _, br in ipairs(branches) do
    local ok = true
    for i = 2, #br.nodes do if removed[br.nodes[i]] then ok = false end end
    if ok and (#br.nodes >= 2 or not br.attach) then live[#live + 1] = br end
  end
  branches = live
  skel.branches = branches
  -- pipe model widths, bottom-up: tips wtip; along a chain the width grows with
  -- length; at forks w^p = sum of the children's w^p
  local p = P.pipe or 2.4
  local kt = (P.taper or 1.2) / size
  local byid = {}
  for _, n in ipairs(nodes) do byid[#byid + 1] = n end
  table.sort(byid, function(a, b) return a.id > b.id end)   -- children before parents
  for _, n in ipairs(byid) do
    if #n.children == 0 then n.wr = 1
    else
      local s = 0
      for _, c in ipairs(n.children) do
        local seg = sqrt((c.x - n.x) ^ 2 + (c.y - n.y) ^ 2)
        local wc = c.wr * (1 + kt * seg)        -- grow along the segment toward the base
        s = s + wc ^ p
        c.wseg = wc                              -- width of the segment end at n
      end
      n.wr = s ^ (1 / p)
    end
  end
  -- scale: trunk base width ~ w0*size, tips never thinner than wmin
  local wmin = P.wtip * math.max(0.7, math.min(1.6, size / 220))
  local base = 0
  for _, r in ipairs(skel.roots) do base = max(base, r.wr) end
  local f = (P.w0 * size) / max(1e-6, base)
  if f < wmin then f = wmin end
  for _, n in ipairs(nodes) do n.w = n.wr * f end
  skel.scale, skel.pipe = f, p
  return skel
end

--- Branch list in kacho-flora's format. Width at node i of a branch: at the
--- branch start (the fork node) the child's own segment width is used, so a
--- lateral starts at its pipe-model width (always <= the parent's width).
function G.to_branches(skel)
  local out = {}
  local map = {}
  for _, br in ipairs(skel.branches) do
    local nd = {}
    local s = 0
    for i, n in ipairs(br.nodes) do
      local w = n.w
      if i == 1 and br.attach and br.nodes[2] then w = br.nodes[2].wseg and br.nodes[2].wseg * skel.scale or br.nodes[2].w end
      if i > 1 then s = s + sqrt((n.x - br.nodes[i - 1].x) ^ 2 + (n.y - br.nodes[i - 1].y) ^ 2) end
      nd[i] = { x = n.x, y = n.y, w = w, s = s, knot = (#n.children > 1) or (i % 2 == 0), node = n }
    end
    for i, q in ipairs(nd) do
      local j = min(#nd, i + 1)
      local k = max(1, (j == i) and i - 1 or i)
      q.a = atan2(nd[j].y - nd[k].y, nd[j].x - nd[k].x)
    end
    local b = { nodes = nd, depth = br.order, L = max(s, 1e-6), stub = br.stub, entering = br.nodes[1].entering and br.order == 0 }
    map[br] = b
    out[#out + 1] = b
  end
  for _, br in ipairs(skel.branches) do
    local b = map[br]
    if br.parent then
      b.parent = map[br.parent]
      if b.parent then
        for _, q in ipairs(b.parent.nodes) do if q.node == br.attach then b.attach_s = q.s; break end end
      end
    end
    if b.entering then
      for i, q in ipairs(b.nodes) do if not q.node.entering then b.entered = i; break end end
    end
  end
  -- monotone taper along every branch (widths never increase toward the tip)
  for _, b in ipairs(out) do
    for i = #b.nodes - 1, 1, -1 do
      if b.nodes[i].w < b.nodes[i + 1].w then b.nodes[i].w = b.nodes[i + 1].w end
    end
  end
  return out
end

---------------------------------------------------------------- invariants
--- Check the skeleton invariants; returns {forks=, max_pipe_err=, detached=,
--- taper_violations=}. pipe error = |w_p^p - sum w_c^p| / w_p^p at forks.
function G.check(skel)
  local p = skel.pipe or 2.4
  local worst, forks = 0, 0
  for _, n in ipairs(skel.nodes) do
    if #n.children > 0 then
      local s = 0
      for _, c in ipairs(n.children) do s = s + (c.wseg * skel.scale) ^ p end
      local e = abs(n.w ^ p - s) / (n.w ^ p)
      if #n.children > 1 then forks = forks + 1 end
      worst = max(worst, e)
    end
  end
  local detached = 0
  for _, br in ipairs(skel.branches) do
    if br.attach then
      local found = false
      for _, n in ipairs(br.parent.nodes) do if n == br.attach then found = true; break end end
      if not found or br.nodes[1] ~= br.attach then detached = detached + 1 end
    end
  end
  local tv = 0
  for _, n in ipairs(skel.nodes) do
    for _, c in ipairs(n.children) do if c.w > n.w + 1e-9 then tv = tv + 1 end end
  end
  return { forks = forks, max_pipe_err = worst, detached = detached, taper_violations = tv }
end

return G
