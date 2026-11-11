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
-- kacho-rng.lua: deterministic seeded random streams and 1-D noise for kacho.
--
-- Portions adapted from florilegium (https://github.com/kevinraymond/florilegium),
-- florilegium-ink.lua (mulberry32 stream, noise1, fbm1).
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
--   * Mulberry32 32-bit PRNG (r.next_u32): Tommy Ettinger (2017, public domain),
--     adapted via florilegium-ink.lua (Kevin Raymond, 2026, MIT).
--   * FNV-1a 32-bit string hash (M.hash): Glenn Fowler, Landon Curt Noll, and
--     Kiem-Phong Vo (1991, public domain), prime 0x01000193, offset 0x811C9DC5.
--   * Box-Muller normal variate (r.normal): G. E. P. Box and M. E. Muller,
--     "A Note on the Generation of Random Normal Deviates", Ann. Math. Statist.
--     29(2), pp. 610-611, 1958.
--   * 1-D gradient noise with cubic Hermite smoothstep 3f^2 - 2f^3 (M.noise1)
--     and octave fractal Brownian motion (M.fbm1): Ken Perlin, "An Image
--     Synthesizer", Proc. SIGGRAPH 85, pp. 287-296; adapted from florilegium.
--
-- Pure Lua 5.3 (integer ops); no TeX globals, usable under plain texlua.
--
-- Usage (all functions are plain fields, call with a dot: r.u(), not r:u()):
--   local rng = require("kacho-rng")
--   local r = rng.new(42)
--   r.u()            -- uniform [0,1)          (alias r.random)
--   r.range(a, b)    -- uniform [a,b)          (alias r.uniform)
--   r.sym(a)         -- uniform [-a,a)
--   r.int(a, b)      -- integer in [ceil(a), floor(b)] (non-integer bounds are rounded inward)
--   r.chance(p)      -- boolean, true with probability p
--   r.pick(t)        -- random element of array t
--   r.normal(mu, sd) -- gaussian (defaults 0, 1)
--   r.next_u32()     -- raw 32-bit output
--   r.fork(tag)      -- independent child; consumes exactly one parent draw
--   r.child(name)    -- order-independent child: depends only on the stream's
--                       initial seed and name (never on how many draws happened)
--   r.noise(oct)     -- smooth 1-D fbm function x -> v, |v| <= 1 (typically |v| < 0.6);
--                       total: non-finite x gives 0
--   rng.hash(str)    -- FNV-1a 32-bit
--   rng.page_seed(docseed, page)
local M = {}

local floor, sqrt, cos, log, pi = math.floor, math.sqrt, math.cos, math.log, math.pi
local MASK = 0xFFFFFFFF

local function imul(a, b) return (a * b) & MASK end

--- FNV-1a 32-bit hash of a string.
function M.hash(str)
  str = tostring(str)
  local h = 0x811C9DC5
  for i = 1, #str do h = ((h ~ str:byte(i)) * 0x01000193) & MASK end
  return h
end

local function to_u32(seed)
  local s = math.tointeger(seed)
  if not s then
    seed = tonumber(seed) or 0
    if seed ~= seed or seed == math.huge or seed == -math.huge then seed = 0 end
    s = floor(seed)
    s = math.tointeger(s) or 0
  end
  return s & MASK
end

--- Create a new stream from an integer seed (masked to 32 bits).
function M.new(seed)
  local s0 = to_u32(seed)
  local s = s0
  local r = { seed = s0 }
  function r.next_u32()
    s = (s + 0x6D2B79F5) & MASK
    local t = s
    t = imul(t ~ (t >> 15), t | 1)
    t = (t ~ (t + imul(t ~ (t >> 7), t | 61))) & MASK
    return (t ~ (t >> 14)) & MASK
  end
  function r.u() return r.next_u32() / 4294967296 end
  r.random = r.u
  function r.range(a, b) return a + (b - a) * r.u() end
  r.uniform = r.range
  function r.sym(a) return a * (2 * r.u() - 1) end
  function r.int(a, b)
    if b < a then a, b = b, a end
    -- integer bounds: [1.5, 2.5] -> {2}; always exactly one draw
    local lo, hi = math.ceil(a), floor(b)
    if hi < lo then hi = lo end
    local v = lo + floor((hi - lo + 1) * r.u())
    return math.tointeger(v) or v
  end
  function r.chance(p) return r.u() < p end
  function r.pick(t) return t[1 + floor(#t * r.u())] end
  function r.normal(mu, sd)
    local u1 = math.max(r.u(), 1e-12)
    local z = sqrt(-2 * log(u1)) * cos(2 * pi * r.u())
    return (mu or 0) + (sd or 1) * z
  end
  function r.fork(tag) return M.new(r.next_u32() ~ M.hash(tag or "")) end
  function r.child(name)
    return M.new(imul((s0 ~ M.hash(name)), 0x9E3779B1) ~ 0x5BD1E995)
  end
  function r.noise(oct) return M.fbm1(r, oct or 3) end
  return r
end

--- Page seed from document seed and physical page index.
function M.page_seed(docseed, page)
  return M.hash("page") ~ ((to_u32(docseed) * 7919 + to_u32(page) * 131) & MASK)
end

--- 1-D gradient noise with a seeded gradient table, smooth, |v| <= 1
--- (typical |v| < 0.6). Total: NaN/inf input returns 0.
function M.noise1(r)
  local g = {}
  for i = 0, 255 do g[i] = r.sym(1) end
  return function(x)
    if x ~= x or x == math.huge or x == -math.huge then return 0 end
    if x > 1e15 or x < -1e15 then x = math.fmod(x, 65536) end   -- keep floor(x) integral
    local i = floor(x); local f = x - i
    local a, b = g[i & 255] * f, g[(i + 1) & 255] * (f - 1)
    local u = f * f * (3 - 2 * f)
    return 2 * (a + (b - a) * u)
  end
end

--- Fractal sum of `oct` octaves of noise1 (double frequency, half amplitude).
function M.fbm1(r, oct)
  local ns = {}
  for k = 1, oct do ns[k] = M.noise1(r) end
  local norm = 0
  local a = 1
  for _ = 1, oct do norm = norm + a; a = a * 0.5 end
  return function(x)
    if x ~= x or x == math.huge or x == -math.huge then return 0 end
    local v, amp, f = 0, 1, 1
    for k = 1, oct do v = v + amp * ns[k](x * f + 17 * k); amp = amp * 0.5; f = f * 2 end
    return v / norm
  end
end

return M
