-- Toast popup notifications. Self-contained (no SNES needed).
--
-- A tiny reusable notification system: queued messages that slide in from
-- the top-right, hold, then ease out. Demonstrates anim.* easing/timing,
-- gfx.text bg/outline, and the mouse.* API (click the canvas, or use the
-- Demo button, to push a toast; click a toast to dismiss it early).

local BLACK = 0xFF000000

-- Colours as {r,g,b} plus a peak alpha; the script builds the packed ARGB
-- at draw time with gfx.argb(a, r,g,b), scaling `a` by the fade so there's
-- no bitwise alpha masking (LuaJIT is Lua 5.1 — no `&`).
local KINDS = {
  info  = { bar = { 0x4D, 0xD8, 0xFF }, bg = { 0x10, 0x18, 0x26 } },
  ok    = { bar = { 0x40, 0xFF, 0x6A }, bg = { 0x0E, 0x20, 0x14 } },
  warn  = { bar = { 0xFF, 0xC2, 0x4D }, bg = { 0x24, 0x1B, 0x07 } },
  error = { bar = { 0xFF, 0x54, 0x66 }, bg = { 0x26, 0x0C, 0x10 } },
}
-- Ordered list: drives the ui.select options AND maps its 1-based index
-- back to a KINDS key (ui.get on a select returns the index, not a string).
local KIND_NAMES = { "info", "ok", "warn", "error" }
local BG_ALPHA = 0xE0     -- peak opacity of the toast body

local W, H        = 150, 22     -- toast size (canvas px)
local MARGIN      = 6
local GAP         = 4
local SLIDE       = 0.22        -- in/out animation seconds
local HOLD        = 3.0         -- visible seconds before auto-dismiss

local toasts = {}               -- active toasts, newest last
local seq    = 0

-- Public-ish helper a real script would expose; here we just call it
-- locally. `kind` keys into KINDS (default "info").
local function notify(text, kind)
  seq = seq + 1
  local resolved = KINDS[kind] and kind or "info"
  toasts[#toasts + 1] = {
    id    = seq,
    text  = tostring(text),
    kind  = resolved,
    born  = time.now(),
    dying = nil,                -- set to a timestamp when dismissed
  }
  log.info(("toast [%s] %s"):format(resolved, text))
end

function on_init()
  ui.button("demo", "Show a toast")
  ui.select("kind", "Kind", KIND_NAMES, 1)
  notify("Click the canvas for a toast", "info")
end

-- ui.get on a select gives a 1-based index; map it to a KINDS key.
local function selected_kind()
  return KIND_NAMES[ui.get("kind")] or "info"
end

-- 0 (off-screen) .. 1 (fully in) .. 0 (gone). Drives slide + fade together.
local function life(t, now)
  local age = now - t.born
  if t.dying then
    return 1 - anim.clamp((now - t.dying) / SLIDE, 0, 1)
  end
  if age < SLIDE then
    return anim.ease(age / SLIDE, "out_cubic")     -- slide/fade in
  end
  return 1                                          -- holding
end

local function draw_toast(t, slot, now)
  local p  = life(t, now)
  if p <= 0 then return end
  local k  = KINDS[t.kind]

  -- Eased horizontal slide: fully in sits at MARGIN from the right edge;
  -- p=0 parks it one width off-screen.
  local rest_x = gfx.width() - W - MARGIN
  local x = anim.lerp(gfx.width() + 4, rest_x, p)
  local y = MARGIN + slot * (H + GAP)

  -- The fade is just the alpha: scale each colour's peak alpha by p and
  -- pack it with gfx.argb. No bitwise ops needed (LuaJIT is Lua 5.1).
  local function fade(rgb, peak)
    return gfx.argb(math.floor(p * peak), rgb[1], rgb[2], rgb[3])
  end
  gfx.box(x, y, W, H, 0x00000000, fade(k.bg, BG_ALPHA))
  gfx.box(x, y, 3, H, 0x00000000, fade(k.bar, 0xFF))
  gfx.text(x + 8, y + 7, t.text,
           gfx.argb(math.floor(p * 255), 0xFF, 0xFF, 0xFF),
           { outline = (p > 0.15) and BLACK or nil })

  -- Hovering highlights; a click here dismisses early. Returns true if
  -- this toast ate the click, so the caller doesn't also spawn one.
  local mx, my = mouse.pos()
  if mx and mx >= x and mx <= x + W and my >= y and my <= y + H then
    gfx.box(x, y, W, H, gfx.argb(math.floor(p * 0x40), 255, 255, 255))
    if mouse.pressed("left") and not t.dying then
      t.dying = now
      return true
    end
  end
  return false
end

function on_frame()
  gfx.font("small")
  local now = time.now()

  -- The Demo button always uses the selected kind.
  if ui.pressed("demo") then
    notify("Hello from sni-lua", selected_kind())
  end

  -- Age out: auto-dismiss after HOLD, drop fully-faded ones.
  for _, t in ipairs(toasts) do
    if not t.dying and (now - t.born) > (SLIDE + HOLD) then
      t.dying = now
    end
  end
  for i = #toasts, 1, -1 do
    local t = toasts[i]
    if t.dying and (now - t.dying) > SLIDE then
      table.remove(toasts, i)
    end
  end

  -- Newest on top: draw last-added in slot 0. A click on a toast
  -- dismisses it and "consumes" the click so it doesn't also spawn one.
  local slot, click_consumed = 0, false
  for i = #toasts, 1, -1 do
    if draw_toast(toasts[i], slot, now) then
      click_consumed = true
    end
    slot = slot + 1
  end

  -- A left-click on empty canvas spawns a toast. mouse.pos() is nil when
  -- the pointer is outside the canvas (app chrome / another window), so a
  -- click there must not count.
  local mx, my = mouse.pos()
  if mx and mouse.pressed("left") and not click_consumed then
    notify(("Clicked at %d, %d"):format(mx, my), "ok")
  end

  gfx.text(MARGIN, gfx.height() - 10,
           "click canvas or use the Script tab's Demo button",
           0xFF8290A8, { outline = BLACK })
end
