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
-- kacho-motifsheet.lua: gallery layouts for examples/kacho-motifs.tex (M2).
--
-- ALGORITHMS & REFERENCES:
--   * S.install / halves / both: splits the page bottom region into left (sumi)
--     and right (hanga) sub-contexts to render every M2 motif side by side.
--   No external code copied.
--
-- Registers one layout per motif, named "motif-<name>", that draws the motif
-- twice in the free area below the page heading: left half in the `sumi`
-- palette, right half in the `hanga` palette. It exists to show and test every
-- motif of kacho-flora / -fauna / -scenery / -seal in isolation; real documents
-- use the M3 layouts (kacho-layout). Load it in a document with
--   \directlua{require("kacho-motifsheet").install(kacho)}
-- Pure Lua; all drawing goes through the motif modules.
local S = {}

local PAL = require("kacho-palette")
local pi, min, max = math.pi, math.min, math.max

local function halves(page)
  local R = page.regions and (page.regions.bottom or page.regions.outer)
  if not R then return nil end
  local gut = 8
  local mid = (R.x0 + R.x1) / 2
  return { x0 = R.x0, y0 = R.y0, x1 = mid - gut / 2, y1 = R.y1 },
         { x0 = mid + gut / 2, y0 = R.y0, x1 = R.x1, y1 = R.y1 }
end

local function sub(ctx, region, pal, tag)
  local c = ctx:sub({ region = region, tag = tag, bleed = {} })
  c.palette = PAL.get(pal)
  return c
end

local function w(r) return r.x1 - r.x0 end
local function h(r) return r.y1 - r.y0 end

-- draw(ctx_half, region, palette_name, index) for each half
local function both(draw)
  return function(ctx, page)
    local a, b = halves(page)
    if not a then return end
    draw(sub(ctx, a, "sumi", "L"), a, "sumi", 1, page)
    draw(sub(ctx, b, "hanga", "R"), b, "hanga", 2, page)
  end
end
S.both = both

S.sheets = {}
local SH = S.sheets

SH.ume = both(function(c, r, pal, i)
  local flora = require("kacho-flora")
  if i == 1 then
    flora.ume(c, { x = r.x0 + w(r) * 0.42, y = r.y0 + 18, angle = pi / 2 + 0.08, size = min(h(r) * 0.62, 420),
      ground = false, attract = { r.x0 + w(r) * 0.5, r.y0 + h(r) * 0.55 } })
  else
    flora.ume(c, { x = r.x0 + 12, y = r.y1 - 30, angle = -0.45, fade_base = true, size = min(h(r) * 0.55, 380),
      attract = { r.x0 + w(r) * 0.55, r.y0 + h(r) * 0.5 } })
  end
end)

SH.sakura = both(function(c, r, pal, i)
  local flora = require("kacho-flora")
  if i == 1 then
    flora.sakura(c, { x = r.x1 - 14, y = r.y1 - 24, angle = pi + 0.4, fade_base = true, size = min(h(r) * 0.6, 400),
      attract = { r.x0 + w(r) * 0.45, r.y0 + h(r) * 0.55 } })
  else
    flora.sakura(c, { x = r.x0 + w(r) * 0.5, y = r.y0 + 18, angle = pi / 2 - 0.1, ground = false, size = min(h(r) * 0.6, 400),
      attract = { r.x0 + w(r) * 0.5, r.y0 + h(r) * 0.6 } })
  end
end)

local function flora() return require("kacho-flora") end
local function fauna() return require("kacho-fauna") end
local function scen() return require("kacho-scenery") end
local function seal() return require("kacho-seal") end

SH.bamboo = both(function(c, r, pal, i)
  scen().kasumi(c, { x0 = r.x0 + 10, x1 = r.x1 - 10, y = r.y0 + h(r) * 0.28, height = 20, bands = 2 })
  flora().bamboo(c, { x = r.x0 + w(r) * (i == 1 and 0.42 or 0.55), y = r.y0 + 16, size = h(r) * 0.91, culms = 3,
    width = min(13, w(r) * 0.05), ground = false })
end)

