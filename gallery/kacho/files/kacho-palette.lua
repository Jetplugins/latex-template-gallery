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
-- kacho-palette.lua: kachō-e colour palettes (sumi ink-wash and hanga woodblock).
--
-- Portions adapted from florilegium (https://github.com/kevinraymond/florilegium),
-- florilegium-ink.lua (sRGB <-> Oklab conversion helpers).
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
--   * Oklab perceptual colour space and sRGB <-> Oklab conversion matrices
--     (M.to_oklab, M.from_oklab, M.mix, M.lighten, M.darken): Björn Ottosson,
--     "A perceptual color space for image processing", December 2020
--     (https://bottosson.github.io/posts/oklab/, public domain); Lua helpers
--     adapted from florilegium-ink.lua (Kevin Raymond, 2026, MIT).
--   * Traditional Japanese pigment & paper palette values (M.HEX, M.SUMI):
--     curated from classical kachō-e woodblock prints (Hiroshige, Hokusai,
--     Ohara Koson) and suibokuga five-tonalities of ink (墨五彩, bokugosai).
--
-- Colours are {r, g, b} tables in 0..1.
--
-- Usage:
--   local palette = require("kacho-palette")
--   local P = palette.get("sumi")        -- or "hanga"
--   P.color("momo")  -> {r,g,b}         (errors on unknown names: no silent black)
--   P.hex("momo")    -> "#E8A9B0"
--   P.ink(v)         -> {r,g,b}, alpha   v = 0 darkest (sumi-noir) .. 1 lightest (sumi-wash)
--   P.paper          -> {r,g,b} paper colour assumed under the art
--   P.role(name)     -> colour for a role: branch, twig, leaf, blossom, blossom_deep,
--                       stamen, accent, seal, wash, mist, rock, ground
--   palette.mix(c1, c2, t), palette.lighten(c, t), palette.darken(c, t)  (Oklab)
local M = {}

local floor = math.floor

---------------------------------------------------------------- colour table
-- name -> hex (survey_2 §4.1). Every name is unique across groups.
M.HEX = {
  -- paper / grounds
  ["washi"] = "#F3EEDC", ["kinu-celadon"] = "#E8E6D2", ["torinoko"] = "#EADFC8",
  ["koson-greige"] = "#C8BBA3", ["koson-greige-dark"] = "#B5A78E",
  -- sumi ink ramp
  ["sumi-noir"] = "#1E1C1A", ["sumi-dark"] = "#3A3733", ["sumi-mid"] = "#66625C",
  ["sumi-light"] = "#9A968F", ["sumi-wash"] = "#C9C5BC",
  -- pigments
  ["shu"] = "#C8382A", ["bengara"] = "#9E3D22", ["momo"] = "#E8A9B0",
  ["sakura-pale"] = "#F6DCDC", ["beni"] = "#B83A5E", ["ume-centre"] = "#C05A3C",
  ["kigaki"] = "#C9963F", ["yamabuki"] = "#E6A33A", ["kincha"] = "#B9822E",
  ["bokashi-sky"] = "#EDC062", ["bokashi-sky-horizon"] = "#F5EBD0",
  ["ai"] = "#2F4F6F", ["gunjo"] = "#4A6A9C", ["asagi"] = "#5D9AA0",
  ["fuji"] = "#9B8BC4", ["fuji-pale"] = "#CFC4E3", ["matsuba"] = "#4E6B3A",
  ["wakatake"] = "#6E9F5E", ["moegi"] = "#9DB86A", ["koke"] = "#8C9A6E",
  ["momiji"] = "#B5452E", ["kuri"] = "#6B4A32", ["gofun"] = "#FBF8F0",
  ["uguisu"] = "#8A8B4A", ["tsubame-navy"] = "#1F2A3A",
  -- ukiyo-e & kanga-e landscape / botanical pigments
  ["bero-ai"] = "#1B365D", ["bero-mid"] = "#2B5B84", ["bero-pale"] = "#5B8FA8",
  ["rokusho"] = "#2E6F5E", ["gunjo-deep"] = "#264E86", ["odo"] = "#C48A45",
  ["akebono-rose"] = "#E8A89A", ["nami-foam"] = "#F7F5EC",
  ["sakura-blush"] = "#F4C6C9", ["beni-crimson"] = "#C93B4B", ["ha-midori"] = "#3E6B48",
}
-- aliases (alternative spellings used in the survey)
M.ALIAS = { ["ochre"] = "odo", ["gunjō"] = "gunjo", ["vermilion"] = "shu", ["prussian-blue"] = "bero-ai" }

-- sumi ramp stops with alpha-over-paper equivalents (survey_2 §4.1)
M.SUMI = {
  { name = "sumi-noir", alpha = 0.95 }, { name = "sumi-dark", alpha = 0.80 },
  { name = "sumi-mid", alpha = 0.55 }, { name = "sumi-light", alpha = 0.35 },
  { name = "sumi-wash", alpha = 0.15 },
}

--- Sorted list of all colour names (deterministic order).
function M.names()
  local t = {}
  for k in pairs(M.HEX) do t[#t + 1] = k end
  table.sort(t)
  return t
end

function M.hex2rgb(h)
  h = tostring(h):gsub("^#", "")
  if not h:match("^%x%x%x%x%x%x$") then error("kacho-palette: bad hex colour '" .. tostring(h) .. "'", 2) end
  return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end
function M.rgb2hex(c)
  local function b(x) return floor(math.max(0, math.min(1, x)) * 255 + 0.5) end
  return string.format("#%02X%02X%02X", b(c[1]), b(c[2]), b(c[3]))
end

---------------------------------------------------------------- Oklab
local function srgb_dec(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function srgb_enc(c) return c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055 end
local function cbrt(x) return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3) end

function M.to_oklab(c)
  local r, g, b = srgb_dec(c[1]), srgb_dec(c[2]), srgb_dec(c[3])
  local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
         1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
         0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end
function M.from_oklab(L, A, B)
  local l = (L + 0.3963377774 * A + 0.2158037573 * B) ^ 3
  local m = (L - 0.1055613458 * A - 0.0638541728 * B) ^ 3
  local s = (L - 0.0894841775 * A - 1.2914855480 * B) ^ 3
  local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  local function c(x) return srgb_enc(math.min(1, math.max(0, x))) end
  return { c(r), c(g), c(b) }
end
--- Oklab lightness 0..1.
function M.lightness(c) return (M.to_oklab(c)) end

--- Perceptual mix of two colours (t=0 -> c1, t=1 -> c2).
function M.mix(c1, c2, t)
  local L1, A1, B1 = M.to_oklab(c1)
  local L2, A2, B2 = M.to_oklab(c2)
  return M.from_oklab(L1 + (L2 - L1) * t, A1 + (A2 - A1) * t, B1 + (B2 - B1) * t)
end
function M.lighten(c, t) return M.mix(c, { 1, 1, 1 }, t) end
function M.darken(c, t)
  local L, A, B = M.to_oklab(c)
  return M.from_oklab(L * (1 - t), A * (1 - t * 0.3), B * (1 - t * 0.3))
end

--- Suggested per-layer alpha for layered washes of colour c over paper:
--- visible step per layer stays around <=3% luminance (explorer_m1_1 §4.3).
function M.layer_alpha(c, paper)
  local dL = math.abs(M.lightness(paper or M.hex2rgb(M.HEX.washi)) - M.lightness(c))
  return math.max(0.015, math.min(0.06, 0.02 / math.max(0.3, dL)))
end

---------------------------------------------------------------- presets
local ROLES = {
  sumi = {
    branch = "sumi-dark", twig = "sumi-noir", leaf = "sumi-mid", blossom = "gofun",
    blossom_deep = "momo", stamen = "kigaki", accent = "kigaki", seal = "shu",
    wash = "sumi-wash", mist = "kinu-celadon", rock = "kigaki", ground = "washi",
  },
  hanga = {
    branch = "kuri", twig = "sumi-dark", leaf = "wakatake", blossom = "sakura-pale",
    blossom_deep = "momo", stamen = "ume-centre", accent = "yamabuki", seal = "shu",
    wash = "bokashi-sky", mist = "bokashi-sky-horizon", rock = "kincha", ground = "torinoko",
  },
}
local GROUNDS = { none = false, washi = "washi", kinu = "kinu-celadon", torinoko = "torinoko",
                  koson = "koson-greige" }

M.PRESETS = { "sumi", "hanga" }

local function resolve(name)
  name = M.ALIAS[name] or name
  local h = M.HEX[name]
  if not h then error("kacho-palette: unknown colour '" .. tostring(name) .. "'", 3) end
  return h
end

--- Ground colour name for a `ground` option value (nil for none); errors on unknown.
function M.ground(value)
  if value == nil or value == "" then return nil end
  local g = GROUNDS[value]
  if g == nil then
    if M.HEX[value] then return value end
    error("kacho-palette: unknown ground '" .. tostring(value) .. "'", 2)
  end
  return g or nil
end

--- Get palette table for a preset name ("sumi" or "hanga").
function M.get(name)
  name = name or "sumi"
  local roles = ROLES[name]
  if not roles then error("kacho-palette: unknown palette '" .. tostring(name) .. "' (use sumi or hanga)", 2) end
  local P = { name = name, style = name }
  local cache = {}
  function P.color(cname)
    local c = cache[cname]
    if not c then c = M.hex2rgb(resolve(cname)); cache[cname] = c end
    return { c[1], c[2], c[3] }
  end
  function P.hex(cname) return resolve(cname) end
  function P.has(cname) return M.HEX[M.ALIAS[cname] or cname] ~= nil end
  function P.role(r)
    local cname = roles[r]
    if not cname then error("kacho-palette: unknown role '" .. tostring(r) .. "'", 2) end
    return P.color(cname)
  end
  P.roles = roles
  P.paper = M.hex2rgb(name == "hanga" and M.HEX.torinoko or M.HEX.washi)
  --- Sumi ramp: v in [0,1], 0 = sumi-noir, 1 = sumi-wash. Returns colour and the
  --- alpha-over-paper equivalent (for painting diluted ink as transparency).
  function P.ink(v)
    v = math.max(0, math.min(1, v or 0))
    local x = v * (#M.SUMI - 1)
    local i = math.min(#M.SUMI - 2, floor(x))
    local t = x - i
    local a, b = M.SUMI[i + 1], M.SUMI[i + 2]
    local c = M.mix(P.color(a.name), P.color(b.name), t)
    return c, a.alpha + (b.alpha - a.alpha) * t
  end
  function P.mix(c1, c2, t) return M.mix(c1, c2, t) end
  return P
end

return M
