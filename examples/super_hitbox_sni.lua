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
        or (off >= 0x05B8 and off <= 0x05B9)   -- NMI frame counter (emu.framecount)
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

local function cached_age(kind, addr, size)
    local key = keyof(kind, addr)
    local w = _watch[size][key] or register(kind, addr, size)
    return snes.age(w)
end

local function read_age(cpu_addr, size)
    size = size or 1
    local kind, addr = classify(cpu_addr)
    if kind == nil then return nil end
    return cached_age(kind, addr, size)
end

local function read_valid(cpu_addr, size, max_age)
    local age = read_age(cpu_addr, size or 1)
    if age == nil then return false, nil end
    if max_age ~= nil and age > max_age then return false, age end
    return true, age
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
xemu.read_age    = function(p, size) return read_age(p, size or 1) end
xemu.read_valid  = function(p, size, max_age) return read_valid(p, size or 1, max_age) end

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
xemu.tier_size = function(cpu_addr, class, size) tier_cpu(cpu_addr, class, size or 1) end

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
-- body's frame-delta math. SM exposes a 16-bit NMI counter at $7E:05B8; the
-- following words are lag counters, not a high word. Extend $05B8 locally and
-- keep it monotonic across both rollovers and soft resets.
local FRAMECOUNT_FALLBACK = 0
local FRAMECOUNT_LAST_RAW = nil
local FRAMECOUNT_BASE = 0
local FRAMECOUNT_LAST = 0
function emu.framecount()
    if not read_valid(0x7E05B8, 2) then
        return FRAMECOUNT_FALLBACK
    end

    local raw = read_n(0x7E05B8, 2, false)
    if FRAMECOUNT_LAST_RAW ~= nil and raw < FRAMECOUNT_LAST_RAW then
        if FRAMECOUNT_LAST_RAW - raw > 0x8000 then
            FRAMECOUNT_BASE = FRAMECOUNT_BASE + 0x10000
        else
            FRAMECOUNT_BASE = FRAMECOUNT_LAST - raw + 1
        end
    end

    FRAMECOUNT_LAST_RAW = raw
    FRAMECOUNT_LAST = FRAMECOUNT_BASE + raw
    return FRAMECOUNT_LAST
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

-- =============================================================================
-- USER CONFIGURATION - edit this section first
-- =============================================================================
-- UI background colours use normal 0xRRGGBBAA alpha here.
-- 0xFF is opaque; lower values are more transparent.
local UI_PANEL_BACKGROUND = 0x00000088      -- filled boxes behind panels
local UI_TEXT_BACKGROUND  = 0x000000A8      -- per-line text backing
local UI_LABEL_BACKGROUND = 0x00000088      -- tiny labels over blocks

local CONFIG = {
    -- General Mesen drawing options.
    drawing = {
        useScriptHud = false,
        mesenYOffset = 7,

        -- Mesen/Mesen2 draw APIs commonly use inverted alpha:
        -- 0x00RRGGBB is opaque and 0xFFRRGGBB is transparent.
        -- Leave true unless your local build behaves like normal ARGB.
        mesenDrawAlphaInverted = true,
    },

    -- Samus-centered high-resolution block viewer.
    -- Uses scriptHud so scale 2/3/4 draws a larger world-space area around Samus.
    samusCenteredBlockView = {
        enabled = false,
        visibleByDefault = true, -- Select+B+L+R toggles only the block/world viewer layer.
        scale = 3, -- 1..4. 4 shows the most blocks around Samus.
        drawScrolls = true,
        drawFx = true,
        drawHitboxes = false,
        drawStatusText = true,
    },



    -- Any% Glitched route assist mode.
    -- Based on the public sm_anyglitched route notes. Everything here is optional;
    -- turn sections off if you only want the generic block viewer.
    anyGlitchedAssist = {
        enabled = true,

        -- Top-level displays.
        showRamDashboard = true,
        showRouteBlockHighlights = true,
        show0380Helper = true,
        showPlmCount = true,
        showFreezeTimer = true,
        showWarnings = true,
        showInputWarnings = true,
        showPracticeWaypoints = true,

        -- Dashboard placement. Uses the current draw surface coordinates.
        dashboard = {
            x = 4,
            y = 32,
            lineHeight = 8,
            background = UI_TEXT_BACKGROUND,
            panelFill = UI_PANEL_BACKGROUND,
            normalColour = "white",
            okColour = "green",
            warnColour = "yellow",
            badColour = "red",

            -- Compact mode removes repeated checklist-style rows and shows only:
            --   route readiness summary, $0026/$0380, PLM count, and freeze result.
            -- Set compact = false if you want the older verbose address-by-address panel.
            compact = true,
            showAddressDetails = true,
            showPlmAndFreeze = true,
            maxLines = 10,
        },

        warnings = {
            x = 4,
            yFromBottom = 72,
            lineHeight = 8,
            framesToShow = 360,
            maxMessages = 8,
            background = UI_TEXT_BACKGROUND,
        },

        -- Important block highlighting in the Samus-centered block view.
        -- These are deliberately route/category concepts, not only block type/BTS labels.
        blockHighlights = {
            drawLabels = true,
            drawBoxes = true,

            -- These were the +/- labels shown next to highlighted blocks/doors.
            -- They are world-space distance from Samus in blocks, useful for navigation
            -- but noisy while learning, so they are off by default.
            drawDistanceWhenVisible = false,
            drawLineToSamus = true,
            labelRenderer = "mini",
            miniFont = { pixelSize = 1, charSpacing = 1, drawBackground = true, backgroundPadding = 1 },

            rules = {
                {
                    enabled = true,
                    name = "Gold Block",
                    short = "GOLD",
                    blockTypes = { [0x0F] = true, [0x07] = true },
                    btsValues = { [0x5D] = true },
                    colour = "yellow",
                    background = UI_LABEL_BACKGROUND,
                    note = "$0380 item/PLM touch",
                },
                {
                    -- Candidate door transition back toward Landing Site / ship area.
                    -- I could not verify 01/81 from the public route notes, so this is configurable.
                    -- Both 01 and 81 are included because Super Metroid door BTS commonly uses bit 7
                    -- as a variant/flag while the low 7 bits select the door list entry.
                    enabled = true,
                    name = "Ship/Landing door candidate",
                    short = "SHIP",
                    blockTypes = { [0x09] = true },
                    btsValues = { [0x01] = true, [0x81] = true },
                    colour = "cyan",
                    background = UI_LABEL_BACKGROUND,
                    note = "candidate transition toward ship/Landing Site",
                },
                {
                    enabled = true,
                    name = "Door Shell PLM",
                    short = "+PLM",
                    blockTypes = { [0x0F] = true, [0x07] = true },
                    btsValues = { [0x14] = true, [0x54] = true, [0x6F] = true },
                    colour = "green",
                    background = UI_LABEL_BACKGROUND,
                    note = "door-shell PLM spawner",
                },
                {
                    enabled = true,
                    name = "God Block",
                    short = "44",
                    blockTypes = { [0x0F] = true, [0x07] = true },
                    btsValues = { [0x44] = true },
                    colour = "orange",
                    background = UI_LABEL_BACKGROUND,
                    note = "glitched PLM/item block",
                },
                {
                    enabled = true,
                    name = "Save-ish PLM",
                    short = "RISK",
                    blockTypes = { [0x0F] = true, [0x07] = true },
                    btsValues = { [0x32] = true },
                    colour = "red",
                    background = UI_LABEL_BACKGROUND,
                    note = "risky save-station-like PLM",
                },
                {
                    -- Door blocks can be useful later, but highlighting every door-like
                    -- block is noisy. Set enabled = true when actively scanning doors.
                    enabled = false,
                    name = "Door / transition",
                    short = "DOOR",
                    blockTypes = { [0x09] = true },
                    colour = "cyan",
                    background = UI_LABEL_BACKGROUND,
                    note = "possible transition/OOB door value",
                },
                {
                    -- Block Shuffler marker. Keep this rule here so it is easy to enable
                    -- once you confirm the Shuffler's BT/BTS in your current setup.
                    -- Example after confirmation: btsValues = { [0x??] = true }, enabled = true
                    enabled = true,
                    name = "Block Shuffler",
                    short = "SHUF",
                    blockTypes = { [0x0F] = true, [0x07] = true },
                    btsValues = { [0x1C] = true },
                    colour = "magenta",
                    background = UI_LABEL_BACKGROUND,
                    note = "custom shuffler marker",
                },
            },
        },

        -- Route RAM targets from the public Any% Glitched notes.
        -- BT source values are checked by high nibble: F_ or 7_ means the generated BT can be 0F/07.
        routeTargets = {
            {
                key = "5D-left",
                name = "5D-left / X-ray",
                btAddress = 0x7E11FD,
                btsAddress = 0x7E1D59,
                goodBtHighNibbles = { [0xF] = true, [0x7] = true },
                goodBtsValues = { [0x5D] = true },
                use = "X-ray pickup",
            },
            {
                key = "5D-right",
                name = "5D-right / +1",
                btAddress = 0x7E1201,
                btsAddress = 0x7E1D5B,
                goodBtHighNibbles = { [0xF] = true, [0x7] = true },
                goodBtsValues = { [0x5D] = true },
                use = "+1 PLM",
            },
            {
                key = "6F-layer",
                name = "6F-layer / +2",
                btAddress = 0x7E090F,
                btsAddress = 0x7E18E2,
                goodBtHighNibbles = { [0xF] = true, [0x7] = true },
                goodBtsValues = { [0x6F] = true },
                use = "+2 PLMs",
            },
            {
                key = "6F-skree",
                name = "6F-skree / +4",
                btAddress = 0x7E0C5F,
                btsAddress = 0x7E1A8A,
                goodBtHighNibbles = { [0xF] = true, [0x7] = true },
                goodBtsValues = { [0x6F] = true },
                use = "+4 PLMs",
            },
        },

        -- Extra route state watches.
        extraWatches = {
            {
                key = "items-source",
                name = "$0026 item src",
                address = 0x7E0026,
                size = 2,
                goodMin = 0x8000,
                excellentValues = { [0xFFFF] = true, [0xC000] = true },
                badValues = { [0x0000] = true },
                goodText = ">=8000",
                badText = "0000 = no X-ray",
                alertWhenBad = true,
            },
            {
                key = "gold-0380",
                name = "$0380 Gold ptr",
                address = 0x7E0380,
                size = 2,
                exactLabels = {
                    [0x8941] = "X-RAY?",
                    [0x8944] = "X-RAY",
                    [0x8966] = "5D-R +1",
                    [0x8967] = "5D-R +1",
                },
                showNearest = true,
            },
            {
                key = "timer-1843",
                name = "$1843 timer",
                address = 0x7E1843,
                size = 1,
                goodRanges = { {0x10, 0x1F} },
                goodText = "10..1F",
            },
            {
                key = "sprite-03D7",
                name = "$03D7 sprite",
                address = 0x7E03D7,
                size = 1,
                watchOnly = true,
            },
        },

        -- Warn when these values change away from the route-useful state.
        watchChanges = {
            enabled = true,
            alertOnLost5D = true,
            alertOnLost6F = true,
            alertOn090FReset = true,
            alertOn0C5FLost = true,
            alertOn0026Bad = true,
            alertOnBombAfter0C5FGood = true,
        },

        -- SNI snapshots can jitter by a few poll cycles on real hardware.
        -- These are validity windows in poll cycles, not console frames.
        -- A poll cycle targets ~16ms but runs longer when SNI/hardware RTT
        -- dominates, so treat these as "a handful of cycles" not exact ms.
        --
        -- Route/PLM/block values are effectively static once set: a
        -- single late cycle should NOT visibly flip them. We keep the
        -- windows generous AND apply freshness hysteresis (see
        -- freshnessHysteresis below) so the dashboard stops flickering
        -- between OK and ?? on routine poll jitter. Timing watches stay
        -- tight because door-skip needs genuinely live input/state.
        freshness = {
            routeMaxAge = 24,   -- ~static route values; was 6 (too twitchy)
            timingMaxAge = 4,   -- live input/game-state; was 2
            plmMaxAge = 30,     -- PLM table; was 10
            blockMaxAge = 90,   -- world/block reads; was 60
        },

        -- Freshness hysteresis: how many CONSECUTIVE stale cycles a value
        -- that was previously fresh must accumulate before the UI is
        -- allowed to show it as stale. This is the main anti-flicker
        -- mechanism: brief jitter past the window is absorbed and the
        -- displayed mark/colour/age only changes once data is genuinely
        -- gone for a sustained run. Set to 0 to disable (hard cutoff).
        freshnessHysteresis = {
            staleCycles = 8,   -- must be stale this long before flipping to stale
            freshCycles = 1,   -- recover to fresh after this many good cycles
        },

        -- Assist hotkeys. Hold Select+B, then tap the configured button.
        -- This avoids collisions with normal gameplay and most practice-hack hotkeys.
        controls = {
            requireSelectBModifier = true,
            resetPlmBaselineButton = "Y",       -- Select+B+Y
            toggleDashboardButton = "L",        -- Select+B+L
            toggleHighlightsButton = "R",       -- Select+B+R
            clearWarningsButton = "start",      -- Select+B+Start
            toggleTrainingGuideButton = "up",   -- Select+B+Up
            nextTrainingPageButton = "right",   -- Select+B+Right
            prevTrainingPageButton = "left",    -- Select+B+Left
            toggleChecklistButton = "down",     -- Select+B+Down toggles Doorskip timing panel

            -- True chord: hold Select+B, then press L+R together.
            -- This toggles the actual block/world viewer layer off/on while
            -- keeping checklist, Doorskip timing, warnings, and RAM helpers active.
            -- It is handled before the individual L/R hotkeys to avoid double-toggles.
            toggleBlockViewerCombo = { "L", "R" },
        },

        -- Doorskip timing analyzer for the Parlor Doorskip setup:
        -- hold Jump, press Start, press Left/Right 5 frames later for auto-spinjump,
        -- press Down at least once before unpause finishes to put Samus in aim-down pose,
        -- then press shoulder L/R exactly on the $0998 game-mode switch from $12 -> $08.
        -- Shoulder L/R is a *press* check, not merely held: pressing before $12->$08 is early.
        doorskipTiming = {
            enabled = true,
            visibleByDefault = true,
            x = 8,
            y = 120,
            width = 200,
            lineHeight = 8,
            background = UI_TEXT_BACKGROUND,
            panelFill = UI_PANEL_BACKGROUND,
            titleColour = "yellow",
            textColour = "white",
            okColour = "green",
            warnColour = "yellow",
            badColour = "red",

            -- D-pad Left/Right auto-spinjump target in frames relative to the Start press frame.
            targetDirectionFramesAfterStart = 5,
            directionGoodWindow = 0, -- exact by default; set 1 to accept +/-1 as GOOD.
            directionNearWindow = 2,

            -- Down must be pressed at least once before the final unpause transition.
            requireDownBeforeResume = true,

            -- The final shoulder L/R must be pressed on this exact game-mode transition.
            targetResumeFromGameMode = 0x12,
            targetResumeToGameMode = 0x08,

            -- If unpause goes 12->0B instead, L/R was pressed too early and triggered
            -- the door transition. Mark that as an immediate early result.
            earlyDoorTransitionToGameMode = 0x0B,
            markEarlyDoorTransition = true,

            shoulderGoodWindow = 0,
            shoulderNearWindow = 2,
            lateShoulderWaitFrames = 16,

            resumeFlashFrames = 18,
            attemptTimeoutFrames = 240,
            historySize = 5,
            showHistory = false,
            showLiveInputLine = true,
            warnOnBadAttempt = true,
        },

        -- In-game learning panel for Doorskip and the pre/post-DoorSkip route state.
        -- This is a practice helper, not a replacement for the route notes/videos.
        trainingGuide = {
            enabled = true,
            visibleByDefault = false,

            -- The expanded checklist is the detailed route-state panel.
            -- When it is visible, the compact RAM dashboard is hidden by default so
            -- the same checks are not displayed in two places at once.
            checklistVisibleByDefault = true,
            hideDashboardWhenChecklistVisible = true,
            toggleChecklistWithTiming = false,

            -- Generic guide-page placement.
            xFromRight = 252,
            y = 32,
            width = 248,
            lineHeight = 8,

            -- Expanded checklist placement and readability.
            -- Leave checklistX/checklistY nil to place it on the right side automatically.
            checklistX = nil,
            checklistY = 580,
            checklistWidth = 278,
            checklistLineHeight = 8,
            checklistShowNotes = false,
            checklistShowSections = false,

            background = UI_TEXT_BACKGROUND,
            panelFill = UI_PANEL_BACKGROUND,
            titleColour = "yellow",
            textColour = "white",
            noteColour = "cyan",
            okColour = "green",
            warnColour = "yellow",
            badColour = "red",
            pages = {
                {
                    title = "Doorskip timing",
                    lines = {
                        "Hold Jump, then press Start.",
                        "Press D-pad Left/Right 5f after Start",
                        "to initiate the auto-spinjump.",
                        "Before unpause finishes, press Down",
                        "at least once to get aim-down pose.",
                        "On the exact $0998 12->08 frame,",
                        "press shoulder L/R. Earlier is bad,",
                        "holding it before the switch is early.",
                    },
                },
                {
                    title = "Doorskip state checklist",
                    lines = {
                        "Goal: reach Parlor OOB first try.",
                        "If Climb is entered, Shuffler is gone.",
                        "Before Doorskip, preserve route RAM:",
                        "  5D-left/right BTS = 5D",
                        "  6F-skree/layer values ready",
                        "  Geemer #10 facing right for $11FD/$1201",
                        "After Doorskip: shoot while X is positive",
                        "so $0026 becomes FFFF, not 0000.",
                    },
                },
                {
                    title = "Pre-shuffle OOB rules",
                    lines = {
                        "Do not bomb before Shuffler touch.",
                        "Avoid wall bonks that reset $090F.",
                        "Avoid crumble-like blocks that overwrite",
                        "$1D59 or $1D5B.",
                        "Use the RAM dashboard as pass/fail:",
                        "5D-left, 5D-right, 6F-layer, 6F-skree",
                        "should all be green before Shuffler.",
                    },
                },
                {
                    title = "Post-shuffle targets",
                    lines = {
                        "Expected route PLMs:",
                        "  Shuffler +1",
                        "  5D-right +1 at $0380 ~= 8966/8967",
                        "  6F-layer +2",
                        "  6F-skree +4",
                        "Then 5D-left for X-ray at $0380 = 8944",
                        "or possibly 8941 depending on touch.",
                    },
                },
                {
                    title = "Script hotkeys",
                    lines = {
                        "All hotkeys: hold Select+B, then tap:",
                        "A labels, X label filter, Y PLM baseline",
                        "L dashboard, R highlights, Start clear warn",
                        "Up guide, Left/Right guide page, Down timing",
                        "L+R block viewer layer on/off",
                        "Door +/- distance labels are optional in",
                        "CONFIG.anyGlitchedAssist.blockHighlights.",
                        "Use this modifier if a practice hack binds",
                        "plain Select/A/X/L/R/Start combinations.",
                    },
                },
            },
        },

        -- Freeze duration estimator. This uses in-game timer stalls while game state is gameplay.
        -- It is a heuristic, but it is useful for practicing Shuffler touches:
        -- about 38f = +0, 76f = +1, 112f = +2.
        freezeTimer = {
            enabled = true,
            minFrames = 24,
            maxFrames = 150,
            shufflerDurations = {
                { frames = 38,  label = "Shuffler +0?" },
                { frames = 76,  label = "Shuffler +1?" },
                { frames = 112, label = "Shuffler +2?" },
            },
            tolerance = 12,
        },

        -- PLM count. Active count is inferred by counting nonzero PLM IDs.
        plm = {
            enabled = true,
            slots = 40,
            baseline = nil, -- nil = auto-set on first valid frame
            targetExtra = 8,
        },

        -- Optional manual waypoints. Fill these with world coordinates if you want arrows.
        -- Example: { name = "5D-left X-ray", x = 0xFD00, y = 0x0120, colour = "yellow" }
        waypoints = {
        },
    },

    -- Debug/control options.
    debugControlsEnabled = true,

    -- Block/BTS label options.
    -- Select+B+A toggles these labels on/off.
    -- Select+B+X toggles between this filtered list and the fallback "all block types" mode.
    blockLabels = {
        filterEnabledByDefault = true,

        -- Hotkeys now require a Select+B modifier to avoid collisions with gameplay/practice hacks.
        -- Hold Select+B, then tap the configured button.
        controls = {
            requireSelectBModifier = true,
            toggleLabelsButton = "A",       -- Select+B+A
            toggleFilterButton = "X",       -- Select+B+X
            toggleFollowSamusButton = nil,  -- optional, e.g. "R" if you want the old follow-Samus toggle
            enablePositionNudgeControls = false, -- old Select+A+D-pad nudge controls, off by default
        },

        -- When filter mode is OFF, this is used for every block type.
        -- Set showType/showBts to choose what the unfiltered fallback displays.
        allBlockTypes = {
            showType = true,
            showBts = true,
            colour = "red",
            background = UI_LABEL_BACKGROUND,
        },

        -- Extra global BTS filter. Leave nil to allow all BTS values.
        -- Example: globalBtsValues = { [0x40] = true, [0x41] = true, [0x42] = true, [0x43] = true },
        globalBtsValues = nil,

        -- Label rendering.
        -- "mini" uses a compact built-in 3x5 hex font that fits inside 16x16 blocks.
        -- "mesen" uses Mesen's normal drawString font.
        textRenderer = "mini",

        -- Text style for labels inside blocks.
        -- "compact" draws type/BTS on one line, e.g. 9/40.
        -- "stacked" draws type above BTS.
        textStyle = "compact",
        includePrefixes = false, -- true gives T:9 and B:40 instead of 9 and 40.

        -- Mini-font sizing. Increase pixelSize to 2 if you want larger labels.
        miniFont = {
            pixelSize = 1,
            charSpacing = 1,
            lineSpacing = 1,
            drawBackground = true,
            backgroundPadding = 0,
        },

        -- The original door-block outline drew its own BTS label unconditionally.
        -- Disable it so it does not collide with the configurable labels below.
        suppressNativeDoorBtsLabels = true,

        defaultColour = "red",
        defaultBackground = UI_LABEL_BACKGROUND,

        -- Configure exactly which block types are important.
        -- showType/showBts can differ per block type.
        -- btsValues limits a block type to specific BTS values.
        -- btsRanges supports inclusive ranges, e.g. { {0x40, 0x43} }.
        --
        -- Block type legend:
        --   00 air, 01 slope, 02 spike air, 03 special air, 04 shootable air,
        --   05 horizontal extension, 06 unused air, 07 bombable air, 08 solid block,
        --   09 door block, 0A spike block, 0B special block, 0C shootable block,
        --   0D vertical extension, 0E grapple block, 0F bombable block.
        blockTypes = {
            -- Door blocks: show both block type and BTS for OOB door scanning.
            [0x09] = {
                showType = true,
                showBts = true,
                colour = "yellow",
            },

            -- Shootable blocks / doorcaps: by default show only doorcap BTS 40..43.
            -- Remove btsRanges or set it to nil to show every shootable block BTS.
            [0x0C] = {
                showType = true,
                showBts = true,
                colour = "cyan",
                btsRanges = { {0x40, 0x43} },
            },

            -- Bombable blocks: example of showing both values for all BTS values.
            [0x0F] = {
                showType = true,
                showBts = true,
                colour = "orange",
            },

            -- Example: uncomment to show only the block type for solid blocks.
            -- [0x08] = { showType = true, showBts = false, colour = "red" },

            -- Example: uncomment to show only BTS for slopes with BTS 00..1F.
            -- [0x01] = { showType = false, showBts = true, colour = "green", btsRanges = { {0x00, 0x1F} } },
        },
    },

    -- Colour/opacity options. Alpha uses normal meaning here:
    -- 0x00 = invisible, 0x80 = half transparent, 0xFF = fully opaque.
    colours = {
        opacity = 0xFF,
        scrollOpacity = nil, -- nil = use opacity
        slopeOpacity = nil,  -- nil = use opacity

        slope = {0x00, 0xFF, 0x00},
        solidBlock = {0xFF, 0x00, 0x00},
        specialBlock = {0x00, 0x00, 0xFF},
        doorBlock = {0x00, 0xFF, 0xFF},
        doorcap = {0xFF, 0x80, 0x00},
        errorBlock = {0x80, 0x00, 0xFF},

        scrollRed = {0xFF, 0x00, 0x00},
        scrollBlue = {0x00, 0x00, 0xFF},
        scrollGreen = {0x00, 0xFF, 0x00},

        enemy = {0xFF, 0xFF, 0xFF},
        spriteObject = {0xFF, 0x80, 0x00},
        enemyProjectile = {0x00, 0xFF, 0x00},
        powerBomb = {0xFF, 0xFF, 0xFF},
        projectile = {0xFF, 0xFF, 0x00},
        samus = {0x00, 0xFF, 0xFF},
        camera = {0x80, 0x80, 0x80},
    },
}
-- =============================================================================
-- END USER CONFIGURATION
-- =============================================================================

-- Internal aliases kept so the rest of the converted script stays close to upstream.
local USE_SCRIPT_HUD = CONFIG.drawing.useScriptHud
local MESEN_Y_OFFSET = CONFIG.drawing.mesenYOffset
local MESEN_DRAW_ALPHA_INVERTED = CONFIG.drawing.mesenDrawAlphaInverted

local USE_SAMUS_CENTERED_BLOCK_VIEW = CONFIG.samusCenteredBlockView.enabled
local SAMUS_CENTERED_BLOCK_VIEW_SCALE = CONFIG.samusCenteredBlockView.scale
local blockViewerLayerVisible = CONFIG.samusCenteredBlockView.visibleByDefault ~= false
local SAMUS_CENTERED_BLOCK_VIEW_DRAW_SCROLLS = CONFIG.samusCenteredBlockView.drawScrolls
local SAMUS_CENTERED_BLOCK_VIEW_DRAW_FX = CONFIG.samusCenteredBlockView.drawFx
local SAMUS_CENTERED_BLOCK_VIEW_DRAW_HITBOXES = CONFIG.samusCenteredBlockView.drawHitboxes
local SAMUS_CENTERED_BLOCK_VIEW_DRAW_STATUS_TEXT = CONFIG.samusCenteredBlockView.drawStatusText
local ANYG = CONFIG.anyGlitchedAssist or {}
-- =============================================================================
-- Super Hitbox -- sni-lua native adapter (PART 2 of 2: post-CONFIG)
-- =============================================================================
-- Spliced in AFTER the upstream CONFIG block + its `local USE_*` aliases,
-- because the draw layer and draw-surface selection read CONFIG (Samus-
-- centered scale, y-offset, view mode). Everything below this part is the
-- pristine upstream body, verbatim.
-- =============================================================================

-- Console / SNES-core guard (upstream had this inline; emu.getState is real).
local _state = emu.getState()
if _state and _state.consoleType
   and _state.consoleType ~= "Snes" and _state.consoleType ~= "SNES" then
    emu.displayMessage("Super Hitbox",
        "This script is for the SNES core. Current console: "
        .. tostring(_state.consoleType))
    return
end

-- ---- script settings panel (sni-lua ui.*) -----------------------------------
--
-- Surface the most-used CONFIG toggles as app controls so the user can flip
-- them without editing this file. We deliberately only expose settings the
-- body reads LIVE from the ANYG table every frame -- toggling those takes
-- effect immediately. (Block-viewer draw sub-toggles and the HUD scale are
-- captured into body-locals once at load and can't be live-driven without
-- patching the verbatim upstream body, which the build intentionally never
-- does; they stay file-edited.)
--
-- Defaults are seeded from the current CONFIG values, so the panel mirrors
-- whatever the file says; the user's saved choices then override on reload.

local _anyg_on = (ANYG and ANYG.enabled) and true or false

ui.header("Any% Glitched assist")
ui.checkbox("anyg_enabled", "Assist enabled", _anyg_on)
ui.checkbox("anyg_dashboard",  "RAM dashboard",       ANYG.showRamDashboard ~= false)
ui.checkbox("anyg_highlights", "Route block highlights", ANYG.showRouteBlockHighlights ~= false)
ui.checkbox("anyg_0380",       "$0380 helper",        ANYG.show0380Helper ~= false)
ui.checkbox("anyg_plm",        "PLM count",           ANYG.showPlmCount ~= false)
ui.checkbox("anyg_freeze",     "Freeze timer",        ANYG.showFreezeTimer ~= false)
ui.checkbox("anyg_warnings",   "Warnings",            ANYG.showWarnings ~= false)
ui.checkbox("anyg_inputwarn",  "Input warnings",      ANYG.showInputWarnings ~= false)
ui.checkbox("anyg_waypoints",  "Practice waypoints",  ANYG.showPracticeWaypoints ~= false)

ui.header("Overlay")
-- colours.opacity is 0..0xFF and IS read live by the colour packer.
ui.slider("opacity", "Opacity", 0, 255,
          (CONFIG.colours and CONFIG.colours.opacity) or 0xFF)
ui.label("Toggles take effect immediately. Scale/viewer layout still edited in the file.")

-- Push the current control values onto the live CONFIG/ANYG tables. Called
-- every frame (cheap: a handful of table writes) so flipping a checkbox in
-- the app shows up on the very next paint.
local function _apply_ui_settings()
    if not ANYG then return end
    ANYG.enabled                 = ui.get("anyg_enabled")
    ANYG.showRamDashboard        = ui.get("anyg_dashboard")
    ANYG.showRouteBlockHighlights= ui.get("anyg_highlights")
    ANYG.show0380Helper          = ui.get("anyg_0380")
    ANYG.showPlmCount            = ui.get("anyg_plm")
    ANYG.showFreezeTimer         = ui.get("anyg_freeze")
    ANYG.showWarnings            = ui.get("anyg_warnings")
    ANYG.showInputWarnings       = ui.get("anyg_inputwarn")
    ANYG.showPracticeWaypoints   = ui.get("anyg_waypoints")
    if CONFIG.colours then
        CONFIG.colours.opacity = ui.get("opacity")
    end
end

-- Wrap the PART 1 on_frame so settings are synced before the body paints.
-- (PART 2 is spliced after PART 1, so this redefinition wins.)
local _base_on_frame = on_frame
function on_frame()
    _apply_ui_settings()
    if _base_on_frame then _base_on_frame() end
end

-- ---- draw surface -> sni-lua canvas -----------------------------------------
--
-- The Samus-centered block viewer draws into a scaled HUD coordinate space
-- (e.g. 3x -> 768x672) and its layout math assumes that larger space. sni-lua's
-- equivalent is gfx.scale(N): the canvas becomes 256N x 224N and the script's
-- coords map 1:1. Without this the body would lay out for the big space on a
-- 256x224 canvas -> everything off-canvas. (This IS load-bearing; only the
-- Mesen drawSurface *indirection* was cruft, not the scaling itself.)

local _hud_scale = 1
if USE_SAMUS_CENTERED_BLOCK_VIEW then
    _hud_scale = math.max(1, math.floor((SAMUS_CENTERED_BLOCK_VIEW_SCALE or 1) + 0.5))
end
gfx.scale(_hud_scale)

-- Upstream's drawYOffset(): the legacy console-screen overlay needs a small
-- vertical nudge; the Samus-centered scriptHud viewer is its own coord space
-- and uses 0. We fold this into the draw primitives below, exactly as upstream
-- did inside its xemu.draw* wrappers.
local function drawYOffset()
    if USE_SAMUS_CENTERED_BLOCK_VIEW then return 0 end
    return MESEN_Y_OFFSET
end

-- Upstream's getConfiguredViewSize(): the body calls this once in on_paint to
-- size its centered layout. sni-lua's gfx.width()/height() ALWAYS report the
-- effective canvas (after gfx.scale and any app override), so this is exactly
-- the right answer with none of the Mesen surface-size plumbing.
function getConfiguredViewSize()
    return gfx.width(), gfx.height()
end

-- Upstream re-selects its draw surface at the top of every on_paint (Mesen
-- needs the surface re-bound per frame). On sni-lua the canvas scale is set
-- once at load (gfx.scale above) and never changes, so the per-frame call is
-- a no-op -- but the body still calls it, so it must exist as a global.
function selectConfiguredDrawSurface() end

