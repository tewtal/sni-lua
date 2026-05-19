-- =============================================================================
-- Super Hitbox -- sni-lua native adapter (PART 1 of 2: pre-CONFIG)
-- =============================================================================
-- super_hitbox_sni.lua is assembled as:
--     [PART 1: this]  ->  [verbatim upstream CONFIG block]  ->
--     [PART 2: draw + surface glue]  ->  [verbatim upstream body]
-- The two adapter parts are the ONLY non-upstream code. Everything from the
-- CONFIG block onward is pristine upstream, so an upstream re-sync is a clean
-- splice (drop in the new file, re-run the build).
--
-- WHY THIS EXISTS / WHAT IT REPLACES
--   The upstream script already abstracts every emulator touchpoint behind its
--   own `xemu` table (xemu.read_*/write_*/draw*). Earlier ports faked Mesen2's
--   entire `emu` API *underneath* that, so a value made a needless round trip:
--   a CPU address was un-mapped then re-mapped to FxPakPro, and a colour's
--   alpha was inverted then un-inverted -- two cancelling layers plus a second
--   cache. This adapter deletes all of that: `xemu` binds DIRECTLY to
--   sni-lua's `snes`/`gfx`, with one honest address map and one colour
--   conversion. It also provides the small *real* `emu`/`event` surface the
--   verbatim body still references directly.
--
-- THE ONE HARD PART -- bandwidth (kept, because it is essential):
--   Upstream reads synchronously thousands of times per frame at addresses
--   computed at runtime. sni-lua has no synchronous read -- the FXPAK is
--   latency-bound, so data is declared as watches and read from cached
--   snapshots. Bridge: a read-through cache. A read HIT returns the cached
--   byte (free). A MISS lazily registers a watch (the poll engine batches it
--   from the next cycle) and returns the last-known value (0 the first time).
--   Within a few frames every address the script touches is being batched.
--
-- Address mapping (SNES S-CPU address -> sni-lua memory region):
--   $7E0000-$7FFFFF / banks $7E,$7F   -> WRAM offset (addr - $7E0000)
--   LoROM mapped ROM                  -> linear FxPakPro ROM via snes2pc
--   banks >= $80                      -> mirror of the low banks
--   anything else (ARAM/SPC)          -> not served over SNI; reads as 0
--                                        (no upstream draw path consumes it)
-- =============================================================================

local ADAPTER_VERSION = "sni-native/1"

