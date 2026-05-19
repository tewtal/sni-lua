-- Drawing + animation tour: text bg/outline, gfx.poly, gfx.arc,
-- gfx.color_lerp, and the anim.* helpers. Self-contained (no SNES).
--
-- These remove the patterns every older example hand-rolled:
--   * shadowed/boxed text  -> gfx.text(..., { bg=, outline= })
--   * many gfx.line calls   -> gfx.poly
--   * partial rings/timers  -> gfx.arc
--   * stepped color tiers    -> gfx.color_lerp
--   * math.sin(time.now()*k) -> anim.pulse / anim.ease / anim.saw

local WHITE  = 0xFFFFFFFF
local BLACK  = 0xFF000000
local PANEL  = 0xB0101018

function on_init()
  ui.slider("hp", "Demo HP", 0, 100, 100)   -- drag to see the bar fade
  log.info("draw_anim_demo loaded")
end

function on_frame()
  -- 1. Readable HUD text with no manual shadow/box: bg + outline options.
  gfx.text(8, 8, "Drawing + anim demo", WHITE,
           { bg = PANEL, outline = BLACK })

  -- 2. A health bar that smoothly fades green -> yellow -> red via
  --    color_lerp, instead of stepped if/else thresholds.
  local hp = ui.get("hp") / 100
  local good, bad = 0xFF40FF40, 0xFFFF4040
  local mid = gfx.color_lerp(bad, 0xFFFFD040, math.min(hp * 2, 1))
  local col = (hp > 0.5) and gfx.color_lerp(0xFFFFD040, good, (hp - 0.5) * 2)
                          or mid
  gfx.box(8, 24, 80, 8, WHITE)               -- frame
  gfx.box(9, 25, 78 * hp, 6, col, col)       -- fill

  -- 3. gfx.poly: a diamond + an open zig-zag, one call each (was N lines).
  gfx.push_origin(120, 26)
    gfx.poly({ {8,0}, {16,8}, {8,16}, {0,8} }, WHITE, 0x4040D0FF, 1)
    gfx.poly({ {24,16}, {32,2}, {40,16}, {48,2} }, 0xFF40D0FF, nil, 1, false)
  gfx.pop_origin()

  -- 4. gfx.arc: a radial timer sweeping once every 3s (anim.saw drives it),
  --    plus a static pie wedge.
  local t = anim.saw(3)                       -- 0..1 sawtooth
  gfx.arc(40, 80, 16, -90, -90 + 360 * t, 0xFF40FF40, nil, 2)
  gfx.text(28, 100, ("%d%%"):format(t * 100), WHITE, { outline = BLACK })
  gfx.arc(100, 80, 16, 30, 150, 0xFFFFD040, 0x60FFD040, 1)  -- filled wedge

  -- 5. anim.* oscillators: a pulsing ring + an eased slide.
  local r = 6 + 5 * anim.pulse(1.5)           -- 0..1 sine -> radius wobble
  gfx.circle(170, 80, r, 0xFFFF80FF, nil, 2)

  local x = anim.lerp(8, 140, anim.ease(anim.saw(2), "inout_quad"))
  gfx.box(x, 120, 6, 6, WHITE, WHITE)
  gfx.text(8, 132, "eased slide (inout_quad)", WHITE, { bg = PANEL })
end