-- ---- colour: one conversion, no inversion -----------------------------------
--
-- The upstream body produces colours as 0xRRGGBBAA (FF alpha = opaque) and the
-- string names below. sni-lua's gfx.* take 0xAARRGGBB (FF alpha = opaque). So
-- exactly one re-pack, RRGGBBAA -> AARRGGBB. (The old Mesen path inverted
-- alpha here and the prelude un-inverted it -- both deleted.)
--
-- Integer-width note: LuaJIT's bit ops are signed 32-bit, so lshift(0xFF,24)
-- is negative while gfx.* want an unsigned 0..0xFFFFFFFF. Decompose with /%
-- and recompose with arithmetic (stays an exact double).

local NAMED = {
    red="FF0000", orange="FF8000", yellow="FFFF00", white="FFFFFF",
    black="000000", green="00FF00", purple="FF00FF", cyan="00FFFF",
    blue="0000FF", gray="808080", grey="808080",
    darkgray="404040", darkgrey="404040",
}

local function to_argb(colour)
    if colour == nil then return nil end
    local r, g, b, a
    if type(colour) == "string" then
        if colour == "clear" then return 0 end
        local hex = NAMED[colour]
        if hex == nil then
            print("Unknown colour = " .. tostring(colour))
            hex = "FFFFFF"
        end
        r = tonumber(hex:sub(1, 2), 16)
        g = tonumber(hex:sub(3, 4), 16)
        b = tonumber(hex:sub(5, 6), 16)
        a = 0xFF
    else
        local c = colour
        if c < 0 then c = c + 0x100000000 end
        r = math.floor(c / 0x1000000) % 0x100
        g = math.floor(c / 0x10000)   % 0x100
        b = math.floor(c / 0x100)     % 0x100
        a = c % 0x100
    end
    return a * 0x1000000 + r * 0x10000 + g * 0x100 + b
end

local function i(v)
    if v == nil then return 0 end
    return math.floor(v + 0.5)
end

-- The body calls mesenColour(colour) in exactly ONE place -- it pre-converts
-- a colour and passes the result to emu.drawRectangle. Our emu.drawRectangle
-- (below) already does the single to_argb conversion, so to keep it at ONE
-- conversion (not two), this is a passthrough: hand the raw upstream colour
-- straight through. (Upstream's mesenColour did the Mesen alpha-invert here;
-- deleting that is the whole point.)
function mesenColour(colour) return colour end

-- ---- the xemu draw surface --------------------------------------------------

xemu.drawPixel = function(x, y, fg)
    gfx.pixel(i(x), i(y + drawYOffset()), to_argb(fg))
end

xemu.drawBox = function(x0, y0, x1, y1, fg, bg)
    local yo     = drawYOffset()
    local left   = math.min(i(x0), i(x1))
    local top    = math.min(i(y0), i(y1)) + yo - 1
    local right  = math.max(i(x0), i(x1))
    local bottom = math.max(i(y0), i(y1)) + yo - 1
    local fillSame = bg ~= nil and bg ~= "clear" and to_argb(bg) == to_argb(fg)
    local c = to_argb(fg)
    gfx.box(left, top, right - left + 1, bottom - top + 1,
            c, fillSame and c or nil, 1.0)
end

xemu.drawLine = function(x0, y0, x1, y1, fg)
    local yo = drawYOffset()
    gfx.line(i(x0), i(y0 + yo - 1), i(x1), i(y1 + yo - 1), to_argb(fg), 1.0)
end

xemu.drawText = function(x, y, text, fg, bg)
    -- sni-lua text has no per-call background; the body draws its own backing
    -- boxes for panels, so dropping bg is faithful.
    gfx.text(i(x), i(y + drawYOffset()), tostring(text), to_argb(fg))
end

-- The body issues one direct emu.drawRectangle (drawMiniText backing); keep it
-- aligned with xemu.drawBox (same y-offset, same colour conversion).
function emu.drawRectangle(x, y, w, h, color, filled, _alpha)
    local c = to_argb(color)
    gfx.box(i(x), i(y + drawYOffset()), i(w), i(h),
            c, filled and c or nil, 1.0)
end

-- =============================================================================
-- Original Super Hitbox script body follows (verbatim upstream, minus the
-- permanently-dead `if xemu.emuId==emuId_bizhawk and false` CPU-profiling
-- block, which referenced emu.getregister/event.onmemoryexecute/io that no
-- sni-lua target provides and which never executed).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Inline Super Metroid helper module
-- ---------------------------------------------------------------------------
function makeReader(p, n, is_signed, interval, is_aram)
    -- p: Pointer to WRAM (or ARAM)
    -- n: Number of bytes to read
    -- is_signed: Whether or not to sign extend read values
    -- interval: If specified, size of array entries, where p is the address within the first array entry
    --           Returned reader will have an array index parameter
    -- is_aram: Whether or not to read from ARAM

    if n < 1 or n > 2 then
        error(string.format('Trying to make reader with n = %d', n))
    end

    local unsignedReaders = {
        [1] = xemu.read_u8,
        [2] = xemu.read_u16_le
    }
    local signedReaders = {
        [1] = xemu.read_s8,
        [2] = xemu.read_s16_le
    }

    if is_aram then
        unsignedReaders = {
            [1] = xemu.read_aram_u8,
            [2] = xemu.read_aram_u16_le
        }
        signedReaders = {
            [1] = xemu.read_aram_s8,
            [2] = xemu.read_aram_s16_le
        }
    end

    local reader = unsignedReaders[n] or function() return 0 end
    if is_signed then
        reader = signedReaders[n] or function() return 0 end
    end

    if interval then
        return function(i) return reader(p + i * interval) end
    else
        return function() return reader(p) end
    end
end

function makeAramReader(p, n, is_signed, interval)
    return makeReader(p, n, is_signed, interval, true)
end

local function cpuBankWrapAddress(p)
    return xemu.or_(xemu.and_(p, 0xFF0000), xemu.and_(p, 0xFFFF))
end

local function cpuBankWrappedOffsetAddress(p, offset)
    return xemu.or_(xemu.and_(p, 0xFF0000), xemu.and_(xemu.and_(p, 0xFFFF) + offset, 0xFFFF))
end

local function readCpu8BankWrapped(p, signed)
    return readCpu8(cpuBankWrapAddress(p), signed or false)
end

local function readCpu16BankWrapped(p, signed)
    local addr = cpuBankWrapAddress(p)
    local lo = readCpu8(addr, false)
    local hi = readCpu8(cpuBankWrappedOffsetAddress(addr, 1), false)
    local value = lo + xemu.lshift(hi, 8)
    if signed and value >= 0x8000 then
        value = value - 0x10000
    end
    return value
end

function makeBankWrappedReader(p, n, is_signed, interval)
    -- p: 24-bit CPU address. Indexed accesses wrap within the original bank.
    if n < 1 or n > 2 then
        error(string.format('Trying to make bank-wrapped reader with n = %d', n))
    end

    local unsignedReaders = {
        [1] = function(addr) return readCpu8BankWrapped(addr, false) end,
        [2] = function(addr) return readCpu16BankWrapped(addr, false) end,
    }
    local signedReaders = {
        [1] = function(addr) return readCpu8BankWrapped(addr, true) end,
        [2] = function(addr) return readCpu16BankWrapped(addr, true) end,
    }

    local reader = unsignedReaders[n] or function() return 0 end
    if is_signed then
        reader = signedReaders[n] or function() return 0 end
    end

    if interval then
        return function(i) return reader(cpuBankWrappedOffsetAddress(p, i * interval)) end
    else
        return function() return reader(p) end
    end
end

function makeAggregateReader(readers)
    return function(i) return readers[i + 1] end
end

function makeWriter(p, n, interval)
    -- p: Pointer to WRAM
    -- n: Number of bytes to write
    -- interval: If specified, size of array entries, where p is the address within the first array entry
    --           Returned writer will have an array index parameter

    if n < 1 or n > 2 then
        error(string.format('Trying to make writer with n = %d', n))
    end

    local writers = {
        [1] = xemu.write_u8,
        [2] = xemu.write_u16_le
    }

    local writer = writers[n]
    if interval then
        return function(i, v) return writer(p + i * interval, v) end
    else
        return function(v) return writer(p, v) end
    end
end

local sm = {}

-- Button bitmasks --
sm.button_B      = 0x8000
sm.button_Y      = 0x4000
sm.button_select = 0x2000
sm.button_start  = 0x1000
sm.button_up     = 0x800
sm.button_down   = 0x400
sm.button_left   = 0x200
sm.button_right  = 0x100
sm.button_A      = 0x80
sm.button_X      = 0x40
sm.button_L      = 0x20
sm.button_R      = 0x10

local BUTTON_BY_NAME = {
    a = sm.button_A,
    b = sm.button_B,
    x = sm.button_X,
    y = sm.button_Y,
    l = sm.button_L,
    r = sm.button_R,
    select = sm.button_select,
    start = sm.button_start,
    up = sm.button_up,
    down = sm.button_down,
    left = sm.button_left,
    right = sm.button_right,
}

local function getButtonMask(buttonName)
    if buttonName == nil then return nil end
    if type(buttonName) == "number" then return buttonName end
    return BUTTON_BY_NAME[string.lower(tostring(buttonName))]
end

local function hotkeyModifierHeld(input, cfg)
    cfg = cfg or {}
    if cfg.requireSelectBModifier == false then
        return xemu.and_(input, sm.button_select) ~= 0
    end
    return xemu.and_(input, sm.button_select) ~= 0 and xemu.and_(input, sm.button_B) ~= 0
end

local hotkeyFrameState = {
    frame = nil,
    input = 0,
    pressed = 0,
    initialized = false,
}

local function getHotkeyFrameState()
    local frame = emu.framecount()
    if hotkeyFrameState.frame ~= frame then
        local previousInput = hotkeyFrameState.input or 0
        local input = sm.getInput()
        hotkeyFrameState.frame = frame
        hotkeyFrameState.input = input
        if hotkeyFrameState.initialized then
            hotkeyFrameState.pressed = xemu.and_(input, xemu.not_(previousInput))
        else
            hotkeyFrameState.pressed = 0
            hotkeyFrameState.initialized = true
        end
    end
    return hotkeyFrameState.input, hotkeyFrameState.pressed, frame
end

local lastDebugControlsFrame = nil
local lastAnygUpdateFrame = nil

local function hotkeyPressed(input, changed, cfg, fieldName, defaultButton)
    cfg = cfg or {}
    if not hotkeyModifierHeld(input, cfg) then return false end
    local mask = getButtonMask(cfg[fieldName] or defaultButton)
    return mask ~= nil and xemu.and_(changed, mask) ~= 0
end

local function hotkeyComboPressed(input, changed, cfg, fieldName)
    cfg = cfg or {}
    if not hotkeyModifierHeld(input, cfg) then return false end

    local combo = cfg[fieldName]
    if type(combo) ~= "table" then return false end

    local comboMask = 0
    for _, buttonName in ipairs(combo) do
        local mask = getButtonMask(buttonName)
        if mask == nil then return false end
        comboMask = xemu.or_(comboMask, mask)
    end

    -- The chord is pressed when all combo buttons are currently held and at
    -- least one of them changed this frame. This avoids repeatedly toggling
    -- while the chord is held.
    return comboMask ~= 0
       and xemu.and_(input, comboMask) == comboMask
       and xemu.and_(changed, comboMask) ~= 0
end

-- WRAM --
sm.getBg1TilemapOptions      = makeReader(0x7E0058, 2)
sm.getBg2TilemapOptions      = makeReader(0x7E0059, 2)

sm.getInput                  = makeReader(0x7E008B, 2)
sm.getChangedInput           = makeReader(0x7E008F, 2)

sm.getBg1ScrollX             = makeReader(0x7E00B1, 2)
sm.setBg1ScrollX             = makeWriter(0x7E00B1, 2)
sm.getBg1ScrollY             = makeReader(0x7E00B3, 2)
sm.setBg1ScrollY             = makeWriter(0x7E00B3, 2)
sm.getBg2ScrollX             = makeReader(0x7E00B5, 2)
sm.setBg2ScrollX             = makeWriter(0x7E00B5, 2)
sm.getBg2ScrollY             = makeReader(0x7E00B7, 2)
sm.setBg2ScrollY             = makeWriter(0x7E00B7, 2)
sm.getBg3ScrollX             = makeReader(0x7E00B9, 2)
sm.setBg3ScrollX             = makeWriter(0x7E00B9, 2)
sm.getBg3ScrollY             = makeReader(0x7E00BB, 2)
sm.setBg3ScrollY             = makeWriter(0x7E00BB, 2)

sm.getMode7Flag              = makeReader(0x7E0783, 2)
sm.getDoorDirection          = makeReader(0x7E0791, 2)
sm.getRoomPointer            = makeReader(0x7E079B, 2)
sm.getAreaIndex              = makeReader(0x7E079F, 2)
sm.getRoomWidth              = makeReader(0x7E07A5, 2)
sm.getRoomHeight             = makeReader(0x7E07A7, 2)
sm.getRoomWidthInScrolls     = makeReader(0x7E07A9, 2)
sm.getRoomHeightInScrolls    = makeReader(0x7E07AB, 2)
sm.getUpScroller             = makeReader(0x7E07AD, 2)
sm.getDownScroller           = makeReader(0x7E07AF, 2)
sm.getDoorListPointer        = makeReader(0x7E07B5, 2)

sm.getLayer1XSubposition     = makeReader(0x7E090F, 2)
sm.getLayer1XPosition        = makeReader(0x7E0911, 2, true)
sm.setLayer1XPosition        = makeWriter(0x7E0911, 2)
sm.getLayer1YSubposition     = makeReader(0x7E0913, 2)
sm.getLayer1YPosition        = makeReader(0x7E0915, 2, true)
sm.setLayer1YPosition        = makeWriter(0x7E0915, 2)
sm.getLayer2XPosition        = makeReader(0x7E0917, 2, true)
sm.getLayer2YPosition        = makeReader(0x7E0919, 2, true)
sm.getLayer2XScroll          = makeReader(0x7E091B, 1)
sm.getLayer2YScroll          = makeReader(0x7E091C, 1)
sm.getBg1ScrollXOffset       = makeReader(0x7E091D, 2, true)
sm.getBg1ScrollYOffset       = makeReader(0x7E091F, 2, true)
sm.getBg2ScrollXOffset       = makeReader(0x7E0921, 2, true)
sm.getBg2ScrollYOffset       = makeReader(0x7E0923, 2, true)

sm.getDownwardsElevatorDelayTimer = makeReader(0x7E092F, 2)

sm.getCameraDistanceIndex    = makeReader(0x7E0941, 2)

sm.getGameState              = makeReader(0x7E0998, 2)
sm.getDoorTransitionFunction = makeReader(0x7E099C, 2)

sm.getEquippedItems         = makeReader(0x7E09A2, 2)
sm.getCollectedItems        = makeReader(0x7E09A4, 2)
sm.getEquippedBeams         = makeReader(0x7E09A6, 2)
sm.getCollectedBeams        = makeReader(0x7E09A8, 2)

sm.getRunBinding             = makeReader(0x7E09B6, 2)

sm.getSamusHealth           = makeReader(0x7E09C2, 2)
sm.getSamusMaxHealth        = makeReader(0x7E09C4, 2)
sm.getSamusMissiles         = makeReader(0x7E09C6, 2)
sm.getSamusMaxMissiles      = makeReader(0x7E09C8, 2)
sm.getSamusSuperMissiles    = makeReader(0x7E09CA, 2)
sm.getSamusMaxSuperMissiles = makeReader(0x7E09CC, 2)
sm.getSamusPowerBombs       = makeReader(0x7E09CE, 2)
sm.getSamusMaxPowerBombs    = makeReader(0x7E09D0, 2)
sm.getSamusMaxReserveHealth = makeReader(0x7E09D4, 2)
sm.getSamusReserveHealth    = makeReader(0x7E09D6, 2)

sm.getGameTimeFrames         = makeReader(0x7E09DA, 2)
sm.getGameTimeSeconds        = makeReader(0x7E09DC, 2)
sm.getGameTimeMinutes        = makeReader(0x7E09DE, 2)
sm.getGameTimeHours          = makeReader(0x7E09E0, 2)

sm.getSamusPreviousMovementType = makeReader(0x7E0A11, 1)
sm.getSamusPose                 = makeReader(0x7E0A1C, 1)
sm.getSamusFacingDirection      = makeReader(0x7E0A1E, 1)
sm.getSamusMovementType         = makeReader(0x7E0A1F, 1)
sm.getKnockbackDirection        = makeReader(0x7E0A52, 2)
sm.getSamusMovementHandler      = makeReader(0x7E0A58, 2)
sm.getSamusPoseInputHandler     = makeReader(0x7E0A60, 2)
sm.getShinesparkTimer           = makeReader(0x7E0A68, 2, true)
sm.getFrozenTimeFlag            = makeReader(0x7E0A78, 2)
sm.getXrayState                 = makeReader(0x7E0A7A, 2)

sm.getSamusAnimationFrameTimer = makeReader(0x7E0A94, 2)
sm.getSamusAnimationFrame      = makeReader(0x7E0A96, 2)
sm.getSpecialSamusPaletteType  = makeReader(0x7E0ACC, 2)

sm.getSamusXPosition           = makeReader(0x7E0AF6, 2)
sm.getSamusXPositionSigned     = makeReader(0x7E0AF6, 2, true)
sm.setSamusXPosition           = makeWriter(0x7E0AF6, 2)
sm.getSamusXSubposition        = makeReader(0x7E0AF8, 2)
sm.getSamusYPosition           = makeReader(0x7E0AFA, 2)
sm.getSamusYPositionSigned     = makeReader(0x7E0AFA, 2, true)
sm.setSamusYPosition           = makeWriter(0x7E0AFA, 2)
sm.getSamusYSubposition        = makeReader(0x7E0AFC, 2)
sm.getSamusXRadius             = makeReader(0x7E0AFE, 2)
sm.getSamusYRadius             = makeReader(0x7E0B00, 2)
sm.getIdealLayer1XPosition     = makeReader(0x7E0B0A, 2)
sm.getIdealLayer1YPosition     = makeReader(0x7E0B0E, 2)
sm.getSamusPreviousXPosition   = makeReader(0x7E0B10, 2)
sm.getSamusPreviousYPosition   = makeReader(0x7E0B14, 2)
sm.getSamusYSubspeed           = makeReader(0x7E0B2C, 2)
sm.getSamusYSpeed              = makeReader(0x7E0B2E, 2)
sm.getSamusYDirection          = makeReader(0x7E0B36, 2)
sm.getSamusRunningMomentumFlag = makeReader(0x7E0B3C, 2)
sm.getSpeedBoosterLevel        = makeReader(0x7E0B3F, 2)
sm.getSamusXSpeed              = makeReader(0x7E0B42, 2)
sm.getSamusXSubspeed           = makeReader(0x7E0B44, 2)
sm.getSamusXMomentum           = makeReader(0x7E0B46, 2)
sm.getSamusXSubmomentum        = makeReader(0x7E0B48, 2)

sm.getCooldownTimer          = makeReader(0x7E0CCC, 2)
sm.getChargeCounter          = makeReader(0x7E0CD0, 2)
sm.getPowerBombXPosition     = makeReader(0x7E0CE2, 2)
sm.getPowerBombYPosition     = makeReader(0x7E0CE4, 2)
sm.getPowerBombRadius        = makeReader(0x7E0CEA, 2)
sm.getPowerBombPreRadius     = makeReader(0x7E0CEC, 2)
sm.getPowerBombFlag          = makeReader(0x7E0CEE, 2)

sm.getXDistanceSamusMoved    = makeReader(0x7E0DA2, 2)
sm.getXSubdistanceSamusMoved = makeReader(0x7E0DA4, 2)
sm.getYDistanceSamusMoved    = makeReader(0x7E0DA6, 2)
sm.getYSubdistanceSamusMoved = makeReader(0x7E0DA8, 2)

sm.getBlockIndex             = makeReader(0x7E0DC4, 2)

sm.getElevatorState          = makeReader(0x7E0E18, 2)

sm.getNEnemies               = makeReader(0x7E0E4E, 2)

sm.getBossNumber             = makeReader(0x7E179C, 2)

sm.getEarthquakeType         = makeReader(0x7E183E, 2)
sm.getEarthquakeTimer        = makeReader(0x7E1840, 2)

sm.getInvincibilityTimer     = makeReader(0x7E18A8, 2)
sm.getRecoilTimer            = makeReader(0x7E18AA, 2)

sm.getHdmaObjectIndex        = makeReader(0x7E18B2, 2)

sm.getFxYPosition            = makeReader(0x7E195E, 2)
sm.setFxYPosition            = makeWriter(0x7E195E, 2)
sm.getLavaAcidYPosition      = makeReader(0x7E1962, 2)
sm.setLavaAcidYPosition      = makeWriter(0x7E1962, 2)
sm.getFxTargetYPosition      = makeReader(0x7E197A, 2)

sm.getMessageBoxIndex = makeReader(0x7E1C1F, 2)

sm.getPlmEnableFlag = makeReader(0x7E1C23, 2)

-- OAM
sm.getOamXLow                = makeReader(0x7E0370, 1, false, 4)
sm.setOamXLow                = makeWriter(0x7E0370, 1, 4)
sm.getOamY                   = makeReader(0x7E0371, 1, false, 4)
sm.setOamY                   = makeWriter(0x7E0371, 1, 4)
sm.getOamProperties          = makeReader(0x7E0372, 2, false, 4)
sm.getOamHigh                = makeReader(0x7E0570, 1, false, 1)
sm.setOamHigh                = makeWriter(0x7E0570, 1, 1)

-- Projectiles
sm.getProjectileXPosition = makeReader(0x7E0B64, 2, false, 2)
sm.getProjectileYPosition = makeReader(0x7E0B78, 2, false, 2)
sm.getProjectileXRadius   = makeReader(0x7E0BB4, 2, false, 2)
sm.getProjectileYRadius   = makeReader(0x7E0BC8, 2, false, 2)
sm.getProjectileXVelocity = makeReader(0x7E0BDC, 2, false, 2)
sm.getProjectileYVelocity = makeReader(0x7E0BF0, 2, false, 2)
sm.getProjectileType      = makeReader(0x7E0C18, 2, false, 2)
sm.getProjectileDamage    = makeReader(0x7E0C2C, 2, false, 2)
sm.getBombTimer           = makeReader(0x7E0C7C, 2, false, 2)

-- Enemies
sm.getEnemyId                      = makeReader(0x7E0F78, 2, false, 0x40)
sm.getEnemyXPosition               = makeReader(0x7E0F7A, 2, false, 0x40)
sm.getEnemyXSubposition            = makeReader(0x7E0F7C, 2, false, 0x40)
sm.getEnemyYPosition               = makeReader(0x7E0F7E, 2, false, 0x40)
sm.getEnemyYSubposition            = makeReader(0x7E0F80, 2, false, 0x40)
sm.getEnemyXRadius                 = makeReader(0x7E0F82, 2, false, 0x40)
sm.getEnemyYRadius                 = makeReader(0x7E0F84, 2, false, 0x40)
sm.getEnemyProperties              = makeReader(0x7E0F86, 2, false, 0x40)
sm.getEnemyExtraProperties         = makeReader(0x7E0F88, 2, false, 0x40)
sm.getEnemyAiHandler               = makeReader(0x7E0F8A, 2, false, 0x40)
sm.getEnemyHealth                  = makeReader(0x7E0F8C, 2, false, 0x40)
sm.getEnemySpritemap               = makeReader(0x7E0F8E, 2, false, 0x40)
sm.getEnemyTimer                   = makeReader(0x7E0F90, 2, false, 0x40)
sm.getEnemyInitialisationParameter = makeReader(0x7E0F92, 2, false, 0x40)
sm.getEnemyInstructionList         = makeReader(0x7E0F92, 2, false, 0x40)
sm.getEnemyInstructionTimer        = makeReader(0x7E0F94, 2, false, 0x40)
sm.getEnemyPaletteIndex            = makeReader(0x7E0F96, 2, false, 0x40)
sm.getEnemyGraphicsIndex           = makeReader(0x7E0F98, 2, false, 0x40)
sm.getEnemyLayer                   = makeReader(0x7E0F9A, 2, false, 0x40)
sm.getEnemyInvincibilityTimer      = makeReader(0x7E0F9C, 2, false, 0x40)
sm.getEnemyFrozenTimer             = makeReader(0x7E0F9E, 2, false, 0x40)
sm.getEnemyPlasmaTimer             = makeReader(0x7E0FA0, 2, false, 0x40)
sm.getEnemyShakeTimer              = makeReader(0x7E0FA2, 2, false, 0x40)
sm.getEnemyFrameCounter            = makeReader(0x7E0FA4, 2, false, 0x40)
sm.getEnemyBank                    = makeReader(0x7E0FA6, 1, false, 0x40)
sm.getEnemyAiVariable0             = makeReader(0x7E0FA8, 2, false, 0x40)
sm.getEnemyAiVariable1             = makeReader(0x7E0FAA, 2, false, 0x40)
sm.getEnemyAiVariable2             = makeReader(0x7E0FAC, 2, false, 0x40)
sm.getEnemyAiVariable3             = makeReader(0x7E0FAE, 2, false, 0x40)
sm.getEnemyAiVariable4             = makeReader(0x7E0FB0, 2, false, 0x40)
sm.getEnemyAiVariable5             = makeReader(0x7E0FB2, 2, false, 0x40)
sm.getEnemyParameter1              = makeReader(0x7E0FB4, 2, false, 0x40)
sm.getEnemyParameter2              = makeReader(0x7E0FB6, 2, false, 0x40)

-- Enemy projectiles
sm.getEnemyProjectileId        = makeReader(0x7E1997, 2, false, 2)
sm.getEnemyProjectileXPosition = makeReader(0x7E1A4B, 2, false, 2)
sm.getEnemyProjectileYPosition = makeReader(0x7E1A93, 2, false, 2)
sm.getEnemyProjectileXRadius   = makeReader(0x7E1BB3, 1, false, 2)
sm.getEnemyProjectileYRadius   = makeReader(0x7E1BB4, 1, false, 2)

-- PLMs
sm.getPlmId               = makeReader(0x7E1C37, 2, false, 2)
sm.getPlmRoomArgument     = makeReader(0x7E1DC7, 2, false, 2)
sm.getPlmInstructionTimer = makeReader(0x7EDE1C, 2, false, 2)

-- Metatiles
sm.getMetatileTopLeft     = makeReader(0x7EA000, 2, false, 8)
sm.getMetatileTopRight    = makeReader(0x7EA002, 2, false, 8)
sm.getMetatileBottomLeft  = makeReader(0x7EA004, 2, false, 8)
sm.getMetatileBottomRight = makeReader(0x7EA006, 2, false, 8)

-- Scroll
sm.getScroll = makeReader(0x7ECD20, 1, false, 1)

-- Sprite objects
sm.getSpriteObjectInstructionList = makeReader(0x7EEF78, 2, false, 2)
sm.getSpriteObjectXPosition       = makeReader(0x7EF0F8, 2, false, 2)
sm.getSpriteObjectYPosition       = makeReader(0x7EF1F8, 2, false, 2)

-- Blocks
sm.getLevelDatum      = makeBankWrappedReader(0x7F0002, 2, false, 2)
sm.getBts             = makeBankWrappedReader(0x7F6402, 1, false, 1)
sm.getBtsSigned       = makeBankWrappedReader(0x7F6402, 1, true,  1)
sm.getBackgroundDatum = makeBankWrappedReader(0x7F9602, 2, false, 2)


-- ARAM --
-- CPU IO cache registers
sm.getAram_cpuIo_read      = makeAramReader(0x0, 1, false, 1)
sm.getAram_cpuIo_write     = makeAramReader(0x4, 1, false, 1)
sm.getAram_cpuIo_read_prev = makeAramReader(0x8, 1, false, 1)

sm.getAram_musicTrackStatus = makeAramReader(0xC, 1)

-- Temporaries
sm.getAram_note                = makeAramReader(0x10, 2)
sm.getAram_panningBias         = makeAramReader(0x10, 2)
sm.getAram_dspVoiceVolumeIndex = makeAramReader(0x12, 1)
sm.getAram_noteModifiedFlag    = makeAramReader(0x13, 1)
sm.getAram_misc0               = makeAramReader(0x14, 2)
sm.getAram_misc1               = makeAramReader(0x16, 2)

sm.getAram_randomNumber          = makeAramReader(0x18, 2)
sm.getAram_enabledSoundVoices    = makeAramReader(0x1A, 1)
sm.getAram_disableNoteProcessing = makeAramReader(0x1B, 1)
sm.getAram_p_return              = makeAramReader(0x20, 2)

-- Sound 1
sm.getAram_sound1_instructionListPointerSet = makeAramReader(0x22, 2)
sm.getAram_sound1_p_charVoiceBitset         = makeAramReader(0x24, 2)
sm.getAram_sound1_p_charVoiceMask           = makeAramReader(0x26, 2)
sm.getAram_sound1_p_charVoiceIndex          = makeAramReader(0x28, 2)

-- Sounds
sm.getAram_sound1_channel0_p_instructionList = makeAramReader(0x2A, 2)
sm.getAram_sound1_channel1_p_instructionList = makeAramReader(0x2C, 2)
sm.getAram_sound1_channel2_p_instructionList = makeAramReader(0x2E, 2)

sm.getAram_trackPointers     = makeAramReader(0x30, 2, false, 2)
sm.getAram_p_tracker         = makeAramReader(0x40, 2)
sm.getAram_trackerTimer      = makeAramReader(0x42, 1)
sm.getAram_soundEffectsClock = makeAramReader(0x43, 1)
sm.getAram_trackIndex        = makeAramReader(0x44, 1)

-- DSP cache
sm.getAram_keyOnFlags           = makeAramReader(0x45, 1)
sm.getAram_keyOffFlags          = makeAramReader(0x46, 1)
sm.getAram_musicVoiceBitset     = makeAramReader(0x47, 1)
sm.getAram_flg                  = makeAramReader(0x48, 1)
sm.getAram_noiseEnableFlags     = makeAramReader(0x49, 1)
sm.getAram_echoEnableFlags      = makeAramReader(0x4A, 1)
sm.getAram_pitchModulationFlags = makeAramReader(0x5B, 1)

-- Echo
sm.getAram_echoTimer          = makeAramReader(0x4C, 1)
sm.getAram_echoDelay          = makeAramReader(0x4D, 1)
sm.getAram_echoFeedbackVolume = makeAramReader(0x4E, 1)

-- Music
sm.getAram_musicTranspose                 = makeAramReader(0x50, 1)
sm.getAram_musicTrackClock                = makeAramReader(0x51, 1)
sm.getAram_musicTempo                     = makeAramReader(0x52, 2)
sm.getAram_dynamicMusicTempoTimer         = makeAramReader(0x54, 1)
sm.getAram_targetMusicTempo               = makeAramReader(0x55, 1)
sm.getAram_musicTempoDelta                = makeAramReader(0x56, 2)
sm.getAram_musicVolume                    = makeAramReader(0x58, 2)
sm.getAram_dynamicMusicVolumeTimer        = makeAramReader(0x5A, 1)
sm.getAram_targetMusicVolume              = makeAramReader(0x5B, 1)
sm.getAram_musicVolumeDelta               = makeAramReader(0x5C, 2)
sm.getAram_musicVoiceVolumeUpdateBitset   = makeAramReader(0x5E, 1)
sm.getAram_percussionInstrumentsBaseIndex = makeAramReader(0x5F, 1)

-- Echo
sm.getAram_echoVolumeLeft         = makeAramReader(0x60, 2)
sm.getAram_echoVolumeRight        = makeAramReader(0x62, 2)
sm.getAram_echoVolumeLeftDelta    = makeAramReader(0x64, 2)
sm.getAram_echoVolumeRightDelta   = makeAramReader(0x66, 2)
sm.getAram_dynamicEchoVolumeTimer = makeAramReader(0x68, 1)
sm.getAram_targetEchoVolumeLeft   = makeAramReader(0x69, 1)
sm.getAram_targetEchoVolumeRight  = makeAramReader(0x6A, 1)

