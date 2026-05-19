-- Assemble examples/super_hitbox_sni.lua from:
--   1. the sni-lua native adapter, PART 1   (compat/super_hitbox_adapter.lua)
--   2. the pristine upstream CONFIG block    (upstream lines 14..633)
--   3. the sni-lua native adapter, PART 2    (compat/super_hitbox_adapter_part2.lua)
--   4. the pristine upstream body            (upstream lines 843..1935 + 1971..end,
--                                             excising the permanently-dead
--                                             `emuId==bizhawk and false` block)
--
-- Run from the examples/ dir with any Lua 5.1+ / LuaJIT:
--   lua compat/build_super_hitbox.lua
--
-- NOTE ON SOURCE OF TRUTH:
--   super_hitbox_sni.lua is now a SINGLE hand-maintained file -- edit it (or
--   the two adapter parts) directly for day-to-day work. This script exists
--   only to (a) bootstrap that file and (b) re-sync a future upstream drop:
--   replace Super_Hitbox_*.lua, sanity-check the line markers below still
--   match, re-run. NO source patching is performed -- the adapter routes the
--   body's xemu bit helpers through bit.* itself, so LuaJIT parses the body
--   verbatim. If the markers no longer match an upstream change, this fails
--   loudly rather than mis-splicing.

local SRC      = "Super_Hitbox_Mesen2_AnyG_route_assist_polished.lua"
local PART1    = "compat/super_hitbox_adapter.lua"
local PART2    = "compat/super_hitbox_adapter_part2.lua"
local OUT      = "super_hitbox_sni.lua"

-- Upstream structural boundaries (1-based, inclusive). Sanity-checked below.
local CONFIG_FIRST, CONFIG_LAST = 14, 633     -- CONFIG header .. last `local USE_*`
local BODY_A_FIRST, BODY_A_LAST = 843, 1935   -- SM helper module .. before dead block
local DEAD_FIRST,   DEAD_LAST   = 1936, 1970  -- `-- Display CPU usage` .. its `end`
local BODY_B_FIRST              = 1971         -- resumes after dead block .. EOF

local function slurp(p)
    local f = assert(io.open(p, "rb"))
    local s = f:read("*a"); f:close(); return s
end

local function lines(s)
    local t = {}
    for ln in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = ln end
    -- gmatch on "...\n" leaves a trailing empty element; drop it.
    if t[#t] == "" then t[#t] = nil end
    return t
end

local function slice(t, a, b)
    local out = {}
    for k = a, b do out[#out + 1] = t[k] end
    return table.concat(out, "\n")
end

local src = lines(slurp(SRC))

-- Fail loudly if an upstream re-sync moved a boundary, instead of silently
-- splicing the wrong region.
local function expect(lineno, needle, what)
    local got = src[lineno] or ""
    if not got:find(needle, 1, true) then
        error(string.format(
            "splice marker moved (upstream changed?): line %d expected to contain %q (%s)\n  got: %s",
            lineno, needle, what, got))
    end
end

expect(CONFIG_FIRST, "====",                  "CONFIG block header")
expect(15,           "USER CONFIGURATION",    "CONFIG title")
expect(CONFIG_LAST,  "CONFIG.anyGlitchedAssist", "last CONFIG alias")
expect(BODY_A_FIRST, "----",                  "SM helper module header")
expect(DEAD_FIRST,   "Display CPU usage",     "dead CPU-profiling block start")
expect(DEAD_FIRST + 1, "emuId_bizhawk and false", "dead block guard")
expect(DEAD_LAST,    "end",                   "dead block end")
-- BODY_B_FIRST itself is blank (the dead block is followed by 2 blank lines
-- then this comment); assert on the first non-blank line that resumes.
expect(DEAD_LAST + 3, "door database",        "body resumes after dead block")

local out = assert(io.open(OUT, "wb"))
out:write(slurp(PART1));  out:write("\n")
out:write(slice(src, CONFIG_FIRST, CONFIG_LAST)); out:write("\n")
out:write(slurp(PART2));  out:write("\n")
out:write(slice(src, BODY_A_FIRST, BODY_A_LAST)); out:write("\n")
out:write(slice(src, BODY_B_FIRST, #src))
out:write("\n")
out:close()

print(string.format("wrote %s (adapter + CONFIG + body, dead block %d-%d excised)",
    OUT, DEAD_FIRST, DEAD_LAST))
