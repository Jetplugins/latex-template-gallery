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
-- kacho-geom.lua: pure geometry for kacho (rectangles, page geometry, decoration regions).
--
-- ALGORITHMS & REFERENCES:
--   * TeX scaled points to PostScript/PDF big points conversion (G.SP_PER_BP =
--     65536 * 72.27 / 72 = 65781.76) and page box layout formulas (G.page):
--     Donald E. Knuth, "The TeXbook", Addison-Wesley, 1984, Ch. 10 & Ch. 23,
--     and Leslie Lamport, "LaTeX: A Document Preparation System", 2nd ed., 1994.
--   * Axis-aligned rectangle boolean difference (G.subtract, G.subtract_all) and
--     margin region decomposition around inflated ink exclusions (G.regions):
--     standard 4-strip orthogonal rectangle decomposition.
--
-- No TeX globals: kacho.lua collects the TeX dimensions (in sp) and the measured
-- ink rectangles (in bp) and passes them here, so everything is unit-testable
-- under plain texlua.
--
-- Conventions: units are PDF big points (bp), origin bottom-left of the paper.
-- A rect is {x0=, y0=, x1=, y1=} with x0 <= x1, y0 <= y1.
local G = {}

local min, max = math.min, math.max

G.SP_PER_BP = 65536 * 72.27 / 72      -- 65781.76
G.MM = 72 / 25.4                       -- bp per mm

function G.bp(sp) return sp / G.SP_PER_BP end
function G.mm(x) return x * G.MM end

---------------------------------------------------------------- rects
function G.rect(x0, y0, x1, y1)
  return { x0 = min(x0, x1), y0 = min(y0, y1), x1 = max(x0, x1), y1 = max(y0, y1) }