-- Music
sm.getAram_trackNoteTimers                 = makeAramReader(0x70, 1, false, 2)
sm.getAram_trackNoteRingTimers             = makeAramReader(0x71, 1, false, 2)
sm.getAram_trackRepeatedSubsectionCounters = makeAramReader(0x80, 1, false, 2)
sm.getAram_trackDynamicVolumeTimers        = makeAramReader(0x90, 1, false, 2)
sm.getAram_trackDynamicPanningTimers       = makeAramReader(0x91, 1, false, 2)
sm.getAram_trackPitchSlideTimers           = makeAramReader(0xA0, 1, false, 2)
sm.getAram_trackPitchSlideDelayTimers      = makeAramReader(0xA1, 1, false, 2)
sm.getAram_trackVibratoDelayTimers         = makeAramReader(0xB0, 1, false, 2)
sm.getAram_trackVibratoExtents             = makeAramReader(0xB1, 1, false, 2)
sm.getAram_trackTremoloDelayTimers         = makeAramReader(0xC0, 1, false, 2)
sm.getAram_trackTremoloExtents             = makeAramReader(0xC1, 1, false, 2)

-- Sounds
sm.getAram_sound1_channel3_p_instructionList = makeAramReader(0xD0, 2)
sm.getAram_p_echoBuffer                      = makeAramReader(0xD2, 2)
sm.getAram_sound2_instructionListPointerSet  = makeAramReader(0xD4, 2)
sm.getAram_sound2_p_charVoiceBitset          = makeAramReader(0xD6, 2)
sm.getAram_sound2_p_charVoiceMask            = makeAramReader(0xD8, 2)
sm.getAram_sound2_p_charVoiceIndex           = makeAramReader(0xDA, 2)
sm.getAram_sound2_channel0_p_instructionList = makeAramReader(0xDC, 2)
sm.getAram_sound2_channel1_p_instructionList = makeAramReader(0xDE, 2)
sm.getAram_sound3_instructionListPointerSet  = makeAramReader(0xE0, 2)
sm.getAram_sound3_p_charVoiceBitset          = makeAramReader(0xE2, 2)
sm.getAram_sound3_p_charVoiceMask            = makeAramReader(0xE4, 2)
sm.getAram_sound3_p_charVoiceIndex           = makeAramReader(0xE6, 2)
sm.getAram_sound3_channel0_p_instructionList = makeAramReader(0xE8, 2)
sm.getAram_sound3_channel1_p_instructionList = makeAramReader(0xEA, 2)

-- Music
sm.getAram_trackDynamicVibratoTimers              = makeAramReader(0x100, 1, false, 2)
sm.getAram_trackNoteLengths                       = makeAramReader(0x200, 1, false, 2)
sm.getAram_trackNoteRingLengths                   = makeAramReader(0x201, 1, false, 2)
sm.getAram_trackNoteVolume                        = makeAramReader(0x210, 1, false, 2)
sm.getAram_trackInstrumentIndices                 = makeAramReader(0x211, 1, false, 2)
sm.getAram_trackInstrumentPitches                 = makeAramReader(0x220, 2, false, 2)
sm.getAram_trackRepeatedSubsectionReturnAddresses = makeAramReader(0x230, 2, false, 2)
sm.getAram_trackRepeatedSubsectionAddresses       = makeAramReader(0x240, 2, false, 2)
sm.getAram_trackSlideLengths                      = makeAramReader(0x280, 1, false, 2)
sm.getAram_trackSlideDelays                       = makeAramReader(0x281, 1, false, 2)
sm.getAram_trackSlideDirections                   = makeAramReader(0x290, 1, false, 2)
sm.getAram_trackSlideExtents                      = makeAramReader(0x291, 1, false, 2)
sm.getAram_trackVibratoPhases                     = makeAramReader(0x2A0, 1, false, 2)
sm.getAram_trackVibratoRates                      = makeAramReader(0x2A1, 1, false, 2)
sm.getAram_trackVibratoDelays                     = makeAramReader(0x2B0, 1, false, 2)
sm.getAram_trackDynamicVibratoLengths             = makeAramReader(0x2B1, 1, false, 2)
sm.getAram_trackVibratoExtentDeltas               = makeAramReader(0x2C0, 1, false, 2)
sm.getAram_trackStaticVibratoExtents              = makeAramReader(0x2C1, 1, false, 2)
sm.getAram_trackTremoloPhases                     = makeAramReader(0x2D0, 1, false, 2)
sm.getAram_trackTremoloRates                      = makeAramReader(0x2D1, 1, false, 2)
sm.getAram_trackTremoloDelays                     = makeAramReader(0x2E0, 1, false, 2)
sm.getAram_trackTransposes                        = makeAramReader(0x2F0, 1, false, 2)
sm.getAram_trackVolumes                           = makeAramReader(0x300, 2, false, 2)
sm.getAram_trackVolumeDeltas                      = makeAramReader(0x310, 2, false, 2)
sm.getAram_trackTargetVolumes                     = makeAramReader(0x320, 1, false, 2)
sm.getAram_trackOutputVolumes                     = makeAramReader(0x321, 1, false, 2)
sm.getAram_trackPanningBiases                     = makeAramReader(0x330, 2, false, 2)
sm.getAram_trackPanningBiasDeltas                 = makeAramReader(0x340, 2, false, 2)
sm.getAram_trackTargetPanningBiases               = makeAramReader(0x350, 1, false, 2)
sm.getAram_trackPhaseInversionOptions             = makeAramReader(0x351, 1, false, 2)
sm.getAram_trackSubnotes                          = makeAramReader(0x360, 1, false, 2)
sm.getAram_trackNotes                             = makeAramReader(0x361, 1, false, 2)
sm.getAram_trackNoteDeltas                        = makeAramReader(0x370, 2, false, 2)
sm.getAram_trackTargetNotes                       = makeAramReader(0x380, 1, false, 2)
sm.getAram_trackSubtransposes                     = makeAramReader(0x381, 1, false, 2)

-- Sound 1
sm.getAram_sound1                                   = makeAramReader(0x392, 1)
sm.getAram_i_sound1                                 = makeAramReader(0x393, 1)
sm.getAram_sound1_i_instructionLists                = makeAramReader(0x394, 1, false, 1)
sm.getAram_sound1_instructionTimers                 = makeAramReader(0x398, 1, false, 1)
sm.getAram_sound1_disableBytes                      = makeAramReader(0x39C, 1, false, 1)
sm.getAram_sound1_i_channel                         = makeAramReader(0x3A0, 1)
sm.getAram_sound1_n_voices                          = makeAramReader(0x3A1, 1)
sm.getAram_sound1_i_voice                           = makeAramReader(0x3A2, 1)
sm.getAram_sound1_remainingEnabledSoundVoices       = makeAramReader(0x3A3, 1)
sm.getAram_sound1_initialisationFlag                = makeAramReader(0x3A4, 1)
sm.getAram_sound1_voiceId                           = makeAramReader(0x3A5, 1)
sm.getAram_sound1_voiceBitsets                      = makeAramReader(0x3A6, 1, false, 1)
sm.getAram_sound1_voiceMasks                        = makeAramReader(0x3AA, 1, false, 1)
sm.getAram_sound1_2i_channel                        = makeAramReader(0x3AE, 1)
sm.getAram_sound1_voiceIndices                      = makeAramReader(0x3AF, 1, false, 1)
sm.getAram_sound1_enabledVoices                     = makeAramReader(0x3B3, 1)
sm.getAram_sound1_dspIndices                        = makeAramReader(0x3B4, 1, false, 1)
sm.getAram_sound1_trackOutputVolumeBackups          = makeAramReader(0x3B8, 1, false, 2)
sm.getAram_sound1_trackPhaseInversionOptionsBackups = makeAramReader(0x3B9, 1, false, 2)
sm.getAram_sound1_releaseFlags                      = makeAramReader(0x3C0, 1, false, 2)
sm.getAram_sound1_releaseTimers                     = makeAramReader(0x3C1, 1, false, 2)
sm.getAram_sound1_repeatCounters                    = makeAramReader(0x3C8, 1, false, 1)
sm.getAram_sound1_repeatPoints                      = makeAramReader(0x3CC, 1, false, 1)
sm.getAram_sound1_adsrSettings                      = makeAramReader(0x3D0, 1, false, 2)
sm.getAram_sound1_updateAdsrSettingsFlags           = makeAramReader(0x3D8, 1, false, 1)
sm.getAram_sound1_notes                             = makeAramReader(0x3DC, 1, false, 7)
sm.getAram_sound1_subnotes                          = makeAramReader(0x3DD, 1, false, 7)
sm.getAram_sound1_subnoteDeltas                     = makeAramReader(0x3DE, 1, false, 7)
sm.getAram_sound1_targetNotes                       = makeAramReader(0x3DF, 1, false, 7)
sm.getAram_sound1_pitchSlideFlags                   = makeAramReader(0x3E0, 1, false, 7)
sm.getAram_sound1_legatoFlags                       = makeAramReader(0x3E1, 1, false, 7)
sm.getAram_sound1_pitchSlideLegatoFlags             = makeAramReader(0x3E2, 1, false, 7)

-- Sound 2
sm.getAram_sound2                                   = makeAramReader(0x3F8, 1)
sm.getAram_i_sound2                                 = makeAramReader(0x3F9, 1)
sm.getAram_sound2_i_instructionLists                = makeAramReader(0x3FA, 1, false, 1)
sm.getAram_sound2_instructionTimers                 = makeAramReader(0x3FC, 1, false, 1)
sm.getAram_sound2_disableBytes                      = makeAramReader(0x3FE, 1, false, 1)

sm.getAram_trackSkipNewNotesFlags                   = makeAramReader(0x400, 1, false, 2)

sm.getAram_sound2_i_channel                         = makeAramReader(0x440, 1)
sm.getAram_sound2_n_voices                          = makeAramReader(0x441, 1)
sm.getAram_sound2_i_voice                           = makeAramReader(0x442, 1)
sm.getAram_sound2_remainingEnabledSoundVoices       = makeAramReader(0x443, 1)
sm.getAram_sound2_initialisationFlag                = makeAramReader(0x444, 1)
sm.getAram_sound2_voiceId                           = makeAramReader(0x445, 1)
sm.getAram_sound2_voiceBitsets                      = makeAramReader(0x446, 1, false, 1)
sm.getAram_sound2_voiceMasks                        = makeAramReader(0x448, 1, false, 1)
sm.getAram_sound2_2i_channel                        = makeAramReader(0x44A, 1)
sm.getAram_sound2_voiceIndices                      = makeAramReader(0x44B, 1, false, 1)
sm.getAram_sound2_enabledVoices                     = makeAramReader(0x44D, 1)
sm.getAram_sound2_dspIndices                        = makeAramReader(0x44E, 1, false, 1)
sm.getAram_sound2_trackOutputVolumeBackups          = makeAramReader(0x450, 1, false, 2)
sm.getAram_sound2_trackPhaseInversionOptionsBackups = makeAramReader(0x451, 1, false, 2)
sm.getAram_sound2_releaseFlags                      = makeAramReader(0x454, 1, false, 2)
sm.getAram_sound2_releaseTimers                     = makeAramReader(0x455, 1, false, 2)
sm.getAram_sound2_repeatCounters                    = makeAramReader(0x458, 1, false, 1)
sm.getAram_sound2_repeatPoints                      = makeAramReader(0x45A, 1, false, 1)
sm.getAram_sound2_adsrSettings                      = makeAramReader(0x45C, 1, false, 2)
sm.getAram_sound2_updateAdsrSettingsFlags           = makeAramReader(0x460, 1, false, 1)
sm.getAram_sound2_notes                             = makeAramReader(0x462, 1, false, 7)
sm.getAram_sound2_subnotes                          = makeAramReader(0x463, 1, false, 7)
sm.getAram_sound2_subnoteDeltas                     = makeAramReader(0x464, 1, false, 7)
sm.getAram_sound2_targetNotes                       = makeAramReader(0x465, 1, false, 7)
sm.getAram_sound2_pitchSlideFlags                   = makeAramReader(0x466, 1, false, 7)
sm.getAram_sound2_legatoFlags                       = makeAramReader(0x467, 1, false, 7)
sm.getAram_sound2_pitchSlideLegatoFlags             = makeAramReader(0x468, 1, false, 7)

-- Sound 3
sm.getAram_sound3                                   = makeAramReader(0x470, 1)
sm.getAram_i_sound3                                 = makeAramReader(0x471, 1)
sm.getAram_sound3_i_instructionLists                = makeAramReader(0x472, 1, false, 1)
sm.getAram_sound3_instructionTimers                 = makeAramReader(0x474, 1, false, 1)
sm.getAram_sound3_disableBytes                      = makeAramReader(0x476, 1, false, 1)
sm.getAram_sound3_i_channel                         = makeAramReader(0x478, 1)
sm.getAram_sound3_n_voices                          = makeAramReader(0x479, 1)
sm.getAram_sound3_i_voice                           = makeAramReader(0x47A, 1)
sm.getAram_sound3_remainingEnabledSoundVoices       = makeAramReader(0x47B, 1)
sm.getAram_sound3_initialisationFlag                = makeAramReader(0x47C, 1)
sm.getAram_sound3_voiceId                           = makeAramReader(0x47D, 1)
sm.getAram_sound3_voiceBitsets                      = makeAramReader(0x47E, 1, false, 1)
sm.getAram_sound3_voiceMasks                        = makeAramReader(0x480, 1, false, 1)
sm.getAram_sound3_2i_channel                        = makeAramReader(0x482, 1)
sm.getAram_sound3_voiceIndices                      = makeAramReader(0x483, 1, false, 1)
sm.getAram_sound3_enabledVoices                     = makeAramReader(0x485, 1)
sm.getAram_sound3_dspIndices                        = makeAramReader(0x486, 1, false, 1)
sm.getAram_sound3_trackOutputVolumeBackups          = makeAramReader(0x488, 1, false, 2)
sm.getAram_sound3_trackPhaseInversionOptionsBackups = makeAramReader(0x489, 1, false, 2)
sm.getAram_sound3_releaseFlags                      = makeAramReader(0x48C, 1, false, 2)
sm.getAram_sound3_releaseTimers                     = makeAramReader(0x48D, 1, false, 2)
sm.getAram_sound3_repeatCounters                    = makeAramReader(0x490, 1, false, 1)
sm.getAram_sound3_repeatPoints                      = makeAramReader(0x492, 1, false, 1)
sm.getAram_sound3_adsrSettings                      = makeAramReader(0x494, 1, false, 2)
sm.getAram_sound3_updateAdsrSettingsFlags           = makeAramReader(0x498, 1, false, 1)
sm.getAram_sound3_notes                             = makeAramReader(0x49A, 1, false, 7)
sm.getAram_sound3_subnotes                          = makeAramReader(0x49B, 1, false, 7)
sm.getAram_sound3_subnoteDeltas                     = makeAramReader(0x49C, 1, false, 7)
sm.getAram_sound3_targetNotes                       = makeAramReader(0x49D, 1, false, 7)
sm.getAram_sound3_pitchSlideFlags                   = makeAramReader(0x49E, 1, false, 7)
sm.getAram_sound3_legatoFlags                       = makeAramReader(0x49F, 1, false, 7)
sm.getAram_sound3_pitchSlideLegatoFlags             = makeAramReader(0x4A0, 1, false, 7)

sm.getAram_disableProcessingCpuIo2 = makeAramReader(0x4A9, 1)
sm.getAram_i_echoFirFilterSet      = makeAramReader(0x4B1, 1)
sm.getAram_sound3LowHealthPriority = makeAramReader(0x4BA, 1)
sm.getAram_sound_priorities        = makeAramReader(0x4BB, 1, false, 1)

sm.getAram_echoBuffer          = makeAramReader(0x500, 1, false, 1)
sm.getAram_noteRingLengthTable = makeAramReader(0x5800, 1, false, 1)
sm.getAram_noteVolumeTable     = makeAramReader(0x5808, 1, false, 1)
sm.getAram_trackerData         = makeAramReader(0x6C00, 1, false, 1)
sm.getAram_instrumentTable     = makeAramReader(0x6C00, 1, false, 1)
sm.getAram_sampleTable         = makeAramReader(0x6D00, 1, false, 1)
sm.getAram_sampleData          = makeAramReader(0x6E00, 1, false, 1)

-- Wrapper readers
sm.getAram_i_sound                                 = makeAggregateReader({sm.getAram_i_sound1                                , sm.getAram_i_sound2                                , sm.getAram_i_sound3                                })
sm.getAram_sound_instructionListPointerSet         = makeAggregateReader({sm.getAram_sound1_instructionListPointerSet        , sm.getAram_sound2_instructionListPointerSet        , sm.getAram_sound3_instructionListPointerSet        })
sm.getAram_sound_p_charVoiceBitset                 = makeAggregateReader({sm.getAram_sound1_p_charVoiceBitset                , sm.getAram_sound2_p_charVoiceBitset                , sm.getAram_sound3_p_charVoiceBitset                })
sm.getAram_sound_p_charVoiceMask                   = makeAggregateReader({sm.getAram_sound1_p_charVoiceMask                  , sm.getAram_sound2_p_charVoiceMask                  , sm.getAram_sound3_p_charVoiceMask                  })
sm.getAram_sound_p_charVoiceIndex                  = makeAggregateReader({sm.getAram_sound1_p_charVoiceIndex                 , sm.getAram_sound2_p_charVoiceIndex                 , sm.getAram_sound3_p_charVoiceIndex                 })
sm.getAram_sound                                   = makeAggregateReader({sm.getAram_sound1                                  , sm.getAram_sound2                                  , sm.getAram_sound3                                  })
sm.getAram_sound_i_instructionLists                = makeAggregateReader({sm.getAram_sound1_i_instructionLists               , sm.getAram_sound2_i_instructionLists               , sm.getAram_sound3_i_instructionLists               })
sm.getAram_sound_instructionTimers                 = makeAggregateReader({sm.getAram_sound1_instructionTimers                , sm.getAram_sound2_instructionTimers                , sm.getAram_sound3_instructionTimers                })
sm.getAram_sound_disableBytes                      = makeAggregateReader({sm.getAram_sound1_disableBytes                     , sm.getAram_sound2_disableBytes                     , sm.getAram_sound3_disableBytes                     })
sm.getAram_sound_i_channel                         = makeAggregateReader({sm.getAram_sound1_i_channel                        , sm.getAram_sound2_i_channel                        , sm.getAram_sound3_i_channel                        })
sm.getAram_sound_n_voices                          = makeAggregateReader({sm.getAram_sound1_n_voices                         , sm.getAram_sound2_n_voices                         , sm.getAram_sound3_n_voices                         })
sm.getAram_sound_i_voice                           = makeAggregateReader({sm.getAram_sound1_i_voice                          , sm.getAram_sound2_i_voice                          , sm.getAram_sound3_i_voice                          })
sm.getAram_sound_remainingEnabledSoundVoices       = makeAggregateReader({sm.getAram_sound1_remainingEnabledSoundVoices      , sm.getAram_sound2_remainingEnabledSoundVoices      , sm.getAram_sound3_remainingEnabledSoundVoices      })
sm.getAram_sound_initialisationFlag                = makeAggregateReader({sm.getAram_sound1_initialisationFlag               , sm.getAram_sound2_initialisationFlag               , sm.getAram_sound3_initialisationFlag               })
sm.getAram_sound_voiceId                           = makeAggregateReader({sm.getAram_sound1_voiceId                          , sm.getAram_sound2_voiceId                          , sm.getAram_sound3_voiceId                          })
sm.getAram_sound_voiceBitsets                      = makeAggregateReader({sm.getAram_sound1_voiceBitsets                     , sm.getAram_sound2_voiceBitsets                     , sm.getAram_sound3_voiceBitsets                     })
sm.getAram_sound_voiceMasks                        = makeAggregateReader({sm.getAram_sound1_voiceMasks                       , sm.getAram_sound2_voiceMasks                       , sm.getAram_sound3_voiceMasks                       })
sm.getAram_sound_2i_channel                        = makeAggregateReader({sm.getAram_sound1_2i_channel                       , sm.getAram_sound2_2i_channel                       , sm.getAram_sound3_2i_channel                       })
sm.getAram_sound_voiceIndices                      = makeAggregateReader({sm.getAram_sound1_voiceIndices                     , sm.getAram_sound2_voiceIndices                     , sm.getAram_sound3_voiceIndices                     })
sm.getAram_sound_enabledVoices                     = makeAggregateReader({sm.getAram_sound1_enabledVoices                    , sm.getAram_sound2_enabledVoices                    , sm.getAram_sound3_enabledVoices                    })
sm.getAram_sound_dspIndices                        = makeAggregateReader({sm.getAram_sound1_dspIndices                       , sm.getAram_sound2_dspIndices                       , sm.getAram_sound3_dspIndices                       })
sm.getAram_sound_trackOutputVolumeBackups          = makeAggregateReader({sm.getAram_sound1_trackOutputVolumeBackups         , sm.getAram_sound2_trackOutputVolumeBackups         , sm.getAram_sound3_trackOutputVolumeBackups         })
sm.getAram_sound_trackPhaseInversionOptionsBackups = makeAggregateReader({sm.getAram_sound1_trackPhaseInversionOptionsBackups, sm.getAram_sound2_trackPhaseInversionOptionsBackups, sm.getAram_sound3_trackPhaseInversionOptionsBackups})
sm.getAram_sound_releaseFlags                      = makeAggregateReader({sm.getAram_sound1_releaseFlags                     , sm.getAram_sound2_releaseFlags                     , sm.getAram_sound3_releaseFlags                     })
sm.getAram_sound_releaseTimers                     = makeAggregateReader({sm.getAram_sound1_releaseTimers                    , sm.getAram_sound2_releaseTimers                    , sm.getAram_sound3_releaseTimers                    })
sm.getAram_sound_repeatCounters                    = makeAggregateReader({sm.getAram_sound1_repeatCounters                   , sm.getAram_sound2_repeatCounters                   , sm.getAram_sound3_repeatCounters                   })
sm.getAram_sound_repeatPoints                      = makeAggregateReader({sm.getAram_sound1_repeatPoints                     , sm.getAram_sound2_repeatPoints                     , sm.getAram_sound3_repeatPoints                     })
sm.getAram_sound_adsrSettings                      = makeAggregateReader({sm.getAram_sound1_adsrSettings                     , sm.getAram_sound2_adsrSettings                     , sm.getAram_sound3_adsrSettings                     })
sm.getAram_sound_updateAdsrSettingsFlags           = makeAggregateReader({sm.getAram_sound1_updateAdsrSettingsFlags          , sm.getAram_sound2_updateAdsrSettingsFlags          , sm.getAram_sound3_updateAdsrSettingsFlags          })
sm.getAram_sound_notes                             = makeAggregateReader({sm.getAram_sound1_notes                            , sm.getAram_sound2_notes                            , sm.getAram_sound3_notes                            })
sm.getAram_sound_subnotes                          = makeAggregateReader({sm.getAram_sound1_subnotes                         , sm.getAram_sound2_subnotes                         , sm.getAram_sound3_subnotes                         })
sm.getAram_sound_subnoteDeltas                     = makeAggregateReader({sm.getAram_sound1_subnoteDeltas                    , sm.getAram_sound2_subnoteDeltas                    , sm.getAram_sound3_subnoteDeltas                    })
sm.getAram_sound_targetNotes                       = makeAggregateReader({sm.getAram_sound1_targetNotes                      , sm.getAram_sound2_targetNotes                      , sm.getAram_sound3_targetNotes                      })
sm.getAram_sound_pitchSlideFlags                   = makeAggregateReader({sm.getAram_sound1_pitchSlideFlags                  , sm.getAram_sound2_pitchSlideFlags                  , sm.getAram_sound3_pitchSlideFlags                  })
sm.getAram_sound_legatoFlags                       = makeAggregateReader({sm.getAram_sound1_legatoFlags                      , sm.getAram_sound2_legatoFlags                      , sm.getAram_sound3_legatoFlags                      })
sm.getAram_sound_pitchSlideLegatoFlags             = makeAggregateReader({sm.getAram_sound1_pitchSlideLegatoFlags            , sm.getAram_sound2_pitchSlideLegatoFlags            , sm.getAram_sound3_pitchSlideLegatoFlags            })

sm.getAram_sound1_p_instructionList = makeAggregateReader({sm.getAram_sound1_channel0_p_instructionList, sm.getAram_sound1_channel1_p_instructionList, sm.getAram_sound1_channel2_p_instructionList, sm.getAram_sound1_channel3_p_instructionList})
sm.getAram_sound2_p_instructionList = makeAggregateReader({sm.getAram_sound2_channel0_p_instructionList, sm.getAram_sound2_channel1_p_instructionList})
sm.getAram_sound3_p_instructionList = makeAggregateReader({sm.getAram_sound3_channel0_p_instructionList, sm.getAram_sound3_channel1_p_instructionList})
sm.getAram_sound_p_instructionList = makeAggregateReader({sm.getAram_sound1_p_instructionList, sm.getAram_sound2_p_instructionList, sm.getAram_sound3_p_instructionList})

