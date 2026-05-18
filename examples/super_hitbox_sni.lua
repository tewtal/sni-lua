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

-- Draw-surface API. The script's Samus-centered block viewer selects the
-- "scriptHud" surface at a scale (default 3) and then draws in that scaled
-- coordinate space (e.g. 768x672). sni-lua's equivalent is the resolution
-- canvas: selecting the HUD surface at scale N => gfx.scale(N), so the
-- script's coords map 1:1 onto our canvas. Without this the script falls
-- back to a 256x224 console-screen space while its layout assumes the
-- larger one -> everything draws off-canvas / wrong size.
emu.drawSurface = { scriptHud = "scriptHud", consoleScreen = "consoleScreen" }

local _hud_scale = 1
function emu.selectDrawSurface(which, scale)
    if which == "scriptHud" then
        _hud_scale = math.max(1, math.floor((scale or 1) + 0.5))
        gfx.scale(_hud_scale)          -- canvas becomes 256*N x 224*N
    else
        _hud_scale = 1
        gfx.scale(1)
    end
end

function emu.getDrawSurfaceSize(_which)
    -- Report the active scaled HUD size so the script's centering math is
    -- correct. gfx.width()/height() reflect the canvas we just set.
    return {
        width = gfx.width(),  height = gfx.height(),
        visibleWidth = gfx.width(), visibleHeight = gfx.height(),
    }
end

function emu.getScreenSize()
    return { width = gfx.width(), height = gfx.height() }
end

