-- Drawing & animation reference. Self-contained (no SNES needed).
--
-- A labelled gallery of every gfx drawing primitive. Requests a 2x canvas
-- (512x448) purely for room to lay the cells out; each cell reads its own
-- local origin so the math stays simple.
--
-- Demonstrates:
--   * text with a background box / outline:  gfx.text(.., { bg=, outline= })
--   * lines & color ramps:                   gfx.line / gfx.gradient_line
--   * rectangles:                            gfx.box / gfx.round_rect
--   * gradient fills:                        gfx.gradient_rect (h / v / round)
--   * soft shadows on rect primitives:       opts.shadow
--   * circles, arcs & pie wedges:            gfx.circle / gfx.arc
--   * triangles & polylines:                 gfx.triangle / gfx.poly
--   * compound path unions (seamless fill):  gfx.begin_path / path_* /
--                                            gfx.fill_path / gfx.stroke_path
--   * smooth colour interpolation:           gfx.color_lerp
--   * easing & oscillators:                  anim.pulse / anim.ease / anim.saw
--   * a local coordinate origin:             gfx.push_origin / pop_origin

local WHITE  = 0xFFFFFFFF
local BLACK  = 0xFF000000
local CYAN   = 0xFF40D0FF
local PANEL  = 0xB0101018

-- Cell grid laid out on the 2x canvas. Each cell is a captioned box; the
-- demo for that cell is drawn in cell-local coords via push_origin.
local COLS, CELL_W, CELL_H, PAD = 4, 118, 96, 8

function on_init()
  gfx.scale(2)                              -- request 512x448 (app may override)
  ui.slider("hp", "Demo HP", 0, 100, 100)   -- drag to see the bar fade
  log.info("drawing example loaded: " .. gfx.width() .. "x" .. gfx.height())
end

-- Place cell `i` (0-based) and draw its caption; returns the cell's inner
-- drawing box size so each demo can lay itself out relative to (0, 0).
local function cell(i, caption)
  local col, row = i % COLS, math.floor(i / COLS)
  local x = PAD + col * (CELL_W + PAD)
  local y = 24 + row * (CELL_H + PAD)
  gfx.push_origin(x, y)
  gfx.round_rect(0, 0, CELL_W, CELL_H, 6, 0x30FFFFFF, 0x18000000, 1)
  gfx.text(4, 3, caption, WHITE, { outline = BLACK })
  return CELL_W, CELL_H
end