--[[
-- CPU IO cache registers
sm.getAram_cpuIo_read                              = makeAramReader(0x0, 1, false, 1)
sm.getAram_cpuIo_write                             = makeAramReader(0x4, 1, false, 1)
sm.getAram_cpuIo_read_prev                         = makeAramReader(0x8, 1, false, 1)

sm.getAram_musicTrackStatus                        = makeAramReader(0xC, 1)
sm.getAram_zero                                    = makeAramReader(0xD, 2)

-- Temporaries
sm.getAram_note                                    = makeAramReader(0xF, 2)
sm.getAram_panningBias                             = makeAramReader(0xF, 2)
sm.getAram_dspVoiceVolumeIndex                     = makeAramReader(0x11, 1)
sm.getAram_noteModifiedFlag                        = makeAramReader(0x12, 1)
sm.getAram_misc0                                   = makeAramReader(0x13, 2)
sm.getAram_misc1                                   = makeAramReader(0x15, 2)

sm.getAram_randomNumber                            = makeAramReader(0x17, 2)
sm.getAram_enableSoundEffectVoices                 = makeAramReader(0x19, 1)
sm.getAram_disableNoteProcessing                   = makeAramReader(0x1A, 1)
sm.getAram_p_return                                = makeAramReader(0x1B, 2)

-- Sound 1
sm.getAram_sound1_instructionListPointerSet        = makeAramReader(0x1D, 2)
sm.getAram_sound1_p_charVoiceBitset                = makeAramReader(0x1F, 2)
sm.getAram_sound1_p_charVoiceMask                  = makeAramReader(0x21, 2)
sm.getAram_sound1_p_charVoiceIndex                 = makeAramReader(0x23, 2)

-- Sounds
sm.getAram_sound_p_instructionListsLow             = makeAramReader(0x25, 1, false, 1)
sm.getAram_sound_p_instructionListsHigh            = makeAramReader(0x2D, 1, false, 1)

sm.getAram_trackPointers                           = makeAramReader(0x35, 2, false, 2)
sm.getAram_p_tracker                               = makeAramReader(0x45, 2)

-- TODO: this is invalidated up to 0xF0
sm.getAram_trackerTimer                            = makeAramReader(0x47, 1)
sm.getAram_soundEffectsClock                       = makeAramReader(0x48, 1)
sm.getAram_trackIndex                              = makeAramReader(0x49, 1)

-- DSP cache
sm.getAram_keyOnFlags                              = makeAramReader(0x4A, 1)
sm.getAram_keyOffFlags                             = makeAramReader(0x4B, 1)
sm.getAram_musicVoiceBitset                        = makeAramReader(0x4C, 1)
sm.getAram_flg                                     = makeAramReader(0x4D, 1)
sm.getAram_noiseEnableFlags                        = makeAramReader(0x4E, 1)
sm.getAram_echoEnableFlags                         = makeAramReader(0x4F, 1)
sm.getAram_pitchModulationFlags                    = makeAramReader(0x50, 1)

-- Echo
sm.getAram_echoTimer                               = makeAramReader(0x51, 1)
sm.getAram_echoDelay                               = makeAramReader(0x52, 1)
sm.getAram_echoFeedbackVolume                      = makeAramReader(0x53, 1)

-- Music
sm.getAram_musicTranspose                          = makeAramReader(0x54, 1)
sm.getAram_musicTrackClock                         = makeAramReader(0x55, 1)
sm.getAram_musicTempo                              = makeAramReader(0x56, 2)
sm.getAram_dynamicMusicTempoTimer                  = makeAramReader(0x58, 1)
sm.getAram_targetMusicTempo                        = makeAramReader(0x59, 1)
sm.getAram_musicTempoDelta                         = makeAramReader(0x5A, 2)
sm.getAram_musicVolume                             = makeAramReader(0x5C, 2)
sm.getAram_dynamicMusicVolumeTimer                 = makeAramReader(0x5E, 1)
sm.getAram_targetMusicVolume                       = makeAramReader(0x5F, 1)
sm.getAram_musicVolumeDelta                        = makeAramReader(0x60, 2)
sm.getAram_musicVoiceVolumeUpdateBitset            = makeAramReader(0x62, 1)
sm.getAram_percussionInstrumentsBaseIndex          = makeAramReader(0x63, 1)

-- Echo
sm.getAram_echoVolumeLeft                          = makeAramReader(0x64, 2)
sm.getAram_echoVolumeRight                         = makeAramReader(0x66, 2)
sm.getAram_echoVolumeLeftDelta                     = makeAramReader(0x68, 2)
sm.getAram_echoVolumeRightDelta                    = makeAramReader(0x6A, 2)
sm.getAram_dynamicEchoVolumeTimer                  = makeAramReader(0x6C, 1)
sm.getAram_targetEchoVolumeLeft                    = makeAramReader(0x6D, 1)
sm.getAram_targetEchoVolumeRight                   = makeAramReader(0x6E, 1)

-- Track
sm.getAram_trackNoteTimers                         = makeAramReader(0x6F, 1, false, 2)
sm.getAram_trackNoteRingTimers                     = makeAramReader(0x70, 1, false, 2)
sm.getAram_trackRepeatedSubsectionCounters         = makeAramReader(0x7F, 1, false, 2)
sm.getAram_trackDynamicVolumeTimers                = makeAramReader(0x80, 1, false, 2)
sm.getAram_trackDynamicPanningTimers               = makeAramReader(0x8F, 1, false, 2)
sm.getAram_trackPitchSlideTimers                   = makeAramReader(0x90, 1, false, 2)
sm.getAram_trackPitchSlideDelayTimers              = makeAramReader(0x9F, 1, false, 2)
sm.getAram_trackVibratoDelayTimers                 = makeAramReader(0xA0, 1, false, 2)
sm.getAram_trackVibratoExtents                     = makeAramReader(0xAF, 1, false, 2)
sm.getAram_trackTremoloDelayTimers                 = makeAramReader(0xB0, 1, false, 2)
sm.getAram_trackTremoloExtents                     = makeAramReader(0xBF, 1, false, 2)

-- Sounds
sm.getAram_p_echoBuffer                            = makeAramReader(0xCE, 2)
sm.getAram_sound2_instructionListPointerSet        = makeAramReader(0xD0, 2)
sm.getAram_sound2_p_charVoiceBitset                = makeAramReader(0xD2, 2)
sm.getAram_sound2_p_charVoiceMask                  = makeAramReader(0xD4, 2)
sm.getAram_sound2_p_charVoiceIndex                 = makeAramReader(0xD6, 2)
sm.getAram_sound3_instructionListPointerSet        = makeAramReader(0xD8, 2)
sm.getAram_sound3_p_charVoiceBitset                = makeAramReader(0xDA, 2)
sm.getAram_sound3_p_charVoiceMask                  = makeAramReader(0xDC, 2)
sm.getAram_sound3_p_charVoiceIndex                 = makeAramReader(0xDE, 2)

sm.getAram_trackDynamicVibratoTimers               = makeAramReader(0x100, 1, false, 2)

-- Music
sm.getAram_trackNoteLengths                        = makeAramReader(0x200, 1, false, 2)
sm.getAram_trackNoteRingLengths                    = makeAramReader(0x201, 1, false, 2)
sm.getAram_trackNoteVolume                         = makeAramReader(0x210, 1, false, 2)
sm.getAram_trackInstrumentIndices                  = makeAramReader(0x211, 1, false, 2)
sm.getAram_trackInstrumentPitches                  = makeAramReader(0x220, 1, false, 2)
sm.getAram_trackRepeatedSubsectionAddresses        = makeAramReader(0x230, 1, false, 2)
sm.getAram_trackRepeatedSubsectionReturnAddresses  = makeAramReader(0x240, 1, false, 2)
sm.getAram_trackSlideLengths                       = makeAramReader(0x250, 1, false, 2)
sm.getAram_trackSlideDelays                        = makeAramReader(0x251, 1, false, 2)
sm.getAram_trackSlideDirections                    = makeAramReader(0x260, 1, false, 2)
sm.getAram_trackSlideExtents                       = makeAramReader(0x261, 1, false, 2)
sm.getAram_trackVibratoPhases                      = makeAramReader(0x270, 1, false, 2)
sm.getAram_trackVibratoRates                       = makeAramReader(0x271, 1, false, 2)
sm.getAram_trackVibratoDelays                      = makeAramReader(0x280, 1, false, 2)
sm.getAram_trackDynamicVibratoLengths              = makeAramReader(0x281, 1, false, 2)
sm.getAram_trackVibratoExtentDeltas                = makeAramReader(0x290, 1, false, 2)
sm.getAram_trackStaticVibratoExtents               = makeAramReader(0x291, 1, false, 2)
sm.getAram_trackTremoloPhases                      = makeAramReader(0x2A0, 1, false, 2)
sm.getAram_trackTremoloRates                       = makeAramReader(0x2A1, 1, false, 2)
sm.getAram_trackTremoloDelays                      = makeAramReader(0x2B0, 1, false, 2)
sm.getAram_trackTransposes                         = makeAramReader(0x2B1, 1, false, 2)
sm.getAram_trackVolumes                            = makeAramReader(0x2C0, 1, false, 2)
sm.getAram_trackVolumeDeltas                       = makeAramReader(0x2D0, 1, false, 2)
sm.getAram_trackTargetVolumes                      = makeAramReader(0x2E0, 1, false, 2)
sm.getAram_trackOutputVolumes                      = makeAramReader(0x2E1, 1, false, 2)
sm.getAram_trackPanningBiases                      = makeAramReader(0x2F0, 1, false, 2)
sm.getAram_trackPanningBiasDeltas                  = makeAramReader(0x300, 1, false, 2)
sm.getAram_trackTargetPanningBiases                = makeAramReader(0x310, 1, false, 2)
sm.getAram_trackPhaseInversionOptions              = makeAramReader(0x311, 1, false, 2)
sm.getAram_trackSubnotes                           = makeAramReader(0x320, 1, false, 2)
sm.getAram_trackNotes                              = makeAramReader(0x321, 1, false, 2)
sm.getAram_trackNoteDeltas                         = makeAramReader(0x330, 1, false, 2)
sm.getAram_trackTargetNotes                        = makeAramReader(0x340, 1, false, 2)
sm.getAram_trackSubtransposes                      = makeAramReader(0x341, 1, false, 2)
sm.getAram_trackSkipNewNotesFlags                  = makeAramReader(0x350, 1, false, 2)

sm.getAram_i_globalChannel                         = makeAramReader(0x35F, 1)
sm.getAram_i_voice                                 = makeAramReader(0x360, 1)
sm.getAram_i_soundLibrary                          = makeAramReader(0x351, 1)

-- Sound 1
sm.getAram_i_sound1                                = makeAramReader(0x362, 1)
sm.getAram_sound1_i_channel                        = makeAramReader(0x363, 1)
sm.getAram_sound1_n_voices                         = makeAramReader(0x364, 1)
sm.getAram_sound1_i_voice                          = makeAramReader(0x365, 1)
sm.getAram_sound1_remainingEnabledSoundVoices      = makeAramReader(0x366, 1)
sm.getAram_sound1_voiceId                          = makeAramReader(0x367, 1)
sm.getAram_sound1_2i_channel                       = makeAramReader(0x368, 1)

-- Sound 2
sm.getAram_i_sound2                                = makeAramReader(0x369, 1)
sm.getAram_sound2_i_channel                        = makeAramReader(0x36A, 1)
sm.getAram_sound2_n_voices                         = makeAramReader(0x36B, 1)
sm.getAram_sound2_i_voice                          = makeAramReader(0x36C, 1)
sm.getAram_sound2_remainingEnabledSoundVoices      = makeAramReader(0x36D, 1)
sm.getAram_sound2_voiceId                          = makeAramReader(0x36E, 1)
sm.getAram_sound2_2i_channel                       = makeAramReader(0x36F, 1)

-- Sound 3
sm.getAram_i_sound3                                = makeAramReader(0x370, 1)
sm.getAram_sound3_i_channel                        = makeAramReader(0x371, 1)
sm.getAram_sound3_n_voices                         = makeAramReader(0x372, 1)
sm.getAram_sound3_i_voice                          = makeAramReader(0x373, 1)
sm.getAram_sound3_remainingEnabledSoundVoices      = makeAramReader(0x374, 1)
sm.getAram_sound3_voiceId                          = makeAramReader(0x375, 1)
sm.getAram_sound3_2i_channel                       = makeAramReader(0x376, 1)

-- Sounds
sm.getAram_sounds                                  = makeAramReader(0x377, 1, false, 1)
sm.getAram_sound_enabledVoices                     = makeAramReader(0x37A, 1, false, 1)
sm.getAram_sound_priorities                        = makeAramReader(0x37D, 1, false, 1)
sm.getAram_sound_initialisationFlags               = makeAramReader(0x380, 1, false, 1)

-- Sound channels
sm.getAram_sound_i_instructionLists                = makeAramReader(0x383, 1, false, 1)
sm.getAram_sound_instructionTimers                 = makeAramReader(0x38B, 1, false, 1)
sm.getAram_sound_disableBytes                      = makeAramReader(0x393, 1, false, 1)
sm.getAram_sound_voiceBitsets                      = makeAramReader(0x39B, 1, false, 1)
sm.getAram_sound_voiceMasks                        = makeAramReader(0x3A3, 1, false, 1)
sm.getAram_sound_voiceIndices                      = makeAramReader(0x3AB, 1, false, 1)
sm.getAram_sound_dspIndices                        = makeAramReader(0x3B3, 1, false, 1)
sm.getAram_sound_trackOutputVolumeBackups          = makeAramReader(0x3BB, 1, false, 1)
sm.getAram_sound_trackPhaseInversionOptionsBackups = makeAramReader(0x3C3, 1, false, 1)
sm.getAram_sound_releaseFlags                      = makeAramReader(0x3CB, 1, false, 1)
sm.getAram_sound_releaseTimers                     = makeAramReader(0x3D3, 1, false, 1)
sm.getAram_sound_repeatCounters                    = makeAramReader(0x3DB, 1, false, 1)
sm.getAram_sound_repeatPoints                      = makeAramReader(0x3E3, 1, false, 1)
sm.getAram_sound_adsrSettingsLow                   = makeAramReader(0x3EB, 1, false, 1)
sm.getAram_sound_adsrSettingsHigh                  = makeAramReader(0x3F3, 1, false, 1)
sm.getAram_sound_updateAdsrSettingsFlags           = makeAramReader(0x3FB, 1, false, 1)
sm.getAram_sound_notes                             = makeAramReader(0x403, 1, false, 1)
sm.getAram_sound_subnotes                          = makeAramReader(0x40B, 1, false, 1)
sm.getAram_sound_subnoteDeltas                     = makeAramReader(0x413, 1, false, 1)
sm.getAram_sound_targetNotes                       = makeAramReader(0x41B, 1, false, 1)
sm.getAram_sound_pitchSlideFlags                   = makeAramReader(0x423, 1, false, 1)
sm.getAram_sound_legatoFlags                       = makeAramReader(0x42B, 1, false, 1)
sm.getAram_sound_pitchSlideLegatoFlags             = makeAramReader(0x433, 1, false, 1)

sm.getAram_disableProcessingCpuIo2                 = makeAramReader(0x43B, 1)
sm.getAram_i_echoFirFilterSet                      = makeAramReader(0x43C, 1)
sm.getAram_sound3LowHealthPriority                 = makeAramReader(0x43D, 1)

sm.getAram_noteRingLengthTable                     = makeAramReader(0x3855, 1, false, 1)
sm.getAram_noteVolumeTable                         = makeAramReader(0x385D, 1, false, 1)
sm.getAram_instrumentTable                         = makeAramReader(0x386D, 1, false, 1)
sm.getAram_trackerData                             = makeAramReader(0x3957, 1, false, 1)
sm.getAram_sampleTable                             = makeAramReader(0x4A00, 1, false, 1)
sm.getAram_sampleData_echoBuffer                   = makeAramReader(0x4B00, 1, false, 1)
-- ]]

-- ---------------------------------------------------------------------------
-- Converted Super Hitbox script
-- ---------------------------------------------------------------------------
if console and console.clear then
    console.clear()
elseif print then
    print("\n\n\n\n\n\n\n\n")
    print("\n\n\n\n\n\n\n\n")
end

if gui and gui.clearGraphics then
    gui.clearGraphics()
elseif emu and emu.clearScreen then
    emu.clearScreen()
end

-- Globals
local recordLagHotspots = true
local debugControlsEnabled = CONFIG.debugControlsEnabled and 1 or 0
local debugFlag = 0
local debugInfoFlag = 0
local doorListFlag = 0
local followSamusFlag = 0--sm.button_B
local tasFlag = 0
local logFlag = 0
local xAdjust = 0
local yAdjust = 0
local doorList = {}

-- Block/BTS label runtime state, configured in CONFIG.blockLabels at the top.
local blockLabelConfig = CONFIG.blockLabels or {}
local debugBlockTextFilterEnabled = blockLabelConfig.filterEnabledByDefault ~= false

-- Colour constants, configured in CONFIG.colours at the top.
-- The original script stores source colours in 0xRRGGBBAA form.
local colourConfig = CONFIG.colours or {}
local colour_opacity = colourConfig.opacity or 0xFF
local colour_scroll_opacity = colourConfig.scrollOpacity or colour_opacity
local colour_slope_opacity = colourConfig.slopeOpacity or colour_opacity

local function rgba(r, g, b, a)
    return xemu.lshift(xemu.and_(r, 0xFF), 24)
         + xemu.lshift(xemu.and_(g, 0xFF), 16)
         + xemu.lshift(xemu.and_(b, 0xFF), 8)
         + xemu.and_(a == nil and colour_opacity or a, 0xFF)
end

local function rgbaFromConfig(name, fallback, alpha)
    local c = colourConfig[name] or fallback
    return rgba(c[1], c[2], c[3], alpha)
end

local colour_slope        = rgbaFromConfig("slope",           {0x00, 0xFF, 0x00}, colour_slope_opacity)
local colour_solidBlock   = rgbaFromConfig("solidBlock",      {0xFF, 0x00, 0x00}, colour_opacity)
local colour_specialBlock = rgbaFromConfig("specialBlock",    {0x00, 0x00, 0xFF}, colour_opacity)
local colour_doorBlock    = rgbaFromConfig("doorBlock",       {0x00, 0xFF, 0xFF}, colour_opacity)
local colour_doorcap      = rgbaFromConfig("doorcap",         {0xFF, 0x80, 0x00}, colour_opacity)
local colour_errorBlock   = rgbaFromConfig("errorBlock",      {0x80, 0x00, 0xFF}, colour_opacity)

local colour_scroll_red   = rgbaFromConfig("scrollRed",       {0xFF, 0x00, 0x00}, colour_scroll_opacity)
local colour_scroll_blue  = rgbaFromConfig("scrollBlue",      {0x00, 0x00, 0xFF}, colour_scroll_opacity)
local colour_scroll_green = rgbaFromConfig("scrollGreen",     {0x00, 0xFF, 0x00}, colour_scroll_opacity)

local colour_enemy           = rgbaFromConfig("enemy",           {0xFF, 0xFF, 0xFF}, colour_opacity)
local colour_spriteObject    = rgbaFromConfig("spriteObject",    {0xFF, 0x80, 0x00}, colour_opacity)
local colour_enemyProjectile = rgbaFromConfig("enemyProjectile", {0x00, 0xFF, 0x00}, colour_opacity)
local colour_powerBomb       = rgbaFromConfig("powerBomb",       {0xFF, 0xFF, 0xFF}, colour_opacity)
local colour_projectile      = rgbaFromConfig("projectile",      {0xFF, 0xFF, 0x00}, colour_opacity)
local colour_samus           = rgbaFromConfig("samus",           {0x00, 0xFF, 0xFF}, colour_opacity)
local colour_camera          = rgbaFromConfig("camera",          {0x80, 0x80, 0x80}, colour_opacity)

-- Add padding borders in BizHawk (highly resource intensive)
local xExtra = 0
local yExtra = 0
if xemu.emuId == xemu.emuId_bizhawk then
    --xExtra = 256
    --yExtra = 224
    client.SetGameExtraPadding(xExtra, yExtra, xExtra, yExtra)
end

local xExtraBlocks = xemu.rshift(xExtra, 4)
local yExtraBlocks = xemu.rshift(yExtra, 4)

local xExtraScrolls = xemu.rshift(xExtraBlocks, 4)
local yExtraScrolls = xemu.rshift(yExtraBlocks, 4)

-- Adjust drawing to account for the borders
function drawText(x, y, text, fg, bg)
    xemu.drawText(x + xExtra, y + yExtra, text, fg, bg or "black")
end

function drawBox(x0, y0, x1, y1, fg, bg)
    xemu.drawBox(x0 + xExtra, y0 + yExtra, x1 + xExtra, y1 + yExtra, fg, bg or "clear")
end

function drawLine(x0, y0, x1, y1, fg)
    xemu.drawLine(x0 + xExtra, y0 + yExtra, x1 + xExtra, y1 + yExtra, fg)
end

function drawRightTriangle(x0, y0, x1, y1, fg)
    drawLine(x0, y0, x1, y1, fg)
    drawLine(x0, y0, x1, y0, fg)
    drawLine(x1, y0, x1, y1, fg)
end



-- A door database for finding valid OoB doors
local doors = {[0x88FE]=true, [0x890A]=true, [0x8916]=true, [0x8922]=true, [0x892E]=true, [0x893A]=true, [0x8946]=true, [0x8952]=true, [0x895E]=true, [0x896A]=true, [0x8976]=true, [0x8982]=true, [0x898E]=true, [0x899A]=true, [0x89A6]=true, [0x89B2]=true, [0x89BE]=true, [0x89CA]=true, [0x89D6]=true, [0x89E2]=true, [0x89EE]=true, [0x89FA]=true, [0x8A06]=true, [0x8A12]=true, [0x8A1E]=true, [0x8A2A]=true, [0x8A36]=true, [0x8A42]=true, [0x8A4E]=true, [0x8A5A]=true, [0x8A66]=true, [0x8A72]=true, [0x8A7E]=true, [0x8A8A]=true, [0x8A96]=true, [0x8AA2]=true, [0x8AAE]=true, [0x8ABA]=true, [0x8AC6]=true, [0x8AD2]=true, [0x8ADE]=true, [0x8AEA]=true, [0x8AF6]=true, [0x8B02]=true, [0x8B0E]=true, [0x8B1A]=true, [0x8B26]=true, [0x8B32]=true, [0x8B3E]=true, [0x8B4A]=true, [0x8B56]=true, [0x8B62]=true, [0x8B6E]=true, [0x8B7A]=true, [0x8B86]=true, [0x8B92]=true, [0x8B9E]=true, [0x8BAA]=true, [0x8BB6]=true, [0x8BC2]=true, [0x8BCE]=true, [0x8BDA]=true, [0x8BE6]=true, [0x8BF2]=true, [0x8BFE]=true, [0x8C0A]=true, [0x8C16]=true, [0x8C22]=true, [0x8C2E]=true, [0x8C3A]=true, [0x8C46]=true, [0x8C52]=true, [0x8C5E]=true, [0x8C6A]=true, [0x8C76]=true, [0x8C82]=true, [0x8C8E]=true, [0x8C9A]=true, [0x8CA6]=true, [0x8CB2]=true, [0x8CBE]=true, [0x8CCA]=true, [0x8CD6]=true, [0x8CE2]=true, [0x8CEE]=true, [0x8CFA]=true, [0x8D06]=true, [0x8D12]=true, [0x8D1E]=true, [0x8D2A]=true, [0x8D36]=true, [0x8D42]=true, [0x8D4E]=true, [0x8D5A]=true, [0x8D66]=true, [0x8D72]=true, [0x8D7E]=true, [0x8D8A]=true, [0x8D96]=true, [0x8DA2]=true, [0x8DAE]=true, [0x8DBA]=true, [0x8DC6]=true, [0x8DD2]=true, [0x8DDE]=true, [0x8DEA]=true, [0x8DF6]=true, [0x8E02]=true, [0x8E0E]=true, [0x8E1A]=true, [0x8E26]=true, [0x8E32]=true, [0x8E3E]=true, [0x8E4A]=true, [0x8E56]=true, [0x8E62]=true, [0x8E6E]=true, [0x8E7A]=true, [0x8E86]=true, [0x8E92]=true, [0x8E9E]=true, [0x8EAA]=true, [0x8EB6]=true, [0x8EC2]=true, [0x8ECE]=true, [0x8EDA]=true, [0x8EE6]=true, [0x8EF2]=true, [0x8EFE]=true, [0x8F0A]=true, [0x8F16]=true, [0x8F22]=true, [0x8F2E]=true, [0x8F3A]=true, [0x8F46]=true, [0x8F52]=true, [0x8F5E]=true, [0x8F6A]=true, [0x8F76]=true, [0x8F82]=true, [0x8F8E]=true, [0x8F9A]=true, [0x8FA6]=true, [0x8FB2]=true, [0x8FBE]=true, [0x8FCA]=true, [0x8FD6]=true, [0x8FE2]=true, [0x8FEE]=true, [0x8FFA]=true, [0x9006]=true, [0x9012]=true, [0x901E]=true, [0x902A]=true, [0x9036]=true, [0x9042]=true, [0x904E]=true, [0x905A]=true, [0x9066]=true, [0x9072]=true, [0x907E]=true, [0x908A]=true, [0x9096]=true, [0x90A2]=true, [0x90AE]=true, [0x90BA]=true, [0x90C6]=true, [0x90D2]=true, [0x90DE]=true, [0x90EA]=true, [0x90F6]=true, [0x9102]=true, [0x910E]=true, [0x911A]=true, [0x9126]=true, [0x9132]=true, [0x913E]=true, [0x914A]=true, [0x9156]=true, [0x9162]=true, [0x916E]=true, [0x917A]=true, [0x9186]=true, [0x9192]=true, [0x919E]=true, [0x91AA]=true, [0x91B6]=true, [0x91C2]=true, [0x91CE]=true, [0x91DA]=true, [0x91E6]=true, [0x91F2]=true, [0x91FE]=true, [0x920A]=true, [0x9216]=true, [0x9222]=true, [0x922E]=true, [0x923A]=true, [0x9246]=true, [0x9252]=true, [0x925E]=true, [0x926A]=true, [0x9276]=true, [0x9282]=true, [0x928E]=true, [0x929A]=true, [0x92A6]=true, [0x92B2]=true, [0x92BE]=true, [0x92CA]=true, [0x92D6]=true, [0x92E2]=true, [0x92EE]=true, [0x92FA]=true, [0x9306]=true, [0x9312]=true, [0x931E]=true, [0x932A]=true, [0x9336]=true, [0x9342]=true, [0x934E]=true, [0x935A]=true, [0x9366]=true, [0x9372]=true, [0x937E]=true, [0x938A]=true, [0x9396]=true, [0x93A2]=true, [0x93AE]=true, [0x93BA]=true, [0x93C6]=true, [0x93D2]=true, [0x93DE]=true, [0x93EA]=true, [0x93F6]=true, [0x9402]=true, [0x940E]=true, [0x941A]=true, [0x9426]=true, [0x9432]=true, [0x943E]=true, [0x944A]=true, [0x9456]=true, [0x9462]=true, [0x946E]=true, [0x947A]=true, [0x9486]=true, [0x9492]=true, [0x949E]=true, [0x94AA]=true, [0x94B6]=true, [0x94C2]=true, [0x94CE]=true, [0x94DA]=true, [0x94E6]=true, [0x94F2]=true, [0x94FE]=true, [0x950A]=true, [0x9516]=true, [0x9522]=true, [0x952E]=true, [0x953A]=true, [0x9546]=true, [0x9552]=true, [0x955E]=true, [0x956A]=true, [0x9576]=true, [0x9582]=true, [0x958E]=true, [0x959A]=true, [0x95A6]=true, [0x95B2]=true, [0x95BE]=true, [0x95CA]=true, [0x95D6]=true, [0x95E2]=true, [0x95EE]=true, [0x95FA]=true, [0x9606]=true, [0x9612]=true, [0x961E]=true, [0x962A]=true, [0x9636]=true, [0x9642]=true, [0x964E]=true, [0x965A]=true, [0x9666]=true, [0x9672]=true, [0x967E]=true, [0x968A]=true, [0x9696]=true, [0x96A2]=true, [0x96AE]=true, [0x96BA]=true, [0x96C6]=true, [0x96D2]=true, [0x96DE]=true, [0x96EA]=true, [0x96F6]=true, [0x9702]=true, [0x970E]=true, [0x971A]=true, [0x9726]=true, [0x9732]=true, [0x973E]=true, [0x974A]=true, [0x9756]=true, [0x9762]=true, [0x976E]=true, [0x977A]=true, [0x9786]=true, [0x9792]=true, [0x979E]=true, [0x97AA]=true, [0x97B6]=true, [0x97C2]=true, [0x97CE]=true, [0x97DA]=true, [0x97E6]=true, [0x97F2]=true, [0x97FE]=true, [0x980A]=true, [0x9816]=true, [0x9822]=true, [0x982E]=true, [0x983A]=true, [0x9846]=true, [0x9852]=true, [0x985E]=true, [0x986A]=true, [0x9876]=true, [0x9882]=true, [0x988E]=true, [0x989A]=true, [0x98A6]=true, [0x98B2]=true, [0x98BE]=true, [0x98CA]=true, [0x98D6]=true, [0x98E2]=true, [0x98EE]=true, [0x98FA]=true, [0x9906]=true, [0x9912]=true, [0x991E]=true, [0x992A]=true, [0x9936]=true, [0x9942]=true, [0x994E]=true, [0x995A]=true, [0x9966]=true, [0x9972]=true, [0x997E]=true, [0x998A]=true, [0x9996]=true, [0x99A2]=true, [0x99AE]=true, [0x99BA]=true, [0x99C6]=true, [0x99D2]=true, [0x99DE]=true, [0x99EA]=true, [0x99F6]=true, [0x9A02]=true, [0x9A0E]=true, [0x9A1A]=true, [0x9A26]=true, [0x9A32]=true, [0x9A3E]=true, [0x9A4A]=true, [0x9A56]=true, [0x9A62]=true, [0x9A6E]=true, [0x9A7A]=true, [0x9A86]=true, [0x9A92]=true, [0x9A9E]=true, [0x9AAA]=true, [0x9AB6]=true, [0xA18C]=true, [0xA198]=true, [0xA1A4]=true, [0xA1B0]=true, [0xA1BC]=true, [0xA1C8]=true, [0xA1D4]=true, [0xA1E0]=true, [0xA1EC]=true, [0xA1F8]=true, [0xA204]=true, [0xA210]=true, [0xA21C]=true, [0xA228]=true, [0xA234]=true, [0xA240]=true, [0xA24C]=true, [0xA258]=true, [0xA264]=true, [0xA270]=true, [0xA27C]=true, [0xA288]=true, [0xA294]=true, [0xA2A0]=true, [0xA2AC]=true, [0xA2B8]=true, [0xA2C4]=true, [0xA2D0]=true, [0xA2DC]=true, [0xA2E8]=true, [0xA2F4]=true, [0xA300]=true, [0xA30C]=true, [0xA318]=true, [0xA324]=true, [0xA330]=true, [0xA33C]=true, [0xA348]=true, [0xA354]=true, [0xA360]=true, [0xA36C]=true, [0xA378]=true, [0xA384]=true, [0xA390]=true, [0xA39C]=true, [0xA3A8]=true, [0xA3B4]=true, [0xA3C0]=true, [0xA3CC]=true, [0xA3D8]=true, [0xA3E4]=true, [0xA3F0]=true, [0xA3FC]=true, [0xA408]=true, [0xA414]=true, [0xA420]=true, [0xA42C]=true, [0xA438]=true, [0xA444]=true, [0xA450]=true, [0xA45C]=true, [0xA468]=true, [0xA474]=true, [0xA480]=true, [0xA48C]=true, [0xA498]=true, [0xA4A4]=true, [0xA4B0]=true, [0xA4BC]=true, [0xA4C8]=true, [0xA4D4]=true, [0xA4E0]=true, [0xA4EC]=true, [0xA4F8]=true, [0xA504]=true, [0xA510]=true, [0xA51C]=true, [0xA528]=true, [0xA534]=true, [0xA540]=true, [0xA54C]=true, [0xA558]=true, [0xA564]=true, [0xA570]=true, [0xA57C]=true, [0xA588]=true, [0xA594]=true, [0xA5A0]=true, [0xA5AC]=true, [0xA5B8]=true, [0xA5C4]=true, [0xA5D0]=true, [0xA5DC]=true, [0xA5E8]=true, [0xA5F4]=true, [0xA600]=true, [0xA60C]=true, [0xA618]=true, [0xA624]=true, [0xA630]=true, [0xA63C]=true, [0xA648]=true, [0xA654]=true, [0xA660]=true, [0xA66C]=true, [0xA678]=true, [0xA684]=true, [0xA690]=true, [0xA69C]=true, [0xA6A8]=true, [0xA6B4]=true, [0xA6C0]=true, [0xA6CC]=true, [0xA6D8]=true, [0xA6E4]=true, [0xA6F0]=true, [0xA6FC]=true, [0xA708]=true, [0xA714]=true, [0xA720]=true, [0xA72C]=true, [0xA738]=true, [0xA744]=true, [0xA750]=true, [0xA75C]=true, [0xA768]=true, [0xA774]=true, [0xA780]=true, [0xA78C]=true, [0xA798]=true, [0xA7A4]=true, [0xA7B0]=true, [0xA7BC]=true, [0xA7C8]=true, [0xA7D4]=true, [0xA7E0]=true, [0xA7EC]=true, [0xA7F8]=true, [0xA810]=true, [0xA828]=true, [0xA834]=true, [0xA840]=true, [0xA84C]=true, [0xA858]=true, [0xA864]=true, [0xA870]=true, [0xA87C]=true, [0xA888]=true, [0xA894]=true, [0xA8A0]=true, [0xA8AC]=true, [0xA8B8]=true, [0xA8C4]=true, [0xA8D0]=true, [0xA8DC]=true, [0xA8E8]=true, [0xA8F4]=true, [0xA900]=true, [0xA90C]=true, [0xA918]=true, [0xA924]=true, [0xA930]=true, [0xA93C]=true, [0xA948]=true, [0xA954]=true, [0xA960]=true, [0xA96C]=true, [0xA978]=true, [0xA984]=true, [0xA990]=true, [0xA99C]=true, [0xA9A8]=true, [0xA9B4]=true, [0xA9C0]=true, [0xA9CC]=true, [0xA9D8]=true, [0xA9E4]=true, [0xA9F0]=true, [0xA9FC]=true, [0xAA08]=true, [0xAA14]=true, [0xAA20]=true, [0xAA2C]=true, [0xAA38]=true, [0xAA44]=true, [0xAA50]=true, [0xAA5C]=true, [0xAA68]=true, [0xAA74]=true, [0xAA80]=true, [0xAA8C]=true, [0xAA98]=true, [0xAAA4]=true, [0xAAB0]=true, [0xAABC]=true, [0xAAC8]=true, [0xAAD4]=true, [0xAAE0]=true, [0xAAEC]=true, [0xAAF8]=true, [0xAB04]=true, [0xAB10]=true, [0xAB1C]=true, [0xAB28]=true, [0xAB34]=true, [0xAB40]=true, [0xAB4C]=true, [0xAB58]=true, [0xAB64]=true, [0xAB70]=true, [0xAB7C]=true, [0xAB88]=true, [0xAB94]=true, [0xABA0]=true, [0xABAC]=true, [0xABB8]=true, [0xABC4]=true, [0xABCF]=true, [0xABDA]=true, [0xABE5]=true}


-- Draw standard block outline
function standardOutline(colour)
    return function(blockX, blockY, blockIndex, stackLimit)
        drawBox(blockX, blockY, blockX + 15, blockY + 15, colour, "clear")
    end
end

-- Block drawing functions
-- For reasons unbeknownst to me, the recursive calls (for the extension blocks) require this table to be global
outline = {
    -- Air
    [0x00] = function(blockX, blockY, blockIndex, stackLimit) end,

    -- Slope
    [0x01] = function(blockX, blockY, blockIndex, stackLimit)
        local bts = sm.getBts(blockIndex)
        local i_slope = xemu.and_(bts, 0x1F)
        local flip_x = xemu.and_(bts, 0x40) ~= 0
        local flip_y = xemu.and_(bts, 0x80) ~= 0
        
        -- Read slope shape
        local p_slope = 0x948B2B + i_slope * 0x10
        
        local ys = {}
        for x = 0, 0xF do
            ys[x] = xemu.read_u8(p_slope + x)
        end
        
        -- Determine drawable X range
        local x_min
        for x = 0, 0xF do
            if ys[x] < 0x10 then
                x_min = x
                break
            end
        end
        
        if x_min == nil then
            return
        end
        
        local x_max
        for j = 0, 0xF do
            local x = 0xF - j
            if ys[x] < 0x10 then
                x_max = x
                break
            end
        end
        
        -- Natural surface
        for i = x_min + 1, x_max - 1 do
            if ys[i - 1] < 0x10 and ys[i] < 0x10 then
                local y_from = ys[i - 1]
                local y_to = ys[i]
                if flip_y then
                    y_from = 0xF - y_from
                    y_to = 0xF - y_to
                end
                
                local x = i
                if flip_x then
                    x = 0xF - x
                end
                
                xemu.drawPixel(
                    blockX + x, blockY + y_to, 
                    colour_slope
                )
            end
        end
        
        -- Position of natural left, right and bottom edges
        local x_left = x_min
        local x_right = x_max
        if flip_x then
            x_left = 0xF - x_left
            x_right = 0xF - x_right
        end
        
        local y_left = ys[x_min]
        local y_right = ys[x_max]
        local y_base = 0xF
        if flip_y then
            y_base = 0xF - y_base
            y_left = 0xF - y_left
            y_right = 0xF - y_right
        end
        
        -- Natural bottom edge
        xemu.drawLine(
            blockX + x_left,  blockY + y_base, 
            blockX + x_right, blockY + y_base, 
            colour_slope
        )
        
        -- Natural left edge
        xemu.drawLine(
            blockX + x_left, blockY + y_base, 
            blockX + x_left, blockY + y_left, 
            colour_slope
        )
        
        -- Natural right edge
        xemu.drawLine(
            blockX + x_right, blockY + y_base, 
            blockX + x_right, blockY + y_right, 
            colour_slope
        )
    end,

    -- Spike air
    [0x02] = function(blockX, blockY, blockIndex, stackLimit) end,

    -- Special air
    [0x03] = standardOutline(colour_specialBlock),

    -- Shootable air
    [0x04] = function(blockX, blockY, blockIndex, stackLimit) end,

    -- Horizontal extension
    [0x05] = function (blockX, blockY, blockIndex, stackLimit)
        -- Prevents infinite recursion
        if stackLimit == 0 then
            standardOutline(colour_errorBlock)(blockX, blockY, blockIndex, stackLimit)
            return
        end

        stackLimit = stackLimit - 1
        local bts = sm.getBtsSigned(blockIndex)

        -- Infinite recursion, game would probably freeze if this block reacts to anything
        if bts == 0 then
            standardOutline(colour_errorBlock)(blockX, blockY, blockIndex, stackLimit)
            return
        end

        blockIndex = blockIndex + bts
        outline[xemu.rshift(sm.getLevelDatum(blockIndex), 12)](blockX, blockY, blockIndex, stackLimit)
    end,

    -- Unused air
    [0x06] = function(blockX, blockY, blockIndex, stackLimit) end,

    -- Bombable air
    [0x07] = function(blockX, blockY, blockIndex, stackLimit) end,

    -- Solid block
    [0x08] = standardOutline(colour_solidBlock),

    -- Door block
    [0x09] = function(blockX, blockY, blockIndex, stackLimit)
        standardOutline(colour_doorBlock)(blockX, blockY, blockIndex, stackLimit)

        -- Legacy behavior from the original script: door blocks always drew their BTS.
        -- Keep this configurable because the new per-block label system can draw BTS too.
        if not blockLabelConfig.suppressNativeDoorBtsLabels then
            drawText(blockX + 4, blockY + 4, string.format("%02X", sm.getBts(blockIndex)), colour_doorBlock)
        end
    end,

    -- Spike block
    [0x0A] = standardOutline(colour_specialBlock),

    -- Special block
    [0x0B] = standardOutline(colour_specialBlock),

    -- Shootable block
    [0x0C] = function(blockX, blockY, blockIndex, stackLimit)
        -- Colour doors specially
        local bts = sm.getBts(blockIndex)
        if bts >= 0x40 and bts <= 0x43 then
            standardOutline(colour_doorcap)(blockX, blockY, blockIndex, stackLimit)
        else
            standardOutline(colour_specialBlock)(blockX, blockY, blockIndex, stackLimit)
        end
    end,

    -- Vertical extension
    [0x0D] = function(blockX, blockY, blockIndex, stackLimit)
        -- Prevents infinite recursion
        if stackLimit == 0 then
            standardOutline(colour_errorBlock)(blockX, blockY, blockIndex, stackLimit)
            return
        end

        stackLimit = stackLimit - 1
        local bts = sm.getBtsSigned(blockIndex)

        -- Infinite recursion, game would probably freeze if this block reacts to anything
        if bts == 0 then
            standardOutline(colour_errorBlock)(blockX, blockY, blockIndex, stackLimit)
            return
        end

        blockIndex = blockIndex + bts * sm.getRoomWidth()
        outline[xemu.rshift(sm.getLevelDatum(blockIndex), 12)](blockX, blockY, blockIndex, stackLimit)
    end,

    -- Grapple block
    [0x0E] = standardOutline(colour_specialBlock),

    -- Bombable block
    [0x0F] = standardOutline(colour_specialBlock)
}