-- Colour handling. The script's mesenDrawColourFromRgba already encodes
-- colours as 0xAARRGGBB AND, with CONFIG.drawing.mesenDrawAlphaInverted =
-- true (the default), it INVERTS alpha (00 = opaque, FF = transparent --
-- Mesen's convention). sni-lua's gfx.* expect standard 0xAARRGGBB where
-- FF = opaque. So we must un-invert the alpha byte here, otherwise every
-- "opaque" thing the script draws arrives as alpha 0x00 = fully
-- transparent (the "nothing renders" symptom).
local MESEN_ALPHA_INVERTED = true
-- NOTE on integer width: LuaJIT's `bit` ops are signed 32-bit, so
-- bit.lshift(0xFF,24) yields a NEGATIVE number, and `a*0x1000000` for
-- a>=0x80 exceeds i32. sni-lua's gfx.* take a u32 0xAARRGGBB. So we must
-- hand back a plain Lua number in the unsigned range [0, 0xFFFFFFFF] and
-- never a bit-op result for the top byte. Decompose, then recompose with
-- arithmetic (which stays a double, exact to 2^53).
local function argb(c)
    if c == nil then return nil end
    -- Pull bytes out of whatever the script gave us (it may itself be a
    -- signed/negative 32-bit value from its own lshift(a,24)).
    if c < 0 then c = c + 0x100000000 end
    local a = math.floor(c / 0x1000000) % 0x100
    local r = math.floor(c / 0x10000)   % 0x100
    local g = math.floor(c / 0x100)     % 0x100
    local b = c % 0x100
    if MESEN_ALPHA_INVERTED then
        a = 0xFF - a
    end
    -- Recompose as an unsigned double in [0, 0xFFFFFFFF].
    return a * 0x1000000 + r * 0x10000 + g * 0x100 + b
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

-- Super Hitbox for Mesen2 (SNES)
-- Standalone conversion generated from the provided Super Hitbox script plus the upstream
-- Super Metroid helper definitions. Load this file from Mesen2's Script Window while a
-- Super Metroid ROM is running.
--
-- Mesen2 notes:
--   * This version does not require "cross emu.lua" or "Super Metroid.lua".
--   * It uses Mesen2 API names: emu.read/read16/write/write16 and SNES memory types.
--   * If you prefer the HUD surface instead of the console framebuffer, change
--     USE_SCRIPT_HUD to true below.
--   * This variant includes Any% Glitched route assists, a Doorskip timing analyzer,
--     and a separate block-viewer layer toggle.

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
        enabled = true,
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

if not emu or not emu.getState then
    error("This standalone version must be run inside Mesen2's Lua script window.")
end

local state = emu.getState()
if state and state.consoleType and state.consoleType ~= "Snes" and state.consoleType ~= "SNES" then
    emu.displayMessage("Super Hitbox", "This script is for the SNES core. Current console: " .. tostring(state.consoleType))
    return
end

local function selectConfiguredDrawSurface()
    if USE_SAMUS_CENTERED_BLOCK_VIEW and emu.drawSurface and emu.drawSurface.scriptHud then
        emu.selectDrawSurface(emu.drawSurface.scriptHud, SAMUS_CENTERED_BLOCK_VIEW_SCALE)
    elseif USE_SCRIPT_HUD and emu.drawSurface and emu.drawSurface.scriptHud then
        emu.selectDrawSurface(emu.drawSurface.scriptHud, 1)
    elseif emu.drawSurface and emu.drawSurface.consoleScreen then
        emu.selectDrawSurface(emu.drawSurface.consoleScreen)
    end
end

selectConfiguredDrawSurface()

local xemu = {}
xemu.emuId_bizhawk = 0
xemu.emuId_snes9x  = 1
xemu.emuId_lsnes   = 2
xemu.emuId_mesen   = 3
xemu.emuId_mesen2  = 4
-- Keep emuId_mesen here because the original script's callback dispatch checks that value.
xemu.emuId = xemu.emuId_mesen

-- Bitwise helpers. Mesen2 uses a modern Lua runtime with native bitwise operators.
xemu.rshift = function(x, y) return bit.rshift(x, y) end
xemu.lshift = function(x, y) return bit.lshift(x, y) end
xemu.not_   = function(x) return bit.bnot(x) end
xemu.and_   = function(x, y) return bit.band(x, y) end
xemu.or_    = function(x, y) return bit.bor(x, y) end
xemu.xor    = function(x, y) return bit.bxor(x, y) end

local function snes2pc(p)
    -- LoROM CPU address to unheadered ROM offset. This is kept for fallback direct ROM reads.
    return xemu.and_(xemu.rshift(p, 1), 0x3F8000) + xemu.and_(p, 0x7FFF)
end

local mem = emu.memType
local snesDebug = mem.snesDebug or mem.snesMemory
local snesMemory = mem.snesMemory or snesDebug
local wram = mem.snesWorkRam or mem.workRam
local spcRam = mem.spcRam or mem.spcMemory
local prgRom = mem.snesPrgRom or mem.prgRom

local function readCpu8(p, signed)
    -- Prefer the S-CPU debug address space so 24-bit SNES CPU addresses work for both WRAM and ROM.
    return emu.read(p, snesDebug, signed or false)
end

local function readCpu16(p, signed)
    return emu.read16(p, snesDebug, signed or false)
end

local function writeWram8(p, v)
    if p < 0x800000 then
        return emu.write(xemu.and_(p, 0x1FFFF), xemu.and_(v, 0xFF), wram)
    end
    emu.log(string.format('Error: trying to write to ROM address %X', p))
end

local function writeWram16(p, v)
    if p < 0x800000 then
        return emu.write16(xemu.and_(p, 0x1FFFF), xemu.and_(v, 0xFFFF), wram)
    end
    emu.log(string.format('Error: trying to write to ROM address %X', p))
end

xemu.read_u8      = function(p) return readCpu8(p, false) end
xemu.read_u16_le  = function(p) return readCpu16(p, false) end
xemu.read_s8      = function(p) return readCpu8(p, true) end
xemu.read_s16_le  = function(p) return readCpu16(p, true) end
xemu.write_u8     = writeWram8
xemu.write_u16_le = writeWram16

xemu.read_aram_u8     = function(p) return emu.read(p, spcRam, false) end
xemu.read_aram_u16_le = function(p) return emu.read16(p, spcRam, false) end
xemu.read_aram_s8     = function(p) return emu.read(p, spcRam, true) end
xemu.read_aram_s16_le = function(p) return emu.read16(p, spcRam, true) end

local function mesenDrawColourFromRgba(r, g, b, a)
    r = xemu.and_(math.floor(r or 0), 0xFF)
    g = xemu.and_(math.floor(g or 0), 0xFF)
    b = xemu.and_(math.floor(b or 0), 0xFF)
    a = xemu.and_(math.floor(a == nil and 0xFF or a), 0xFF)

    local drawAlpha = a
    if MESEN_DRAW_ALPHA_INVERTED then
        -- Mesen's draw APIs commonly use inverted alpha: 00 = opaque, FF = transparent.
        drawAlpha = 0xFF - a
    end

    return xemu.lshift(drawAlpha, 24)
         + xemu.lshift(r, 16)
         + xemu.lshift(g, 8)
         + b
end

local function mesenColour(colour)
    if colour == nil then
        return nil
    end

    if type(colour) == "string" then
        if colour == "red" then
            return mesenDrawColourFromRgba(0xFF, 0x00, 0x00, 0xFF)
        elseif colour == "orange" then
            return mesenDrawColourFromRgba(0xFF, 0x80, 0x00, 0xFF)
        elseif colour == "yellow" then
            return mesenDrawColourFromRgba(0xFF, 0xFF, 0x00, 0xFF)
        elseif colour == "white" then
            return mesenDrawColourFromRgba(0xFF, 0xFF, 0xFF, 0xFF)
        elseif colour == "black" then
            return mesenDrawColourFromRgba(0x00, 0x00, 0x00, 0xFF)
        elseif colour == "green" then
            return mesenDrawColourFromRgba(0x00, 0xFF, 0x00, 0xFF)
        elseif colour == "purple" then
            return mesenDrawColourFromRgba(0xFF, 0x00, 0xFF, 0xFF)
        elseif colour == "cyan" then
            return mesenDrawColourFromRgba(0x00, 0xFF, 0xFF, 0xFF)
        elseif colour == "blue" then
            return mesenDrawColourFromRgba(0x00, 0x00, 0xFF, 0xFF)
        elseif colour == "gray" or colour == "grey" then
            return mesenDrawColourFromRgba(0x80, 0x80, 0x80, 0xFF)
        elseif colour == "darkgray" or colour == "darkgrey" then
            return mesenDrawColourFromRgba(0x40, 0x40, 0x40, 0xFF)
        elseif colour == "clear" then
            return mesenDrawColourFromRgba(0x00, 0x00, 0x00, 0x00)
        else
            emu.log(string.format("Unknown colour = %s", colour))
            return mesenDrawColourFromRgba(0xFF, 0xFF, 0xFF, 0xFF)
        end
    end

    -- The original script stores numeric colours as 0xRRGGBBAA.
    -- Convert that to the draw-call format expected by the selected Mesen alpha mode.
    local a = xemu.and_(colour, 0xFF)
    local b = xemu.and_(xemu.rshift(colour, 8), 0xFF)
    local g = xemu.and_(xemu.rshift(colour, 16), 0xFF)
    local r = xemu.and_(xemu.rshift(colour, 24), 0xFF)
    return mesenDrawColourFromRgba(r, g, b, a)
end

local function i(v)
    if v == nil then return 0 end
    return math.floor(v + 0.5)
end

local function drawYOffset()
    -- The old console-screen overlay needs a small vertical offset in Mesen.
    -- The Samus-centered scriptHud viewer is its own coordinate space, so no offset is used.
    if USE_SAMUS_CENTERED_BLOCK_VIEW and emu.drawSurface and emu.drawSurface.scriptHud then
        return 0
    end
    return MESEN_Y_OFFSET
end

local function getConfiguredViewSize()
    if USE_SAMUS_CENTERED_BLOCK_VIEW and emu.getDrawSurfaceSize and emu.drawSurface and emu.drawSurface.scriptHud then
        local size = emu.getDrawSurfaceSize(emu.drawSurface.scriptHud)
        if size then
            return size.visibleWidth or size.width or (256 * SAMUS_CENTERED_BLOCK_VIEW_SCALE),
                   size.visibleHeight or size.height or (224 * SAMUS_CENTERED_BLOCK_VIEW_SCALE)
        end
    end

    if emu.getScreenSize then
        local size = emu.getScreenSize()
        if size then
            return size.width or 256, size.height or 224
        end
    end

    if USE_SAMUS_CENTERED_BLOCK_VIEW then
        return 256 * SAMUS_CENTERED_BLOCK_VIEW_SCALE, 224 * SAMUS_CENTERED_BLOCK_VIEW_SCALE
    end

    return 256, 224
end

xemu.drawPixel = function(x, y, fg)
    emu.drawPixel(i(x), i(y + drawYOffset()), mesenColour(fg), 1)
end

xemu.drawBox = function(x0, y0, x1, y1, fg, bg)
    local left = math.min(i(x0), i(x1))
    local top = math.min(i(y0), i(y1)) + drawYOffset() - 1
    local right = math.max(i(x0), i(x1))
    local bottom = math.max(i(y0), i(y1)) + drawYOffset() - 1
    local fill = bg ~= nil and bg ~= "clear" and mesenColour(bg) == mesenColour(fg)
    emu.drawRectangle(left, top, right - left + 1, bottom - top + 1, mesenColour(fg), fill, 1)
end

xemu.drawLine = function(x0, y0, x1, y1, fg)
    emu.drawLine(i(x0), i(y0 + drawYOffset() - 1), i(x1), i(y1 + drawYOffset() - 1), mesenColour(fg), 1)
end

xemu.drawText = function(x, y, text, fg, bg)
    emu.drawString(i(x), i(y + drawYOffset()), tostring(text), mesenColour(fg), mesenColour(bg or "black"), 0, 1)
end


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
sm.getLevelDatum      = makeReader(0x7F0002, 2, false, 2)
sm.getBts             = makeReader(0x7F6402, 1, false, 1)
sm.getBtsSigned       = makeReader(0x7F6402, 1, true,  1)
sm.getBackgroundDatum = makeReader(0x7F9602, 2, false, 2)


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

-- Display CPU usage
if xemu.emuId == xemu.emuId_bizhawk and false then -- GUI drawing functions from on_paint are clearing this text output for some reason...
    idling = false
    lagFrames = 0
    if recordLagHotspots then
        outfile = io.open("lag.txt", "w")
    end

    function idleHook()
        -- Report CPU time used by current frame
        -- NMI occurs at v = 225
        local v = emu.getregister('V')
        local cpu = lagFrames * 100 + (v - 225) % 262 * 100 / 262
        if recordLagHotspots and 100 <= cpu and cpu < 110 then
            outfile:write(string.format("%d: %f\n", emu.framecount(), cpu))
            console.log(string.format("%d: %f", emu.framecount(), cpu))
        end
        drawText(4, 36, string.format('CPU used: %.2f%%', cpu), cpu < 100 and "white" or "red", 0x000000FF)

        idling = true
        lagFrames = 0
    end

    function nmiHook()
        if not idling then
            lagFrames = lagFrames + 1
            drawText(4, 36, string.format('CPU used: %.2f%%', lagFrames * 100), "red", 0x000000FF)
        end

        idling = false
    end

    event.onmemoryexecute(nmiHook, 0x009583)
    event.onmemoryexecute(idleHook, 0x82897A)
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
    local input = sm.getInput()
    local changedInput = sm.getChangedInput()
    local controls = ((CONFIG.blockLabels or {}).controls or {})

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
    for i = 0,slots - 1 do
        local id = sm.getPlmId(i)
        if id ~= 0 then
            count = count + 1
        end
    end
    return count
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
    return ((sm.getGameTimeHours() or 0) * 60 * 60 * 60)
         + ((sm.getGameTimeMinutes() or 0) * 60 * 60)
         + ((sm.getGameTimeSeconds() or 0) * 60)
         + (sm.getGameTimeFrames() or 0)
end

local function anygAnyBombActive()
    for i = 0,9 do
        if sm.getBombTimer(i) ~= 0 then
            return true
        end
    end
    return false
end

local function anygUpdateFreezeTimer()
    local cfg = ANYG.freezeTimer or {}
    if not cfg.enabled then return end

    local gameState = sm.getGameState()
    local timeKey = anygGameTimeKey()
    if anygState.prevGameTime ~= nil and gameState == 8 then
        if timeKey == anygState.prevGameTime then
            anygState.freezeFrames = anygState.freezeFrames + 1
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
end

local function anygCheckImportantChanges(snapshot)
    local cfg = ANYG.watchChanges or {}
    if not cfg.enabled then return end

    local function changedLost(key, desired, label)
        local prev = anygState.prevValues[key]
        local now = snapshot[key]
        if prev == desired and now ~= desired then
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
        local now = snapshot["090F"]
        if prev ~= nil and now == 0 and prev ~= 0 then
            local hi = xemu.rshift(xemu.and_(prev, 0xF0), 4)
            if hi == 0xF or hi == 0x7 or prev >= 0xFC then
                anygAddWarning(string.format("$090F reset: %02X -> 00", prev), "red")
            end
        end
    end

    if cfg.alertOn0C5FLost then
        local prev = anygState.prevValues["0C5F"]
        local now = snapshot["0C5F"]
        if prev ~= nil and (xemu.rshift(prev, 4) == 0xF or xemu.rshift(prev, 4) == 0x7) and not (xemu.rshift(now, 4) == 0xF or xemu.rshift(now, 4) == 0x7) then
            anygAddWarning(string.format("$0C5F lost: %02X -> %02X", prev, now), "red")
        end
    end

    if cfg.alertOn0026Bad then
        local prev = anygState.prevValues["0026"]
        local now = snapshot["0026"]
        if now == 0 and prev ~= 0 then
            anygAddWarning("$0026 became 0000: likely no X-ray from item touch", "red")
        elseif now == 0xFFFF and prev ~= 0xFFFF then
            anygAddWarning("$0026 is FFFF: X-ray + major items source ready", "green")
        end
    end

    if cfg.alertOnBombAfter0C5FGood then
        local bombActive = anygAnyBombActive()
        local c5f = snapshot["0C5F"] or 0
        local c5fGood = xemu.rshift(c5f, 4) == 0xF or xemu.rshift(c5f, 4) == 0x7
        if bombActive and not anygState.previousBombActive and c5fGood then
            anygAddWarning("Bomb active while $0C5F is good: avoid resetting 6F-skree setup", "yellow")
        end
        anygState.previousBombActive = bombActive
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
    if status == "EARLY" or status == "LATE" then return cfg.warnColour or "yellow" end
    return cfg.badColour or "red"
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
    if ds.directionOffset ~= nil then
        dirText = string.format("dir %+d %s", ds.directionDiff or 0, ds.directionStatus or "?")
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
    elseif ds.angleOffset ~= nil then
        shoulderText = string.format("L/R %+d %s", ds.angleOffset, ds.angleStatus or "?")
    end

    return string.format("Doorskip: %s | %s | %s", dirText, downText, shoulderText)
end

local function anygFinalizeShoulderTiming(cfg, button, diff)
    local ds = anygState.doorskip
    if ds.shoulderResolved then return end

    ds.angleButton = button or ds.firstShoulderButton
    ds.angleOffset = diff
    ds.angleStatus = anygTimingStatus(diff or 9999, cfg.shoulderGoodWindow or 0, cfg.shoulderNearWindow or 2)
    ds.angleHeldOnResume = false
    ds.anglePressedOnResume = diff == 0
    ds.shoulderResolved = true
    ds.awaitingLateShoulder = false

    local dirOk = ds.directionStatus == "GOOD"
    local downOk = (cfg.requireDownBeforeResume == false) or ds.downStatus == "OK"
    local shoulderOk = ds.angleStatus == "GOOD"
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
    ds.angleStatus = "MISSED"
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

local function anygUpdateDoorskipTiming()
    local cfg = anygDoorskipConfig()
    if not anygEnabled() or not cfg.enabled then return end

    local input = sm.getInput()
    local changed = sm.getChangedInput()
    local gameState = sm.getGameState()
    local prevGameState = anygState.prevGameState
    local ds = anygState.doorskip

    local startPressed = xemu.and_(changed, sm.button_start) ~= 0
    local leftPressed = xemu.and_(changed, sm.button_left) ~= 0
    local rightPressed = xemu.and_(changed, sm.button_right) ~= 0
    local downPressed = xemu.and_(changed, sm.button_down) ~= 0
    local shoulderLPressed = xemu.and_(changed, sm.button_L) ~= 0
    local shoulderRPressed = xemu.and_(changed, sm.button_R) ~= 0
    local shoulderHeld = xemu.and_(input, sm.button_L + sm.button_R) ~= 0
    local shoulderPressed = shoulderLPressed or shoulderRPressed

    if startPressed then
        anygStartDoorskipAttempt(input)
    end

    local attemptActive = ds.startFrame ~= nil and anygState.frame - ds.startFrame <= (cfg.attemptTimeoutFrames or 240)

    if attemptActive and (leftPressed or rightPressed) then
        local button = leftPressed and sm.button_left or sm.button_right
        ds.lastDirectionPressFrame = anygState.frame
        ds.lastDirectionButton = button
        if ds.directionFrame == nil then
            local offset = anygState.frame - ds.startFrame
            local diff = offset - (cfg.targetDirectionFramesAfterStart or 5)
            local status = anygTimingStatus(diff, cfg.directionGoodWindow or 0, cfg.directionNearWindow or 2)
            ds.directionFrame = anygState.frame
            ds.directionButton = button
            ds.directionOffset = offset
            ds.directionDiff = diff
            ds.directionStatus = status
            ds.lastResultText = string.format("D-pad %s at +%df: %s (%+d)", anygButtonNameFromMask(button), offset, status, diff)
            ds.lastResultColour = anygTimingColour(status)
            if status ~= "GOOD" and cfg.warnOnBadAttempt then
                anygAddWarning(ds.lastResultText, ds.lastResultColour)
            end
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
    local resumedToGameplay = prevGameState == targetFrom and gameState == targetTo
    local earlyDoorTransition = cfg.markEarlyDoorTransition ~= false and prevGameState == targetFrom and gameState == earlyDoorTo

    if prevGameState ~= nil and gameState ~= prevGameState and attemptActive then
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
end

local function anygHandleControls()
    local cfg = ANYG.controls or {}
    local input = sm.getInput()
    local changed = sm.getChangedInput()
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
        anygState.plmBaseline = anygCountPlms()
        anygAddWarning(string.format("PLM baseline reset to %d", anygState.plmBaseline), "green")
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
    anygState.frame = anygState.frame + 1
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

    local snapshot = {
        ["11FD"] = xemu.read_u8(0x7E11FD),
        ["1201"] = xemu.read_u8(0x7E1201),
        ["1D59"] = xemu.read_u8(0x7E1D59),
        ["1D5B"] = xemu.read_u8(0x7E1D5B),
        ["090F"] = xemu.read_u8(0x7E090F),
        ["18E2"] = xemu.read_u8(0x7E18E2),
        ["0C5F"] = xemu.read_u8(0x7E0C5F),
        ["1A8A"] = xemu.read_u8(0x7E1A8A),
        ["0026"] = xemu.read_u16_le(0x7E0026),
        ["0380"] = xemu.read_u16_le(0x7E0380),
        ["1843"] = xemu.read_u8(0x7E1843),
        ["03D7"] = xemu.read_u8(0x7E03D7),
    }

    anygCheckImportantChanges(snapshot)
    anygState.prevValues = snapshot

    if ANYG.plm and ANYG.plm.enabled then
        local count = anygCountPlms()
        if anygState.plmBaseline == nil then
            anygState.plmBaseline = ANYG.plm.baseline or count
        end
        if anygState.lastPlmCount ~= nil and count ~= anygState.lastPlmCount then
            local delta = count - anygState.lastPlmCount
            anygAddWarning(string.format("PLM count %d (%+d)", count, delta), delta > 0 and "green" or "yellow")
        end
        anygState.lastPlmCount = count
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
        local bt = anygRead(target.btAddress, 1)
        local bts = anygRead(target.btsAddress, 1)
        local btStatus = anygCheckBtSource(bt, target)
        local btsStatus = anygCheckBtsSource(bts, target)
        local ok = btStatus == "OK" and btsStatus == "OK"
        return ok, bt, bts, btStatus, btsStatus
    end

    if d.compact ~= false then
        local summaryParts = {}
        local summaryStatus = "OK"
        for _, target in ipairs(ANYG.routeTargets or {}) do
            local ok, bt, bts = targetStatus(target)
            if not ok then summaryStatus = "BAD" end
            local short = target.key or target.name or "?"
            short = short:gsub("%-", "")
            table.insert(summaryParts, string.format("%s %s", short, ok and "OK" or string.format("%02X/%02X", bt, bts)))
        end
        drawLineText("AnyG: " .. table.concat(summaryParts, "  "), summaryStatus)

        local v0026 = xemu.read_u16_le(0x7E0026)
        local v0380 = xemu.read_u16_le(0x7E0380)
        local label0380 = ""
        local status0026 = v0026 >= 0x8000 and "OK" or (v0026 == 0 and "BAD" or "WARN")
        for _, watch in ipairs(ANYG.extraWatches or {}) do
            if watch.key == "gold-0380" and watch.exactLabels then
                label0380 = watch.exactLabels[v0380] or ""
            end
        end
        local status0380 = label0380 ~= "" and "OK" or "INFO"
        local statusLine = (status0026 == "BAD" or status0380 == "BAD") and "BAD" or (status0026 == "WARN" and "WARN" or "OK")
        drawLineText(string.format("$0026 %04X  $0380 %04X %s", v0026, v0380, label0380), statusLine)

        if d.showAddressDetails then
            local v090F = xemu.read_u8(0x7E090F)
            local v1843 = xemu.read_u8(0x7E1843)
            local v03D7 = xemu.read_u8(0x7E03D7)
            drawLineText(string.format("detail: $090F %02X  $1843 %02X  $03D7 %02X", v090F, v1843, v03D7), "INFO")
        end

        if d.showPlmAndFreeze ~= false then
            local parts = {}
            local status = "INFO"
            if ANYG.showPlmCount and ANYG.plm and ANYG.plm.enabled then
                local count = anygState.lastPlmCount or anygCountPlms()
                local baseline = anygState.plmBaseline or count
                local extra = count - baseline
                local targetExtra = ANYG.plm.targetExtra or 8
                table.insert(parts, string.format("PLM %02d (%+d/%d)", count, extra, targetExtra))
                if extra >= targetExtra then status = "OK" elseif extra > 0 then status = "WARN" end
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
        local ok, bt, bts, btStatus, btsStatus = targetStatus(target)
        local status = ok and "OK" or "BAD"
        drawLineText(string.format("%-10s BT %02X %s  BTS %02X %s", target.key or target.name, bt, btStatus, bts, btsStatus), status)
    end

    for _, watch in ipairs(ANYG.extraWatches or {}) do
        local value = anygRead(watch.address, watch.size or 1)
        local status, note = anygCheckWatch(value, watch)
        local digits = (watch.size == 2) and 4 or 2
        if watch.exactLabels and watch.exactLabels[value] then
            note = watch.exactLabels[value]
            status = "OK"
        elseif watch.showNearest and watch.exactLabels then
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
        local count = anygState.lastPlmCount or anygCountPlms()
        local baseline = anygState.plmBaseline or count
        local extra = count - baseline
        local targetExtra = ANYG.plm.targetExtra or 8
        local status = extra >= targetExtra and "OK" or (extra > 0 and "WARN" or "INFO")
        drawLineText(string.format("PLMs %02d  base %02d  extra %+d/%d", count, baseline, extra, targetExtra), status)
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
    local value = xemu.read_u16_le(0x7E0380)
    local label = nil
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
    if label == nil then
        label = ""
    end
    local colour = (label ~= "") and "yellow" or "white"
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

    local gs = sm.getGameState()
    if cfg.showLiveInputLine then
        local input = sm.getInput()
        local jumpHeld = xemu.and_(input, sm.button_A) ~= 0
        local downHeld = xemu.and_(input, sm.button_down) ~= 0
        anygDrawPanelLine(x, y, string.format("$0998=%02X  Jump:%s  Down:%s", gs, jumpHeld and "held" or "no", downHeld and "held" or "no"), textC, bg)
        y = y + lh
    end

    local startText
    if ds.startFrame ~= nil then
        startText = string.format("Start +%df    $0998=%02X", anygState.frame - ds.startFrame, gs)
    else
        startText = string.format("Waiting for Start    $0998=%02X", gs)
    end
    anygDrawPanelLine(x, y, startText, textC, bg)
    y = y + lh

    local dirColour = warnC
    local dirText = string.format("D-pad L/R: target +%df", cfg.targetDirectionFramesAfterStart or 5)
    if ds.directionOffset ~= nil then
        dirColour = anygTimingColour(ds.directionStatus)
        dirText = string.format("D-pad %s: %+d  %s", anygButtonNameFromMask(ds.directionButton), ds.directionDiff or 0, ds.directionStatus or "?")
    elseif ds.startFrame ~= nil then
        local due = (cfg.targetDirectionFramesAfterStart or 5) - (anygState.frame - ds.startFrame)
        dirText = string.format("D-pad L/R: due %+df", due)
        dirColour = math.abs(due) <= 1 and warnC or textC
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

    local v11FD = xemu.read_u8(0x7E11FD)
    local v1201 = xemu.read_u8(0x7E1201)
    local v1D59 = xemu.read_u8(0x7E1D59)
    local v1D5B = xemu.read_u8(0x7E1D5B)
    local v090F = xemu.read_u8(0x7E090F)
    local v0C5F = xemu.read_u8(0x7E0C5F)
    local v18E2 = xemu.read_u8(0x7E18E2)
    local v1A8A = xemu.read_u8(0x7E1A8A)
    local v1843 = xemu.read_u8(0x7E1843)
    local v0026 = xemu.read_u16_le(0x7E0026)
    local v0380 = xemu.read_u16_le(0x7E0380)
    local bombActive = anygAnyBombActive()

    local function hiGood(v)
        local hi = xemu.rshift(xemu.and_(v, 0xF0), 4)
        return hi == 0xF or hi == 0x7
    end

    local function status(ok, warn)
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

    local function addCheck(rows, label, ok, warn, value, note)
        local mark, colour = status(ok, warn)
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
        string.format("$1D59=%02X", v1D59), "want 5D for 5D-left / X-ray block")
    addCheck(rows, "5D-right BTS", v1D5B == 0x5D, false,
        string.format("$1D5B=%02X", v1D5B), "want 5D for 5D-right / +1 PLM")
    addCheck(rows, "Geemer BT pair", hiGood(v11FD) and hiGood(v1201), hiGood(v11FD) or hiGood(v1201),
        string.format("$11FD/$1201=%02X/%02X", v11FD, v1201), "both should be F_ or 7_ before Shuffler")
    addCheck(rows, "6F-layer pair", hiGood(v090F) and v18E2 == 0x6F, v18E2 == 0x6F and v090F ~= 0,
        string.format("$090F/$18E2=%02X/%02X", v090F, v18E2), "$090F should be F_/7_; $18E2 should be 6F")
    addCheck(rows, "6F-skree pair", hiGood(v0C5F) and v1A8A == 0x6F, v1A8A == 0x6F and v0C5F ~= 0,
        string.format("$0C5F/$1A8A=%02X/%02X", v0C5F, v1A8A), "$0C5F should stay F_/7_; $1A8A should be 6F")

    addSection(rows, "RULES / DANGER CHECKS")
    addCheck(rows, "No bomb active", not bombActive, false,
        bombActive and "bomb active" or "clear", "do not bomb again before Shuffler")
    addCheck(rows, "$0026 item source", v0026 >= 0x8000, v0026 ~= 0 and v0026 < 0x8000,
        string.format("$0026=%04X", v0026), "FFFF/C000 good; 0000 means no X-ray/all-items")
    addCheck(rows, "$1843 slope timer", v1843 >= 0x10 and v1843 <= 0x1F, v1843 >= 0x08 and v1843 <= 0x27,
        string.format("$1843=%02X", v1843), "route movement prefers about 10..1F")

    addSection(rows, "POST-SHUFFLER / TOUCH FEEDBACK")
    local count = anygState.lastPlmCount or anygCountPlms()
    local baseline = anygState.plmBaseline or count
    local extra = count - baseline
    local targetExtra = ((ANYG.plm or {}).targetExtra or 8)
    addCheck(rows, "Extra PLMs", extra >= targetExtra, extra > 0,
        string.format("%+d/%d  total %02d", extra, targetExtra, count), "Select+B+Y resets the baseline")
    addCheck(rows, "$0380 Gold value", false, true,
        string.format("$0380=%04X", v0380), gold0380Label(v0380))
    local ds = anygState.doorskip or {}
    local downOk = ds.downStatus == "OK"
    local shoulderOk = ds.angleStatus == "GOOD"
    local dirOk = ds.directionStatus == "GOOD"
    local dsWarn = ds.startFrame ~= nil or ds.lastResultText ~= nil
    local dsValue = "waiting"
    if ds.startFrame ~= nil then
        dsValue = string.format("Start +%df", anygState.frame - ds.startFrame)
    elseif ds.lastResultText ~= nil then
        dsValue = ds.lastResultText
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

            -- Block type is the most significant 4 bits of level data
            local blockType = xemu.rshift(sm.getLevelDatum(blockIndex), 12)
            local bts = sm.getBts(blockIndex)
            -- Draw the block outline depending on its block type.
            local f = outline[blockType] or standardOutline(colour_errorBlock)
            f(blockX, blockY, blockIndex, stackLimit)

            anygDrawRouteBlockMarker(blockX, blockY, blockType, bts, blockIndex, cameraX, cameraY, viewWidth, viewHeight)

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
