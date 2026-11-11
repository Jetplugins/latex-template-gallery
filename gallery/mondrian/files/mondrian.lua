-- Copyright (c) 2026 JetPlugins. MIT License; see UPSTREAM-LICENSE.txt.
-- Deterministic, page-local binary space partitioning. No images or shell calls.
local M = {}
local SP = 65536 * 72.27 / 72
local palette = {
  paper = {0.976, 0.969, 0.945}, black = {0.065, 0.069, 0.073},
  red = {0.82, 0.10, 0.085}, blue = {0.055, 0.22, 0.61},
  yellow = {0.99, 0.79, 0.055}, grey = {0.89, 0.885, 0.86},
}

local function number(value, name, low, high, integer)
  local n = tonumber(value)
  assert(n and n == n and n >= low and n <= high and (not integer or n % 1 == 0),
    "mondrian: " .. name .. " must be " .. (integer and "an integer" or "a number") ..
    " between " .. low .. " and " .. high)
  return n
end

function M.composition(width, height, seed, density)
  local state = seed % 2147483647
  if state == 0 then state = 1 end
  local function random()
    state = (state * 48271) % 2147483647
    return state / 2147483647
  end
  local cells = {{x = 0, y = 0, w = width, h = height}}
  local target = 6 + math.floor(density * 11)
  while #cells < target do
    local pick, score
    for i, c in ipairs(cells) do
      if c.w > 64 or c.h > 100 then
        local s = c.w * c.h * (0.85 + random() * 0.3)
        if not score or s > score then pick, score = i, s end
      end
    end
    if not pick then break end
    local c = table.remove(cells, pick)
    local vertical = c.w > 64 and (c.h < 100 or c.w / c.h > 0.7 + random() * 0.7)
    local t = 0.30 + random() * 0.36
    if vertical then
      local cut = c.w * t
      cells[#cells + 1] = {x=c.x, y=c.y, w=cut, h=c.h}
      cells[#cells + 1] = {x=c.x+cut, y=c.y, w=c.w-cut, h=c.h}
    else
      local cut = c.h * t
      cells[#cells + 1] = {x=c.x, y=c.y, w=c.w, h=cut}
      cells[#cells + 1] = {x=c.x, y=c.y+cut, w=c.w, h=c.h-cut}
    end
  end
  -- Three distinct accents; most of the composition remains warm white.
  local ranked = {}
  for i, c in ipairs(cells) do
    c.color = "paper"
    ranked[i] = {index=i, score=random(), area=c.w*c.h}
  end
  table.sort(ranked, function(a,b) return a.score < b.score end)
  for i, name in ipairs({"red", "blue", "yellow"}) do
    cells[ranked[i].index].color = name
  end
  if #ranked > 8 then cells[ranked[4].index].color = "grey" end
  return cells
end

function M.paint(w, h, left, right, page, seed, density, intensity, enabled)
  seed = number(seed, "seed", 1, 2147483646, true)
  density = number(density, "density", 0, 1)
  intensity = number(intensity, "intensity", 0, 1)
  if not enabled then return end
  w, h, left, right = w/SP, h/SP, left/SP, right/SP
  local width = math.max(0, math.max(left, right) - 28.35)
  -- Narrow margins produce no panel rather than colliding with the text.
  if width < 24 then return end
  local on_right = right > left
  local x = on_right and w-width or 0
  local commands = {"q"}
  local function emit(format, ...) commands[#commands+1] = string.format(format, ...) end
  local function color(name, operator)
    local c, p = palette[name], palette.paper
    local t = name == "paper" and 0 or intensity
    emit("%.4f %.4f %.4f %s", p[1]+(c[1]-p[1])*t,
      p[2]+(c[2]-p[2])*t, p[3]+(c[3]-p[3])*t, operator)
  end
  color("paper", "rg"); emit("0 0 %.3f %.3f re f", w, h)
  emit("%.3f 0 %.3f %.3f re W n", x, width, h)
  emit("3.2 w 0 j")
  for _, c in ipairs(M.composition(width, h, (seed + page * 104729) % 2147483647, density)) do
    local cx = on_right and w-c.x-c.w or c.x
    color(c.color, "rg"); color("black", "RG")
    emit("%.3f %.3f %.3f %.3f re B", cx, c.y, c.w, c.h)
  end
  commands[#commands+1] = "Q"
  local literal = node.new("whatsit", "pdf_literal")
  literal.mode = 0
  literal.data = table.concat(commands, "\n")
  node.write(literal)
end

return M