SH.orchid = both(function(c, r, pal, i)
  flora().orchid(c, { x = r.x0 + w(r) * 0.5, y = r.y0 + 40, size = min(w(r) * 0.85, h(r) * 0.5), leaves = 11, flowers = 2 })
end)

SH.maple = both(function(c, r, pal, i)
  flora().maple(c, { fade_base = true, x = i == 1 and r.x1 - 12 or r.x0 + 12, y = r.y1 - 30, angle = i == 1 and pi + 0.5 or -0.5,
    size = min(h(r) * 0.55, 400), attract = { r.x0 + w(r) * 0.5, r.y0 + h(r) * 0.55 }, falling = 3 })
end)

SH.wisteria = both(function(c, r, pal, i)
  flora().wisteria(c, { x = r.x0 + 10, y = r.y1 - 40, angle = -0.08, size = w(r) * 0.92, droop = h(r) * 0.45, racemes = 8 })
end)

SH.iris = both(function(c, r, pal, i)
  flora().iris(c, { x = r.x0 + w(r) * 0.5, y = r.y0 + 30, size = h(r) * 0.55, leaves = 8, flowers = 3 })
end)

SH.bonus1 = both(function(c, r, pal, i)
  if i == 1 then
    flora().osmanthus(c, { x = r.x0 + w(r) * 0.45, y = r.y0 + 20, angle = pi / 2 + 0.1, size = h(r) * 0.6, ground = false })
  else
    flora().camellia(c, { fade_base = true, x = r.x1 - 14, y = r.y1 - 40, angle = pi + 0.6, size = h(r) * 0.5,
      attract = { r.x0 + w(r) * 0.5, r.y0 + h(r) * 0.6 } })
  end
end)

SH.bonus2 = both(function(c, r, pal, i)
  if i == 1 then
    flora().narcissus(c, { x = r.x0 + w(r) * 0.5, y = r.y0 + h(r) * 0.55, size = h(r) * 0.32, leaves = 7, scapes = 2 })
    flora().chrysanthemum(c, { x = r.x0 + w(r) * 0.5, y = r.y0 + 30, size = h(r) * 0.3, flowers = 3 })
  else
    flora().pine(c, { x = r.x0 + w(r) * 0.45, y = r.y0 + 24, angle = pi / 2, size = h(r) * 0.7, limbs = 4, ground = false })
  end
end)

