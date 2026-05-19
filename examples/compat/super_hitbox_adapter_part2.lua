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
