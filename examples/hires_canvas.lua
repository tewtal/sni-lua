-- Higher-resolution canvas.
--
-- Requests a 2x canvas (512x448) so the overlay can draw sub-SNES-pixel
-- detail: a fine grid and crisp text that would be impossible at native
-- 256x224. The capture/game still fills the same on-screen area; only the
-- drawing precision changes.
--
-- Try switching the app's Overlay > Canvas dropdown:
--   "Script-controlled" -> honors the gfx.scale(2) below
--   "Native 256x224"    -> app overrides; gfx.width() reports 256
-- Either way the layout stays correct because we read gfx.width()/height()
-- instead of hardcoding 256/224.

function on_init()
  gfx.scale(2)                       -- request 512x448 (app may override)
  print("hires_canvas: " .. gfx.width() .. "x" .. gfx.height())
end

local WHITE = 0xFFFFFFFF
local GRID  = 0x30FFFFFF             -- faint
local AXIS  = 0xFF40D0FF

function on_frame()
  local w, h = gfx.width(), gfx.height()

  -- Fine grid every 16 canvas px. At 2x that's every 8 SNES px — twice as
  -- dense as anything you could align at native res.
  local step = 16
  local x = 0
  while x <= w do
    gfx.line(x, 0, x, h, GRID, 1.0)
    x = x + step
  end
  local y = 0
  while y <= h do
    gfx.line(0, y, w, y, GRID, 1.0)
    y = y + step
  end

  -- Center crosshair using the active canvas size (not hardcoded).
  local cx, cy = w / 2, h / 2
  gfx.line(cx - 12, cy, cx + 12, cy, AXIS, 1.0)
  gfx.line(cx, cy - 12, cx, cy + 12, AXIS, 1.0)

  gfx.font("small")
  gfx.text(2, 2, ("canvas %dx%d  (read via gfx.width/height)")
                  :format(w, h), WHITE)
  gfx.text(2, 11, "fine grid = sub-SNES-pixel detail at 2x", WHITE)
end