SH.birds = both(function(c, r, pal, i)
  local fl = flora()
  local bb, info
  if i == 1 then
    bb, info = fl.ume(c, { fade_base = true, x = r.x0 + 18, y = r.y0 + h(r) * 0.56, angle = 0.12, size = w(r) * 1.08, variant = "white",
      perch_clear = 34, attract = { r.x0 + w(r) * 0.6, r.y0 + h(r) * 0.56 } })
  else
    bb, info = fl.maple(c, { fade_base = true, x = r.x1 - 18, y = r.y0 + h(r) * 0.54, angle = pi - 0.12, size = w(r) * 1.08,
      perch_clear = 34, attract = { r.x0 + w(r) * 0.4, r.y0 + h(r) * 0.54 } })
  end
  local kinds = i == 1 and { "robin", "uguisu", "sparrow" } or { "mejiro", "mejiro", "sparrow" }
  local placed = {}
  for _, p in ipairs((info and info.perch) or {}) do
    if #placed >= #kinds then break end
    local ok = true
    for _, q in ipairs(placed) do
      if ((p.cx or p.x) - (q.cx or q.x)) ^ 2 + ((p.cy or p.y) - (q.cy or q.y)) ^ 2 < 46 ^ 2 then ok = false; break end
    end
    if ok then
      local kd = kinds[#placed + 1]
      local b = fauna().bird(c, { perch = p, kind = kd, size = kd == "mejiro" and 36 or 42 })
      if b then placed[#placed + 1] = p end
    end
  end
  -- Place swallows banking in flight above the upper branch tips (still touching the upper twig bbox)
  local sw_nodes = {}
  for _, br in ipairs((info and info.tree) or {}) do
    if (br.depth or 0) >= 1 and br.nodes and #br.nodes >= 2 then
      for _, idx in ipairs({ math.max(2, math.floor(#br.nodes * 0.72)), #br.nodes }) do
        local nd = br.nodes[idx]
        if nd and nd.x >= r.x0 + 36 and nd.x <= r.x1 - 36 and nd.y >= r.y0 + 36 and nd.y <= r.y1 - 48 then
          sw_nodes[#sw_nodes + 1] = nd
        end
      end
    end
  end
  table.sort(sw_nodes, function(a, b) return a.y > b.y end)
  local sw_placed = 0
  for _, nd in ipairs(sw_nodes) do
    if sw_placed >= 2 then break end
    local sx, sy = nd.x, min(r.y1 - 36, nd.y + 12)
    local ok = true
    for _, q in ipairs(placed) do
      if (sx - (q.cx or q.x)) ^ 2 + (sy - (q.cy or q.y)) ^ 2 < 54 ^ 2 then ok = false; break end
    end
    if ok then
      local k = sw_placed + 1
      local b = fauna().swallow(c, { x = sx, y = sy, size = 56, angle = 0.22 * k, face = k == 1 and 1 or -1 })
      if b then
        c.record("ume-twig", { x0 = sx - 2, y0 = sy - 1, x1 = sx + 2, y1 = sy + 1 })
        sw_placed = sw_placed + 1
        placed[#placed + 1] = { cx = sx, cy = sy }
      end
    end
  end
end)

SH.seal = both(function(c, r, pal, i)
  local styles = { "hakubun", "shubun" }
  local shapes = { "square", "oval", "tall", "square" }
  for row = 1, 4 do
    for col = 1, 2 do
      local x = r.x0 + w(r) * (col == 1 and 0.3 or 0.7)
      local y = r.y1 - 70 - (row - 1) * 150
      seal().hanko(c, { x = x, y = y, size = 26 + row * 6, style = styles[(row + col + i) % 2 + 1], shape = shapes[row] })
    end
  end
end)

SH.scenery = both(function(c, r, pal, i)
  local sc = scen()
  -- Band 1 (Top): bokashi sky, Mt Fuji, kasumi mist, and tanzaku cartouche
  local top = { x0 = r.x0 + 2, y0 = r.y0 + h(r) * 0.62, x1 = r.x1 - 2, y1 = r.y1 - 2 }
  local ct = c:sub({ region = top, tag = "top" })
  ct.palette = c.palette
  sc.sky(ct, { rect = top, corner = i == 1 and "left" or "right" })
  sc.fuji(ct, { x = (top.x0 + top.x1) / 2, y = top.y0 + 24, width = w(top) * 0.84 })
  sc.kasumi(ct, { x0 = top.x0 + 6, x1 = top.x1 - 6, y = top.y0 + 28, height = 16, bands = 2 })
  sc.tanzaku(ct, { x = i == 1 and (top.x0 + 24) or (top.x1 - 24), y = top.y1 - 10, width = 22, height = 78, variant = i == 1 and "gold" or "shu" })
  -- Band 2 (Middle): coastal tsun cliffs on outer side and Hokusai waves peaking on inner side
  sc.cliffs(c, { x = i == 1 and (r.x0 + w(r) * 0.23) or (r.x1 - w(r) * 0.23), y = r.y0 + h(r) * 0.38,
    width = w(r) * 0.36, height = h(r) * 0.17, side = i == 1 and "left" or "right", with_waves = false })
  sc.waves(c, { x0 = r.x0 + 6, x1 = r.x1 - 6, y = r.y0 + h(r) * 0.26, height = h(r) * 0.12, crest_side = i == 1 and "right" or "left" })
  -- Band 3 (Bottom): Taihu scholar's rock (no grass bank)
  sc.rock(c, { x = r.x0 + w(r) * 0.5, y = r.y0 + 14, size = h(r) * 0.21, variant = i == 1 and "ink" or "ochre" })
end)

function S.install(kacho)
  local names = {}
  for k in pairs(SH) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do kacho.register_layout("motif-" .. k, SH[k]) end
end

return S