end
function G.copy(r) return r and { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1 } end
function G.width(r) return r.x1 - r.x0 end
function G.height(r) return r.y1 - r.y0 end
function G.area(r) return max(0, r.x1 - r.x0) * max(0, r.y1 - r.y0) end
function G.empty(r) return r == nil or r.x1 <= r.x0 or r.y1 <= r.y0 end
function G.center(r) return (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 end

--- Strict overlap (touching edges do not intersect).
function G.intersects(a, b)
  return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
end
--- True if `inner` lies inside `outer` (with optional tolerance eps).
function G.contains(outer, inner, eps)
  eps = eps or 0
  return inner.x0 >= outer.x0 - eps and inner.y0 >= outer.y0 - eps
     and inner.x1 <= outer.x1 + eps and inner.y1 <= outer.y1 + eps
end
function G.contains_point(r, x, y)
  return x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1
end
function G.inflate(r, dx, dy)
  dy = dy or dx
  return { x0 = r.x0 - dx, y0 = r.y0 - dy, x1 = r.x1 + dx, y1 = r.y1 + dy }
end
function G.intersection(a, b)
  local r = { x0 = max(a.x0, b.x0), y0 = max(a.y0, b.y0), x1 = min(a.x1, b.x1), y1 = min(a.y1, b.y1) }
  if r.x1 <= r.x0 or r.y1 <= r.y0 then return nil end
  return r
end
--- Union (bounding box) of any number of rects; nil arguments are skipped.
function G.union(...)
  local out
  for i = 1, select("#", ...) do
    local r = select(i, ...)
    if r then
      if not out then out = G.copy(r)
      else
        out.x0 = min(out.x0, r.x0); out.y0 = min(out.y0, r.y0)
        out.x1 = max(out.x1, r.x1); out.y1 = max(out.y1, r.y1)
      end
    end
  end
  return out
end
--- Union of an array of rects.
function G.union_list(list)
  local out
  for _, r in ipairs(list) do out = G.union(out, r) end
  return out
end
--- Extend rect (or nil) by a point; returns the (possibly new) rect.
function G.add_point(r, x, y)
  if not r then return { x0 = x, y0 = y, x1 = x, y1 = y } end
  if x < r.x0 then r.x0 = x end
  if x > r.x1 then r.x1 = x end
  if y < r.y0 then r.y0 = y end
  if y > r.y1 then r.y1 = y end
  return r
end
--- Rect difference r \ x as up to 4 non-overlapping rects.
function G.subtract(r, x)
  if not G.intersects(r, x) then return { G.copy(r) } end
  local out = {}
  if x.y1 < r.y1 then out[#out + 1] = { x0 = r.x0, y0 = x.y1, x1 = r.x1, y1 = r.y1 } end
  if x.y0 > r.y0 then out[#out + 1] = { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = x.y0 } end
  local y0, y1 = max(r.y0, x.y0), min(r.y1, x.y1)
  if x.x0 > r.x0 then out[#out + 1] = { x0 = r.x0, y0 = y0, x1 = x.x0, y1 = y1 } end
  if x.x1 < r.x1 then out[#out + 1] = { x0 = x.x1, y0 = y0, x1 = r.x1, y1 = y1 } end
  return out
end
--- Subtract every rect of `xs` from `r`; returns list of pieces.
function G.subtract_all(r, xs)
  local pieces = { G.copy(r) }
  for _, x in ipairs(xs) do
    local np = {}
    for _, p in ipairs(pieces) do
      for _, q in ipairs(G.subtract(p, x)) do np[#np + 1] = q end
    end
    pieces = np
  end
  return pieces
end
function G.fmt(r)
  return string.format("%.2f %.2f %.2f %.2f", r.x0, r.y0, r.x1, r.y1)
end

---------------------------------------------------------------- page geometry
-- d: table of TeX dimensions in sp:
--   paperwidth paperheight hoffset voffset oddsidemargin evensidemargin topmargin
--   headheight headsep textheight textwidth footskip baselineskip
-- info: { folio=\count0, index=physical page, twoside=bool, safe_mm=5, buffer_mm=4 }
-- Returns the page table described in tex/API.md section 4.1 (without regions).
function G.page(d, info)
  info = info or {}
  local folio = info.folio or 1
  local twoside = info.twoside and true or false
  local bp = G.bp
  local pw, ph = bp(d.paperwidth), bp(d.paperheight)
  local odd = (folio % 2 ~= 0)
  local side = (twoside and not odd) and d.evensidemargin or d.oddsidemargin
  local x0 = 72 + bp((d.hoffset or 0) + side)
  local x1 = x0 + bp(d.textwidth)
  local headtop = ph - 72 - bp((d.voffset or 0) + d.topmargin)
  local ytop = headtop - bp(d.headheight + d.headsep)
  local y0 = ytop - bp(d.textheight)
  local bls = bp(d.baselineskip or 0)
  if bls <= 0 then bls = 14 end
  local footbase = y0 - bp(d.footskip)
  local p = {
    index = info.index or 1, folio = folio, odd = odd, twoside = twoside,
    paper = { w = pw, h = ph },
    paperrect = { x0 = 0, y0 = 0, x1 = pw, y1 = ph },
  }
  p.text = { x0 = x0, y0 = y0, x1 = x1, y1 = ytop }
  p.head = { x0 = x0, y0 = ytop + bp(d.headsep), x1 = x1, y1 = headtop }
  p.foot = { x0 = x0, y0 = footbase - 0.35 * bls, x1 = x1, y1 = footbase + 0.8 * bls }
  p.typearea = G.union(p.text, p.head, p.foot)
  if twoside then p.outer = odd and "right" or "left"
  else p.outer = (pw - x1 >= x0) and "right" or "left" end
  p.inner = (p.outer == "right") and "left" or "right"
  local s = G.mm(info.safe_mm or 5)
  p.safe = { x0 = s, y0 = s, x1 = pw - s, y1 = ph - s }
  p.buffer = G.mm(info.buffer_mm or 4)
  return p
end

---------------------------------------------------------------- regions
G.MIN_REGION = 8 * G.MM   -- regions thinner than this in either dimension are dropped
G.INK_TOL = 1.0           -- bp: justified lines sit exactly on the text edge

-- Compute the decoration regions of a page.
--   page   : from G.page (uses page.safe, page.buffer, page.outer)
--   block  : rect to keep clear (type area on body pages, title box on title pages)
--   ink    : list of measured ink rects (bp) on the page (may be empty)
-- Sets and returns page.exclude (list), page.regions (name -> largest rect free of
-- every exclusion), page.region_list (all pieces), page.bands (name -> band rect
-- before subtracting measured ink; use with page.exclude).
function G.regions(page, block, ink)
  ink = ink or {}
  local s, b = page.safe, page.buffer
  local ex = G.inflate(block, b)
  local exclude = { ex }
  -- measured ink that sticks out of the block (marginpars, overfull lines,
  -- protruding headers) becomes extra exclusion
  for _, r in ipairs(ink) do
    local rr = G.inflate(r, b)
    if not G.contains(ex, rr, G.INK_TOL) then exclude[#exclude + 1] = rr end
  end
  page.exclude = exclude
  page.block = block
  local L = { x0 = s.x0, y0 = s.y0, x1 = min(s.x1, ex.x0), y1 = s.y1 }
  local R = { x0 = max(s.x0, ex.x1), y0 = s.y0, x1 = s.x1, y1 = s.y1 }
  local T = { x0 = s.x0, y0 = max(s.y0, ex.y1), x1 = s.x1, y1 = s.y1 }
  local B = { x0 = s.x0, y0 = s.y0, x1 = s.x1, y1 = min(s.y1, ex.y0) }
  local outer, inner = page.outer == "right" and R or L, page.outer == "right" and L or R
  local cand = {
    { "outer", outer }, { "inner", inner }, { "top", T }, { "bottom", B },
    { "left", L }, { "right", R },
  }
  local function corner(name, a, c) local r = G.intersection(a, c); if r then cand[#cand + 1] = { name, r } end end
  corner("top_outer", T, outer); corner("top_inner", T, inner)
  corner("bottom_outer", B, outer); corner("bottom_inner", B, inner)
  -- Note: the free space below the last line of a partial page lies inside the
  -- type area; it is deliberately NOT offered as a region (the debug-log contract
  -- forbids any element intersecting the type area).
  -- bands before subtracting measured ink: layouts may use these together with
  -- page.exclude (fits checks) to work around small protrusions
  page.bands = {}
  for _, c in ipairs(cand) do
    if not G.empty(c[2]) and G.width(c[2]) >= G.MIN_REGION and G.height(c[2]) >= G.MIN_REGION then
      page.bands[c[1]] = G.copy(c[2])
    end
  end
  local regions, list = {}, {}
  local extra = {}
  for i = 2, #exclude do extra[#extra + 1] = exclude[i] end
  for _, c in ipairs(cand) do
    local name, r = c[1], c[2]
    if not G.empty(r) then
      local pieces = G.subtract_all(r, extra)
      local best
      for _, p in ipairs(pieces) do
        if G.width(p) >= G.MIN_REGION and G.height(p) >= G.MIN_REGION then
          p.name = name
          list[#list + 1] = p
          if not best or G.area(p) > G.area(best) then best = p end
        end
      end
      if best then regions[name] = best end
    end
  end
  page.regions, page.region_list = regions, list
  return regions, exclude
end

--- True if rect r is clear of every rect in the exclude list.
function G.clear_of(r, exclude)
  for _, x in ipairs(exclude) do if G.intersects(r, x) then return false end end
  return true
end

return G
