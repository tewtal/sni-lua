-- Regenerate examples/super_hitbox_sni.lua from the pristine Mesen2 script
-- + the compat prelude, applying the minimal LuaJIT-compat patch.
--
-- Run from the examples/ dir with any Lua 5.1+ / LuaJIT:
--   lua compat/build_super_hitbox.lua
--
-- We keep the original Super_Hitbox_*.lua untouched (source of truth) and
-- produce the runnable port as a build artifact, so re-syncing an upstream
-- update is just: drop in the new file, re-run this.

local SRC   = "Super_Hitbox_Mesen2_AnyG_route_assist_polished.lua"
local PRE   = "compat/mesen2_prelude.lua"
local OUT   = "super_hitbox_sni.lua"

local function slurp(p)
    local f = assert(io.open(p, "rb"))
    local s = f:read("*a"); f:close(); return s
end

local body = slurp(SRC)

-- The ONLY change to the script body: its xemu bit helpers (lines ~667-672)
-- use Lua 5.3+ operators (>> << | ~) that LuaJIT cannot parse. Every other
-- bit op in the 4500-line body already routes through these helpers, so
-- rewriting just these makes the whole script LuaJIT-clean. Match the exact
-- original lines so an upstream change here fails loudly instead of silently
-- mis-patching.
local patches = {
    {
        "xemu.rshift = function(x, y) return x >> y end",
        "xemu.rshift = function(x, y) return bit.rshift(x, y) end",
    },
    {
        "xemu.lshift = function(x, y) return x << y end",
        "xemu.lshift = function(x, y) return bit.lshift(x, y) end",
    },
    {
        "xemu.not_   = function(x) return ~x end",
        "xemu.not_   = function(x) return bit.bnot(x) end",
    },
    {
        "xemu.and_   = function(x, y) return x & y end",
        "xemu.and_   = function(x, y) return bit.band(x, y) end",
    },
    {
        "xemu.or_    = function(x, y) return x | y end",
        "xemu.or_    = function(x, y) return bit.bor(x, y) end",
    },
    {
        "xemu.xor    = function(x, y) return x ~ y end",
        "xemu.xor    = function(x, y) return bit.bxor(x, y) end",
    },
}

for _, p in ipairs(patches) do
    local from, to = p[1], p[2]
    local found
    body, found = body:gsub(from:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1"), to, 1)
    if found ~= 1 then
        error("patch target not found (upstream changed?): " .. from)
    end
end

local out = assert(io.open(OUT, "wb"))
out:write(slurp(PRE))
out:write("\n")
out:write(body)
out:close()
print("wrote " .. OUT)
