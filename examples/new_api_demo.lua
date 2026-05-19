-- New API tour: time / log / gfx (circle, triangle, text metrics,
-- push_origin) / snes.buttons / signed reads / on_unload / ui.exists.
--
-- Self-contained — load it standalone (no SNES needed). With a connected
-- SNES the controller box lights up; without one it shows "(no pad data)".

-- A controller watch. snes.buttons() decodes the standard 16-bit SNES pad
-- layout from whatever address holds it for your game. For Super Metroid
-- the held-buttons mirror is $7E:008B (WRAM offset 0x008B). Tier it
-- realtime so input isn't queued behind bulk reads.
local pad = snes.watch(0x008B, 2, "realtime")
snes.tier(pad, "realtime")

-- Signed reads also gained i8 / i32 (i16 already existed).
local speed = snes.watch(0x0B2E, 2, "high")   -- example signed velocity

local WHITE, GREEN, YELLOW, CYAN = 0xFFFFFFFF, 0xFF40FF40, 0xFFFFD040, 0xFF40D0FF

function on_init()
  ui.checkbox("show_pulse", "Show pulsing ring", true)
  ui.slider("ring_speed", "Pulse speed", 1, 10, 4)
  log.info("new_api_demo loaded")
  if ui.exists("show_pulse") then
    log.info("ui.exists confirms the panel is declared")
  end
end

-- Persist a launch counter on unload (auto-store would also save it, but
-- this shows the explicit teardown hook firing on reload/quit).
function on_unload()
  store.set("closed_at_frame", time.frame())
  log.warn("new_api_demo unloading at frame " .. time.frame())
end

function on_frame()
  -- time.* : monotonic clock, frame counter, per-frame delta.
  gfx.text(8, 8, ("t=%.1fs  frame=%d  dt=%.3f")
                 :format(time.now(), time.frame(), time.dt()), WHITE)

  -- Text metrics: right-align a caption without guessing glyph widths.
  local cap = "v2 API"
  gfx.text(gfx.width() - gfx.text_width(cap) - 8, 8, cap, CYAN)

  -- push_origin: draw a little widget in local coords, place it once.
  gfx.push_origin(16, 30)
    gfx.text(0, 0, "Controller", YELLOW)
    local b = snes.buttons(pad)
    if b then
      -- light a triangle for the d-pad, circles for face buttons
      local function dot(x, on) gfx.circle(x, 18, 4, WHITE,
                                           on and GREEN or nil, 1) end
      dot(0,  b.B); dot(12, b.Y); dot(24, b.A); dot(36, b.X)
      gfx.text(0, 28, ("raw=0x%04X"):format(b.raw), WHITE)
    else
      gfx.text(0, 16, "(no pad data — connect a SNES)", YELLOW)
    end
  gfx.pop_origin()

  -- A signed read + a pulsing ring whose radius is time-driven.
  local v = snes.i16(speed)
  if v then gfx.text(8, 70, ("i16 speed = %d"):format(v), WHITE) end

  if ui.get("show_pulse") then
    local sp = ui.get("ring_speed")
    local r  = 10 + 6 * (1 + math.sin(time.now() * sp))
    gfx.circle(gfx.width() / 2, gfx.height() / 2, r, GREEN, nil, 2)
    -- a direction arrow as a filled triangle
    gfx.triangle(120,150, 140,160, 120,170, YELLOW, 0x60FFD040, 1)
  end
end
