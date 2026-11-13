-- Isolated monochrome ornaments: no document settings or page RNG access.
local Orn = require("flora.ornaments")
local Paint = require("flora.paint")
local Rng = require("flora.rng")
local M = {}
local function number(v, name)
  local n = tonumber(v)
  assert(n and n == n and math.abs(n) < 1e9, "floraornament: invalid " .. name)
  return n
end
function M.draw(kind, width, height, baseline, seed, color)
  local k = assert(Orn.kinds[kind], "floraornament: unknown kind " .. tostring(kind))
  width, height = number(width, "width"), number(height, "height")
  baseline, seed = number(baseline, "baseline"), number(seed, "seed")
  assert(width > 0 and height > 0, "floraornament: width and height must be positive")
  assert(seed % 1 == 0, "floraornament: seed must be an integer")
  local pt = Paint.new({ backend = "pgf" })
  -- Override this painter only. Keep opacity and path geometry, but map
  -- every pigment to the requested xcolor expression.
  function pt:color(_) return color end
  pt:begin_group("inline")
  Orn.draw(k, pt, Rng.new(seed), { 0, 0, width, height }, { cord = height / 3 })
  pt:end_group()
  local pad = k.reach * math.max(width, height)
  local bounds = { x0 = -pad, y0 = -pad, x1 = width + pad, y1 = height + pad }
  -- Include measured stroke/curve extents as well as the registered reach.
  for _, b in ipairs(pt.boxes) do
    bounds.x0, bounds.y0 = math.min(bounds.x0, b.x0), math.min(bounds.y0, b.y0)
    bounds.x1, bounds.y1 = math.max(bounds.x1, b.x1), math.max(bounds.y1, b.y1)
  end
  return pt, bounds, baseline
end
function M.typeset(kind, width, height, baseline, seed, color)
  local pt, b, base = M.draw(kind, width, height, baseline, seed, color)
  -- The mark makes the measurer (measure.lua) take the box as ink, so the
  -- flora keeps clear of the ornament's real size.
  tex.sprint("\\hbox{\\directlua{flora.mark('ink')}\\begin{pgfpicture}")
  tex.sprint(string.format("\\pgfsetbaseline{%.5fpt}", base))
  require("flora.init").typeset(pt)
  tex.sprint("\\pgfresetboundingbox")
  tex.sprint(string.format(
    "\\pgfpathrectangle{\\pgfqpoint{%.5fpt}{%.5fpt}}{\\pgfqpoint{%.5fpt}{%.5fpt}}\\pgfusepath{use as bounding box}",
    b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0))
  tex.sprint("\\end{pgfpicture}}")
end
return M
