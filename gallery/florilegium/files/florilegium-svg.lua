-- florilegium-svg.lua -- a florilegium page as SVG, without TeX: for Typst, the web, notes,
-- anything that takes an image. The same Lua draws the same garden; only the
-- last step differs. florilegium-ink.lua writes a PDF content stream as always, and this
-- file reads it back (the few operators ink uses) and writes SVG elements.
-- Copyright (c) 2026 Kevin Raymond. MIT License: see LICENSE or florilegium.sty.
--
--   texlua florilegium-svg.lua --seed 7 > margin.svg        (or lua 5.3/5.4: lua florilegium-svg.lua ...)
--   texlua florilegium-svg.lua --help
--
-- The page is laid out the way LuaLaTeX and the geometry package lay it out:
-- lengths are scanned as TeX scans them, and florilegium.geometry() itself
-- reads them, so --seed 7 is the garden on page 1 of a document built with
-- \def\florilegiumseed{7} and the same margins.

local M = {}
M.version = "1.3"                 -- the release; florilegium.lua checks that every file has the same
local fmt, floor, concat = string.format, math.floor, table.concat

-- ---------------------------------------------------------------- lengths
-- a length as TeX scans it ("68mm" -> 12679822 sp): integer part, the fraction
-- rounded to 2^-16, then the unit as the ratio num/denom with the remainder
-- carried, as in TeX's scan_dimen. A bare number is millimeters.
local UNITS = { pt = { 1, 1 }, mm = { 7227, 2540 }, cm = { 7227, 254 }, ["in"] = { 7227, 100 }, bp = { 7227, 7200 } }
function M.sp(s)
  s = tostring(s)
  local sign, int, frac, unit = s:match("^%s*([-+]?)(%d*)%.?(%d*)%s*(%a*)%s*$")
  if not int or int .. frac == "" then error("florilegium: not a length: '" .. s .. "'", 0) end
  local u = UNITS[unit == "" and "mm" or unit]
  if not u then error("florilegium: unknown unit '" .. unit .. "' in '" .. s .. "'", 0) end
  local v, f = tonumber(int ~= "" and int or "0"), 0
  if frac ~= "" then                          -- round_decimals
    local a = 0
    for k = math.min(#frac, 17), 1, -1 do a = (a + tonumber(frac:sub(k, k)) * 131072) // 10 end
    f = (a + 1) // 2
  end
  if u[1] ~= 1 then
    local q, r = (v * u[1]) // u[2], (v * u[1]) % u[2]
    f = (u[1] * f + 65536 * r) // u[2]
    v = q + f // 65536
    f = f % 65536
  end
  local n = v * 65536 + f
  return sign == "-" and -n or n
end

local PAPERS = { a4 = { "210mm", "297mm" }, a5 = { "148mm", "210mm" }, letter = { "8.5in", "11in" }, legal = { "8.5in", "14in" } }

-- ---------------------------------------------------------------- PDF -> SVG
-- ink writes paths (m l c h), fills (f) and strokes (S), clips (W n), colors
-- (rg RG), line widths and dashes (w d), caps and joins (J j), graphics states
-- for opacity and multiply (/floaNN, /flomNN gs), and q/Q around them. Each
-- fill or stroke becomes a <path>; a clip opens a group that its Q closes.
local function hex(r, g, b)
  local function c(v) return math.max(0, math.min(255, floor(tonumber(v) * 255 + 0.5))) end
  return fmt("#%02x%02x%02x", c(r), c(g), c(b))
end
local function num(t) return (t:gsub("%.0$", "")) end   -- "12.0" -> "12"

function M.translate(stream, out, id)
  local st = { fill = "#000000", stroke = "#000000", w = "1", op = 1, mult = false }
  local stack, open = {}, 0
  local args, d, arr = {}, {}, nil
  local nclip = 0
  local function paint(stroke)
    local a = { '<path d="', concat(d), '"' }
    if stroke then
      a[#a + 1] = fmt(' fill="none" stroke="%s" stroke-width="%s"', st.stroke, st.w)
      if st.dash then a[#a + 1] = fmt(' stroke-dasharray="%s"', st.dash) end
      if st.op < 1 then a[#a + 1] = fmt(' stroke-opacity="%g"', st.op) end
    else
      a[#a + 1] = fmt(' fill="%s"', st.fill)
      if st.op < 1 then a[#a + 1] = fmt(' fill-opacity="%g"', st.op) end
    end
    if st.mult then a[#a + 1] = ' style="mix-blend-mode:multiply"' end
    a[#a + 1] = "/>"
    out[#out + 1] = concat(a)
  end
  local clip = false
  for t in stream:gmatch("%S+") do
    local c = t:byte()
    if arr then                               -- inside a dash array: "[2 2] 0 d"
      local v, closed = t:gsub("%]$", "")
      if v ~= "" then arr[#arr + 1] = num(v) end
      if closed > 0 then args[#args + 1] = arr arr = nil end
    elseif c == 91 then                       -- [
      arr = {}
      local v, closed = t:sub(2):gsub("%]$", "")
      if v ~= "" then arr[#arr + 1] = num(v) end
      if closed > 0 then args[#args + 1] = arr arr = nil end
    elseif (c >= 48 and c <= 57) or c == 45 or c == 46 or c == 47 then   -- a number or a /name
      args[#args + 1] = t
    else
      local n = #args
      if t == "m" or t == "l" then
        d[#d + 1] = (t == "m" and "M" or "L") .. num(args[n - 1]) .. " " .. num(args[n])
      elseif t == "c" then
        d[#d + 1] = "C" .. num(args[n - 5]) .. " " .. num(args[n - 4]) .. " " .. num(args[n - 3]) .. " " ..
          num(args[n - 2]) .. " " .. num(args[n - 1]) .. " " .. num(args[n])
      elseif t == "h" then d[#d + 1] = "Z"
      elseif t == "f" then paint(false) d = {}
      elseif t == "S" then paint(true) d = {}
      elseif t == "W" then clip = true
      elseif t == "n" then
        if clip then
          nclip = nclip + 1
          local cid = fmt("%sc%d", id, nclip)
          out[#out + 1] = fmt('<clipPath id="%s"><path d="%s"/></clipPath><g clip-path="url(#%s)">', cid, concat(d), cid)
          open = open + 1
          clip = false
        end
        d = {}
      elseif t == "q" then
        stack[#stack + 1] = { st = { fill = st.fill, stroke = st.stroke, w = st.w, dash = st.dash, op = st.op, mult = st.mult }, open = open }
        open = 0
      elseif t == "Q" then
        for _ = 1, open do out[#out + 1] = "</g>" end
        local s = table.remove(stack)
        st, open = s.st, s.open
      elseif t == "rg" then st.fill = hex(args[n - 2], args[n - 1], args[n])
      elseif t == "RG" then st.stroke = hex(args[n - 2], args[n - 1], args[n])
      elseif t == "w" then st.w = num(args[n])
      elseif t == "d" then
        local a = args[n - 1]
        st.dash = type(a) == "table" and #a > 0 and concat(a, " ") or nil
      elseif t == "gs" then
        local kind, v = args[n]:match("^/flo([am])(%d+)$")
        if not kind then error("florilegium: unknown graphics state " .. tostring(args[n]), 0) end
        st.op, st.mult = tonumber(v) / 100, kind == "m"
      elseif t == "J" or t == "j" then        -- always round (ink sets 1 J 1 j); the root group says so
      else error("florilegium: florilegium-svg.lua cannot translate the PDF operator '" .. t .. "'", 0) end
      args = {}
    end
  end
  for _ = 1, open do out[#out + 1] = "</g>" end
  return out
end

-- ---------------------------------------------------------------- the page
-- Run the TeX glue with a stand-in for the few parts of TeX it touches: the
-- page's lengths (tex.dimen), the page number, and the node a literal goes
-- into, which here only keeps its text. The globals are put back afterwards.
local DEFAULTS = {                            -- florilegium-grow.tex
  paper = "a4", left = "68mm", right = "22mm", top = "32mm", bottom = "30mm",
  headsep = "8mm", headheight = "12pt", footskip = "30pt",
}

-- an HTML color as xcolor hands it to Lua: n/255 to five decimals (\rdivide, the
-- sixth rounding up by 1 sp), read as a TeX length and printed back as TeX
-- prints one. 0x24 is 0.14119, not 0.141176: the ramp is built from these.
local function print_scaled(s)                -- TeX's print_scaled, without "pt"
  local out, delta = { tostring(s // 65536), "." }, 10
  s = 10 * (s % 65536) + 5
  repeat
    if delta > 65536 then s = s + 0x8000 - 50000 end
    out[#out + 1] = tostring(s // 65536)
    s, delta = 10 * (s % 65536), delta * 10
  until s <= delta
  return concat(out)
end
local function xcolor(n)
  local q, r, digits = n // 255, n % 255, {}
  for k = 1, 6 do r = r * 10 digits[k] = r // 255 r = r % 255 end
  local s = M.sp(q .. "." .. concat(digits, "", 1, 5) .. "pt")
  if digits[6] > 4 then s = s + 1 end
  return tonumber((print_scaled(s):gsub("%.0$", "")))   -- and \strip@pt
end
local function html(h)
  h = tostring(h):gsub("^#", "")
  if not h:match("^%x%x%x%x%x%x$") then error("florilegium: not a color (RRGGBB): '" .. h .. "'", 0) end
  return xcolor(tonumber(h:sub(1, 2), 16)), xcolor(tonumber(h:sub(3, 4), 16)), xcolor(tonumber(h:sub(5, 6), 16))
end

-- o: seed, page, paper ("a4", "letter", ... or {w, h}), left right top bottom
-- headsep headheight footskip (lengths), twoside, textend (a length from the top
-- of the text block: the last page, with the garden in the space below), season
-- ("spring", "summer", "autumn" or 0..1), theme, density, intensity, visitors,
-- ink, accent (RRGGBB), head (false: no head rule), authored, background (RRGGBB),
-- id (prefix for the clip ids). Returns the SVG, the page layout g (cm), and a table:
-- streams, the PDF literals the SVG was made from; captions, the text a theme sets in
-- the margin (the math theme's symbols and equations), which needs a TeX typesetter
-- and is not in the SVG: { x, y (page cm), tex, anchor (TikZ's), size (pt), rotate
-- (degrees, counterclockwise), color (#rrggbb), opacity }, mirrored as florilegium.lua
-- mirrors it for TikZ; stats, what grew (florilegium-grow.lua: motifs, counts by motif, stems,
-- cells; nil for the authored page and the math theme).
function M.page(o)
  o = o or {}
  for k, v in pairs(DEFAULTS) do if o[k] == nil then o[k] = v end end
  local paper = type(o.paper) == "table" and o.paper or PAPERS[o.paper]
  if not paper then error("florilegium: unknown paper '" .. tostring(o.paper) .. "'", 0) end
  local page = floor(tonumber(o.page) or 1)
  local pw, ph = M.sp(paper[1]), M.sp(paper[2])
  local L, R, T, B = M.sp(o.left), M.sp(o.right), M.sp(o.top), M.sp(o.bottom)
  local hh, hs, inch = M.sp(o.headheight), M.sp(o.headsep), M.sp("1in")
  local tw, th = pw - L - R, ph - T - B
  if tw <= 0 or th <= 0 then error("florilegium: the margins leave no room for the text", 0) end
  -- geometry: the inner margin on odd pages is `left`; on even pages of a
  -- two-sided document the text moves over by the difference
  local dimen = {
    paperwidth = pw, paperheight = ph, textwidth = tw, textheight = th,
    oddsidemargin = L - inch, evensidemargin = pw - tw - L - inch,
    topmargin = T - inch - hh - hs, headheight = hh, headsep = hs, footskip = M.sp(o.footskip),
  }
  local streams = {}
  local saved = { tex = tex, node = node, luatexbase = luatexbase, texio = texio }
  tex = { dimen = dimen, count = { [0] = page }, hoffset = 0, sprint = function() end,
    error = function(m) error(m, 0) end }
  luatexbase = { registernumber = function() return 0 end }
  node = { new = function() return {} end, write = function(n) streams[#streams + 1] = n.data end,
    id = function(name) return name end, subtype = function(name) return name end }
  texio = nil
  local ok, res = pcall(function()
    local fl = require("florilegium")
    local ink = require("florilegium-ink")
    fl.twoside = o.twoside and true or false
    local ir, ig, ib = html(o.ink or "2456C4")
    local ar, ag, ab = html(o.accent or "B4662F")
    fl.colors(ir, ig, ib, ar, ag, ab)
    local fixed = o.seed and tonumber(o.seed)
    if o.seed and not (fixed and fixed >= 1) then error("florilegium: a seed is a positive integer", 0) end
    local seed = fl.seed(page, fixed and floor(fixed) or nil)
    local age = o.season
    if age == nil or age == "summer" then age = nil
    elseif age == "spring" then age = 0
    elseif age == "autumn" then age = 1
    else
      age = tonumber(age)
      if not age then error("florilegium: a season is spring, summer, autumn or 0..1", 0) end
    end
    fl.age = age
    fl.theme = (o.theme ~= "" and o.theme ~= "flora") and o.theme or nil
    fl.density = tonumber(o.density) or 1
    fl.intensity = tonumber(o.intensity) or 1
    fl.visitors = o.visitors ~= false
    local g = fl.geometry()
    fl.last_captions, fl.last_stats = nil, nil
    if o.authored then fl.authored(seed, nil)
    elseif o.textend then
      -- as florilegium.sty computes it from \flo@endtotal
      fl.grown(seed, 1, g.ytop - M.sp(o.textend) * 2.54 / (72.27 * 65536), nil)
    else fl.grown(seed, 0, 0, nil) end
    -- the captions as the TikZ nodes would set them: florilegium.lua's captions()
    local caps = {}
    local old = ink.set_pale(0.85 * (1 - math.max(0, math.min(1, fl.intensity))))
    local plain = ink.tone(0.12)
    ink.set_pale(old)
    local function rgb255(c) return fmt("#%02x%02x%02x", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5)) end
    for _, cap in ipairs(fl.last_captions or {}) do
      local anchor = cap.anchor or "north"
      if g.mirror then anchor = anchor:gsub("east", "\0"):gsub("west", "east"):gsub("\0", "west") end
      caps[#caps + 1] = {
        x = g.mirror and g.pw - cap.x or cap.x, y = cap.y, tex = cap.text, anchor = anchor,
        size = cap.scale and 10 * cap.scale or (cap.small and 5.5 or 6.5),
        rotate = cap.rotate and (g.mirror and -cap.rotate or cap.rotate) or 0,
        color = rgb255(cap.color or plain), opacity = cap.opacity or 1,
      }
    end
    ink.set_pale(0)
    return { g = g, captions = caps, stats = fl.last_stats }
  end)
  if not ok then                              -- leave nothing half drawn for the next page
    local ink = package.loaded["florilegium-ink"]
    if ink then ink.take_recording() ink.discard() ink.set_lift(0) ink.set_pale(0) end
  end
  tex, node, luatexbase, texio = saved.tex, saved.node, saved.luatexbase, saved.texio
  if not ok then error(res, 0) end
  local g = res.g
  if o.head == false then streams[#streams] = nil end   -- the head rule is the last literal
  -- the SVG: big points, y up as in PDF, so the paths are copied as they are
  local CM = 72 / 2.54
  local W, H = g.pw * CM, g.ph * CM
  local id = o.id or fmt("flo%d-", floor(tonumber(o.seed) or 0))
  local out = {
    fmt('<svg xmlns="http://www.w3.org/2000/svg" width="%.2fmm" height="%.2fmm" viewBox="0 0 %.2f %.2f">', g.pw * 10, g.ph * 10, W, H),
  }
  if o.background then
    local h = tostring(o.background):gsub("^#", "")
    if not h:match("^%x%x%x%x%x%x$") then error("florilegium: not a color (RRGGBB): '" .. h .. "'", 0) end
    out[#out + 1] = fmt('<rect width="%.2f" height="%.2f" fill="#%s"/>', W, H, h:lower())
  end
  out[#out + 1] = fmt('<g transform="matrix(1 0 0 -1 0 %.2f)" stroke-linecap="round" stroke-linejoin="round">', H)
  for i, s in ipairs(streams) do M.translate(s, out, id .. i) end
  out[#out + 1] = "</g></svg>\n"
  return concat(out, "\n"), g, { streams = streams, captions = res.captions, stats = res.stats }
end

-- ---------------------------------------------------------------- command line
local USAGE = [[
usage: texlua florilegium-svg.lua [options] > page.svg      (lua 5.3 or 5.4 works too)

  --seed N          the document's seed (\def\florilegiumseed{N}); default: none
  --page N          the page number (default 1)
  --paper NAME      a4 (default), a5, letter, legal, or WxH in mm (e.g. 176x250)
  --left/--right/--top/--bottom LEN   margins as geometry takes them (default 68mm 22mm 32mm 30mm)
  --headsep LEN     (default 8mm)    --headheight LEN (12pt)    --footskip LEN (30pt)
  --twoside         a two-sided document: the garden in the wider outer margin
  --textend LEN     the last page: the text ends LEN below the top of the text block
  --season S        spring, summer (default), autumn, or 0..1
  --theme NAME      flora (default), geometric or math (math: its text needs TeX, left out)
  --density X       0.05..1 (default 1)      --intensity X   0..1 (default 1)
  --ink RRGGBB      (default 2456C4)         --accent RRGGBB (default B4662F)
  --novisitors      no butterflies, bees, snails or birds
  --nohead          leave out the head rule and its ivy leaf
  --authored        the hand-placed composition (A4, 68 mm left margin)
  --background RRGGBB   paint the paper (default: transparent)
  -o FILE           write to FILE instead of standard output
A length is a number and a unit (mm, cm, in, pt, bp); a bare number is mm.
]]

function M.main(argv)
  local o, file = {}, nil
  local flags = { twoside = true, novisitors = "visitors", nohead = "head", authored = true }
  local values = { seed = 1, page = 1, paper = 1, left = 1, right = 1, top = 1, bottom = 1, headsep = 1, headheight = 1,
    footskip = 1, textend = 1, season = 1, theme = 1, density = 1, intensity = 1, ink = 1, accent = 1, background = 1 }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key = a:match("^%-%-([%w]+)$")
    if a == "-h" or a == "--help" then io.write(USAGE) return 0
    elseif a == "-o" then file = argv[i + 1] i = i + 1
    elseif key and flags[key] then
      if flags[key] == true then o[key] = true else o[flags[key]] = false end
    elseif key and values[key] and argv[i + 1] then
      o[key] = argv[i + 1] i = i + 1
    else io.stderr:write("florilegium-svg.lua: unknown option " .. a .. "\n" .. USAGE) return 2 end
    i = i + 1
  end
  if o.paper and not PAPERS[o.paper] then
    local w, h = o.paper:match("^(%d+%.?%d*)x(%d+%.?%d*)$")
    if not w then io.stderr:write("florilegium-svg.lua: unknown paper " .. o.paper .. "\n") return 2 end
    o.paper = { w .. "mm", h .. "mm" }
  end
  local ok, svg, _, more = pcall(M.page, o)
  if not ok then io.stderr:write("florilegium-svg.lua: " .. tostring(svg) .. "\n") return 1 end
  if #more.captions > 0 then
    io.stderr:write(fmt("florilegium-svg.lua: %d equations and symbols need TeX and are left out (LuaLaTeX sets them; the playground uses MathJax)\n", #more.captions))
  end
  local f = file and assert(io.open(file, "w")) or io.stdout
  f:write(svg)
  if file then f:close() end
  return 0
end

-- run as a script: put this file's directory on the module path
if arg and arg[0] and arg[0]:match("florilegium%-svg%.lua$") and not package.loaded["florilegium-svg"] then
  local dir = arg[0]:match("^(.*)[/\\]") or "."
  package.path = dir .. "/?.lua;" .. package.path
  package.loaded["florilegium-svg"] = M
  os.exit(M.main(arg))
end

return M