-- LuaJIT is Lua 5.1-based: no native >> << & | ~ (those are 5.3+). Use the
-- `bit` library. The upstream body routes its own bit ops through xemu.* which
-- we point at bit.* below, so the whole script stays LuaJIT-clean with NO
-- source patching (earlier ports had to gsub the body's xemu helpers).
local band, bor, bxor, bnot, lsh, rsh =
    bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift

-- ---- address mapping --------------------------------------------------------

local function snes2pc(p)
    -- LoROM CPU address -> unheadered linear ROM offset.
    return band(rsh(p, 1), 0x3F8000) + band(p, 0x7FFF)
end

-- Classify a 24-bit S-CPU address into ("wram", wram_offset) |
-- ("rom", fxpak_addr) | nil for spaces we don't serve over SNI.
local function classify(cpu_addr)
    local bank   = band(rsh(cpu_addr, 16), 0xFF)
    local off    = band(cpu_addr, 0xFFFF)
    local lobank = band(bank, 0x7F)
    if cpu_addr >= 0x7E0000 and cpu_addr <= 0x7FFFFF then
        return "wram", cpu_addr - 0x7E0000
    elseif bank == 0x7E or bank == 0x7F then
        return "wram", cpu_addr - 0x7E0000
    elseif lobank <= 0x3F and off >= 0x8000 then
        return "rom", snes2pc(cpu_addr)
    elseif lobank >= 0x40 and lobank <= 0x7D then
        return "rom", snes2pc(cpu_addr)
    elseif bank >= 0x80 then
        return classify(band(cpu_addr, 0x7FFFFF))
    end
    return nil
end

-- ---- tiered auto-classification ---------------------------------------------
--
-- Every address the script touches is auto-assigned a poll tier so the script
-- renders at full rate from cache while the engine streams fresh data in by
-- priority. An explicit xemu.tier() hint always wins (the engine only ever
-- raises urgency, never lowers it).
--
--   realtime : controller + viewport origins + frame clock. Tiny,
--              latency-critical -> the poll engine's dedicated sub-poll.
--   high     : Samus/camera/sprite/enemy WRAM that moves every frame.
--   normal   : slower WRAM (HUD-ish values).
--   low      : level/block/room tables + ROM. Large, slow-changing;
--              prefetched in the background, always served from cache.

local function is_controller(off)        -- $7E:008B held, $7E:008F newly-pressed
    return off == 0x008B or off == 0x008C
        or off == 0x008F or off == 0x0090
end

local function is_realtime(off)
    return (off >= 0x00B0 and off <= 0x00BB)   -- BG scroll mirrors
        or (off >= 0x0998 and off <= 0x0999)   -- game mode (pause/unpause)
        or (off >= 0x0911 and off <= 0x0916)   -- layer 1 camera X/Y
        or (off >= 0x0AF6 and off <= 0x0AFB)   -- Samus X/Y (centered view)
        or (off >= 0x05B8 and off <= 0x05BB)   -- NMI frame counter (emu.framecount)
end

local function is_high_volatility(off)
    return (off >= 0x0911 and off <= 0x0B0F)   -- Samus pos/vel/pose/hitbox
        or (off >= 0x0D00 and off <= 0x1FFF)   -- sprite/enemy/projectile tbls
        or (off >= 0x0790 and off <= 0x07BF)   -- room/scroll pointers (read hot)
end

local function default_tier(kind, off)
    if kind == "rom" then return "low" end
    if is_controller(off) then return "realtime" end
    if is_realtime(off) then return "realtime" end
    if is_high_volatility(off) then return "high" end
    return "normal"
end

local PRIORITY_RANK = { low = 1, normal = 2, high = 3, realtime = 4 }

local function stronger(current, requested)
    if requested == nil then return current end
    if current == nil then return requested end
    if (PRIORITY_RANK[requested] or 0) > (PRIORITY_RANK[current] or 0) then
        return requested
    end
    return current
end

-- ---- read-through cache over sni-lua watches --------------------------------

-- Keep separate 1-byte and 2-byte watches. The runtime publishes a watched
-- u16 atomically from one snapshot; stitching two independently refreshed
-- bytes can make edge-sensitive inputs (controller) flap.
local _watch = { [1] = {}, [2] = {} }  -- size -> (key -> watch id)
local _byte  = {}                      -- key -> last known byte
local _word  = {}                      -- key -> last known u16
local _hint  = {}                      -- key -> strongest requested tier

-- A stable cache key per (kind, addr): WRAM keyed by offset, ROM by fxpak
-- addr + a high bit so the two address spaces never collide.
local function keyof(kind, addr)
    if kind == "rom" then return addr + 0x1000000 end
    return addr
end

local function register(kind, addr, size, prio)
    local key = keyof(kind, addr)
    local w = _watch[size][key]
    if w == nil then
        local p = prio
        if p == nil then
            p = default_tier(kind, kind == "wram" and addr or 0)
            for k = 0, size - 1 do
                p = stronger(p, _hint[keyof(kind, addr + k)])
            end
        end
        if kind == "wram" then
            w = snes.watch(addr, size, p)            -- WRAM offset form
        else
            w = snes.watch_abs(addr, size, p)        -- raw FxPakPro addr (ROM)
        end
        _watch[size][key] = w
    elseif prio ~= nil then
        snes.tier(w, prio)
    end
    return w
end

local function cached_byte(kind, addr)
    local key = keyof(kind, addr)
    local w = _watch[1][key] or register(kind, addr, 1)
    local b = snes.u8(w)
    if b ~= nil then
        b = band(b, 0xFF)
        _byte[key] = b
        return b
    end
    return _byte[key] or 0
end

local function cached_u16(kind, addr)
    local key = keyof(kind, addr)
    local w = _watch[2][key] or register(kind, addr, 2)
    local v = snes.u16(w)
    if v ~= nil then
        _word[key] = v
        return v
    end
    if _word[key] ~= nil then return _word[key] end
    -- Reuse warmed byte caches until the native u16 watch has a snapshot.
    return cached_byte(kind, addr) + cached_byte(kind, addr + 1) * 256
end

local function invalidate_words(kind, addr, size)
    for a = addr - 1, addr + size - 1 do
        if a >= 0 then _word[keyof(kind, a)] = nil end
    end
end

-- ---- the xemu read/write/bit surface ----------------------------------------

xemu = {}

xemu.emuId_bizhawk = 0
xemu.emuId_snes9x  = 1
xemu.emuId_lsnes   = 2
xemu.emuId_mesen   = 3
xemu.emuId_mesen2  = 4
-- The upstream tail dispatch branches on this. emuId_mesen selects the
-- addEventCallback path, which we drive from on_frame.
xemu.emuId = xemu.emuId_mesen

xemu.rshift = function(x, y) return rsh(x, y) end
xemu.lshift = function(x, y) return lsh(x, y) end
xemu.not_   = function(x)    return bnot(x)   end
xemu.and_   = function(x, y) return band(x, y) end
xemu.or_    = function(x, y) return bor(x, y)  end
xemu.xor    = function(x, y) return bxor(x, y) end

local function read_n(cpu_addr, n, signed)
    local kind, addr = classify(cpu_addr)
    if kind == nil then return 0 end  -- ARAM/SPC: benign zero
    local v
    if n == 2 then
        v = cached_u16(kind, addr)
        if signed and v >= 0x8000 then v = v - 0x10000 end
    else
        v = cached_byte(kind, addr)
        if signed and v >= 0x80 then v = v - 0x100 end
    end
    return v
end

xemu.read_u8     = function(p) return read_n(p, 1, false) end
xemu.read_u16_le = function(p) return read_n(p, 2, false) end
xemu.read_s8     = function(p) return read_n(p, 1, true)  end
xemu.read_s16_le = function(p) return read_n(p, 2, true)  end

-- The body's bank-wrapped readers (makeBankWrappedReader, kept verbatim) call
-- these two as free globals. Upstream defined them in its glue zone delegating
-- to emu.read(...,snesDebug,...); ours delegate straight to read_n.
function readCpu8(p, signed)  return read_n(p, 1, signed or false) end
function readCpu16(p, signed) return read_n(p, 2, signed or false) end

-- ARAM/SPC isn't bandwidth-friendly over SNI and no draw path consumes it
-- (the upstream sound-engine readers are defined but never called). Serve 0.
xemu.read_aram_u8     = function() return 0 end
xemu.read_aram_u16_le = function() return 0 end
xemu.read_aram_s8     = function() return 0 end
xemu.read_aram_s16_le = function() return 0 end

-- Writes are fire-and-forget on the SNI actor (never block the frame). Only
-- WRAM is honored. The upstream writers pass a bank-masked offset relative to
-- $7E0000 (& 0x1FFFF) -- already a raw WRAM offset.
local function write_wram(off, value, size)
    off = band(off, 0x1FFFF)
    snes.write(0xF50000 + off, value, size)
    if size == 2 then
        _byte[off]     = band(value, 0xFF)
        _byte[off + 1] = band(rsh(value, 8), 0xFF)
        invalidate_words("wram", off, 2)
        _word[off]     = band(value, 0xFFFF)
    else
        _byte[off] = band(value, 0xFF)
        invalidate_words("wram", off, 1)
    end
end

xemu.write_u8     = function(off, v) write_wram(off, band(v, 0xFF), 1) end
xemu.write_u16_le = function(off, v) write_wram(off, band(v, 0xFFFF), 2) end

-- xemu.tier(cpuAddr, class): force a poll tier on an address. Used by on_init
-- to pin controller/camera/frame-clock into the realtime sub-poll from cycle
-- 1; also exposed for the body to opt into.
local function tier_cpu(cpu_addr, class, size)
    local kind, addr = classify(cpu_addr)
    if kind == nil then return end
    size = size or 1
    for k = 0, size - 1 do
        local kk = keyof(kind, addr + k)
        _hint[kk] = stronger(_hint[kk], class)
    end
    local w = register(kind, addr, size, class)
    snes.tier(w, class)
    -- A u16 watch starting one byte earlier overlaps this address too.
    local prev = _watch[2][keyof(kind, addr - 1)]
    if prev ~= nil then snes.tier(prev, class) end
end
xemu.tier = function(cpu_addr, class) tier_cpu(cpu_addr, class, 1) end

-- ---- minimal real `emu` / `event` the verbatim body calls directly ----------
--
-- These are the ONLY symbols the upstream body uses outside its xemu table
-- (audited: framecount, displayMessage/log, drawRectangle, clearScreen,
-- getState, addEventCallback + the event.* the never-taken non-Mesen tail
-- branches reference). Each gets a direct sni-lua-native implementation; we do
-- NOT fake the rest of the Mesen2 API.

emu = {}

-- The body indexes emu.memType for opaque memory-type tokens it only ever
-- compares by identity; any stable value works since our address map (not the
-- token) decides WRAM vs ROM.
emu.memType = setmetatable({}, { __index = function() return "snes" end })
emu.eventType   = { nmi = "nmi", startFrame = "startFrame", endFrame = "endFrame" }

function emu.getState() return { consoleType = "Snes" } end
function emu.log(msg) print(tostring(msg)) end
function emu.displayMessage(_cat, msg) print(tostring(msg)) end
-- sni-lua clears the canvas every frame, so a one-time clear is a no-op.
function emu.clearScreen() end

-- emu.framecount(): the CONSOLE's NMI frame clock, NOT our render loop. Over
-- SNI we are a latency-bound observer and cannot see every console frame; a
-- self-incremented render tick would drift vs the console and break the
-- body's frame-delta math (its hotkey edge-detector keys off this). SM bumps
-- a 32-bit NMI counter at $7E:05B8 (lo) / $05BA (hi) every NMI regardless of
-- pause/door/menu -- monotonic and console-paced. on_init pins it realtime so
-- it tracks as tightly as the link allows. The 32-bit form won't wrap for
-- ~828 days, so long sessions never see the 16-bit (~18 min) rollover corrupt
-- a delta.
local FRAMECOUNT_FALLBACK = 0
function emu.framecount()
    local lo = read_n(0x7E05B8, 2, false)
    local hi = read_n(0x7E05BA, 2, false)
    local v = hi * 0x10000 + lo
    if v == 0 then return FRAMECOUNT_FALLBACK end  -- cache cold / pre-connect
    return v
end

-- The body's tail dispatch calls emu.addEventCallback(on_paint, nmi) on the
-- Mesen branch; capture it and pump from on_frame. The bizhawk/snes9x
-- branches are never taken (emuId == emuId_mesen) but `event` must exist as a
-- table for that elseif chain to parse.
local _paint_cb = nil
function emu.addEventCallback(cb, _evt) _paint_cb = cb end
function emu.removeEventCallback() _paint_cb = nil end
function emu.frameadvance() end

event = {
    unregisterbyname = function() end,
    onframestart     = function() end,
}

-- ---- sni-lua lifecycle ------------------------------------------------------

function on_init()
    print("Super Hitbox running via " .. ADAPTER_VERSION .. " (sni-lua native)")

    -- Pin controller + game-mode mirrors to the realtime sub-poll from cycle 1
    -- so input and pause/unpause timing aren't queued behind block data.
    tier_cpu(0x7E008B, "realtime", 2)   -- held buttons
    tier_cpu(0x7E008F, "realtime", 2)   -- newly-pressed
    tier_cpu(0x7E0998, "realtime", 2)   -- game mode

    -- SM NMI frame counter -> realtime so emu.framecount() tracks the
    -- console clock as tightly as the link allows.
    tier_cpu(0x7E05B8, "realtime", 2)
    tier_cpu(0x7E05BA, "realtime", 2)

    -- Block/hitbox grid origin = Samus position (centered/follow) or layer-1
    -- camera (normal). Keep both paths realtime so it scrolls smoothly.
    for a = 0x7E00B0, 0x7E00BB do tier_cpu(a, "realtime") end  -- BG scroll
    for a = 0x7E0911, 0x7E0916 do tier_cpu(a, "realtime") end  -- camera X/Y
    for a = 0x7E0AF6, 0x7E0AFB do tier_cpu(a, "realtime") end  -- Samus X/Y

    print("controller @ realtime ($7E:008B/$008F), frame clock = NMI $7E:05B8")
    print("grid origin = camera/Samus @ realtime; rendering full-rate from cache")
end

function on_frame()
    FRAMECOUNT_FALLBACK = FRAMECOUNT_FALLBACK + 1  -- pre-connect only
    if _paint_cb then _paint_cb() end
end

-- PART 2 (draw layer + draw-surface selection) is spliced in AFTER the
-- upstream CONFIG block, since it reads CONFIG (Samus-centered scale,
-- y-offset, view mode). It uses the globals `xemu` and `emu` defined above.