function isValidLevelData()
    -- The screen refresh should only be done when the game is in a valid state to draw the level data.
    -- Game state 8 is main gameplay, level data is always valid.
    -- Game states 9, Ah and Bh are the various stages of going through a door,
    -- the level data is only invalid when the door transition function is $E36E during game state Bh(?).
    -- Game states Ch..12h are the various stages of pausing and unpausing
    -- the level data is only invalid during game states Eh..10h,
    -- but Dh sets up the BG position for the map
    -- Game state 2Ah is the demo
    local gameState = sm.getGameState()
    local doorTransitionFunction = sm.getDoorTransitionFunction()

    return
           8 <= gameState and gameState < 0xB
        or 0xC <= gameState and gameState < 0xD
        or 0x11 <= gameState and gameState < 0x13
        or 0x2A == gameState
        or gameState == 0xB and doorTransitionFunction ~= 0xE36E
end

function handleDebugControls()
    local input, changedInput, frame = getHotkeyFrameState()
    local controls = ((CONFIG.blockLabels or {}).controls or {})

    if lastDebugControlsFrame == frame then
        return
    end
    lastDebugControlsFrame = frame

    if not hotkeyModifierHeld(input, controls) then
        return
    end

    -- Show the clipdata and BTS text overlay.
    -- If debugBlockTextFilterEnabled is true, only configured block types are labeled.
    if hotkeyPressed(input, changedInput, controls, "toggleLabelsButton", "A") then
        debugFlag = xemu.xor(debugFlag, 1)
        emu.displayMessage("Super Hitbox", debugFlag ~= 0 and "Block/BTS labels on" or "Block/BTS labels off")
    end

    -- Toggle between filtered block/BTS labels and the original show-all behaviour.
    if hotkeyPressed(input, changedInput, controls, "toggleFilterButton", "X") then
        debugBlockTextFilterEnabled = not debugBlockTextFilterEnabled
        emu.displayMessage(
            "Super Hitbox",
            debugBlockTextFilterEnabled and "Block/BTS text: filtered" or "Block/BTS text: all block types"
        )
    end

    -- Show the list of (possibly OoB) door block BTS that exist
    doorListFlag = debugFlag

    -- Optional camera follow toggle. Disabled by default because Select+B is now the hotkey modifier.
    if controls.toggleFollowSamusButton ~= nil and hotkeyPressed(input, changedInput, controls, "toggleFollowSamusButton", nil) then
        followSamusFlag = xemu.xor(followSamusFlag, 1)
        emu.displayMessage("Super Hitbox", followSamusFlag ~= 0 and "Follow Samus on" or "Follow Samus off")
    end

    -- Initialise door list
    for i = 0,0x7F do
        doorList[i] = 0
    end

    -- Old debug nudge controls are off by default to avoid accidental gameplay/practice-hack conflicts.
    if not controls.enablePositionNudgeControls then
        return
    end

    if xemu.and_(input, sm.button_A) ~= 0 then
        -- These move Samus around. Use only for debugging, not route practice.
        local samusXPosition = sm.getSamusXPosition()
        local samusYPosition = sm.getSamusYPosition()
        samusXPosition = xemu.and_(samusXPosition +             xemu.and_(changedInput, sm.button_right),    0xFFFF)
        samusXPosition = xemu.and_(samusXPosition - xemu.rshift(xemu.and_(changedInput, sm.button_left), 1), 0xFFFF)
        samusYPosition = xemu.and_(samusYPosition + xemu.rshift(xemu.and_(changedInput, sm.button_down), 2), 0xFFFF)
        samusYPosition = xemu.and_(samusYPosition - xemu.rshift(xemu.and_(changedInput, sm.button_up),   3), 0xFFFF)
        sm.setSamusXPosition(samusXPosition)
        sm.setSamusYPosition(samusYPosition)
    else
        -- These move the synthetic camera around.
        xAdjust = xAdjust + xemu.rshift(xemu.and_(changedInput, sm.button_right), 8) * 256
        xAdjust = xAdjust - xemu.rshift(xemu.and_(changedInput, sm.button_left),  9) * 256
        yAdjust = yAdjust + xemu.rshift(xemu.and_(changedInput, sm.button_down), 10) * 224
        yAdjust = yAdjust - xemu.rshift(xemu.and_(changedInput, sm.button_up),   11) * 224
    end
end

function displayScrollBoundaries(cameraX, cameraY, roomWidth, viewWidth, viewHeight)
    viewWidth = viewWidth or 256
    viewHeight = viewHeight or 224

    local firstScrollX = -1
    local lastScrollX = math.ceil(viewWidth / 0x100) + 1
    local firstScrollY = -1
    local lastScrollY = math.ceil(viewHeight / 0x100) + 1

    for y = firstScrollY,lastScrollY do
        for x = firstScrollX,lastScrollX do
            local scrollXAbsolute = cameraX + x * 0x100
            local scrollYAbsolute = cameraY + y * 0x100
            if 0 <= scrollXAbsolute and scrollXAbsolute < roomWidth * 0x10 + 0x100 and 0 <= scrollYAbsolute and scrollYAbsolute < sm.getRoomHeight() * 0x10 + 0x100 then
                local scrollX = x * 0x100 - xemu.and_(cameraX, 0xFF)
                local scrollY = y * 0x100 - xemu.and_(cameraY, 0xFF)
            
                local i_scroll = xemu.rshift(scrollYAbsolute, 8) * xemu.rshift(roomWidth, 4) + xemu.rshift(scrollXAbsolute, 8)
                local scroll = sm.getScroll(i_scroll)

                local colour = colour_scroll_red
                if scroll == 1 then
                    colour = colour_scroll_blue
                elseif scroll == 2 then
                    colour = colour_scroll_green
                end

                drawBox(scrollX, scrollY, scrollX + 0xFF, scrollY + 0xFF, colour)
            end
        end
    end
end

function displayCameraMargin()
    local cameraDistanceIndex = sm.getCameraDistanceIndex()
    
    local top = sm.getUpScroller()
    local bottom = sm.getDownScroller()
    local left = xemu.read_u16_le(0x90963F + cameraDistanceIndex)
    local right = xemu.read_u16_le(0x909647 + cameraDistanceIndex)
    
    drawBox(left, top, right, bottom, colour_camera)
end

local function btsMatchesFilter(bts, values, ranges)
    if values == nil and ranges == nil then
        return true
    end

    if values ~= nil and values[bts] then
        return true
    end

    if ranges ~= nil then
        for _, range in pairs(ranges) do
            local first = range[1]
            local last = range[2]
            if first ~= nil and last ~= nil and first <= bts and bts <= last then
                return true
            end
        end
    end

    return false
end

function getBlockLabelSettings(blockType, bts)
    if blockLabelConfig.globalBtsValues ~= nil and not blockLabelConfig.globalBtsValues[bts] then
        return nil
    end

    local settings
    if debugBlockTextFilterEnabled then
        local blockTypes = blockLabelConfig.blockTypes or {}
        settings = blockTypes[blockType]
        if settings == true then
            settings = { showType = true, showBts = true }
        elseif settings == false or settings == nil then
            return nil
        end
    else
        settings = blockLabelConfig.allBlockTypes or { showType = true, showBts = true }
    end

    if not btsMatchesFilter(bts, settings.btsValues, settings.btsRanges) then
        return nil
    end

    if settings.showType == false and settings.showBts == false then
        return nil
    end

    return settings
end

local function formatBlockTypeText(blockType)
    if blockLabelConfig.includePrefixes then
        return string.format("T:%X", blockType)
    end
    return string.format("%X", blockType)
end

local function formatBtsText(bts)
    if blockLabelConfig.includePrefixes then
        return string.format("B:%02X", bts)
    end
    return string.format("%02X", bts)
end

local miniFontGlyphs = {
    ["0"] = {"111", "101", "101", "101", "111"},
    ["1"] = {"010", "110", "010", "010", "111"},
    ["2"] = {"111", "001", "111", "100", "111"},
    ["3"] = {"111", "001", "111", "001", "111"},
    ["4"] = {"101", "101", "111", "001", "001"},
    ["5"] = {"111", "100", "111", "001", "111"},
    ["6"] = {"111", "100", "111", "101", "111"},
    ["7"] = {"111", "001", "010", "010", "010"},
    ["8"] = {"111", "101", "111", "101", "111"},
    ["9"] = {"111", "101", "111", "001", "111"},
    ["A"] = {"111", "101", "111", "101", "101"},
    ["B"] = {"110", "101", "110", "101", "110"},
    ["C"] = {"111", "100", "100", "100", "111"},
    ["D"] = {"110", "101", "101", "101", "110"},
    ["E"] = {"111", "100", "111", "100", "111"},
    ["F"] = {"111", "100", "111", "100", "100"},
    ["/"] = {"001", "001", "010", "100", "100"},
    [":"] = {"000", "010", "000", "010", "000"},
    ["T"] = {"111", "010", "010", "010", "010"},
    ["B"] = {"110", "101", "110", "101", "110"},
    [" "] = {"000", "000", "000", "000", "000"},
    ["G"] = {"111", "100", "101", "101", "111"},
    ["H"] = {"101", "101", "111", "101", "101"},
    ["I"] = {"111", "010", "010", "010", "111"},
    ["J"] = {"001", "001", "001", "101", "111"},
    ["K"] = {"101", "101", "110", "101", "101"},
    ["L"] = {"100", "100", "100", "100", "111"},
    ["M"] = {"101", "111", "111", "101", "101"},
    ["N"] = {"101", "111", "111", "111", "101"},
    ["O"] = {"111", "101", "101", "101", "111"},
    ["P"] = {"111", "101", "111", "100", "100"},
    ["Q"] = {"111", "101", "101", "111", "001"},
    ["R"] = {"111", "101", "111", "110", "101"},
    ["S"] = {"111", "100", "111", "001", "111"},
    ["U"] = {"101", "101", "101", "101", "111"},
    ["V"] = {"101", "101", "101", "101", "010"},
    ["W"] = {"101", "101", "111", "111", "101"},
    ["X"] = {"101", "101", "010", "101", "101"},
    ["Y"] = {"101", "101", "010", "010", "010"},
    ["Z"] = {"111", "001", "010", "100", "111"},
    ["+"] = {"000", "010", "111", "010", "000"},
    ["-"] = {"000", "000", "111", "000", "000"},
    ["!"] = {"010", "010", "010", "000", "010"},
    ["?"] = {"111", "001", "011", "000", "010"},
    ["="] = {"000", "111", "000", "111", "000"},
    ["."] = {"000", "000", "000", "000", "010"},
    ["$"] = {"111", "110", "111", "011", "111"},
}

local function miniFontOptions(settings)
    local defaults = blockLabelConfig.miniFont or {}
    local overrides = settings.miniFont or {}

    local drawBackground
    if overrides.drawBackground ~= nil then
        drawBackground = overrides.drawBackground
    elseif defaults.drawBackground ~= nil then
        drawBackground = defaults.drawBackground
    else
        drawBackground = true
    end

    return {
        pixelSize = overrides.pixelSize or defaults.pixelSize or 1,
        charSpacing = overrides.charSpacing or defaults.charSpacing or 1,
        lineSpacing = overrides.lineSpacing or defaults.lineSpacing or 1,
        drawBackground = drawBackground,
        backgroundPadding = overrides.backgroundPadding or defaults.backgroundPadding or 0,
    }
end

local function miniTextSize(text, opts)
    text = tostring(text or "")
    local glyphW = 3 * opts.pixelSize
    local glyphH = 5 * opts.pixelSize
    local width = 0
    if #text > 0 then
        width = #text * glyphW + (#text - 1) * opts.charSpacing
    end
    return width, glyphH
end

local function drawFilledRect(x, y, width, height, colour)
    if colour == nil or colour == "clear" or width <= 0 or height <= 0 then
        return
    end
    emu.drawRectangle(i(x), i(y + drawYOffset()), i(width), i(height), mesenColour(colour), true, 1)
end

local function drawMiniText(x, y, text, fg, bg, opts)
    text = tostring(text or "")
    opts = opts or { pixelSize = 1, charSpacing = 1, drawBackground = true, backgroundPadding = 1 }

    local textWidth, textHeight = miniTextSize(text, opts)
    if opts.drawBackground and bg ~= nil and bg ~= "clear" then
        drawFilledRect(
            x - opts.backgroundPadding,
            y - opts.backgroundPadding,
            textWidth + opts.backgroundPadding * 2,
            textHeight + opts.backgroundPadding * 2,
            bg
        )
    end

    local cursorX = x
    local p = opts.pixelSize
    for iChar = 1,#text do
        local ch = string.upper(string.sub(text, iChar, iChar))
        local glyph = miniFontGlyphs[ch] or miniFontGlyphs[" "]
        for row = 1,5 do
            local bits = glyph[row]
            for col = 1,3 do
                if string.sub(bits, col, col) == "1" then
                    if p == 1 then
                        xemu.drawPixel(cursorX + col - 1, y + row - 1, fg)
                    else
                        drawFilledRect(cursorX + (col - 1) * p, y + (row - 1) * p, p, p, fg)
                    end
                end
            end
        end
        cursorX = cursorX + 3 * p + opts.charSpacing
    end
end

local function drawConfiguredLabelText(x, y, text, fg, bg, settings)
    local renderer = settings.textRenderer or blockLabelConfig.textRenderer or "mini"
    if renderer == "mini" then
        drawMiniText(x, y, text, fg, bg, miniFontOptions(settings))
    else
        drawText(x, y, text, fg, bg)
    end
end

function drawBlockBtsLabel(blockX, blockY, blockType, bts, settings)
    local colour = settings.colour or blockLabelConfig.defaultColour or "red"
    local background = settings.background
    if background == nil then
        background = blockLabelConfig.defaultBackground or "black"
    end

    local showType = settings.showType ~= false
    local showBts = settings.showBts ~= false
    local textStyle = settings.textStyle or blockLabelConfig.textStyle or "compact"
    local renderer = settings.textRenderer or blockLabelConfig.textRenderer or "mini"
    local opts = renderer == "mini" and miniFontOptions(settings) or nil

    local function labelSize(text)
        if renderer == "mini" then
            return miniTextSize(text, opts)
        end
        -- Approximate Mesen's normal font. Used only for centering.
        return #tostring(text) * 6, 8
    end

    local function centeredX(text)
        local w = labelSize(text)
        return blockX + math.floor((16 - w) / 2)
    end

    if showType and showBts and textStyle == "compact" then
        local text = formatBlockTypeText(blockType) .. "/" .. formatBtsText(bts)
        local w, h = labelSize(text)
        drawConfiguredLabelText(blockX + math.floor((16 - w) / 2), blockY + math.floor((16 - h) / 2), text, colour, background, settings)
        return
    end

    if showType and showBts then
        local typeText = formatBlockTypeText(blockType)
        local btsText = formatBtsText(bts)
        local _, lineH = labelSize(typeText)
        local gap = renderer == "mini" and opts.lineSpacing or 0
        local totalH = lineH * 2 + gap
        local top = blockY + math.floor((16 - totalH) / 2)
        drawConfiguredLabelText(centeredX(typeText), top, typeText, colour, background, settings)
        drawConfiguredLabelText(centeredX(btsText), top + lineH + gap, btsText, colour, background, settings)
    elseif showType then
        local text = formatBlockTypeText(blockType)
        local _, h = labelSize(text)
        drawConfiguredLabelText(centeredX(text), blockY + math.floor((16 - h) / 2), text, colour, background, settings)
    elseif showBts then
        local text = formatBtsText(bts)
        local _, h = labelSize(text)
        drawConfiguredLabelText(centeredX(text), blockY + math.floor((16 - h) / 2), text, colour, background, settings)
    end
end



-- =============================================================================
-- Any% Glitched route assist helpers
-- =============================================================================
local anygState = {
    frame = 0,
    prevValues = {},
    warnings = {},
    plmBaseline = nil,
    lastPlmCount = nil,
    freezeFrames = 0,
    prevGameTime = nil,
    lastFreeze = nil,
    previousBombActive = false,
    trainingGuideVisible = nil,
    trainingChecklistVisible = nil,
    trainingGuidePage = 1,
    prevGameState = nil,
    prevGameStateFresh = false,
    prevValueFresh = {},
    routeWatchesPinned = false,
    lastWarningFrameByKey = {},
    prevFreezeFrame = nil,
    prevDoorskipFrame = nil,
    doorskipTimingVisible = nil,
    doorskip = {
        attemptId = 0,
        startFrame = nil,
        startGameTime = nil,
        directionFrame = nil,
        directionButton = nil,
        directionOffset = nil,
        directionDiff = nil,
        directionStatus = nil,
        lastDirectionPressFrame = nil,
        lastDirectionButton = nil,
        downFrame = nil,
        downOffset = nil,
        downDiffToResume = nil,
        downStatus = nil,
        lastAnglePressFrame = nil,
        lastAngleButton = nil,
        firstShoulderPressFrame = nil,
        firstShoulderButton = nil,
        shoulderAlreadyHeldAtStart = false,
        shoulderResolved = false,
        awaitingLateShoulder = false,
        resumeFrame = nil,
        resumeFromState = nil,
        resumeToState = nil,
        angleButton = nil,
        angleHeldOnResume = false,
        anglePressedOnResume = false,
        angleOffset = nil,
        angleStatus = nil,
        lastResultText = nil,
        lastResultColour = "white",
        flashFrames = 0,
        timingUncertain = false,
        history = {},
    },
}

local function anygEnabled()
    return ANYG and ANYG.enabled
end

local function anygRead(address, size)
    if size == 2 then
        return xemu.read_u16_le(address)
    end
    return xemu.read_u8(address)
end

local ANYG_ROUTE_MAX_AGE = 6
local ANYG_TIMING_MAX_AGE = 2
local ANYG_PLM_MAX_AGE = 10
local ANYG_BLOCK_MAX_AGE = 60

local function anygMaxAge(key, fallback)
    local cfg = ANYG.freshness or {}
    local value = cfg[key]
    if type(value) == "number" and value >= 0 then
        return value
    end
    return fallback
end

local function anygRouteMaxAge()
    return anygMaxAge("routeMaxAge", ANYG_ROUTE_MAX_AGE)
end

local function anygTimingMaxAge()
    return anygMaxAge("timingMaxAge", ANYG_TIMING_MAX_AGE)
end

local function anygPlmMaxAge()
    return anygMaxAge("plmMaxAge", ANYG_PLM_MAX_AGE)
end

local function anygBlockMaxAge()
    return anygMaxAge("blockMaxAge", ANYG_BLOCK_MAX_AGE)
end

-- Freshness hysteresis state, keyed per watch (address|size). Each entry
-- tracks the last UI-visible verdict plus how many consecutive cycles the
-- raw read has disagreed with it, so a single late poll cycle does not
-- flip the dashboard. Cold values (never observed, age == nil) bypass this
-- entirely -- "no data yet" must surface immediately and honestly.
local anygFreshSticky = {}

local function anygFreshHysteresisCfg()
    local cfg = (ANYG and ANYG.freshnessHysteresis) or {}
    local staleN = cfg.staleCycles
    local freshN = cfg.freshCycles
    if type(staleN) ~= "number" or staleN < 0 then staleN = 8 end
    if type(freshN) ~= "number" or freshN < 0 then freshN = 1 end
    return staleN, freshN
end

local function anygReadValidRaw(address, size, maxAge)
    if xemu.read_valid then
        return xemu.read_valid(address, size or 1, maxAge)
    end
    return true, 0
end

-- Sticky wrapper around the raw validity check. Returns the *displayed*
-- verdict (with hysteresis applied) plus the true age so callers that
-- show "stale+N" still report the real staleness once it commits.
local function anygReadValid(address, size, maxAge)
    local rawValid, age = anygReadValidRaw(address, size or 1, maxAge)
    local staleN, freshN = anygFreshHysteresisCfg()

    -- Hysteresis disabled, or genuinely cold (never seen): pass through.
    if staleN == 0 or age == nil then
        return rawValid, age
    end

    local key = (address or 0) * 8 + (size or 1)
    local s = anygFreshSticky[key]
    if s == nil then
        s = { shown = rawValid, run = 0, frame = nil }
        anygFreshSticky[key] = s
    end

    -- Advance the hysteresis run AT MOST ONCE PER SCRIPT FRAME. The same
    -- address is read from several render paths each frame; without this
    -- guard the staleCycles threshold would be consumed by duplicate
    -- intra-frame reads and depend on which panels happen to be visible.
    local frame = anygState.frame
    if frame ~= s.frame then
        s.frame = frame
        if rawValid == s.shown then
            s.run = 0
        else
            s.run = s.run + 1
            local needed = rawValid and freshN or staleN
            if s.run >= needed then
                s.shown = rawValid
                s.run = 0
            end
        end
    end

    return s.shown, age
end

local function anygReadFresh(address, size, maxAge)
    local value = anygRead(address, size or 1)
    local valid, age = anygReadValid(address, size or 1, maxAge or anygRouteMaxAge())
    return value, valid, age
end

local function anygFreshText(valid, age)
    if valid then return "" end
    if age == nil then return "cold" end
    return string.format("stale+%d", age)
end

local function anygPin(address, class, size)
    if xemu.tier_size then
        xemu.tier_size(address, class, size or 1)
    elseif xemu.tier then
        xemu.tier(address, class)
    end
end

local function anygPinRouteWatches()
    if anygState.routeWatchesPinned then return end
    anygState.routeWatchesPinned = true

    anygPin(0x7E008B, "realtime", 2) -- held input
    anygPin(0x7E008F, "realtime", 2) -- newly-pressed input
    anygPin(0x7E0998, "realtime", 2) -- game state
    anygPin(0x7E0A94, "realtime", 2) -- Samus animation timer
    anygPin(0x7E0A96, "realtime", 2) -- Samus animation frame
    anygPin(0x7E0380, "realtime", 2) -- Gold Block dispatch pointer

    anygPin(0x7E0026, "high", 2)
    anygPin(0x7E090F, "high", 2)
    anygPin(0x7E0C5F, "high", 1)
    anygPin(0x7E1843, "high", 1)
    anygPin(0x7E03D7, "high", 1)
    anygPin(0x7E09DA, "high", 2)
    anygPin(0x7E09DC, "high", 2)
    anygPin(0x7E09DE, "high", 2)
    anygPin(0x7E09E0, "high", 2)

    for _, target in ipairs(ANYG.routeTargets or {}) do
        anygPin(target.btAddress, "high", 1)
        anygPin(target.btsAddress, "high", 1)
    end
    for _, watch in ipairs(ANYG.extraWatches or {}) do
        anygPin(watch.address, "high", watch.size or 1)
    end
    for i = 0,((ANYG.plm or {}).slots or 40) - 1 do
        anygPin(0x7E1C37 + i * 2, "high", 2)
    end
    for i = 0,9 do
        anygPin(0x7E0C7C + i * 2, "high", 2)
    end
end

local function anygHex(value, digits)
    if value == nil then return "??" end
    return string.format("%0" .. tostring(digits or 2) .. "X", xemu.and_(value, digits == 4 and 0xFFFF or 0xFF))
end

local function anygValueInSet(value, set)
    return set ~= nil and set[value] == true
end

local function anygValueInRanges(value, ranges)
    if ranges == nil then return false end
    for _, range in ipairs(ranges) do
        if range[1] <= value and value <= range[2] then
            return true
        end
    end
    return false
end

local function anygAddWarning(message, colour)
    if not anygEnabled() or not ANYG.showWarnings then
        return
    end

    local cfg = ANYG.warnings or {}
    local maxMessages = cfg.maxMessages or 8
    local frames = cfg.framesToShow or 360

    table.insert(anygState.warnings, 1, {
        message = message,
        colour = colour or "yellow",
        ttl = frames,
    })

    while #anygState.warnings > maxMessages do
        table.remove(anygState.warnings)
    end
end

local function anygAddWarningKey(key, message, colour, minGapFrames)
    local frame = anygState.frame or 0
    local last = anygState.lastWarningFrameByKey[key]
    if last ~= nil and frame - last < (minGapFrames or 60) then
        return
    end
    anygState.lastWarningFrameByKey[key] = frame
    anygAddWarning(message, colour)
end

local function anygStatusColour(status)
    local d = (ANYG.dashboard or {})
    if status == "OK" then return d.okColour or "green" end
    if status == "BAD" then return d.badColour or "red" end
    if status == "WARN" then return d.warnColour or "yellow" end
    return d.normalColour or "white"
end

local function anygCheckBtSource(value, target)
    local hi = xemu.rshift(xemu.and_(value or 0, 0xF0), 4)
    if target.goodBtHighNibbles and target.goodBtHighNibbles[hi] then
        return "OK"
    end
    return "BAD"
end

local function anygCheckBtsSource(value, target)
    if target.goodBtsValues and target.goodBtsValues[value] then
        return "OK"
    end
    if target.goodBtsRanges and anygValueInRanges(value, target.goodBtsRanges) then
        return "OK"
    end
    return "BAD"
end

local function anygCheckWatch(value, watch)
    if watch.watchOnly then
        return "INFO", "watch"
    end
    if watch.badValues and watch.badValues[value] then
        return "BAD", watch.badText or "bad"
    end
    if watch.excellentValues and watch.excellentValues[value] then
        return "OK", watch.goodText or "excellent"
    end
    if watch.goodValues and watch.goodValues[value] then
        return "OK", watch.goodText or "ok"
    end
    if watch.goodMin and value >= watch.goodMin then
        return "OK", watch.goodText or string.format(">=%X", watch.goodMin)
    end
    if watch.goodRanges and anygValueInRanges(value, watch.goodRanges) then
        return "OK", watch.goodText or "range ok"
    end
    if watch.goodValues or watch.goodMin or watch.goodRanges or watch.excellentValues then
        return "WARN", watch.goodText or "not target"
    end
    return "INFO", "watch"
end

local function anygCountPlms()
    local cfg = ANYG.plm or {}
    local slots = cfg.slots or 40
    local count = 0
    local fresh = true
    local worstAge = 0
    for i = 0,slots - 1 do
        local id = sm.getPlmId(i)
        local valid, age = anygReadValid(0x7E1C37 + i * 2, 2, anygPlmMaxAge())
        if not valid then
            fresh = false
        elseif age ~= nil and age > worstAge then
            worstAge = age
        end
        if id ~= 0 then
            count = count + 1
        end
    end
    return count, fresh, worstAge
end

local function anygClassifyFreeze(frames)
    local cfg = ANYG.freezeTimer or {}
    local bestLabel = "freeze"
    local bestDist = 9999
    for _, item in ipairs(cfg.shufflerDurations or {}) do
        local dist = math.abs(frames - item.frames)
        if dist < bestDist then
            bestDist = dist
            bestLabel = item.label or bestLabel
        end
    end
    if bestDist <= (cfg.tolerance or 12) then
        return bestLabel
    end
    return "freeze?"
end

local function anygGameTimeKey()
    local fresh = true
    local worstAge = 0
    local function readTime(address)
        local value, valid, age = anygReadFresh(address, 2, anygRouteMaxAge())
        if not valid then
            fresh = false
        elseif age ~= nil and age > worstAge then
            worstAge = age
        end
        return value
    end
    local frames = readTime(0x7E09DA)
    local seconds = readTime(0x7E09DC)
    local minutes = readTime(0x7E09DE)
    local hours = readTime(0x7E09E0)
    return ((hours or 0) * 60 * 60 * 60)
         + ((minutes or 0) * 60 * 60)
         + ((seconds or 0) * 60)
         + (frames or 0),
         fresh,
         worstAge
end

local function anygAnyBombActive()
    local fresh = true
    local worstAge = 0
    for i = 0,9 do
        local valid, age = anygReadValid(0x7E0C7C + i * 2, 2, anygPlmMaxAge())
        if not valid then
            fresh = false
        elseif age ~= nil and age > worstAge then
            worstAge = age
        end
        if sm.getBombTimer(i) ~= 0 then
            return true, fresh, worstAge
        end
    end
    return false, fresh, worstAge
end

local function anygUpdateFreezeTimer()
    local cfg = ANYG.freezeTimer or {}
    if not cfg.enabled then return end

    local gameState = sm.getGameState()
    local gameStateFresh = anygReadValid(0x7E0998, 2, anygTimingMaxAge())
    local timeKey, timeFresh = anygGameTimeKey()
    local frame = emu.framecount()
    local frameDelta = 1
    if anygState.prevFreezeFrame ~= nil and frame > anygState.prevFreezeFrame then
        frameDelta = frame - anygState.prevFreezeFrame
    end

    if not gameStateFresh or not timeFresh then
        anygState.prevFreezeFrame = frame
        return
    end

    if anygState.prevGameTime ~= nil and gameState == 8 then
        if timeKey == anygState.prevGameTime then
            anygState.freezeFrames = anygState.freezeFrames + frameDelta
        else
            local f = anygState.freezeFrames
            if f >= (cfg.minFrames or 24) and f <= (cfg.maxFrames or 150) then
                local label = anygClassifyFreeze(f)
                anygState.lastFreeze = { frames = f, label = label, frame = anygState.frame }
                anygAddWarning(string.format("Freeze %df: %s", f, label), label:find("+1", 1, true) and "green" or "yellow")
            end
            anygState.freezeFrames = 0
        end
    else
        anygState.freezeFrames = 0
    end
    anygState.prevGameTime = timeKey
    anygState.prevFreezeFrame = frame
end

