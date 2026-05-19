-- Script-declared settings panel (ui.*).
--
-- A script can expose settings the user tweaks from the app — no editing
-- the script. Declare controls once in on_init; read them any frame with
-- ui.get(id). Values auto-persist (per script) and restore on reload.
--
-- Controls show up under a "Script" tab that appears only when a script
-- declares some; loading this jumps straight to it.
--
-- Needs no SNES connection — load it standalone to play with the panel.

function on_init()
  ui.header("Box")
  ui.checkbox("show",  "Show box",   true)
  ui.slider("size",    "Size",       4, 64, 24)
  ui.slider("thick",   "Line width", 1, 6, 2)
  ui.color("box_col",  "Box color",  0xFF40FF40)
  ui.checkbox("fill",  "Fill it",    false)

  ui.header("Label")
  ui.text("caption",   "Caption",    "hello sni-lua")
  ui.select("corner",  "Anchor",     { "Top-left", "Top-right",
                                       "Bottom-left", "Bottom-right" }, 1)
  ui.color("text_col", "Text color", 0xFFFFFFFF)

  ui.header("Actions")
  ui.button("recenter", "Recenter box")
  ui.label("Click recenter to drop the box back to the middle.")
end

-- Box center, nudged by the recenter button.
local cx, cy = 128, 112

function on_frame()
  gfx.font("small")

  -- One-shot button: true exactly once per click.
  if ui.pressed("recenter") then
    cx, cy = gfx.width() / 2, gfx.height() / 2
  end

  if ui.get("show") then
    local s  = ui.get("size")
    local th = ui.get("thick")
    local fillc = ui.get("fill") and ui.get("box_col") or nil
    gfx.box(cx - s / 2, cy - s / 2, s, s,
            ui.get("box_col"), fillc, th)
  end

  -- Caption anchored to the chosen corner (1-based select index).
  local cap = ui.get("caption")
  local w, h = gfx.width(), gfx.height()
  local pad  = 6
  local pos  = ui.get("corner")
  local tx = (pos == 2 or pos == 4) and (w - pad - #cap * 4) or pad
  local ty = (pos == 3 or pos == 4) and (h - pad - 8) or pad
  gfx.text(tx, ty, cap, ui.get("text_col"))
end
