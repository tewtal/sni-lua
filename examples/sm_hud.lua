-- Super Metroid HUD + Samus hitbox overlay
--
-- Demonstrates the unified async-aware API:
--   * snes.watch(offset, size, priority) registers a WRAM watch with the
--     poll engine ONCE. It does not read anything now.
--   * snes.u16(handle) reads the latest CACHED snapshot every frame -- a
--     lock-free load, never an SNI round trip. The poll engine batches all
--     watches into one MultiRead/cycle behind the scenes.
--   * gfx.* pushes into the retained draw list the renderer consumes.
--
-- Priority guidance:
--   "high"   -> refreshed every poll cycle  (fast-moving: position)
--   "normal" -> every ~3 cycles             (health, ammo)
--   "low"    -> every ~12 cycles            (rarely-changing room data)

-- WRAM offsets (FxPakPro addr = 0xF50000 + offset; the helper does this).
local samus_x  = snes.watch(0x0AF6, 2, "high")   -- X position (pixels)
local samus_y  = snes.watch(0x0AFA, 2, "high")   -- Y position (pixels)
local x_radius = snes.watch(0x0AFE, 2, "high")   -- hitbox X radius
local y_radius = snes.watch(0x0B00, 2, "high")   -- hitbox Y radius
local health   = snes.watch(0x09C2, 2, "normal") -- current energy
local max_hp   = snes.watch(0x09C4, 2, "low")    -- max energy
local missiles = snes.watch(0x09C6, 2, "normal") -- current missiles
local room_id  = snes.watch(0x079B, 2, "low")    -- room pointer

local WHITE  = 0xFFFFFFFF
local GREEN  = 0xFF40FF40
local YELLOW = 0xFFFFD040
local RED    = 0xFFFF4040
local CYAN   = 0xFF40D0FF
local SHADOW = 0xC0000000

-- Tiny helper: text with a 1px shadow so it stays readable over any capture.
local function label(x, y, str, color)
  gfx.text(x + 1, y + 1, str, SHADOW)
  gfx.text(x, y, str, color or WHITE)
end

function on_init()
  print("sm_hud.lua loaded -- move Samus to see the hitbox track")
end

function on_frame()
  -- Guard the first few frames: watches are nil until the first poll
  -- cycle has populated the snapshot.
  local hp  = snes.u16(health)
  local mhp = snes.u16(max_hp)
  local mis = snes.u16(missiles)
  if hp == nil then
    label(8, 8, "waiting for first poll...", YELLOW)
    return
  end

  -- HUD text block (SNES pixel coords; renderer scales to the viewport).
  local hp_color = (hp <= 30) and RED or (hp <= 90 and YELLOW or GREEN)
  label(8, 8,  ("Energy %d / %d"):format(hp, mhp or 99), hp_color)
  label(8, 18, ("Missiles %d"):format(mis or 0), CYAN)
  label(8, 28, ("Room  $%04X"):format(snes.u16(room_id) or 0), WHITE)

  -- Staleness indicator: room_id is "low" priority so it lags a bit.
  -- snes.age() reports poll cycles since last refresh.
  local age = snes.age(room_id)
  if age and age > 24 then
    label(8, 38, ("room data stale (%d cycles)"):format(age), YELLOW)
  end

  -- Samus hitbox. SM stores center + radii; draw the box from those.
  local sx, sy = snes.u16(samus_x), snes.u16(samus_y)
  local rx, ry = snes.u16(x_radius), snes.u16(y_radius)
  if sx and sy and rx and ry and rx > 0 and ry > 0 then
    -- Position is in level coords; for a fixed-camera demo this still shows
    -- the box tracking. (Camera-relative mapping is a later refinement.)
    local screen_x = sx % 256
    local screen_y = sy % 224
    gfx.box(screen_x - rx, screen_y - ry, rx * 2, ry * 2,
            GREEN, 0x2000FF00, 1.0)            -- outline + faint fill
    gfx.pixel(screen_x, screen_y, RED)         -- center point
  end
end