local function anygCheckImportantChanges(snapshot)
    local cfg = ANYG.watchChanges or {}
    if not cfg.enabled then return end

    local function changedLost(key, desired, label)
        local prev = anygState.prevValues[key]
        local prevFresh = anygState.prevValueFresh[key] ~= false
        local now = snapshot[key]
        local nowFresh = snapshot._fresh == nil or snapshot._fresh[key] ~= false
        if prevFresh and nowFresh and prev == desired and now ~= desired then
            anygAddWarning(string.format("%s lost: %02X -> %02X", label, prev, now), "red")
        end
    end

    if cfg.alertOnLost5D then
        changedLost("1D59", 0x5D, "$1D59 5D-left")
        changedLost("1D5B", 0x5D, "$1D5B 5D-right")
    end
    if cfg.alertOnLost6F then
        changedLost("18E2", 0x6F, "$18E2 6F-layer")
        changedLost("1A8A", 0x6F, "$1A8A 6F-skree")
    end

    if cfg.alertOn090FReset then
        local prev = anygState.prevValues["090F"]
        local prevFresh = anygState.prevValueFresh["090F"] ~= false
        local now = snapshot["090F"]
        local nowFresh = snapshot._fresh == nil or snapshot._fresh["090F"] ~= false
        if prevFresh and nowFresh and prev ~= nil and now == 0 and prev ~= 0 then
            local hi = xemu.rshift(xemu.and_(prev, 0xF0), 4)
            if hi == 0xF or hi == 0x7 or prev >= 0xFC then
                anygAddWarning(string.format("$090F reset: %02X -> 00", prev), "red")
            end
        end
    end

    if cfg.alertOn0C5FLost then
        local prev = anygState.prevValues["0C5F"]
        local prevFresh = anygState.prevValueFresh["0C5F"] ~= false
        local now = snapshot["0C5F"]
        local nowFresh = snapshot._fresh == nil or snapshot._fresh["0C5F"] ~= false
        if prevFresh and nowFresh and prev ~= nil and (xemu.rshift(prev, 4) == 0xF or xemu.rshift(prev, 4) == 0x7) and not (xemu.rshift(now, 4) == 0xF or xemu.rshift(now, 4) == 0x7) then
            anygAddWarning(string.format("$0C5F lost: %02X -> %02X", prev, now), "red")
        end
    end

    if cfg.alertOn0026Bad then
        local prev = anygState.prevValues["0026"]
        local prevFresh = anygState.prevValueFresh["0026"] ~= false
        local now = snapshot["0026"]
        local nowFresh = snapshot._fresh == nil or snapshot._fresh["0026"] ~= false
        if prevFresh and nowFresh and now == 0 and prev ~= nil and prev ~= 0 then
            anygAddWarning("$0026 became 0000: likely no X-ray from item touch", "red")
        elseif prevFresh and nowFresh and now == 0xFFFF and prev ~= 0xFFFF then
            anygAddWarning("$0026 is FFFF: X-ray + major items source ready", "green")
        end
    end

    if cfg.alertOnBombAfter0C5FGood then
        local bombActive, bombFresh = anygAnyBombActive()
        local c5f = snapshot["0C5F"] or 0
        local c5fFresh = snapshot._fresh == nil or snapshot._fresh["0C5F"] ~= false
        local c5fGood = xemu.rshift(c5f, 4) == 0xF or xemu.rshift(c5f, 4) == 0x7
        if bombFresh and c5fFresh and bombActive and not anygState.previousBombActive and c5fGood then
            anygAddWarning("Bomb active while $0C5F is good: avoid resetting 6F-skree setup", "yellow")
        end
        if bombFresh then
            anygState.previousBombActive = bombActive
        end
    end
end


local function anygDoorskipConfig()
    return ANYG.doorskipTiming or {}
end

local function anygDoorskipVisible()
    local cfg = anygDoorskipConfig()
    if not anygEnabled() or not cfg.enabled then return false end
    if anygState.doorskipTimingVisible == nil then
        anygState.doorskipTimingVisible = cfg.visibleByDefault ~= false
    end
    return anygState.doorskipTimingVisible == true
end

local function anygIsPauseLikeGameState(gameState)
    -- $0C..$12 are pause/unpause states in the original hitbox viewer's validity notes.
    return gameState ~= nil and gameState >= 0x0C and gameState <= 0x12
end

local function anygTimingStatus(diff, goodWindow, nearWindow)
    local absDiff = math.abs(diff or 9999)
    if absDiff <= (goodWindow or 0) then
        return "GOOD"
    end
    if absDiff <= (nearWindow or 2) then
        return diff < 0 and "EARLY" or "LATE"
    end
    return diff < 0 and "VERY EARLY" or "VERY LATE"
end

local function anygTimingColour(status)
    local cfg = anygDoorskipConfig()
    if status == "GOOD" then return cfg.okColour or "green" end
    if status == "UNKNOWN" then return cfg.warnColour or "yellow" end
    if status == "EARLY" or status == "LATE" then return cfg.warnColour or "yellow" end
    return cfg.badColour or "red"
end

-- When $0998 advances to $0E after the pause-start, SM has already latched a
-- stable animation timer/frame pair that tells us how early/late the D-pad
-- direction press was. This avoids relying on live per-frame edge sampling.
local ANYG_DOORSKIP_DIRECTION_SAMPLE_TO_DIFF = {
    ["0001:0002"] = -4,
    ["0002:0002"] = -3,
    ["0001:0001"] = -2,
    ["0002:0001"] = -1,
    ["0003:0001"] = 0,
    ["0001:0008"] = 1,
    ["0002:0008"] = 2,
    ["0001:0007"] = 3,
    ["0002:0007"] = 4,
}

local function anygDoorskipDirectionSampleKey(timer, frame)
    return string.format("%04X:%04X", xemu.and_(timer or 0, 0xFFFF), xemu.and_(frame or 0, 0xFFFF))
end

local function anygDecodeDoorskipDirectionDiff(timer, frame)
    return ANYG_DOORSKIP_DIRECTION_SAMPLE_TO_DIFF[anygDoorskipDirectionSampleKey(timer, frame)]
end

local function anygButtonNameFromMask(mask)
    if mask == sm.button_left then return "Left" end
    if mask == sm.button_right then return "Right" end
    if mask == sm.button_L then return "L" end
    if mask == sm.button_R then return "R" end
    return "?"
end

local function anygPushDoorskipHistory(text, colour)
    local cfg = anygDoorskipConfig()
    local ds = anygState.doorskip
    table.insert(ds.history, 1, { text = text, colour = colour or "white" })
    while #ds.history > (cfg.historySize or 5) do
        table.remove(ds.history)
    end
end

local function anygStartDoorskipAttempt(input)
    local ds = anygState.doorskip
    ds.attemptId = (ds.attemptId or 0) + 1
    ds.startFrame = anygState.frame
    ds.startGameTime = anygGameTimeKey()
    ds.directionFrame = nil
    ds.directionButton = nil
    ds.directionOffset = nil
    ds.directionDiff = nil
    ds.directionStatus = nil
    ds.directionTimerValue = nil
    ds.directionAnimationFrameValue = nil
    ds.lastDirectionPressFrame = nil
    ds.lastDirectionButton = nil
    ds.downFrame = nil
    ds.downOffset = nil
    ds.downDiffToResume = nil
    ds.downStatus = nil
    ds.lastAnglePressFrame = nil
    ds.lastAngleButton = nil
    ds.firstShoulderPressFrame = nil
    ds.firstShoulderButton = nil
    ds.shoulderAlreadyHeldAtStart = false
    ds.shoulderResolved = false
    ds.awaitingLateShoulder = false
    ds.resumeFrame = nil
    ds.resumeFromState = nil
    ds.resumeToState = nil
    ds.earlyDoorTransitionFrame = nil
    ds.earlyDoorTransitionFromState = nil
    ds.earlyDoorTransitionToState = nil
    ds.angleButton = nil
    ds.angleHeldOnResume = false
    ds.anglePressedOnResume = false
    ds.angleOffset = nil
    ds.angleStatus = nil
    ds.lastResultText = "Doorskip timing: Start pressed"
    ds.lastResultColour = "white"
    ds.flashFrames = 0
    ds.timingUncertain = false

    if xemu.and_(input, sm.button_A) == 0 then
        anygAddWarning("Doorskip: Start pressed without Jump held", "yellow")
    end

    -- If shoulder L/R was already held when the attempt began, record that as an early press.
    -- The route wants a fresh shoulder L/R press on the $12->$08 frame, not a pre-held input.
    if xemu.and_(input, sm.button_L) ~= 0 then
        ds.firstShoulderPressFrame = anygState.frame
        ds.firstShoulderButton = sm.button_L
        ds.shoulderAlreadyHeldAtStart = true
    elseif xemu.and_(input, sm.button_R) ~= 0 then
        ds.firstShoulderPressFrame = anygState.frame
        ds.firstShoulderButton = sm.button_R
        ds.shoulderAlreadyHeldAtStart = true
    end
end

local function anygDownText(ds)
    if ds.downStatus == "OK" then
        return string.format("Down before 12->08: OK (%+df)", ds.downDiffToResume or 0)
    elseif ds.downStatus == "LATE" then
        return string.format("Down before 12->08: LATE (%+df)", ds.downDiffToResume or 0)
    elseif ds.downStatus == "MISSING" then
        return "Down before 12->08: MISSING"
    elseif ds.downOffset ~= nil then
        return string.format("Down pressed at +%df", ds.downOffset)
    end
    return "Down before 12->08: waiting"
end

local function anygBuildDoorskipResultText(ds)
    local dirText = "dir ?"
    if ds.directionDiff ~= nil then
        dirText = string.format("dir %+d %s", ds.directionDiff or 0, ds.directionStatus or "?")
    elseif ds.directionTimerValue ~= nil and ds.directionAnimationFrameValue ~= nil then
        dirText = string.format("dir raw %s/%s", anygHex(ds.directionTimerValue, 2), anygHex(ds.directionAnimationFrameValue, 2))
    end

    local downText = "down ?"
    if ds.downStatus ~= nil then
        downText = "down " .. ds.downStatus
    elseif ds.downOffset ~= nil then
        downText = "down seen"
    end

    local shoulderText = "L/R ?"
    if ds.angleStatus == "GOOD" then
        shoulderText = "L/R +0 GOOD"
    elseif ds.angleStatus == "EARLY DOOR" then
        if ds.angleOffset ~= nil then
            shoulderText = string.format("L/R %+d EARLY 12->0B", ds.angleOffset)
        else
            shoulderText = "L/R EARLY 12->0B"
        end
    elseif ds.angleStatus == "WAITING" then
        shoulderText = "L/R waiting"
    elseif ds.angleStatus == "MISSED" then
        shoulderText = "L/R MISSED"
    elseif ds.angleStatus == "UNKNOWN" then
        shoulderText = "L/R UNKNOWN"
    elseif ds.angleOffset ~= nil then
        shoulderText = string.format("L/R %+d %s", ds.angleOffset, ds.angleStatus or "?")
    end

    local text = string.format("Doorskip: %s | %s | %s", dirText, downText, shoulderText)
    if ds.timingUncertain then
        text = text .. " | obs gap"
    end
    return text
end

local function anygFinalizeShoulderTiming(cfg, button, diff)
    local ds = anygState.doorskip
    if ds.shoulderResolved then return end

    ds.angleButton = button or ds.firstShoulderButton
    ds.angleOffset = diff
    ds.angleStatus = anygTimingStatus(diff or 9999, cfg.shoulderGoodWindow or 0, cfg.shoulderNearWindow or 2)
    if ds.timingUncertain and ds.angleStatus == "GOOD" then
        ds.angleStatus = "UNKNOWN"
    end
    ds.angleHeldOnResume = false
    ds.anglePressedOnResume = diff == 0
    ds.shoulderResolved = true
    ds.awaitingLateShoulder = false

    local dirOk = ds.directionStatus == "GOOD"
    local downOk = (cfg.requireDownBeforeResume == false) or ds.downStatus == "OK"
    local shoulderOk = ds.angleStatus == "GOOD" and not ds.timingUncertain
    local overallGood = dirOk and downOk and shoulderOk

    local colour = overallGood and (cfg.okColour or "green") or (cfg.warnColour or "yellow")
    if ds.angleStatus == "VERY EARLY" or ds.angleStatus == "VERY LATE" or ds.angleStatus == "MISSED" or ds.downStatus == "MISSING" then
        colour = cfg.badColour or "red"
    end

    ds.lastResultText = anygBuildDoorskipResultText(ds)
    ds.lastResultColour = colour
    anygPushDoorskipHistory(ds.lastResultText, colour)
    if cfg.warnOnBadAttempt and not overallGood then
        anygAddWarning(ds.lastResultText, colour)
    end
end


local function anygFinalizeEarlyDoorTransition(cfg)
    local ds = anygState.doorskip
    if ds.shoulderResolved then return end

    local button = ds.firstShoulderButton
    if button == nil then
        local input = sm.getInput()
        if xemu.and_(input, sm.button_L) ~= 0 then
            button = sm.button_L
        elseif xemu.and_(input, sm.button_R) ~= 0 then
            button = sm.button_R
        end
    end

    ds.angleButton = button
    if ds.firstShoulderPressFrame ~= nil and ds.earlyDoorTransitionFrame ~= nil then
        ds.angleOffset = ds.firstShoulderPressFrame - ds.earlyDoorTransitionFrame
    else
        ds.angleOffset = nil
    end
    ds.angleStatus = "EARLY DOOR"
    ds.angleHeldOnResume = false
    ds.anglePressedOnResume = false
    ds.shoulderResolved = true
    ds.awaitingLateShoulder = false

    local colour = cfg.badColour or "red"
    ds.lastResultText = anygBuildDoorskipResultText(ds)
    ds.lastResultColour = colour
    anygPushDoorskipHistory(ds.lastResultText, colour)
    if cfg.warnOnBadAttempt then
        anygAddWarning(ds.lastResultText, colour)
    end
end

local function anygMarkShoulderMissed(cfg)
    local ds = anygState.doorskip
    if ds.shoulderResolved then return end
    ds.angleOffset = nil
    ds.angleStatus = ds.timingUncertain and "UNKNOWN" or "MISSED"
    ds.shoulderResolved = true
    ds.awaitingLateShoulder = false

    local colour = ds.timingUncertain and (cfg.warnColour or "yellow") or (cfg.badColour or "red")
    ds.lastResultText = anygBuildDoorskipResultText(ds)
    ds.lastResultColour = colour
    anygPushDoorskipHistory(ds.lastResultText, colour)
    if cfg.warnOnBadAttempt then
        anygAddWarning(ds.lastResultText, colour)
    end
end

local function anygUpdateDoorskipTiming()
    local cfg = anygDoorskipConfig()
    if not anygEnabled() or not cfg.enabled then return end

    local input = sm.getInput()
    local changed = sm.getChangedInput()
    local gameState = sm.getGameState()
    local prevGameState = anygState.prevGameState
    local ds = anygState.doorskip

    local timingMaxAge = anygTimingMaxAge()
    -- Door-skip timing is frame-accurate: a genuinely stale frame must
    -- abort with "timing unknown" rather than be smoothed over. Use the
    -- RAW validity here, deliberately bypassing the render hysteresis.
    local inputFresh = anygReadValidRaw(0x7E008B, 2, timingMaxAge)
    local changedFresh = anygReadValidRaw(0x7E008F, 2, timingMaxAge)
    local gameStateFresh = anygReadValidRaw(0x7E0998, 2, timingMaxAge)
    if not gameStateFresh then
        if ds.startFrame ~= nil and ANYG.showInputWarnings ~= false then
            ds.timingUncertain = true
            anygAddWarningKey("doorskip-gamestate-stale", "Doorskip: $0998 stale/cold; exact timing unknown", "yellow", 30)
        end
        return
    end

    local frameDelta = nil
    if anygState.prevDoorskipFrame ~= nil then
        frameDelta = anygState.frame - anygState.prevDoorskipFrame
    end
    local exactSample = inputFresh
        and changedFresh
        and anygState.prevGameStateFresh
        and frameDelta == 1

    local attemptActive = ds.startFrame ~= nil and anygState.frame - ds.startFrame <= (cfg.attemptTimeoutFrames or 240)
    if attemptActive and not exactSample then
        ds.timingUncertain = true
        if ANYG.showInputWarnings ~= false then
            anygAddWarningKey("doorskip-observation-gap", "Doorskip: missed/stale frame; exact timing unknown", "yellow", 30)
        end
    end

    local leftPressed = exactSample and xemu.and_(changed, sm.button_left) ~= 0
    local rightPressed = exactSample and xemu.and_(changed, sm.button_right) ~= 0
    local downPressed = exactSample and xemu.and_(changed, sm.button_down) ~= 0
    local shoulderLPressed = exactSample and xemu.and_(changed, sm.button_L) ~= 0
    local shoulderRPressed = exactSample and xemu.and_(changed, sm.button_R) ~= 0
    local shoulderHeld = inputFresh and xemu.and_(input, sm.button_L + sm.button_R) ~= 0
    local shoulderPressed = shoulderLPressed or shoulderRPressed
    local stateChanged = exactSample and prevGameState ~= nil and prevGameState ~= gameState
    local enteredPauseStart = stateChanged and gameState == 0x0C
    local directionLatched = prevGameState ~= nil and prevGameState ~= 0x0E and gameState == 0x0E

    if enteredPauseStart and xemu.and_(input, sm.button_A) ~= 0 then
        anygStartDoorskipAttempt(input)
    elseif ds.startFrame == nil
        and inputFresh
        and gameState == 0x0C
        and xemu.and_(input, sm.button_start) ~= 0
        and xemu.and_(input, sm.button_A) ~= 0 then
        anygStartDoorskipAttempt(input)
        ds.timingUncertain = true
        if ANYG.showInputWarnings ~= false then
            anygAddWarningKey("doorskip-start-inferred", "Doorskip: Start inferred after observation gap", "yellow", 60)
        end
    elseif ds.startFrame == nil and directionLatched then
        anygStartDoorskipAttempt(input)
        ds.timingUncertain = true
        if ANYG.showInputWarnings ~= false then
            anygAddWarningKey("doorskip-latch-inferred", "Doorskip: attempt inferred at direction latch", "yellow", 60)
        end
    end

    attemptActive = ds.startFrame ~= nil and anygState.frame - ds.startFrame <= (cfg.attemptTimeoutFrames or 240)

    if attemptActive and (leftPressed or rightPressed) then
        local button = leftPressed and sm.button_left or sm.button_right
        ds.lastDirectionPressFrame = anygState.frame
        ds.lastDirectionButton = button
    end

    if attemptActive and directionLatched and ds.directionFrame == nil then
        local timer = sm.getSamusAnimationFrameTimer()
        local animFrame = sm.getSamusAnimationFrame()
        -- Raw validity: this is the frame-accurate D-pad timing capture.
        local timerFresh = anygReadValidRaw(0x7E0A94, 2, timingMaxAge)
        local animFrameFresh = anygReadValidRaw(0x7E0A96, 2, timingMaxAge)
        local animFresh = timerFresh and animFrameFresh
        local diff = animFresh and anygDecodeDoorskipDirectionDiff(timer, animFrame) or nil
        local button = ds.lastDirectionButton
        if button == nil then
            if xemu.and_(input, sm.button_left) ~= 0 then
                button = sm.button_left
            elseif xemu.and_(input, sm.button_right) ~= 0 then
                button = sm.button_right
            else
                button = sm.button_left
            end
        end

        ds.directionFrame = anygState.frame
        ds.directionButton = button
        ds.directionTimerValue = timer
        ds.directionAnimationFrameValue = animFrame

        if not animFresh then
            ds.directionOffset = nil
            ds.directionDiff = nil
            ds.directionStatus = "UNKNOWN"
            ds.timingUncertain = true
            ds.lastResultText = string.format(
                "D-pad timing stale/cold $0A94/$0A96 = %s/%s at $0998=0E",
                anygHex(timer, 2),
                anygHex(animFrame, 2)
            )
            ds.lastResultColour = cfg.warnColour or "yellow"
        elseif diff ~= nil then
            local status = anygTimingStatus(diff, cfg.directionGoodWindow or 0, cfg.directionNearWindow or 2)
            ds.directionOffset = diff
            ds.directionDiff = diff
            ds.directionStatus = status
            ds.lastResultText = string.format(
                "D-pad %s via $0A94/$0A96 %s/%s: %s (%+d)",
                anygButtonNameFromMask(button),
                anygHex(timer, 2),
                anygHex(animFrame, 2),
                status,
                diff
            )
            ds.lastResultColour = anygTimingColour(status)
        else
            ds.directionOffset = nil
            ds.directionDiff = nil
            ds.directionStatus = "UNKNOWN"
            ds.lastResultText = string.format(
                "D-pad timing raw $0A94/$0A96 = %s/%s at $0998=0E",
                anygHex(timer, 2),
                anygHex(animFrame, 2)
            )
            ds.lastResultColour = cfg.badColour or "red"
        end

        if ds.directionStatus ~= "GOOD" and cfg.warnOnBadAttempt then
            anygAddWarning(ds.lastResultText, ds.lastResultColour)
        end
    end

    if attemptActive and downPressed and ds.downFrame == nil then
        ds.downFrame = anygState.frame
        ds.downOffset = anygState.frame - ds.startFrame
        ds.lastResultText = string.format("Down pressed at +%df", ds.downOffset)
        ds.lastResultColour = cfg.textColour or "white"
    end

    if attemptActive and ds.resumeFrame == nil then
        if shoulderPressed and ds.firstShoulderPressFrame == nil then
            ds.firstShoulderPressFrame = anygState.frame
            ds.firstShoulderButton = shoulderLPressed and sm.button_L or sm.button_R
        elseif shoulderHeld and ds.firstShoulderPressFrame == nil then
            -- This catches cases where shoulder was already held before the script saw a changed bit.
            ds.firstShoulderPressFrame = anygState.frame
            if xemu.and_(input, sm.button_L) ~= 0 then
                ds.firstShoulderButton = sm.button_L
            else
                ds.firstShoulderButton = sm.button_R
            end
            ds.shoulderAlreadyHeldAtStart = ds.startFrame == anygState.frame
        end
    elseif attemptActive and ds.resumeFrame ~= nil and shoulderPressed and not ds.shoulderResolved then
        local button = shoulderLPressed and sm.button_L or sm.button_R
        ds.firstShoulderPressFrame = anygState.frame
        ds.firstShoulderButton = button
        anygFinalizeShoulderTiming(cfg, button, anygState.frame - ds.resumeFrame)
    end

    local targetFrom = cfg.targetResumeFromGameMode or 0x12
    local targetTo = cfg.targetResumeToGameMode or 0x08
    local earlyDoorTo = cfg.earlyDoorTransitionToGameMode or 0x0B
    local resumedToGameplay = stateChanged and prevGameState == targetFrom and gameState == targetTo
    local earlyDoorTransition = cfg.markEarlyDoorTransition ~= false and stateChanged and prevGameState == targetFrom and gameState == earlyDoorTo

    if stateChanged and attemptActive then
        ds.lastResultText = string.format("Game mode %02X -> %02X", prevGameState, gameState)
        ds.lastResultColour = cfg.titleColour or "yellow"
        if resumedToGameplay or earlyDoorTransition then
            ds.flashFrames = cfg.resumeFlashFrames or 18
        end
    end

    if earlyDoorTransition and attemptActive then
        ds.earlyDoorTransitionFrame = anygState.frame
        ds.earlyDoorTransitionFromState = prevGameState
        ds.earlyDoorTransitionToState = gameState

        if ds.downFrame ~= nil and ds.downStatus == nil then
            ds.downDiffToResume = ds.downFrame - anygState.frame
            ds.downStatus = ds.downFrame < anygState.frame and "OK" or "LATE"
        elseif ds.downStatus == nil then
            ds.downDiffToResume = nil
            ds.downStatus = "MISSING"
        end

        if shoulderPressed and ds.firstShoulderPressFrame == nil then
            ds.firstShoulderPressFrame = anygState.frame
            ds.firstShoulderButton = shoulderLPressed and sm.button_L or sm.button_R
        end

        anygFinalizeEarlyDoorTransition(cfg)
    end

    if resumedToGameplay and attemptActive then
        ds.resumeFrame = anygState.frame
        ds.resumeFromState = prevGameState
        ds.resumeToState = gameState
        ds.angleHeldOnResume = shoulderHeld
        ds.anglePressedOnResume = shoulderPressed

        if ds.downFrame ~= nil then
            ds.downDiffToResume = ds.downFrame - ds.resumeFrame
            ds.downStatus = ds.downFrame < ds.resumeFrame and "OK" or "LATE"
        else
            ds.downDiffToResume = nil
            ds.downStatus = "MISSING"
        end

        -- The shoulder input is only good if the press occurs on the $12->$08 transition frame.
        -- If it was held from before, this reports the negative frame offset instead of calling it good.
        if shoulderPressed and ds.firstShoulderPressFrame == nil then
            ds.firstShoulderPressFrame = anygState.frame
            ds.firstShoulderButton = shoulderLPressed and sm.button_L or sm.button_R
        end

        if ds.firstShoulderPressFrame ~= nil then
            anygFinalizeShoulderTiming(cfg, ds.firstShoulderButton, ds.firstShoulderPressFrame - ds.resumeFrame)
        else
            ds.angleStatus = "WAITING"
            ds.angleOffset = nil
            ds.awaitingLateShoulder = true
            ds.lastResultText = anygBuildDoorskipResultText(ds)
            ds.lastResultColour = cfg.warnColour or "yellow"
        end
    end

    if attemptActive and ds.awaitingLateShoulder and ds.resumeFrame ~= nil and ds.earlyDoorTransitionFrame == nil then
        if anygState.frame - ds.resumeFrame > (cfg.lateShoulderWaitFrames or 16) then
            anygMarkShoulderMissed(cfg)
        end
    end

    if ds.flashFrames and ds.flashFrames > 0 then
        ds.flashFrames = ds.flashFrames - 1
    end

    if ds.startFrame ~= nil and anygState.frame - ds.startFrame > (cfg.attemptTimeoutFrames or 240) then
        if ds.resumeFrame ~= nil and not ds.shoulderResolved then
            anygMarkShoulderMissed(cfg)
        end
        ds.startFrame = nil
    end

    anygState.prevGameState = gameState
    anygState.prevGameStateFresh = gameStateFresh
    anygState.prevDoorskipFrame = anygState.frame
end