function on_frame()
  local t   = anim.saw(3)                   -- 0..1 sawtooth, ~3s period
  local p15 = anim.pulse(1.5)               -- 0..1 sine, 1.5 Hz

  gfx.text(8, 6, "gfx primitive gallery", WHITE, { bg = PANEL, outline = BLACK })

  -- 1. Text options: backing rect + per-glyph outline (no manual shadow).
  cell(0, "text bg/outline")
    gfx.text(10, 34, "HP 99", WHITE, { bg = PANEL, outline = BLACK })
    gfx.text(10, 54, "big", CYAN, 2)                 -- numeric arg = scale
    gfx.text(58, 70, "centre", WHITE,
             { align = "center", valign = "middle", outline = BLACK })
  gfx.pop_origin()

  -- 2. color_lerp health bar: smooth green->yellow->red, no thresholds.
  cell(1, "color_lerp bar")
    local hp = ui.get("hp") / 100
    local good = 0xFF40FF40
    local mid  = gfx.color_lerp(0xFFFF4040, 0xFFFFD040, math.min(hp * 2, 1))
    local col  = (hp > 0.5)
                 and gfx.color_lerp(0xFFFFD040, good, (hp - 0.5) * 2) or mid
    gfx.box(12, 40, 90, 10, WHITE)                   -- frame
    gfx.box(13, 41, 88 * hp, 8, col, col)            -- fill
    gfx.text(12, 60, ("%d%%"):format(hp * 100), WHITE, { outline = BLACK })
  gfx.pop_origin()

  -- 3. line vs gradient_line (a colour ramp along the segment).
  cell(2, "line / gradient")
    gfx.line(12, 38, 104, 38, WHITE, 1)
    gfx.line(12, 50, 104, 50, CYAN, 3)
    gfx.gradient_line(12, 68, 104, 68, 0xFF40FF40, 0xFFFF4040, 4)
    gfx.gradient_line(12, 82, 104, 82, 0x0040D0FF, 0xFF40D0FF, 4)
  gfx.pop_origin()

  -- 4. round_rect: native rounded rectangle, outline + fill.
  cell(3, "round_rect")
    gfx.round_rect(12, 34, 94, 24, 12, WHITE, 0x4018D0FF, 2)
    gfx.round_rect(12, 64, 94, 24, 6, CYAN)          -- outline only
  gfx.pop_origin()

  -- 5. gradient_rect: horizontal, vertical, and a rounded silhouette.
  cell(4, "gradient_rect")
    gfx.gradient_rect(12, 34, 94, 16, 0xFF10E0FF, 0xFF0044FF)
    gfx.gradient_rect(12, 54, 94, 16, 0xFFFF40FF, 0xFFFFD040,
                      { dir = "vertical" })
    gfx.gradient_rect(12, 74, 94, 16, 0xFF40FF40, 0xFF0066FF,
                      { radius = 8 })
  gfx.pop_origin()

  -- 6. opts.shadow: soft glow under box / round_rect / gradient_rect.
  cell(5, "shadow opts")
    gfx.box(16, 36, 28, 28, CYAN, 0x3040D0FF, 1,
            { shadow = { blur = 10, spread = 2, color = 0x6040D0FF } })
    gfx.round_rect(56, 36, 50, 28, 8, WHITE, 0x40FFFFFF, 1,
                   { shadow = true })                -- default glow
    gfx.gradient_rect(16, 70, 90, 16, 0xFFFFD040, 0xFFFF4040,
                      { radius = 8,
                        shadow = { dx = 0, dy = 3, blur = 8,
                                   color = 0x80000000 } })
  gfx.pop_origin()

  -- 7. circle: outline + a pulsing filled core (anim.pulse).
  cell(6, "circle + pulse")
    gfx.circle(58, 60, 26, CYAN, nil, 2)
    gfx.circle(58, 60, 8 + 8 * p15, 0xFFFF80FF, 0x60FF80FF)
  gfx.pop_origin()

  -- 8. arc: a sweeping radial timer + a static filled pie wedge.
  cell(7, "arc / pie")
    gfx.arc(36, 62, 20, -90, -90 + 360 * t, 0xFF40FF40, nil, 3)
    gfx.text(26, 86, ("%d%%"):format(t * 100), WHITE, { outline = BLACK })
    gfx.arc(86, 62, 20, 30, 150, 0xFFFFD040, 0x60FFD040, 1)  -- pie slice
  gfx.pop_origin()

  -- 9. triangle: outline + filled.
  cell(8, "triangle")
    gfx.triangle(20, 84, 52, 36, 84, 84, CYAN, nil, 2)
    gfx.triangle(60, 84, 84, 52, 104, 84, WHITE, 0x40FFFFFF)
  gfx.pop_origin()

  -- 10. poly: a closed filled diamond + an open zig-zag polyline.
  cell(9, "poly")
    gfx.poly({ {28,32}, {44,52}, {28,72}, {12,52} }, WHITE, 0x4040D0FF, 1)
    gfx.poly({ {56,72}, {68,40}, {80,72}, {92,40}, {104,72} },
             CYAN, nil, 2, false)            -- open polyline
  gfx.pop_origin()

  -- 11. Path builder: union of primitives -> one seamless concave fill,
  --     the canonical D-pad case (no overlapping-alpha seams).
  cell(10, "fill_path D-pad")
    local cx, cy, arm, w, r = 58, 60, 30, 11, 5
    gfx.begin_path()
    gfx.path_round_rect(cx - w, cy - arm, w * 2, arm * 2, r)   -- vertical arm
    gfx.path_round_rect(cx - arm, cy - w, arm * 2, w * 2, r)   -- horiz. arm
    gfx.fill_path(0x8000E5FF, 0xFF00E5FF, 2)                   -- fill+outline
  gfx.pop_origin()

  -- 12. stroke_path: the same union as an outline only, plus a mixed path
  --     (rect + circle) to show primitives compose.
  cell(11, "stroke_path")
    gfx.begin_path()
    gfx.path_rect(20, 40, 36, 36)
    gfx.path_circle(78, 58, 22)
    gfx.stroke_path(CYAN, 2)
  gfx.pop_origin()

  -- 13. anim.* sampler: eased slide + a blinking alert.
  cell(12, "anim easing")
    local sx = anim.lerp(12, 92, anim.ease(anim.saw(2), "inout_quad"))
    gfx.box(sx, 44, 8, 8, WHITE, WHITE)
    gfx.text(12, 58, "inout_quad", WHITE, { outline = BLACK })
    if anim.blink(0.5) then
      gfx.text(12, 74, "! alert", 0xFFFF4040, { outline = BLACK })
    end
  gfx.pop_origin()

  -- 14. push_origin nesting: a small widget drawn in local coords, then
  --     re-placed; the inner box wobbles via the shared oscillator.
  cell(13, "push_origin")
    gfx.push_origin(20, 36)
      gfx.round_rect(0, 0, 72, 48, 6, WHITE, 0x3040D0FF, 1)
      gfx.text(6, 4, "widget", WHITE, { outline = BLACK })
      gfx.box(6, 22, 60 * p15, 6, CYAN, CYAN)
    gfx.pop_origin()
  gfx.pop_origin()
end
