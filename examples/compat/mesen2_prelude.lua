-- =============================================================================
-- Mesen2 -> sni-lua compatibility prelude
-- =============================================================================
-- This defines a fake `emu` table (Mesen2's Lua API surface) backed by
-- sni-lua's async snes/gfx API, so an UNMODIFIED Mesen2 SNES script can run
-- on top of the SNI/USB2SNES pipeline.
--
-- THE HARD PART: bandwidth.
--   Mesen2's emu.read(addr,...) is synchronous & instant -- it reads emulator
--   RAM directly, thousands of times per frame, at addresses computed at
--   runtime. sni-lua has NO synchronous read by design: the FXPAK is
--   latency-bound, so scripts must declare watches and read cached snapshots.
--
--   Bridge: a read-through cache. emu.read(addr) checks a persistent cache.
--   HIT  -> return the cached byte (free, no round trip).
--   MISS -> lazily register a watch for that address (so the poll engine
--           batches it from next cycle on) and return the last-known value
--           (0 the very first time). Within a few frames every address the
--           script actually touches is being batched automatically. The
--           script's synchronous-looking code "just works" on the async
--           model -- this is exactly the bandwidth-hiding the app is built
--           for, applied transparently to a foreign script.
--
-- Address mapping (Mesen S-CPU debug space -> sni-lua FxPakPro space):
--   $7E0000-$7FFFFF  WRAM   -> FxPakPro $F50000 + (addr-$7E0000)
--   ROM (LoROM)             -> FxPakPro linear ROM via snes2pc
--   ARAM/SPC                -> not bandwidth-friendly over SNI; served as 0
--                              (the hitbox/route logic doesn't need it).
-- =============================================================================

local PRELUDE_VERSION = "mesen2-compat/1"

-- ---- low-level: cached byte access over sni-lua watches ----------------------

-- One watch per touched address-region. We register byte-granular watches and
-- let the poll engine's coalescer fuse adjacent ones into batched MultiReads,
-- so this stays efficient even though the script asks byte-by-byte.
local _watch_of = {}          -- fxpak addr -> watch id
local _byte_cache = {}        -- fxpak addr -> last known byte (0..255)

-- LuaJIT is Lua 5.1-based: NO native >> << & | ~ operators (those are 5.3+).
-- It ships the `bit` library instead; use it everywhere here. (The original
-- script body routes its own bit ops through xemu.* helpers, which the
-- splicer rewrites to bit.* for the same reason.)
local band, bor, rsh, lsh =
    bit.band, bit.bor, bit.rshift, bit.lshift

local function snes2pc(p)
    -- LoROM CPU address -> unheadered ROM offset (FxPakPro ROM is linear).
    return band(rsh(p, 1), 0x3F8000) + band(p, 0x7FFF)
end

-- Translate a Mesen S-CPU debug address to an sni-lua FxPakPro address,
-- or return nil for spaces we deliberately don't serve over SNI.
local function to_fxpak(cpu_addr)
    local bank = band(rsh(cpu_addr, 16), 0xFF)
    local off  = band(cpu_addr, 0xFFFF)
    local lobank = band(bank, 0x7F)
    if cpu_addr >= 0x7E0000 and cpu_addr <= 0x7FFFFF then
        -- WRAM linear window.
        return 0xF50000 + (cpu_addr - 0x7E0000)
    elseif (bank == 0x7E or bank == 0x7F) then
        return 0xF50000 + (cpu_addr - 0x7E0000)
    elseif lobank <= 0x3F and off >= 0x8000 then
        -- LoROM mapped ROM.
        return snes2pc(cpu_addr)
    elseif lobank >= 0x40 and lobank <= 0x7D then
        -- LoROM upper ROM banks.
        return snes2pc(cpu_addr)
    elseif bank >= 0x80 then
        -- Mirror of the low banks.
        return to_fxpak(band(cpu_addr, 0x7FFFFF))
    end
    return nil
end

-- Priority heuristic: WRAM moves every frame -> high; ROM is static -> low
-- (registered once, rarely re-read by the poll engine, but always cached).
local function priority_for(fxpak)
    if fxpak >= 0xF50000 and fxpak <= 0xF6FFFF then
        return "high"
    end
    return "low"
end

local function cached_byte(fxpak)
    local v = _byte_cache[fxpak]
    if v ~= nil then
        -- Refresh from the latest snapshot if the watch has produced data.
        local w = _watch_of[fxpak]
        if w then
            local b = snes.u8(w)
            if b ~= nil then
                _byte_cache[fxpak] = b
                return b
            end
        end
        return v
    end
    -- First touch: register a 1-byte watch (coalesced by the engine) and
    -- return 0 until the poll loop fills it in (usually within ~1-2 frames).
    local w = _watch_of[fxpak]
    if w == nil then
        w = snes.watch_abs(fxpak, 1, priority_for(fxpak))
        _watch_of[fxpak] = w
    end
    local b = snes.u8(w)
    b = b or 0
    _byte_cache[fxpak] = b
    return b
end

-- Read 1 or 2 bytes (little-endian) with optional sign extension.
local function read_n(cpu_addr, n, signed)
    local fx = to_fxpak(cpu_addr)
    if fx == nil then
        return 0 -- unmapped (e.g. ARAM) -> benign zero
    end
    local lo = cached_byte(fx)
    local val
    if n == 2 then
        local hi = cached_byte(fx + 1)
        val = lo + hi * 256
        if signed and val >= 0x8000 then val = val - 0x10000 end
    else
        val = lo
        if signed and val >= 0x80 then val = val - 0x100 end
    end
    return val
end

-- ---- fake `emu` table : Mesen2 API surface ----------------------------------

emu = {}

-- Memory type tokens. The script only switches on identity, so opaque
-- sentinels are fine; our read()/write() ignore the type and use the
-- address mapping above (which already distinguishes WRAM vs ROM).
emu.memType = {
    snesMemory   = "snesMemory",
    snesDebug    = "snesDebug",
    snesWorkRam  = "snesWorkRam",
    workRam      = "workRam",
    snesPrgRom   = "snesPrgRom",
    prgRom       = "prgRom",
    spcRam       = "spcRam",
    spcMemory    = "spcMemory",
}

emu.eventType = { nmi = "nmi", startFrame = "startFrame", endFrame = "endFrame" }

emu.emuId_bizhawk = 0
emu.emuId_snes9x  = 1
emu.emuId_lsnes   = 2
emu.emuId_mesen   = 3
emu.emuId_mesen2  = 4

function emu.getState()
    -- Enough for the script's SNES-core guard.
    return { consoleType = "Snes" }
end

function emu.read(addr, _memType, signed)
    return read_n(addr, 1, signed or false)
end

function emu.read16(addr, _memType, signed)
    return read_n(addr, 2, signed or false)
end

-- Writes go through sni-lua's fire-and-forget snes.write (queued on the SNI
-- actor; never blocks the frame). Only WRAM writes are honored.
function emu.write(addr, value, _memType)
    local fx = to_fxpak(addr)
    if fx and fx >= 0xF50000 and fx <= 0xF6FFFF then
        local b = band(value, 0xFF)
        snes.write(fx, b, 1)
        _byte_cache[fx] = b
    end
end

function emu.write16(addr, value, _memType)
    local fx = to_fxpak(addr)
    if fx and fx >= 0xF50000 and fx <= 0xF6FFFF then
        snes.write(fx, band(value, 0xFFFF), 2)
        _byte_cache[fx]     = band(value, 0xFF)
        _byte_cache[fx + 1] = band(rsh(value, 8), 0xFF)
    end
end

emu.framecount_n = 0
function emu.framecount() return emu.framecount_n end

function emu.log(msg) print(tostring(msg)) end
function emu.displayMessage(_cat, msg) print(tostring(msg)) end

-- Draw-surface API is a no-op here: sni-lua has one overlay canvas. The
-- script's surface selection just falls back to default behaviour.
emu.drawSurface = nil
function emu.selectDrawSurface() end
function emu.getDrawSurfaceSize() return nil end
function emu.getScreenSize() return { width = 256, height = 224 } end

-- Mesen draw colours are 0xAARRGGBB. sni-lua's gfx.* also take 0xAARRGGBB
-- (gfx.argb / Color::from_argb), so colours pass straight through. Mesen's
-- "filled" boolean for rectangles maps to gfx.box's fill arg.
local function argb(c)
    if c == nil then return nil end
    return band(c, 0xFFFFFFFF)
end

function emu.drawPixel(x, y, color, _alpha)
    gfx.pixel(x, y, argb(color))
end

function emu.drawLine(x0, y0, x1, y1, color, _alpha)
    gfx.line(x0, y0, x1, y1, argb(color), 1.0)
end

function emu.drawRectangle(x, y, w, h, color, filled, _alpha)
    local c = argb(color)
    if filled then
        gfx.box(x, y, w, h, c, c, 1.0)      -- outline + fill same colour
    else
        gfx.box(x, y, w, h, c, nil, 1.0)    -- outline only
    end
end

function emu.drawString(x, y, text, color, _bgColor, _maxWidth, _scale)
    -- Background colour is dropped (sni-lua text has no per-call bg); the
    -- script already draws its own backing boxes for panels.
    gfx.text(x, y, tostring(text), argb(color))
end

-- Frame dispatch: the script calls emu.addEventCallback(on_paint, nmi) at the
-- end. We capture that callback and drive it from sni-lua's on_frame.
local _paint_cb = nil
function emu.addEventCallback(cb, _evt) _paint_cb = cb end
function emu.removeEventCallback() _paint_cb = nil end

-- Some scripts also reference these globals (BizHawk/snes9x paths). Stub them
-- so the dispatch tail's branches don't error even though we use the Mesen
-- branch.
event = { unregisterbyname = function() end, onframestart = function() end }
console = { log = function(m) print(tostring(m)) end }

-- sni-lua lifecycle. The original script body (appended after this prelude)
-- runs at load: it builds everything and calls emu.addEventCallback(on_paint).
-- We then pump that callback every frame.
function on_init()
    print("Super Hitbox running via " .. PRELUDE_VERSION ..
          " (Mesen2 compat over SNI)")
    print("First frames may be blank while watches populate the cache.")
end

function on_frame()
    emu.framecount_n = emu.framecount_n + 1
    if _paint_cb then
        _paint_cb()
    end
end

-- =============================================================================
-- Original Super Hitbox script body follows (unmodified).
-- =============================================================================