local function anygHandleControls()
    local cfg = ANYG.controls or {}
    local input, changed = getHotkeyFrameState()
    if not hotkeyModifierHeld(input, cfg) then
        return
    end

    -- Handle multi-button chords before individual button hotkeys.
    if hotkeyComboPressed(input, changed, cfg, "toggleBlockViewerCombo") then
        blockViewerLayerVisible = not blockViewerLayerVisible
        emu.displayMessage("AnyG assist", blockViewerLayerVisible and "block viewer layer on" or "block viewer layer off; helpers still on")
        return
    end

    if hotkeyPressed(input, changed, cfg, "resetPlmBaselineButton", "Y") then
        local count, fresh, age = anygCountPlms()
        if fresh then
            anygState.plmBaseline = count
            anygAddWarning(string.format("PLM baseline reset to %d", anygState.plmBaseline), "green")
        else
            anygAddWarning(string.format("PLM baseline not reset: %s PLM table", anygFreshText(false, age)), "yellow")
        end
    end

    if hotkeyPressed(input, changed, cfg, "toggleDashboardButton", "L") then
        ANYG.showRamDashboard = not ANYG.showRamDashboard
        emu.displayMessage("AnyG assist", ANYG.showRamDashboard and "RAM dashboard on" or "RAM dashboard off")
    end

    if hotkeyPressed(input, changed, cfg, "toggleHighlightsButton", "R") then
        ANYG.showRouteBlockHighlights = not ANYG.showRouteBlockHighlights
        emu.displayMessage("AnyG assist", ANYG.showRouteBlockHighlights and "route block highlights on" or "route block highlights off")
    end

    if hotkeyPressed(input, changed, cfg, "clearWarningsButton", "start") then
        anygState.warnings = {}
        emu.displayMessage("AnyG assist", "warnings cleared")
    end

    if hotkeyPressed(input, changed, cfg, "toggleTrainingGuideButton", "up") then
        anygState.trainingGuideVisible = not anygState.trainingGuideVisible
        emu.displayMessage("AnyG assist", anygState.trainingGuideVisible and "training guide on" or "training guide off")
    end

    if hotkeyPressed(input, changed, cfg, "nextTrainingPageButton", "right") then
        local pages = (((ANYG.trainingGuide or {}).pages) or {})
        local n = math.max(1, #pages)
        anygState.trainingGuidePage = (anygState.trainingGuidePage % n) + 1
        anygState.trainingGuideVisible = true
    end

    if hotkeyPressed(input, changed, cfg, "prevTrainingPageButton", "left") then
        local pages = (((ANYG.trainingGuide or {}).pages) or {})
        local n = math.max(1, #pages)
        anygState.trainingGuidePage = ((anygState.trainingGuidePage + n - 2) % n) + 1
        anygState.trainingGuideVisible = true
    end

    if hotkeyPressed(input, changed, cfg, "toggleChecklistButton", "down") then
        anygState.doorskipTimingVisible = not anygDoorskipVisible()
        if (ANYG.trainingGuide or {}).toggleChecklistWithTiming then
            anygState.trainingChecklistVisible = anygState.doorskipTimingVisible
        end
        emu.displayMessage("AnyG assist", anygState.doorskipTimingVisible and "Doorskip timing on" or "Doorskip timing off")
    end
end
local function anygUpdateState()
    if not anygEnabled() then return end
    anygPinRouteWatches()
    local _, _, frame = getHotkeyFrameState()
    if lastAnygUpdateFrame == frame then
        return
    end
    lastAnygUpdateFrame = frame

    if anygState.frame == nil then
        anygState.frame = frame
    else
        anygState.frame = math.max(anygState.frame + 1, frame)
    end
    anygHandleControls()
    anygUpdateDoorskipTiming()

    for i = #anygState.warnings,1,-1 do
        local w = anygState.warnings[i]
        w.ttl = w.ttl - 1
        if w.ttl <= 0 then
            table.remove(anygState.warnings, i)
        end
    end

    anygUpdateFreezeTimer()

    local snapshot = { _fresh = {}, _age = {} }
    local function snap(key, address, size, maxAge)
        local value, fresh, age = anygReadFresh(address, size, maxAge or anygRouteMaxAge())
        snapshot[key] = value
        snapshot._fresh[key] = fresh
        snapshot._age[key] = age
    end
    snap("11FD", 0x7E11FD, 1)
    snap("1201", 0x7E1201, 1)
    snap("1D59", 0x7E1D59, 1)
    snap("1D5B", 0x7E1D5B, 1)
    snap("090F", 0x7E090F, 1)
    snap("18E2", 0x7E18E2, 1)
    snap("0C5F", 0x7E0C5F, 1)
    snap("1A8A", 0x7E1A8A, 1)
    snap("0026", 0x7E0026, 2)
    snap("0380", 0x7E0380, 2)
    snap("1843", 0x7E1843, 1)
    snap("03D7", 0x7E03D7, 1)

    anygCheckImportantChanges(snapshot)
    anygState.prevValues = snapshot
    anygState.prevValueFresh = snapshot._fresh

    if ANYG.plm and ANYG.plm.enabled then
        local count, fresh, age = anygCountPlms()
        if not fresh then
            if ANYG.showInputWarnings ~= false then
                anygAddWarningKey("plm-table-stale", string.format("PLM count waiting: %s table", anygFreshText(false, age)), "yellow", 60)
            end
        elseif anygState.plmBaseline == nil then
            anygState.plmBaseline = ANYG.plm.baseline or count
            anygState.lastPlmCount = count
        elseif anygState.lastPlmCount ~= nil and count ~= anygState.lastPlmCount then
            local delta = count - anygState.lastPlmCount
            anygAddWarning(string.format("PLM count %d (%+d)", count, delta), delta > 0 and "green" or "yellow")
            anygState.lastPlmCount = count
        else
            anygState.lastPlmCount = count
        end
    end
end

local function anygClassifyBlock(blockType, bts)
    if not anygEnabled() or not ANYG.showRouteBlockHighlights then
        return nil
    end
    local cfg = ANYG.blockHighlights or {}
    for _, rule in ipairs(cfg.rules or {}) do
        if rule.enabled ~= false then
            local typeOk = rule.blockTypes == nil or rule.blockTypes[blockType]
            local btsOk = rule.btsValues == nil or rule.btsValues[bts]
            if typeOk and btsOk then
                return rule
            end
        end
    end
    return nil
end

local function anygDrawRouteBlockMarker(blockX, blockY, blockType, bts, blockIndex, cameraX, cameraY, viewWidth, viewHeight)
    local rule = anygClassifyBlock(blockType, bts)
    if rule == nil then return end

    local cfg = ANYG.blockHighlights or {}
    local colour = rule.colour or "yellow"
    local bg = rule.background or "black"

    if cfg.drawBoxes ~= false then
        drawBox(blockX - 1, blockY - 1, blockX + 16, blockY + 16, colour, "clear")
        drawBox(blockX - 2, blockY - 2, blockX + 17, blockY + 17, colour, "clear")
    end

    if cfg.drawLabels ~= false then
        local label = rule.short or rule.name or string.format("%X/%02X", blockType, bts)
        local opts = cfg.miniFont or { pixelSize = 1, charSpacing = 1, drawBackground = true, backgroundPadding = 1 }
        if cfg.labelRenderer == "mesen" then
            drawText(blockX, blockY - 8, label, colour, bg)
        else
            local w, _ = miniTextSize(label, opts)
            drawMiniText(blockX + math.floor((16 - w) / 2), blockY - 7, label, colour, bg, opts)
        end
    end

    local cx = math.floor((viewWidth or 256) / 2)
    local cy = math.floor((viewHeight or 224) / 2)
    local blockCenterX = blockX + 8
    local blockCenterY = blockY + 8

    if cfg.drawLineToSamus then
        drawLine(cx, cy, blockCenterX, blockCenterY, colour)
    end

    if cfg.drawDistanceWhenVisible then
        local dxBlocks = math.floor((blockCenterX - cx) / 16)
        local dyBlocks = math.floor((blockCenterY - cy) / 16)
        if math.abs(dxBlocks) >= 4 or math.abs(dyBlocks) >= 4 then
            local text = string.format("%+d,%+d", dxBlocks, dyBlocks)
            drawText(blockX, blockY + 17, text, colour, bg)
        end
    end
end

local function anygDrawDashboard(viewWidth, viewHeight)
    if not anygEnabled() or not ANYG.showRamDashboard then return end

    local guideCfg = ANYG.trainingGuide or {}
    if guideCfg.hideDashboardWhenChecklistVisible ~= false then
        local checklistVisible = anygState.trainingChecklistVisible
        if checklistVisible == nil then
            checklistVisible = guideCfg.enabled and (guideCfg.checklistVisibleByDefault ~= false)
        end
        if checklistVisible then
            return
        end
    end

    local d = ANYG.dashboard or {}
    local x = d.x or 4
    local y = d.y or 32
    local lh = d.lineHeight or 8
    local maxLines = d.maxLines or 10
    local line = 0
    if d.panelFill ~= false then
        drawFilledRect(x - 4, y - 4, 230, maxLines * lh + 8, d.panelFill or d.background or UI_PANEL_BACKGROUND)
    end

    local function drawLineText(text, status)
        if line >= maxLines then return end
        drawText(x, y + line * lh, text, anygStatusColour(status or "INFO"), d.background or UI_TEXT_BACKGROUND)
        line = line + 1
    end

    local function targetStatus(target)
        local bt, btFresh, btAge = anygReadFresh(target.btAddress, 1)
        local bts, btsFresh, btsAge = anygReadFresh(target.btsAddress, 1)
        local fresh = btFresh and btsFresh
        local age = btFresh and btsAge or btAge
        if not fresh then
            return false, bt, bts, "WAIT", "WAIT", false, age
        end
        local btStatus = anygCheckBtSource(bt, target)
        local btsStatus = anygCheckBtsSource(bts, target)
        local ok = btStatus == "OK" and btsStatus == "OK"
        return ok, bt, bts, btStatus, btsStatus, true, age
    end

    if d.compact ~= false then
        local summaryParts = {}
        local summaryStatus = "OK"
        for _, target in ipairs(ANYG.routeTargets or {}) do
            local ok, bt, bts, _, _, fresh, age = targetStatus(target)
            if not fresh then
                if summaryStatus ~= "BAD" then summaryStatus = "WARN" end
            elseif not ok then
                summaryStatus = "BAD"
            end
            local short = target.key or target.name or "?"
            short = short:gsub("%-", "")
            local valueText = ok and "OK" or string.format("%02X/%02X", bt, bts)
            if not fresh then
                valueText = anygFreshText(false, age)
            end
            table.insert(summaryParts, string.format("%s %s", short, valueText))
        end
        drawLineText("AnyG: " .. table.concat(summaryParts, "  "), summaryStatus)

        local v0026, fresh0026, age0026 = anygReadFresh(0x7E0026, 2)
        local v0380, fresh0380, age0380 = anygReadFresh(0x7E0380, 2)
        local label0380 = ""
        local status0026 = v0026 >= 0x8000 and "OK" or (v0026 == 0 and "BAD" or "WARN")
        for _, watch in ipairs(ANYG.extraWatches or {}) do
            if watch.key == "gold-0380" and watch.exactLabels then
                label0380 = watch.exactLabels[v0380] or ""
            end
        end
        local status0380 = label0380 ~= "" and "OK" or "INFO"
        local statusLine = (status0026 == "BAD" or status0380 == "BAD") and "BAD" or (status0026 == "WARN" and "WARN" or "OK")
        if not fresh0026 or not fresh0380 then
            statusLine = "WARN"
            label0380 = anygFreshText(false, fresh0026 and age0380 or age0026)
        end
        drawLineText(string.format("$0026 %04X  $0380 %04X %s", v0026, v0380, label0380), statusLine)

        if d.showAddressDetails then
            local v090F, f090F, a090F = anygReadFresh(0x7E090F, 1)
            local v1843, f1843, a1843 = anygReadFresh(0x7E1843, 1)
            local v03D7, f03D7, a03D7 = anygReadFresh(0x7E03D7, 1)
            local detailStatus = (f090F and f1843 and f03D7) and "INFO" or "WARN"
            local detailNote = detailStatus == "WARN" and (" " .. anygFreshText(false, (not f090F and a090F) or (not f1843 and a1843) or a03D7)) or ""
            drawLineText(string.format("detail: $090F %02X  $1843 %02X  $03D7 %02X%s", v090F, v1843, v03D7, detailNote), detailStatus)
        end

        if d.showPlmAndFreeze ~= false then
            local parts = {}
            local status = "INFO"
            if ANYG.showPlmCount and ANYG.plm and ANYG.plm.enabled then
                local count, fresh, age = anygCountPlms()
                if anygState.lastPlmCount ~= nil and fresh then count = anygState.lastPlmCount end
                local baseline = anygState.plmBaseline or count
                local extra = count - baseline
                local targetExtra = ANYG.plm.targetExtra or 8
                if fresh then
                    table.insert(parts, string.format("PLM %02d (%+d/%d)", count, extra, targetExtra))
                    if extra >= targetExtra then status = "OK" elseif extra > 0 then status = "WARN" end
                else
                    table.insert(parts, "PLM " .. anygFreshText(false, age))
                    status = "WARN"
                end
            end
            if ANYG.showFreezeTimer and (ANYG.freezeTimer or {}).enabled then
                if anygState.freezeFrames and anygState.freezeFrames > 0 then
                    table.insert(parts, string.format("freeze now %df", anygState.freezeFrames))
                    status = "WARN"
                elseif anygState.lastFreeze then
                    table.insert(parts, string.format("last freeze %df %s", anygState.lastFreeze.frames, anygState.lastFreeze.label))
                    if anygState.lastFreeze.label:find("+1", 1, true) then status = "OK" else status = "WARN" end
                end
            end
            if #parts > 0 then
                drawLineText(table.concat(parts, "  "), status)
            end
        end
        return
    end

    -- Verbose legacy mode.
    drawLineText("AnyG route assist", "INFO")

    for _, target in ipairs(ANYG.routeTargets or {}) do
        local ok, bt, bts, btStatus, btsStatus, fresh, age = targetStatus(target)
        local status = fresh and (ok and "OK" or "BAD") or "WARN"
        local note = fresh and "" or (" " .. anygFreshText(false, age))
        drawLineText(string.format("%-10s BT %02X %s  BTS %02X %s%s", target.key or target.name, bt, btStatus, bts, btsStatus, note), status)
    end

    for _, watch in ipairs(ANYG.extraWatches or {}) do
        local value, fresh, age = anygReadFresh(watch.address, watch.size or 1)
        local status, note = anygCheckWatch(value, watch)
        if not fresh then
            status = "WARN"
            note = anygFreshText(false, age)
        end
        local digits = (watch.size == 2) and 4 or 2
        if fresh and watch.exactLabels and watch.exactLabels[value] then
            note = watch.exactLabels[value]
            status = "OK"
        elseif fresh and watch.showNearest and watch.exactLabels then
            local nearestValue, nearestLabel, nearestDist = nil, nil, 0x10000
            for k, label in pairs(watch.exactLabels) do
                local dist = math.abs(value - k)
                if dist < nearestDist then
                    nearestValue, nearestLabel, nearestDist = k, label, dist
                end
            end
            if nearestValue ~= nil then
                note = string.format("near %04X %s (%+d)", nearestValue, nearestLabel, value - nearestValue)
            end
        end
        drawLineText(string.format("%-14s %s  %s", watch.name, anygHex(value, digits), note or ""), status)
    end

    if ANYG.showPlmCount and ANYG.plm and ANYG.plm.enabled then
        local count, fresh, age = anygCountPlms()
        if anygState.lastPlmCount ~= nil and fresh then count = anygState.lastPlmCount end
        local baseline = anygState.plmBaseline or count
        local extra = count - baseline
        local targetExtra = ANYG.plm.targetExtra or 8
        local status = fresh and (extra >= targetExtra and "OK" or (extra > 0 and "WARN" or "INFO")) or "WARN"
        local text = fresh and string.format("PLMs %02d  base %02d  extra %+d/%d", count, baseline, extra, targetExtra)
            or ("PLMs " .. anygFreshText(false, age))
        drawLineText(text, status)
    end

    if ANYG.showFreezeTimer and (ANYG.freezeTimer or {}).enabled then
        local text = "Freeze: none"
        local status = "INFO"
        if anygState.freezeFrames and anygState.freezeFrames > 0 then
            text = string.format("Freeze now: %df", anygState.freezeFrames)
            status = "WARN"
        elseif anygState.lastFreeze then
            text = string.format("Last freeze: %df %s", anygState.lastFreeze.frames, anygState.lastFreeze.label)
            status = anygState.lastFreeze.label:find("+1", 1, true) and "OK" or "WARN"
        end
        drawLineText(text, status)
    end
end

local function anygDraw0380Helper(viewWidth, viewHeight)
    if not anygEnabled() or not ANYG.show0380Helper then return end
    local value, fresh, age = anygReadFresh(0x7E0380, 2, anygTimingMaxAge())
    local label = nil
    if fresh then
        for _, watch in ipairs(ANYG.extraWatches or {}) do
            if watch.key == "gold-0380" and watch.exactLabels then
                label = watch.exactLabels[value]
                if label == nil and watch.showNearest then
                    local nearestValue, nearestLabel, nearestDist = nil, nil, 0x10000
                    for k, l in pairs(watch.exactLabels) do
                        local dist = math.abs(value - k)
                        if dist < nearestDist then
                            nearestValue, nearestLabel, nearestDist = k, l, dist
                        end
                    end
                    if nearestValue ~= nil and nearestDist <= 0x40 then
                        label = string.format("near %04X %s", nearestValue, nearestLabel)
                    end
                end
            end
        end
    else
        label = anygFreshText(false, age)
    end
    if label == nil then
        label = ""
    end
    local colour = fresh and ((label ~= "") and "yellow" or "white") or "cyan"
    drawText(math.floor(viewWidth / 2) + 12, math.floor(viewHeight / 2) - 20, string.format("$0380 %04X %s", value, label), colour, "black")
end

local function anygDrawWarnings(viewWidth, viewHeight)
    if not anygEnabled() or not ANYG.showWarnings then return end
    local cfg = ANYG.warnings or {}
    local x = cfg.x or 4
    local lh = cfg.lineHeight or 8
    local y = viewHeight - (cfg.yFromBottom or 72)
    for iMsg, msg in ipairs(anygState.warnings) do
        drawText(x, y + (iMsg - 1) * lh, msg.message, msg.colour or "yellow", cfg.background or "black")
    end
end

local function anygTrainingGuideVisible()
    local cfg = ANYG.trainingGuide or {}
    if not anygEnabled() or not cfg.enabled then return false end
    if anygState.trainingGuideVisible == nil then
        anygState.trainingGuideVisible = cfg.visibleByDefault == true
    end
    return anygState.trainingGuideVisible == true
end

local function anygTrainingChecklistVisible()
    local cfg = ANYG.trainingGuide or {}
    if not anygEnabled() or not cfg.enabled then return false end
    if anygState.trainingChecklistVisible == nil then
        anygState.trainingChecklistVisible = cfg.checklistVisibleByDefault ~= false
    end
    return anygState.trainingChecklistVisible == true
end

local function anygDrawPanelLine(x, y, text, colour, bg)
    drawText(x, y, text, colour or "white", bg or "black")
end

local function anygDrawTrainingGuide(viewWidth, viewHeight)
    if not anygTrainingGuideVisible() then return end

    local cfg = ANYG.trainingGuide or {}
    local pages = cfg.pages or {}
    if #pages == 0 then return end

    local pageIndex = math.max(1, math.min(anygState.trainingGuidePage or 1, #pages))
    local page = pages[pageIndex]
    local width = cfg.width or 240
    local x = cfg.x or math.max(4, (viewWidth or 256) - (cfg.xFromRight or width))
    local y = cfg.y or 32
    local lh = cfg.lineHeight or 8
    local bg = cfg.background or "black"

    local nLines = 2 + #(page.lines or {})
    local fill = cfg.panelFill or bg
    drawFilledRect(x - 4, y - 4, width + 8, nLines * lh + 10, fill)
    drawBox(x - 2, y - 2, x + width, y + nLines * lh + 4, cfg.titleColour or "yellow", "clear")
    anygDrawPanelLine(x, y, string.format("AnyG guide %d/%d: %s", pageIndex, #pages, page.title or ""), cfg.titleColour or "yellow", bg)
    anygDrawPanelLine(x, y + lh, "Select+B+Left/Right pages, Up hide", cfg.textColour or "white", bg)
    for i, line in ipairs(page.lines or {}) do
        anygDrawPanelLine(x, y + (i + 1) * lh, line, cfg.textColour or "white", bg)
    end
end

local function anygCheckLineStatus(label, ok, warn, detail)
    if ok then return label .. " OK" end
    if warn then return label .. " WARN" end
    if detail then return label .. " BAD " .. detail end
    return label .. " BAD"
end


local function anygDrawDoorskipTiming(viewWidth, viewHeight)
    if not anygDoorskipVisible() then return end
    local cfg = anygDoorskipConfig()
    local ds = anygState.doorskip
    local x = cfg.x or 4
    local y = cfg.y or math.max(4, (viewHeight or 224) - 64)
    local width = cfg.width or 250
    local lh = cfg.lineHeight or 8
    local bg = cfg.background or "black"
    local title = cfg.titleColour or "yellow"
    local textC = cfg.textColour or "white"
    local okC = cfg.okColour or "green"
    local warnC = cfg.warnColour or "yellow"
    local badC = cfg.badColour or "red"

    local historyLines = (cfg.showHistory and #(ds.history or {}) > 0) and math.min(#(ds.history or {}), cfg.historySize or 5) + 1 or 0
    local liveLine = cfg.showLiveInputLine and 1 or 0
    local nLines = 7 + liveLine + historyLines
    local fill = cfg.panelFill or bg
    drawFilledRect(x - 4, y - 4, width + 8, nLines * lh + 10, fill)
    drawBox(x - 2, y - 2, x + width, y + nLines * lh + 4, title, "clear")

    anygDrawPanelLine(x, y, "Doorskip timing", title, bg)
    y = y + lh

    local gs, gsFresh, gsAge = anygReadFresh(0x7E0998, 2, anygTimingMaxAge())
    local gsText = gsFresh and anygHex(gs, 2) or anygFreshText(false, gsAge)
    if cfg.showLiveInputLine then
        local input, inputFresh, inputAge = anygReadFresh(0x7E008B, 2, anygTimingMaxAge())
        local jumpHeld = xemu.and_(input, sm.button_A) ~= 0
        local downHeld = xemu.and_(input, sm.button_down) ~= 0
        local liveFresh = gsFresh and inputFresh
        local inputText = inputFresh and "" or ("  input " .. anygFreshText(false, inputAge))
        anygDrawPanelLine(
            x,
            y,
            string.format("$0998=%s  Jump:%s  Down:%s%s", gsText, jumpHeld and "held" or "no", downHeld and "held" or "no", inputText),
            liveFresh and textC or warnC,
            bg
        )
        y = y + lh
    end

    local startText
    if ds.startFrame ~= nil then
        startText = string.format("Start +%df    $0998=%s", anygState.frame - ds.startFrame, gsText)
    else
        startText = string.format("Waiting for Start    $0998=%s", gsText)
    end
    anygDrawPanelLine(x, y, startText, textC, bg)
    y = y + lh

    local dirColour = warnC
    local dirText = "D-pad timing: wait for $0998=0E"
    if ds.directionStatus == "UNKNOWN" then
        dirColour = warnC
        dirText = string.format(
            "D-pad timing: UNKNOWN (%s/%s)",
            anygHex(ds.directionTimerValue, 2),
            anygHex(ds.directionAnimationFrameValue, 2)
        )
    elseif ds.directionDiff ~= nil then
        dirColour = anygTimingColour(ds.directionStatus)
        dirText = string.format(
            "D-pad %s: %+d  %s (%s/%s)",
            anygButtonNameFromMask(ds.directionButton),
            ds.directionDiff or 0,
            ds.directionStatus or "?",
            anygHex(ds.directionTimerValue, 2),
            anygHex(ds.directionAnimationFrameValue, 2)
        )
    elseif ds.directionTimerValue ~= nil and ds.directionAnimationFrameValue ~= nil then
        dirColour = badC
        dirText = string.format(
            "D-pad latch: raw %s/%s",
            anygHex(ds.directionTimerValue, 2),
            anygHex(ds.directionAnimationFrameValue, 2)
        )
    elseif ds.startFrame ~= nil then
        dirText = "D-pad timing: waiting for 0E latch"
        dirColour = textC
    end
    anygDrawPanelLine(x, y, dirText, dirColour, bg)
    y = y + lh

    local downColour = textC
    if ds.downStatus == "OK" then
        downColour = okC
    elseif ds.downStatus == "LATE" or ds.downStatus == "MISSING" then
        downColour = badC
    elseif ds.downOffset ~= nil then
        downColour = warnC
    end
    anygDrawPanelLine(x, y, anygDownText(ds), downColour, bg)
    y = y + lh

    local resumeText = "Resume: wait for $0998 12->08"
    local resumeColour = textC
    if ds.earlyDoorTransitionFrame ~= nil then
        resumeText = string.format("Resume failed: 12->0B at frame %d", ds.earlyDoorTransitionFrame)
        resumeColour = badC
    elseif ds.resumeFrame ~= nil then
        resumeText = string.format("Resume 12->08: frame %d", ds.resumeFrame)
        resumeColour = ds.flashFrames and ds.flashFrames > 0 and title or textC
    elseif ds.startFrame ~= nil then
        resumeText = "Resume: waiting for 12->08"
    end
    anygDrawPanelLine(x, y, resumeText, resumeColour, bg)
    y = y + lh

    local shoulderText = "Shoulder L/R: press on 12->08"
    local shoulderColour = textC
    if ds.angleStatus == "GOOD" then
        shoulderText = "Shoulder L/R: +0 GOOD"
        shoulderColour = okC
    elseif ds.angleStatus == "EARLY DOOR" then
        if ds.angleOffset ~= nil then
            shoulderText = string.format("Shoulder L/R: %+df EARLY 12->0B", ds.angleOffset)
        else
            shoulderText = "Shoulder L/R: EARLY 12->0B"
        end
        shoulderColour = badC
    elseif ds.angleStatus == "WAITING" then
        shoulderText = "Shoulder L/R: waiting/late?"
        shoulderColour = warnC
    elseif ds.angleStatus == "MISSED" then
        shoulderText = "Shoulder L/R: MISSED"
        shoulderColour = badC
    elseif ds.angleStatus == "UNKNOWN" then
        shoulderText = "Shoulder L/R: UNKNOWN"
        shoulderColour = warnC
    elseif ds.angleOffset ~= nil then
        shoulderText = string.format("Shoulder L/R: %+df  %s", ds.angleOffset, ds.angleStatus or "?")
        shoulderColour = anygTimingColour(ds.angleStatus)
    elseif ds.firstShoulderPressFrame ~= nil and ds.resumeFrame == nil then
        shoulderText = string.format("Shoulder L/R: early by at least %df", anygState.frame - ds.firstShoulderPressFrame)
        shoulderColour = badC
    end
    anygDrawPanelLine(x, y, shoulderText, shoulderColour, bg)
    y = y + lh

    if ds.lastResultText ~= nil then
        anygDrawPanelLine(x, y, ds.lastResultText, ds.lastResultColour or textC, bg)
    else
        anygDrawPanelLine(x, y, "Result: no attempt yet", textC, bg)
    end
    y = y + lh

    if ds.flashFrames and ds.flashFrames > 0 then
        local cx = math.floor((viewWidth or 256) / 2)
        drawLine(cx - 18, 4, cx + 18, 4, title)
        drawLine(cx, 4, cx, 28, title)
        if ds.earlyDoorTransitionFrame ~= nil and (ds.resumeFrame == nil or ds.earlyDoorTransitionFrame >= ds.resumeFrame) then
            drawText(cx + 22, 4, "$0998 12->0B EARLY", badC, bg)
        else
            drawText(cx + 22, 4, "$0998 12->08 NOW", title, bg)
        end
    end

    if cfg.showHistory and #(ds.history or {}) > 0 then
        anygDrawPanelLine(x, y, "Recent:", title, bg)
        y = y + lh
        for i, row in ipairs(ds.history) do
            if i > (cfg.historySize or 5) then break end
            anygDrawPanelLine(x, y, row.text, row.colour or textC, bg)
            y = y + lh
        end
    end
end

local function anygDrawTrainingChecklist(viewWidth, viewHeight)
    if not anygTrainingChecklistVisible() then return end

    local cfg = ANYG.trainingGuide or {}
    local width = cfg.checklistWidth or cfg.width or 272
    local x = cfg.checklistX or math.max(4, (viewWidth or 256) - width - 4)
    local y = cfg.checklistY or ((cfg.y or 32) + 112)
    local lh = cfg.checklistLineHeight or cfg.lineHeight or 8
    local bg = cfg.background or "black"
    local fill = cfg.panelFill or bg
    local title = cfg.titleColour or "yellow"
    local textC = cfg.textColour or "white"
    local noteC = cfg.noteColour or cfg.textColour or "white"
    local okC = cfg.okColour or "green"
    local warnC = cfg.warnColour or "yellow"
    local badC = cfg.badColour or "red"
    local showNotes = cfg.checklistShowNotes ~= false
    local showSections = cfg.checklistShowSections ~= false

    local v11FD, f11FD = anygReadFresh(0x7E11FD, 1)
    local v1201, f1201 = anygReadFresh(0x7E1201, 1)
    local v1D59, f1D59 = anygReadFresh(0x7E1D59, 1)
    local v1D5B, f1D5B = anygReadFresh(0x7E1D5B, 1)
    local v090F, f090F = anygReadFresh(0x7E090F, 1)
    local v0C5F, f0C5F = anygReadFresh(0x7E0C5F, 1)
    local v18E2, f18E2 = anygReadFresh(0x7E18E2, 1)
    local v1A8A, f1A8A = anygReadFresh(0x7E1A8A, 1)
    local v1843, f1843 = anygReadFresh(0x7E1843, 1)
    local v0026, f0026 = anygReadFresh(0x7E0026, 2)
    local v0380, f0380 = anygReadFresh(0x7E0380, 2)
    local bombActive, bombFresh = anygAnyBombActive()

    local function hiGood(v)
        local hi = xemu.rshift(xemu.and_(v, 0xF0), 4)
        return hi == 0xF or hi == 0x7
    end

    local function status(ok, warn, fresh)
        if fresh == false then return "??", warnC end
        if ok then return "OK", okC end
        if warn then return "!!", warnC end
        return "BAD", badC
    end

    local function gold0380Label(value)
        for _, watch in ipairs(ANYG.extraWatches or {}) do
            if watch.key == "gold-0380" and watch.exactLabels then
                if watch.exactLabels[value] then
                    return watch.exactLabels[value]
                end
                if watch.showNearest then
                    local nearestValue, nearestLabel, nearestDist = nil, nil, 0x10000
                    for k, label in pairs(watch.exactLabels) do
                        local dist = math.abs(value - k)
                        if dist < nearestDist then
                            nearestValue, nearestLabel, nearestDist = k, label, dist
                        end
                    end
                    if nearestValue ~= nil and nearestDist <= 0x40 then
                        return string.format("near %04X %s", nearestValue, nearestLabel)
                    end
                end
            end
        end
        return "watch during touches"
    end

    local function addSection(rows, text)
        if showSections then
            table.insert(rows, { kind = "section", text = text })
        end
    end

    local function addCheck(rows, label, ok, warn, value, note, fresh)
        local mark, colour = status(ok, warn, fresh)
        table.insert(rows, {
            kind = "check",
            label = label,
            mark = mark,
            colour = colour,
            value = value or "",
            note = note,
        })
    end

    local rows = {}
    addSection(rows, "PRE-SHUFFLER VALUES")
    addCheck(rows, "5D-left BTS", v1D59 == 0x5D, false,
        string.format("$1D59=%02X", v1D59), "want 5D for 5D-left / X-ray block", f1D59)
    addCheck(rows, "5D-right BTS", v1D5B == 0x5D, false,
        string.format("$1D5B=%02X", v1D5B), "want 5D for 5D-right / +1 PLM", f1D5B)
    addCheck(rows, "Geemer BT pair", hiGood(v11FD) and hiGood(v1201), hiGood(v11FD) or hiGood(v1201),
        string.format("$11FD/$1201=%02X/%02X", v11FD, v1201), "both should be F_ or 7_ before Shuffler", f11FD and f1201)
    addCheck(rows, "6F-layer pair", hiGood(v090F) and v18E2 == 0x6F, v18E2 == 0x6F and v090F ~= 0,
        string.format("$090F/$18E2=%02X/%02X", v090F, v18E2), "$090F should be F_/7_; $18E2 should be 6F", f090F and f18E2)
    addCheck(rows, "6F-skree pair", hiGood(v0C5F) and v1A8A == 0x6F, v1A8A == 0x6F and v0C5F ~= 0,
        string.format("$0C5F/$1A8A=%02X/%02X", v0C5F, v1A8A), "$0C5F should stay F_/7_; $1A8A should be 6F", f0C5F and f1A8A)

    addSection(rows, "RULES / DANGER CHECKS")
    addCheck(rows, "No bomb active", not bombActive, false,
        bombActive and "bomb active" or "clear", "do not bomb again before Shuffler", bombFresh)
    addCheck(rows, "$0026 item source", v0026 >= 0x8000, v0026 ~= 0 and v0026 < 0x8000,
        string.format("$0026=%04X", v0026), "FFFF/C000 good; 0000 means no X-ray/all-items", f0026)
    addCheck(rows, "$1843 slope timer", v1843 >= 0x10 and v1843 <= 0x1F, v1843 >= 0x08 and v1843 <= 0x27,
        string.format("$1843=%02X", v1843), "route movement prefers about 10..1F", f1843)

    addSection(rows, "POST-SHUFFLER / TOUCH FEEDBACK")
    local count, countFresh = anygCountPlms()
    if anygState.lastPlmCount ~= nil and countFresh then count = anygState.lastPlmCount end
    local baseline = anygState.plmBaseline or count
    local extra = count - baseline
    local targetExtra = ((ANYG.plm or {}).targetExtra or 8)
    addCheck(rows, "Extra PLMs", extra >= targetExtra, extra > 0,
        string.format("%+d/%d  total %02d", extra, targetExtra, count), "Select+B+Y resets the baseline", countFresh)
    addCheck(rows, "$0380 Gold value", false, true,
        string.format("$0380=%04X", v0380), f0380 and gold0380Label(v0380) or "waiting for fresh OAM", f0380)
    local ds = anygState.doorskip or {}
    local downOk = ds.downStatus == "OK"
    local timingCertain = not ds.timingUncertain
    local shoulderOk = timingCertain and ds.angleStatus == "GOOD"
    local dirOk = timingCertain and ds.directionStatus == "GOOD"
    local dsWarn = ds.startFrame ~= nil or ds.lastResultText ~= nil
    local dsValue = "waiting"
    if ds.startFrame ~= nil then
        dsValue = string.format("Start +%df", anygState.frame - ds.startFrame)
    elseif ds.lastResultText ~= nil then
        dsValue = ds.lastResultText
    end
    if not timingCertain and dsValue ~= "waiting" then
        dsValue = dsValue .. " | obs gap"
    end
    addCheck(rows, "Doorskip timing", dirOk and downOk and shoulderOk, dsWarn,
        dsValue, "details in Select+B+Down timing panel")

    local contentLines = 2
    for _, row in ipairs(rows) do
        if row.kind == "section" then
            contentLines = contentLines + 1
        else
            contentLines = contentLines + 1
            if showNotes and row.note and row.note ~= "" then
                contentLines = contentLines + 1
            end
        end
    end

    local height = contentLines * lh + 8
    drawFilledRect(x - 4, y - 4, width + 8, height, fill)
    drawBox(x - 4, y - 4, x + width + 4, y + height - 4, title, "clear")
    drawBox(x - 2, y - 2, x + width + 2, y + height - 6, title, "clear")

    local cy = y
    anygDrawPanelLine(x, cy, "AnyG route checklist", title, bg)
    cy = cy + lh
    anygDrawPanelLine(x, cy, "Detailed checks live here; dashboard hidden", textC, bg)
    cy = cy + lh

    for _, row in ipairs(rows) do
        if row.kind == "section" then
            drawLine(x, cy + lh - 2, x + width - 8, cy + lh - 2, title)
            anygDrawPanelLine(x, cy, row.text, title, bg)
            cy = cy + lh
        else
            anygDrawPanelLine(x, cy, string.format("[%s]", row.mark), row.colour, bg)
            anygDrawPanelLine(x + 32, cy, row.label, textC, bg)
            anygDrawPanelLine(x + 150, cy, row.value, row.colour, bg)
            cy = cy + lh
            if showNotes and row.note and row.note ~= "" then
                anygDrawPanelLine(x + 32, cy, "- " .. row.note, noteC, bg)
                cy = cy + lh
            end
        end
    end
end

local function anygDrawWaypoints(cameraX, cameraY, viewWidth, viewHeight)
    if not anygEnabled() or not ANYG.showPracticeWaypoints then return end
    local cx = math.floor(viewWidth / 2)
    local cy = math.floor(viewHeight / 2)
    for _, wp in ipairs(ANYG.waypoints or {}) do
        local sx = wp.x - cameraX
        local sy = wp.y - cameraY
        local colour = wp.colour or "white"
        if sx >= 0 and sx < viewWidth and sy >= 0 and sy < viewHeight then
            drawBox(sx - 3, sy - 3, sx + 3, sy + 3, colour, "clear")
            drawText(sx + 5, sy - 4, wp.name or "WP", colour, "black")
        else
            local dx = wp.x - (cameraX + cx)
            local dy = wp.y - (cameraY + cy)
            local edgeX = cx
            local edgeY = cy
            if math.abs(dx) > math.abs(dy) then
                edgeX = dx > 0 and (viewWidth - 12) or 12
                edgeY = cy + math.floor(dy * (edgeX - cx) / dx)
            elseif dy ~= 0 then
                edgeY = dy > 0 and (viewHeight - 12) or 12
                edgeX = cx + math.floor(dx * (edgeY - cy) / dy)
            end
            edgeX = math.max(4, math.min(viewWidth - 40, edgeX))
            edgeY = math.max(4, math.min(viewHeight - 12, edgeY))
            drawText(edgeX, edgeY, wp.name or "WP", colour, "black")
        end
    end
end

function displayBlocks(cameraX, cameraY, roomWidth, viewWidth, viewHeight)
    viewWidth = viewWidth or 256
    viewHeight = viewHeight or 224

    -- Add one block of margin on each edge so partially visible edge blocks are drawn.
    local firstBlockX = -1 - xExtraBlocks
    local lastBlockX = math.ceil(viewWidth / 0x10) + 1 + xExtraBlocks
    local firstBlockY = -1 - yExtraBlocks
    local lastBlockY = math.ceil(viewHeight / 0x10) + 1 + yExtraBlocks

    for y = firstBlockY,lastBlockY do
        for x = firstBlockX,lastBlockX do
            -- Impose a limit on the number of block extensions allowed, otherwise infinite loops can occur
            local stackLimit = 224

            -- Align block outlines graphically to the synthetic viewport
            local blockX = x * 0x10 - xemu.and_(cameraX, 0xF)
            local blockY = y * 0x10 - xemu.and_(cameraY, 0xF)

            -- Blocks are 16x16 px², using a right shift to avoid dealing with floats
            local blockIndex = xemu.rshift(xemu.and_(cameraY + y * 0x10, 0xFFF), 4) * roomWidth
                             + xemu.rshift(xemu.and_(cameraX + x * 0x10, 0xFFFF), 4)
            local blockFresh = true
            if xemu.read_valid then
                local levelAddr = cpuBankWrappedOffsetAddress(0x7F0002, blockIndex * 2)
                local btsAddr = cpuBankWrappedOffsetAddress(0x7F6402, blockIndex)
                local blockMaxAge = anygBlockMaxAge()
                blockFresh = select(1, xemu.read_valid(levelAddr, 2, blockMaxAge))
                          and select(1, xemu.read_valid(btsAddr, 1, blockMaxAge))
            end

            -- Block type is the most significant 4 bits of level data
            local blockType = xemu.rshift(sm.getLevelDatum(blockIndex), 12)
            local bts = sm.getBts(blockIndex)
            -- Draw the block outline depending on its block type.
            local f = outline[blockType] or standardOutline(colour_errorBlock)
            f(blockX, blockY, blockIndex, stackLimit)

            if blockFresh then
                anygDrawRouteBlockMarker(blockX, blockY, blockType, bts, blockIndex, cameraX, cameraY, viewWidth, viewHeight)
            end

            -- Draw labels after outlines so labels remain readable.
            if debugFlag ~= 0 then
                local labelSettings = getBlockLabelSettings(blockType, bts)
                if labelSettings ~= nil then
                    drawBlockBtsLabel(blockX, blockY, blockType, bts, labelSettings)
                end
            end
        end
    end
end

function displayDebugInfo(cameraX, cameraY, roomWidth)
    if debugInfoFlag == 0 then
        return
    end

    local cameraXBlock = xemu.rshift(cameraX, 4)
    local cameraYBlock = xemu.rshift(xemu.and_(cameraY, 0xFFF), 4)
    local clip = 0x7F0000 + xemu.and_(2 + (cameraXBlock + cameraYBlock * roomWidth) * 2, 0xFFFF)
    local clip_end = 0x7F0002 + 0x1FE * roomWidth + 0x1FFE
    local bts_end = 0x7F6402 + roomWidth * sm.getRoomHeight()
    drawText(0, 0, string.format("cameraX: %03X\ncameraY: %03X\nClip: %X\nClip end: %X\nBTS end: %X", cameraXBlock, cameraYBlock, clip, clip_end, bts_end), "cyan")

    if debugFlag == 0 then
        return
    end

    if doorListFlag ~= 0 then
        p_doorList = sm.getDoorListPointer()
        for i = 0,xemu.rshift(clip_end - 0x7F0002, 1) do
            if xemu.and_(sm.getLevelDatum(i), 0xF000) == 0x9000 then
                bts = xemu.and_(sm.getBts(i), 0x7F)
                if doors[xemu.read_u16_le(0x8F0000 + p_doorList + bts * 2)] then
                    doorList[bts] = doorList[bts] + 1
                end
            end
        end
        doorListFlag = 0
    end

    y = 216
    for j = 0,0x7F do
        i = 0x7F - j
        if doorList[i] ~= 0 then
            drawText(0, y, string.format("%02X x %i", i, doorList[i]), "cyan")
            y = y - 8
        end
    end
end

function displayFx(cameraX, cameraY, viewWidth)
    viewWidth = viewWidth or 256
    local fxY = sm.getFxYPosition() - cameraY
    local lavaAcidY = sm.getLavaAcidYPosition() - cameraY
    local fxTargetY = sm.getFxTargetYPosition() - cameraY
    drawLine(0, fxY, viewWidth - 1, fxY, 0x004080FF)
    drawLine(0, lavaAcidY, viewWidth - 1, lavaAcidY, 0xFFC080FF)
    drawLine(0, fxTargetY, viewWidth - 1, fxTargetY, 0xFFFFFFFF)
end

function displayKraidHitbox(cameraX, cameraY)
    if sm.getEnemyId(0) ~= 0xE2BF then
        return
    end

    local kraidXPosition = sm.getEnemyXPosition(0)
    local kraidYPosition = sm.getEnemyYPosition(0)
    local p_kraidInstructionList = 0xA70000 + xemu.read_u16_le(0x7E0FAA)

    -- Vulnerable hitbox for Kraid's mouth
    local p_projectileHitbox = xemu.read_u16_le(p_kraidInstructionList - 2)
    if p_projectileHitbox ~= 0xFFFF then
        local kraidLeftOffset   = xemu.read_s16_le(0xA70000 + p_projectileHitbox)
        local kraidTopOffset    = xemu.read_s16_le(0xA70000 + p_projectileHitbox + 2)
        local kraidBottomOffset = xemu.read_s16_le(0xA70000 + p_projectileHitbox + 6)
        local left   = kraidXPosition + kraidLeftOffset   - cameraX
        local top    = kraidYPosition + kraidTopOffset    - cameraY
        local bottom = kraidYPosition + kraidBottomOffset - cameraY
        drawBox(left, top, 256, bottom, 0xFFFFFFFF, "clear")
    end

    -- Invulnerable hitbox for Kraid's mouth
    p_projectileHitbox = xemu.read_u16_le(p_kraidInstructionList - 4)
    local kraidLeftOffset   = xemu.read_s16_le(0xA70000 + p_projectileHitbox)
    local kraidTopOffset    = xemu.read_s16_le(0xA70000 + p_projectileHitbox + 2)
    local kraidBottomOffset = xemu.read_s16_le(0xA70000 + p_projectileHitbox + 6)
    local left   = kraidXPosition + kraidLeftOffset   - cameraX
    local top    = kraidYPosition + kraidTopOffset    - cameraY
    local bottom = kraidYPosition + kraidBottomOffset - cameraY
    drawLine(left, top, 256, top, 0xFFFF80FF)
    drawLine(left, top, left, bottom, 0xFFFF80FF)

    -- Kraid's body
    local kraidSectionTopOffset = -0x8000
    local kraidSectionRightOffset = kraidLeftOffset
    for j = 1,8 do
        local i = 8 - j
        local kraidSectionBottomOffset = xemu.read_s16_le(0xA7B161 + i * 4)
        local kraidSectionLeftOffset   = xemu.read_s16_le(0xA7B161 + i * 4 + 2)
        local left   = kraidXPosition + kraidSectionLeftOffset   - cameraX
        local right  = kraidXPosition + kraidSectionRightOffset  - cameraX
        local top    = kraidYPosition + kraidSectionTopOffset    - cameraY
        local bottom = kraidYPosition + kraidSectionBottomOffset - cameraY

        -- Projectile hitbox is only defined up to Kraid's head, Samus hitbox uses whole table
        if kraidSectionTopOffset <= kraidBottomOffset then
            drawLine(left, top, right, top, 0xFF8080FF)
            drawLine(left, top, left, bottom, 0xFF8080FF)
            local kraidSectionTopOffset    = math.max(kraidSectionTopOffset, kraidBottomOffset)
            local kraidSectionBottomOffset = math.max(kraidSectionBottomOffset, kraidBottomOffset)
            local top    = kraidYPosition + kraidSectionTopOffset    - cameraY
            local bottom = kraidYPosition + kraidSectionBottomOffset - cameraY
            drawLine(left, top, right, top, 0xFFFF80FF)
            drawLine(left, top, left, bottom, 0xFFFFC0C0)
        else
            drawLine(left, top, right, top, 0xFFFFC0C0)
            drawLine(left, top, left, bottom, 0xFFFFC0C0)
        end

        kraidSectionTopOffset   = kraidSectionBottomOffset
        kraidSectionRightOffset = kraidSectionLeftOffset
    end
end

function displayMotherBrainHitbox(cameraX, cameraY)
    if sm.getEnemyId(0) ~= 0xEC7F then
        return
    end

    local p_motherBrainBodyHitbox = 0xA9B427
    local p_motherBrainBrainHitbox = 0xA9B439
    local p_motherBrainNeckHitbox = 0xA9B44B

    local motherBrainHitboxFlags = xemu.read_u16_le(0x7E7808)

    if xemu.and_(motherBrainHitboxFlags, 1) ~= 0 then
        local xPosition = sm.getEnemyXPosition(0)
        local yPosition = sm.getEnemyYPosition(0)
        local n_hitboxes = xemu.read_u16_le(p_motherBrainBodyHitbox)
        local p_hitboxes = p_motherBrainBodyHitbox + 2
        for i = 0,n_hitboxes-1 do
            local leftOffset   = math.abs(xemu.read_s16_le(p_hitboxes + i * 8))
            local topOffset    = math.abs(xemu.read_s16_le(p_hitboxes + i * 8 + 2))
            local rightOffset  = math.abs(xemu.read_s16_le(p_hitboxes + i * 8 + 4))
            local bottomOffset = math.abs(xemu.read_s16_le(p_hitboxes + i * 8 + 6))
            local left   = xPosition - leftOffset   - cameraX
            local top    = yPosition - topOffset    - cameraY
            local right  = xPosition + rightOffset  - cameraX
            local bottom = yPosition + bottomOffset - cameraY
            drawBox(left, top, right, bottom, "green")
        end
    end

    if xemu.and_(motherBrainHitboxFlags, 2) ~= 0 then
        local xPosition = sm.getEnemyXPosition(1)
        local yPosition = sm.getEnemyYPosition(1)
        local n_hitboxes = xemu.read_u16_le(p_motherBrainBrainHitbox)
        local p_hitboxes = p_motherBrainBrainHitbox + 2
        for i = 0,n_hitboxes-1 do
            local leftOffset   = math.abs(xemu.read_s16_le(p_hitboxes + i * 8))
            local topOffset    = math.abs(xemu.read_s16_le(p_hitboxes + i * 8 + 2))
            local rightOffset  = math.abs(xemu.read_s16_le(p_hitboxes + i * 8 + 4))
            local bottomOffset = math.abs(xemu.read_s16_le(p_hitboxes + i * 8 + 6))
            local left   = xPosition - leftOffset   - cameraX
            local top    = yPosition - topOffset    - cameraY
            local right  = xPosition + rightOffset  - cameraX
            local bottom = yPosition + bottomOffset - cameraY
            drawBox(left, top, right, bottom, "blue")
        end
    end

    if xemu.and_(motherBrainHitboxFlags, 4) ~= 0 then
        local n_hitboxes = xemu.read_u16_le(p_motherBrainNeckHitbox)
        local p_hitboxes = p_motherBrainNeckHitbox + 2
        for i = 1,3 do
            local xPosition = xemu.read_u16_le(0x7E8044 + i * 6)
            local yPosition = xemu.read_u16_le(0x7E8046 + i * 6)
            for ii = 0,n_hitboxes-1 do
                local leftOffset   = math.abs(xemu.read_s16_le(p_hitboxes + ii * 8))
                local topOffset    = math.abs(xemu.read_s16_le(p_hitboxes + ii * 8 + 2))
                local rightOffset  = math.abs(xemu.read_s16_le(p_hitboxes + ii * 8 + 4))
                local bottomOffset = math.abs(xemu.read_s16_le(p_hitboxes + ii * 8 + 6))
                local left   = xPosition - leftOffset   - cameraX
                local top    = yPosition - topOffset    - cameraY
                local right  = xPosition + rightOffset  - cameraX
                local bottom = yPosition + bottomOffset - cameraY
                drawBox(left, top, right, bottom, "cyan")
            end
        end
    end

    --local x = xemu.read_s16_le(0x7E7814) - cameraX
    --local y = xemu.read_s16_le(0x7E7816) - cameraY
    --drawRightTriangle(x, y, x + 0x70, y - 0x60, "white")
    
    --local xPositionBody = sm.getEnemyXPosition(0)
    --local yPositionBody = sm.getEnemyYPosition(0)
    --drawRightTriangle(xPositionBody, yPositionBody, x, y, "yellow")
end

function displayEnemyHitboxes(cameraX, cameraY)
    local y = 0
    local n_enemies = sm.getNEnemies()
    --drawText(0, 0, string.format("n_enemies: %04X", n_enemies), 0xFF00FFFF)
    if n_enemies == 0 then
        return
    end

    -- Iterate backwards, I want earlier enemies drawn on top of later ones
    for j=1,n_enemies do
        local i = n_enemies - j
        local enemyId = sm.getEnemyId(i)
        if enemyId ~= 0 then
            local enemyXPosition = sm.getEnemyXPosition(i)
            local enemyYPosition = sm.getEnemyYPosition(i)
            local enemyXRadius   = sm.getEnemyXRadius(i)
            local enemyYRadius   = sm.getEnemyYRadius(i)
            local left   = enemyXPosition - enemyXRadius - cameraX
            local top    = enemyYPosition - enemyYRadius - cameraY
            local right  = enemyXPosition + enemyXRadius - cameraX
            local bottom = enemyYPosition + enemyYRadius - cameraY

            -- Draw enemy hitbox
            -- If not using extended spritemap format or frozen, draw simple hitbox
            if xemu.and_(sm.getEnemyExtraProperties(i), 4) == 0 or sm.getEnemyAiHandler(i) == 4 then
                drawBox(left, top, right, bottom, colour_enemy, "clear")
            else
                -- Process extended spritemap format
                local p_spritemap = sm.getEnemySpritemap(i)
                if p_spritemap ~= 0 then
                    local bank = xemu.lshift(sm.getEnemyBank(i), 0x10)
                    p_spritemap = bank + p_spritemap
                    local n_spritemap = xemu.read_u8(p_spritemap)
                    if n_spritemap ~= 0 then
                        for ii=0,n_spritemap-1 do
                            local entryPointer = p_spritemap + 2 + ii*8
                            local entryXOffset = xemu.read_s16_le(entryPointer)
                            local entryYOffset = xemu.read_s16_le(entryPointer + 2)
                            local p_entryHitbox = xemu.read_u16_le(entryPointer + 6)
                            if p_entryHitbox ~= 0 then
                                p_entryHitbox = bank + p_entryHitbox
                                local n_hitbox = xemu.read_u16_le(p_entryHitbox)
                                if n_hitbox ~= 0 then
                                    for iii=0,n_hitbox-1 do
                                        local entryLeft   = xemu.read_s16_le(p_entryHitbox + 2 + iii*12)
                                        local entryTop    = xemu.read_s16_le(p_entryHitbox + 2 + iii*12 + 2)
                                        local entryRight  = xemu.read_s16_le(p_entryHitbox + 2 + iii*12 + 4)
                                        local entryBottom = xemu.read_s16_le(p_entryHitbox + 2 + iii*12 + 6)
                                        drawBox(
                                            enemyXPosition - cameraX + entryXOffset + entryLeft,
                                            enemyYPosition - cameraY + entryYOffset + entryTop,
                                            enemyXPosition - cameraX + entryXOffset + entryRight,
                                            enemyYPosition - cameraY + entryYOffset + entryBottom,
                                            colour_enemy, "clear"
                                        )
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- Show enemy index
           drawText(left + 16, top, string.format("%u", i), colour_enemy)
            --drawText(left + 16, top, string.format("%u: %04X", i, enemyId), colour_enemy)

            -- Log enemy index and ID to list in top-right
            if logFlag ~= 0 then
                drawText(224, y, string.format("%u: %04X", i, enemyId), colour_enemy, 0xFF)
                --drawText(192, y, string.format("%u: %04X", i, sm.getEnemyInstructionList(i)), colour_enemy, 0xFF)
                --drawText(160, y, string.format("%u: %04X", i, sm.getEnemyAiVariable5(i)), colour_enemy, 0xFF)
                y = y + 8
            end

            -- Show enemy health
            local enemySpawnHealth = xemu.read_u16_le(0xA00004 + enemyId)
            if enemySpawnHealth ~= 0 then
                local enemyHealth = sm.getEnemyHealth(i)
                drawText(left, top - 16, string.format("%u/%u", enemyHealth, enemySpawnHealth), colour_enemy)
                -- Draw enemy health bar
                if enemyHealth ~= 0 then
                    drawBox(left, top - 8, left + enemyHealth * 32 / enemySpawnHealth, top - 5, colour_enemy, colour_enemy)
                    drawBox(left, top - 8, left + 32, top - 5, colour_enemy, "clear")
                end
            end
        end
    end
end

function displaySpriteObjects(cameraX, cameraY)
    for j=1,32 do
        -- Iterate backwards, I want earlier sprite objects drawn on top of later ones
        local i = 32 - j
        local spriteObjectId = sm.getSpriteObjectInstructionList(i)
        if spriteObjectId ~= 0 then
            local spriteObjectXPosition = sm.getSpriteObjectXPosition(i)
            local spriteObjectYPosition = sm.getSpriteObjectYPosition(i)
            local spriteObjectXRadius = 8
            local spriteObjectYRadius = 8
            local left   = spriteObjectXPosition - spriteObjectXRadius - cameraX
            local top    = spriteObjectYPosition - spriteObjectYRadius - cameraY
            local right  = spriteObjectXPosition + spriteObjectXRadius - cameraX
            local bottom = spriteObjectYPosition + spriteObjectYRadius - cameraY

            -- Draw sprite object
            drawBox(left, top, right, bottom, colour_spriteObject, "clear")

            -- Show sprite object index
            drawText(left, top, string.format("%u", i), colour_spriteObject, "black")
            --drawText(left, top, string.format("%u: %04X", i, spriteObjectId), colour_spriteObject, "black")

            -- Log sprite object index and ID to list in top-left
            if logFlag ~= 0 then
                drawText(0, y, string.format("%u: %04X", i, spriteObjectId), colour_spriteObject, "black")
                y = y + 8
            end
        end
    end
end

function displayEnemyProjectileHitboxes(cameraX, cameraY)
    for j=1,18 do
        -- Iterate backwards, I want earlier enemy projectiles drawn on top of later ones
        local i = 18 - j
        local enemyProjectileId = sm.getEnemyProjectileId(i)
        if enemyProjectileId ~= 0 then
            local enemyProjectileXPosition = sm.getEnemyProjectileXPosition(i)
            local enemyProjectileYPosition = sm.getEnemyProjectileYPosition(i)
            local enemyProjectileXRadius   = sm.getEnemyProjectileXRadius(i)
            local enemyProjectileYRadius   = sm.getEnemyProjectileYRadius(i)
            local left   = enemyProjectileXPosition - enemyProjectileXRadius - cameraX
            local top    = enemyProjectileYPosition - enemyProjectileYRadius - cameraY
            local right  = enemyProjectileXPosition + enemyProjectileXRadius - cameraX
            local bottom = enemyProjectileYPosition + enemyProjectileYRadius - cameraY

            -- Draw enemy projectile hitbox
            drawBox(left, top, right, bottom, colour_enemyProjectile, "clear")
            --drawBox(math.min(left, right - 2), math.min(top, bottom - 2), math.max(right, left + 2), math.max(bottom, top + 2), colour_enemyProjectile, "clear")

            -- Show enemy projectile index
            drawText(left, top, string.format("%u", i), colour_enemyProjectile)
            --drawText(left, top, string.format("%u: %04X", i, enemyProjectileId), colour_enemyProjectile)
            --xemu.write_u16_le(0x7E1BD7 + i * 2, xemu.and_(xemu.read_u16_le(0x7E1BD7 + i * 2), 0xEFFF))
            --drawText(left, top, string.format("%04X", xemu.read_u16_le(0x7E1BD7 + i * 2)), 0x00FFFFFF, 0x000000FF)

            -- Log enemy projectile index and ID to list in top-right (after sprite objects)
            if logFlag ~= 0 then
                drawText(0, y, string.format("%u: %04X", i, enemyProjectileId), colour_enemyProjectile)
                y = y + 8
            end
        end
    end
end

function displayPowerBombExplosionHitbox(cameraX, cameraY)
    if sm.getPowerBombFlag() == 0 then
        return
    end

    local powerBombXPosition = sm.getPowerBombXPosition()
    local powerBombYPosition = sm.getPowerBombYPosition()
    local powerBombXRadius = sm.getPowerBombRadius() / 0x100
    local powerBombYRadius = powerBombXRadius * 3 / 4
    local left   = powerBombXPosition - powerBombXRadius - cameraX
    local top    = powerBombYPosition - powerBombYRadius - cameraY
    local right  = powerBombXPosition + powerBombXRadius - cameraX
    local bottom = powerBombYPosition + powerBombYRadius - cameraY

    -- Draw power bomb hitbox
    drawBox(left, top, right, bottom, colour_powerBomb, "clear")
end

function displayProjectileHitboxes(cameraX, cameraY)
    for i=0,9 do
        local projectileXPosition = sm.getProjectileXPosition(i)
        local projectileYPosition = sm.getProjectileYPosition(i)
        local projectileXRadius   = sm.getProjectileXRadius(i)
        local projectileYRadius   = sm.getProjectileYRadius(i)
        local left   = projectileXPosition - projectileXRadius - cameraX
        local top    = projectileYPosition - projectileYRadius - cameraY
        local right  = projectileXPosition + projectileXRadius - cameraX
        local bottom = projectileYPosition + projectileYRadius - cameraY

        -- Draw projectile hitbox
        drawBox(left, top, right, bottom, colour_projectile, "clear")

        -- Show projectile damage
        drawText(left, top - 8, sm.getProjectileDamage(i), colour_projectile)
        -- Show bomb timer
        if sm.getBombTimer(i) ~= 0 then
            if i >= 5 then
                drawText(left, top - 16, sm.getBombTimer(i), colour_projectile)
            else
                drawText(left, top - 16, string.format("%04X", sm.getBombTimer(i)), colour_projectile)
            end
        end
    end
end

function displaySamusHitbox(cameraX, cameraY, samusXPosition, samusYPosition, viewWidth, viewHeight)
    viewWidth = viewWidth or 256
    viewHeight = viewHeight or 224
    local samusXRadius = sm.getSamusXRadius()
    local samusYRadius = sm.getSamusYRadius()
    if followSamusFlag ~= 0 then
        local cx = math.floor(viewWidth / 2)
        local cy = math.floor(viewHeight / 2)
        left   = cx - samusXRadius
        top    = cy - samusYRadius
        right  = cx + samusXRadius
        bottom = cy + samusYRadius
    else
        left   = samusXPosition - samusXRadius - cameraX
        top    = samusYPosition - samusYRadius - cameraY
        right  = samusXPosition + samusXRadius - cameraX
        bottom = samusYPosition + samusYRadius - cameraY
    end

    -- Draw Samus' hitbox
    drawBox(left, top, right, bottom, colour_samus, "clear")

    -- Show current cooldown time
    local cooldown = sm.getCooldownTimer()
    if cooldown ~= 0 then
        drawText(right, (top + bottom) / 2 - 16, cooldown, "green")
    end

    -- Show current beam charge
    local charge = sm.getChargeCounter()
    if charge ~= 0 then
        drawText(right, (top + bottom) / 2 - 8, charge, "green")
    end

    -- Show recoil/invincibility
    local invincibility = sm.getInvincibilityTimer()
    local recoil = sm.getRecoilTimer()
    if recoil ~= 0 then
        drawText(right, (top + bottom) / 2, recoil, colour_samus)
    elseif invincibility ~= 0 then
        drawText(right, (top + bottom) / 2, invincibility, colour_samus)
    end

    local shine = sm.getShinesparkTimer()
    if shine ~= 0 then
        drawText(right, (top + bottom) / 2 + 8, shine, colour_samus)
    end

    if tasFlag ~= 0 then
        drawText(left, top - 16, string.format("%X.%04X", sm.getSamusXSpeed(), sm.getSamusXSubspeed()), 0xFF00FFFF)
        drawText(left, top - 8,  string.format("%X.%04X", sm.getSamusXMomentum(), sm.getSamusXSubmomentum()), 0xFF00FFFF)
        drawText(left, bottom,   string.format("%X.%04X", sm.getSamusYSpeed(), sm.getSamusYSubspeed()), 0xFF00FFFF)
        drawText(left, bottom + 8, sm.getSpeedBoosterLevel(), 0xFF00FFFF)
    end
end

-- Finally, the main loop
function on_paint()
    -- Timing and input analysis must run even during pause/unpause states, because
    -- Doorskip's important feedback happens exactly when $0998 switches back to gameplay.
    selectConfiguredDrawSurface()
    local viewWidth, viewHeight = getConfiguredViewSize()
    anygUpdateState()

    if not isValidLevelData() then
        anygDrawDoorskipTiming(viewWidth, viewHeight)
        anygDrawWarnings(viewWidth, viewHeight)
        anygDrawTrainingGuide(viewWidth, viewHeight)
        return
    end

    local samusXPosition = sm.getSamusXPositionSigned()
    local samusYPosition = sm.getSamusYPositionSigned()
    
    -- Debug controls
    if debugControlsEnabled ~= 0 then
        handleDebugControls()
    end
    
    -- Co-ordinates of the top-left of the drawn viewport.
    -- In Samus-centered mode, this is intentionally decoupled from the in-game camera.
    -- Higher scriptHud scales create a larger viewport, so more blocks fit around Samus.
    if USE_SAMUS_CENTERED_BLOCK_VIEW then
        cameraX = samusXPosition - math.floor(viewWidth / 2) + xAdjust
        cameraY = samusYPosition - math.floor(viewHeight / 2) + yAdjust
    elseif followSamusFlag ~= 0 then
        cameraX = samusXPosition - 128 + xAdjust
        cameraY = samusYPosition - 112 + yAdjust
    else
        cameraX = sm.getLayer1XPosition()
        cameraY = sm.getLayer1YPosition()
    end
    
    -- Width of the room in blocks
    local roomWidth = sm.getRoomWidth()
    
    if USE_SAMUS_CENTERED_BLOCK_VIEW then
        if blockViewerLayerVisible then
            if SAMUS_CENTERED_BLOCK_VIEW_DRAW_SCROLLS then
                displayScrollBoundaries(cameraX, cameraY, roomWidth, viewWidth, viewHeight)
            end
            displayDebugInfo(cameraX, cameraY, roomWidth)
            displayBlocks(cameraX, cameraY, roomWidth, viewWidth, viewHeight)

            if SAMUS_CENTERED_BLOCK_VIEW_DRAW_FX then
                displayFx(cameraX, cameraY, viewWidth)
            end

            if SAMUS_CENTERED_BLOCK_VIEW_DRAW_HITBOXES then
                displayKraidHitbox(cameraX, cameraY)
                displayMotherBrainHitbox(cameraX, cameraY)
                displayEnemyHitboxes(cameraX, cameraY)
                y = 0
                displaySpriteObjects(cameraX, cameraY)
                displayEnemyProjectileHitboxes(cameraX, cameraY)
                displayPowerBombExplosionHitbox(cameraX, cameraY)
                displayProjectileHitboxes(cameraX, cameraY)
            end

            displaySamusHitbox(cameraX, cameraY, samusXPosition, samusYPosition, viewWidth, viewHeight)

            -- Center crosshair, helpful when the viewport is much larger than the game screen.
            local cx = math.floor(viewWidth / 2)
            local cy = math.floor(viewHeight / 2)
            drawLine(cx - 6, cy, cx + 6, cy, colour_samus)
            drawLine(cx, cy - 6, cx, cy + 6, colour_samus)

            if SAMUS_CENTERED_BLOCK_VIEW_DRAW_STATUS_TEXT then
                local blocksWide = math.floor(viewWidth / 16)
                local blocksHigh = math.floor(viewHeight / 16)
                drawText(4, 4, string.format("Samus-centered blocks | HUD scale %dx | approx %dx%d blocks", SAMUS_CENTERED_BLOCK_VIEW_SCALE, blocksWide, blocksHigh), 0xFFFFFFFF, 0x000000FF)
                drawText(4, 12, string.format("Samus: %04X,%04X  View origin: %04X,%04X", xemu.and_(samusXPosition, 0xFFFF), xemu.and_(samusYPosition, 0xFFFF), xemu.and_(cameraX, 0xFFFF), xemu.and_(cameraY, 0xFFFF)), 0xFFFFFFFF, 0x000000FF)
                drawText(4, 20, debugBlockTextFilterEnabled and "Block labels: filtered (Select+B+X: all)" or "Block labels: all block types (Select+B+X: filtered)", 0xFFFFFFFF, 0x000000FF)
            end

            anygDrawWaypoints(cameraX, cameraY, viewWidth, viewHeight)
        end

        -- Keep these assist layers visible even when the block/world viewer layer is hidden.
        anygDraw0380Helper(viewWidth, viewHeight)
        anygDrawDashboard(viewWidth, viewHeight)
        anygDrawWarnings(viewWidth, viewHeight)
        anygDrawTrainingGuide(viewWidth, viewHeight)
        anygDrawDoorskipTiming(viewWidth, viewHeight)
        anygDrawTrainingChecklist(viewWidth, viewHeight)

        if tasFlag ~= 0 then
            -- Show in-game time
            drawText(viewWidth - 40, 0, string.format("%d:%d:%d.%d", sm.getGameTimeHours(), sm.getGameTimeMinutes(), sm.getGameTimeSeconds(), sm.getGameTimeFrames()), 0xFFFFFFFF)
        end
        return
    end

    -- Original in-game-camera overlay path
    if blockViewerLayerVisible then
        displayScrollBoundaries(cameraX, cameraY, roomWidth, viewWidth, viewHeight)
        --displayCameraMargin()
        displayDebugInfo(cameraX, cameraY, roomWidth)
        displayBlocks(cameraX, cameraY, roomWidth, viewWidth, viewHeight)
        displayFx(cameraX, cameraY, viewWidth)
        
        displayKraidHitbox(cameraX, cameraY)
        displayMotherBrainHitbox(cameraX, cameraY)
        displayEnemyHitboxes(cameraX, cameraY)
        y = 0
        displaySpriteObjects(cameraX, cameraY)
        displayEnemyProjectileHitboxes(cameraX, cameraY)
        
        displayPowerBombExplosionHitbox(cameraX, cameraY)
        displayProjectileHitboxes(cameraX, cameraY)
        displaySamusHitbox(cameraX, cameraY, samusXPosition, samusYPosition, viewWidth, viewHeight)
        anygDrawWaypoints(cameraX, cameraY, viewWidth, viewHeight)
    end

    -- Keep assist layers visible even when the block/world viewer layer is hidden.
    anygDraw0380Helper(viewWidth, viewHeight)
    anygDrawDashboard(viewWidth, viewHeight)
    anygDrawWarnings(viewWidth, viewHeight)
    anygDrawTrainingGuide(viewWidth, viewHeight)
    anygDrawDoorskipTiming(viewWidth, viewHeight)
    anygDrawTrainingChecklist(viewWidth, viewHeight)
    
    if tasFlag ~= 0 then
        -- Show in-game time
        drawText(216, 0, string.format("%d:%d:%d.%d", sm.getGameTimeHours(), sm.getGameTimeMinutes(), sm.getGameTimeSeconds(), sm.getGameTimeFrames()), 0xFFFFFFFF)
    end
end

if xemu.emuId == xemu.emuId_bizhawk then
    -- BizHawk requires using onframestart to draw on the correct frame
    event.unregisterbyname("Super Hitbox")
    event.onframestart(on_paint, "Super Hitbox")
elseif xemu.emuId == xemu.emuId_mesen then
    emu.addEventCallback(on_paint, emu.eventType.nmi)
elseif xemu.emuId ~= xemu.emuId_lsnes then
    while true do
        on_paint()
        emu.frameadvance()
    end
end
