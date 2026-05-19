-- Animated SNES input viewer
--
-- Watches Super Metroid's held-controller mirror at WRAM $008B and renders a
-- polished controller overlay with button glow, press ripples, and recent
-- input history.
--
-- For another game, change PAD_OFFSET to that game's 2-byte held pad mirror.
-- If no SNES data is available, "Demo without SNES" animates fake input so the
-- layout can be previewed standalone.

local PAD_OFFSET = 0x008B
local pad = snes.watch(PAD_OFFSET, 2, "realtime")
snes.tier(pad, "realtime")

local BASE_W, BASE_H = 256, 224
gfx.canvas(BASE_W, BASE_H)
gfx.text_sizing("game", 1.0)

local WHITE  = 0xFFFFFFFF
local BLACK  = 0xFF000000
local PANEL  = 0xC00B101C
local PANEL2 = 0x88152030
local EDGE   = 0xFF3E526D
local MUTED  = 0xFF8290A8
local DIM    = 0xFF445066

local BUTTON_ORDER = {
  "L", "R", "Up", "Down", "Left", "Right",
  "Select", "Start", "Y", "B", "X", "A",
}

local HISTORY_ORDER = {
  "L", "R", "Up", "Down", "Left", "Right",
  "Select", "Start", "Y", "B", "X", "A",
}

local SHORT = {
  Up = "Up", Down = "Down", Left = "Left", Right = "Right",
  Select = "Sel", Start = "Start",
}

local BUTTON_COLOR = {
  A = 0xFFFF4D6D, B = 0xFFFFD166, X = 0xFF5EEAD4, Y = 0xFFA78BFA,
  L = 0xFF79FF9E, R = 0xFF79FF9E,
  Up = 0xFF4DD8FF, Down = 0xFF4DD8FF,
  Left = 0xFF4DD8FF, Right = 0xFF4DD8FF,
  Select = 0xFFFFF1A8, Start = 0xFFFFF1A8,
}

local FULL_LAYOUT = {
  L      = { x =  64, y =  55, w =  76, h = 14, kind = "pill", label = "L" },
  R      = { x = 192, y =  55, w =  76, h = 14, kind = "pill", label = "R" },
  Up     = { x =  63, y =  95, w =  17, h = 17, kind = "dpad" },
  Down   = { x =  63, y = 137, w =  17, h = 17, kind = "dpad" },
  Left   = { x =  42, y = 116, w =  17, h = 17, kind = "dpad" },
  Right  = { x =  84, y = 116, w =  17, h = 17, kind = "dpad" },
  Select = { x = 105, y = 145, w =  36, h = 13, kind = "pill", label = "SEL" },
  Start  = { x = 150, y = 145, w =  38, h = 13, kind = "pill", label = "START" },
  Y      = { x = 174, y = 116, r =  11, kind = "round", label = "Y" },
  B      = { x = 194, y = 137, r =  11, kind = "round", label = "B" },
  X      = { x = 194, y =  95, r =  11, kind = "round", label = "X" },
  A      = { x = 215, y = 116, r =  11, kind = "round", label = "A" },
}

local COMPACT_LAYOUT = {
  L      = { x =  15, y =  18, w =  14, h =  9, kind = "mini_pill", label = "L" },
  R      = { x =  32, y =  18, w =  14, h =  9, kind = "mini_pill", label = "R" },
  Up     = { x =  53, y =  12, w =   9, h =  9, kind = "mini_arrow" },
  Down   = { x =  53, y =  24, w =   9, h =  9, kind = "mini_arrow" },
  Left   = { x =  47, y =  18, w =   9, h =  9, kind = "mini_arrow" },
  Right  = { x =  59, y =  18, w =   9, h =  9, kind = "mini_arrow" },
  Select = { x =  82, y =  18, w =  22, h =  9, kind = "mini_pill", label = "Sel" },
  Start  = { x = 109, y =  18, w =  22, h =  9, kind = "mini_pill", label = "St" },
  Y      = { x = 134, y =  18, r =   5, kind = "mini_round", label = "Y" },
  B      = { x = 146, y =  24, r =   5, kind = "mini_round", label = "B" },
  X      = { x = 146, y =  12, r =   5, kind = "mini_round", label = "X" },
  A      = { x = 158, y =  18, r =   5, kind = "mini_round", label = "A" },
}

local DEMO_STEPS = {
  { 0.20, { "Right" } },
  { 0.20, { "Right", "B" } },
  { 0.18, { "Right", "B", "Y" } },
  { 0.16, {} },
  { 0.20, { "Left" } },
  { 0.20, { "Left", "Y" } },
  { 0.18, { "Down", "B" } },
  { 0.18, { "Up", "X" } },
  { 0.22, { "Start" } },
  { 0.18, {} },
  { 0.22, { "L" } },
  { 0.22, { "R" } },
  { 0.26, { "L", "R", "A" } },
  { 0.22, {} },
}

local demo_period = 0
for i = 1, #DEMO_STEPS do
  demo_period = demo_period + DEMO_STEPS[i][1]
end

local button_state = {}
for i = 1, #BUTTON_ORDER do
  button_state[BUTTON_ORDER[i]] = { down = false, heat = 0, pulse = 0, hold = 0 }
end

local bursts = {}
local history = {}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function approach(v, target, step)
  if v < target then
    return math.min(target, v + step)
  end
  return math.max(target, v - step)
end

local function setting(id, fallback)
  local v = ui.get(id)
  if v == nil then return fallback end
  return v
end

local function translucent(color, amount)
  return gfx.color_lerp(0x00000000, color, clamp(amount, 0, 1))
end

local function label_for(name)
  return SHORT[name] or name
end

local function make_empty_input()
  local b = {}
  for i = 1, #BUTTON_ORDER do
    b[BUTTON_ORDER[i]] = false
  end
  return b
end

local function demo_input()
  local t = time.now() % demo_period
  local n = 1
  while t > DEMO_STEPS[n][1] do
    t = t - DEMO_STEPS[n][1]
    n = n + 1
  end

  local b = make_empty_input()
  local names = DEMO_STEPS[n][2]
  for i = 1, #names do
    local name = names[i]
    b[name] = true
  end
  return b
end

local function history_label(input)
  local parts = {}
  for i = 1, #HISTORY_ORDER do
    local name = HISTORY_ORDER[i]
    if input[name] then
      parts[#parts + 1] = label_for(name)
    end
  end
  if #parts == 0 then
    return "release"
  end
  return table.concat(parts, "+")
end

local function push_history(input)
  table.insert(history, 1, {
    label = history_label(input),
    age = 0,
  })
  while #history > 8 do
    table.remove(history)
  end
end

local function read_input()
  local b = snes.buttons(pad)
  if b then
    return b
  end
  if setting("demo", true) then
    return demo_input()
  end
  return nil
end

local function update_state(input)
  local dt = time.dt()
  if dt <= 0 or dt > 0.1 then
    dt = 1 / 60
  end

  for i = #bursts, 1, -1 do
    bursts[i].age = bursts[i].age + dt
    if bursts[i].age > 0.70 then
      table.remove(bursts, i)
    end
  end

  for i = #history, 1, -1 do
    history[i].age = history[i].age + dt
    if history[i].age > 6.0 then
      table.remove(history, i)
    end
  end

  local any_press = false
  for i = 1, #BUTTON_ORDER do
    local name = BUTTON_ORDER[i]
    local st = button_state[name]
    local down = input and input[name] == true

    if down and not st.down then
      any_press = true
      st.pulse = 1
      bursts[#bursts + 1] = { button = name, age = 0 }
    end

    st.down = down
    st.heat = approach(st.heat, down and 1 or 0, dt * (down and 10 or 5))
    st.pulse = math.max(0, st.pulse - dt * 2.8)
    st.hold = down and (st.hold + dt) or 0
  end

  if input and any_press then
    push_history(input)
  end
end

local function text_center(x, y, str, color, scale, opts)
  local s = scale or 1
  local o = opts or {}
  o.scale = s
  if not o.outline then
    o.outline = BLACK
  end
  gfx.text(x - gfx.text_width(str) * s / 2,
           y - gfx.text_height(str) * s / 2,
           str, color, o)
end

local function draw_pill(cx, cy, w, h, edge, fill, thickness)
  local r = h / 2
  local lx = cx - w / 2 + r
  local rx = cx + w / 2 - r
  local top = cy - h / 2
  local bot = cy + h / 2
  local th = thickness or 1

  if fill then
    gfx.box(lx, top, math.max(0, rx - lx), h, 0x00000000, fill)
    gfx.circle(lx, cy, r, 0x00000000, fill)
    gfx.circle(rx, cy, r, 0x00000000, fill)
  end

  if edge and edge ~= 0x00000000 then
    gfx.line(lx, top, rx, top, edge, th)
    gfx.line(lx, bot, rx, bot, edge, th)
    gfx.arc(lx, cy, r, 90, 270, edge, nil, th)
    gfx.arc(rx, cy, r, -90, 90, edge, nil, th)
  end
end

local function draw_dpad_arrow(name, x, y, size, color)
  local s = size or 5
  if name == "Up" then
    gfx.triangle(x, y - s, x - s, y + s * 0.65, x + s, y + s * 0.65,
                 color, color)
  elseif name == "Down" then
    gfx.triangle(x, y + s, x - s, y - s * 0.65, x + s, y - s * 0.65,
                 color, color)
  elseif name == "Left" then
    gfx.triangle(x - s, y, x + s * 0.65, y - s, x + s * 0.65, y + s,
                 color, color)
  elseif name == "Right" then
    gfx.triangle(x + s, y, x - s * 0.65, y - s, x - s * 0.65, y + s,
                 color, color)
  end
end

local function draw_background()
  if not setting("backdrop", true) then
    return
  end

  gfx.box(0, 0, gfx.width(), gfx.height(), 0x00000000, 0x3C060A14)
end

local function draw_shell()
  local th = 1.4
  gfx.circle(61, 120, 57, EDGE, PANEL, th)
  gfx.circle(195, 120, 57, EDGE, PANEL, th)
  gfx.box(61, 63, 134, 114, EDGE, PANEL, th)
  gfx.box(35, 79, 186, 82, 0x00000000, PANEL2, 1)
end

local function draw_button(name, def, accent)
  local st = button_state[name]
  local base = BUTTON_COLOR[name] or accent
  local heat = st.heat
  local pulse = st.pulse
  local glow = setting("glow", 75) / 100

  local edge = gfx.color_lerp(EDGE, base, heat)
  local fill = gfx.color_lerp(0x48203042, base, 0.45 * heat)
  local label = def.label or label_for(name)

  if glow > 0 and heat > 0.02 then
    local g = heat * glow
    if def.kind == "round" then
      gfx.circle(def.x, def.y, def.r + 8 * g, 0x00000000, translucent(base, 0.14 * g))
      gfx.circle(def.x, def.y, def.r + 4 * g, 0x00000000, translucent(base, 0.20 * g))
    else
      draw_pill(def.x, def.y, def.w + 10 * g, def.h + 8 * g,
                0x00000000, translucent(base, 0.12 * g), 1)
    end
  end

  if def.kind == "round" then
    gfx.circle(def.x, def.y, def.r, edge, fill, 2)
    if pulse > 0 then
      gfx.arc(def.x, def.y, def.r + 3 + 8 * (1 - pulse), -90, 270,
              translucent(base, pulse), nil, 2)
    end
    gfx.font("normal")
    text_center(def.x, def.y + 0.5, label, heat > 0.5 and WHITE or MUTED, 1)
  elseif def.kind == "dpad" then
    gfx.box(def.x - def.w / 2, def.y - def.h / 2, def.w, def.h,
            edge, fill, 1.5)
    if pulse > 0 then
      gfx.box(def.x - def.w / 2 - 2 - 4 * (1 - pulse),
              def.y - def.h / 2 - 2 - 4 * (1 - pulse),
              def.w + 4 + 8 * (1 - pulse),
              def.h + 4 + 8 * (1 - pulse),
              translucent(base, pulse), nil, 1)
    end
    draw_dpad_arrow(name, def.x, def.y, def.w * 0.34,
                    heat > 0.5 and WHITE or MUTED)
  else
    draw_pill(def.x, def.y, def.w, def.h, edge, fill, 1.5)
    if pulse > 0 then
      draw_pill(def.x, def.y, def.w + 7 * (1 - pulse), def.h + 7 * (1 - pulse),
                translucent(base, pulse), nil, 1)
    end
    gfx.font("small")
    text_center(def.x, def.y, label, heat > 0.5 and WHITE or MUTED, 1)
  end
end

local function draw_compact_button(name, def)
  local st = button_state[name]
  local base = BUTTON_COLOR[name] or WHITE
  local heat = st.heat
  local pulse = st.pulse
  local idle = gfx.color_lerp(DIM, base, 0.35)
  local edge = gfx.color_lerp(idle, base, heat)
  local fill = gfx.color_lerp(0x60203042, base, 0.70 * heat)
  local text = heat > 0.45 and WHITE or gfx.color_lerp(MUTED, base, 0.35)

  if def.kind == "mini_arrow" then
    if heat > 0.03 then
      gfx.circle(def.x, def.y, 6 + 3 * heat, 0x00000000,
                 translucent(base, 0.18 * heat))
    end
    draw_dpad_arrow(name, def.x, def.y, 4.1, edge)
    if pulse > 0 then
      gfx.circle(def.x, def.y, 7 + 5 * (1 - pulse),
                 translucent(base, pulse), nil, 1)
    end
  elseif def.kind == "mini_round" then
    if heat > 0.03 then
      gfx.circle(def.x, def.y, def.r + 3 * heat, 0x00000000,
                 translucent(base, 0.18 * heat))
    end
    gfx.circle(def.x, def.y, def.r, edge, fill, 1.2)
    if pulse > 0 then
      gfx.circle(def.x, def.y, def.r + 2 + 4 * (1 - pulse),
                 translucent(base, pulse), nil, 1)
    end
    gfx.font("small")
    text_center(def.x, def.y + 0.5, def.label, text, 1)
  else
    draw_pill(def.x, def.y, def.w, def.h, edge, fill, 1)
    if pulse > 0 then
      draw_pill(def.x, def.y, def.w + 4 * (1 - pulse),
                def.h + 4 * (1 - pulse), translucent(base, pulse), nil, 1)
    end
    gfx.font("small")
    text_center(def.x, def.y + 0.5, def.label, text, 1)
  end
end

local function draw_bursts(layout)
  if not setting("ripples", true) then
    return
  end

  for i = 1, #bursts do
    local b = bursts[i]
    local def = layout[b.button]
    if def then
      local st = 1 - b.age / 0.70
      local col = translucent(BUTTON_COLOR[b.button] or 0xFFFFFFFF, st)
      local r = (def.r or math.max(def.w or 10, def.h or 10) / 2) + 6 + 24 * b.age
      gfx.circle(def.x, def.y, r, col, nil, 1.5)
    end
  end
end

local function draw_history(accent, y, x, max_w)
  if not setting("history", true) then
    return
  end

  gfx.font("small")
  x = x or 9
  y = y or 198
  local right = x + (max_w or (BASE_W - x - 8))
  for i = 1, #history do
    local item = history[i]
    local fade = clamp(1 - item.age / 6.0, 0, 1)
    local label = item.label
    local w = gfx.text_width(label) + 8
    if x + w > right then
      break
    end
    local fill = translucent(accent, 0.16 * fade)
    local edge = translucent(accent, 0.55 * fade)
    draw_pill(x + w / 2, y, w, 12, edge, fill, 1)
    gfx.text(x + 4, y - 4, label, gfx.color_lerp(DIM, WHITE, fade),
             { outline = BLACK })
    x = x + w + 4
  end
end

local function draw_full(accent)
  draw_shell()
  draw_bursts(FULL_LAYOUT)

  -- D-pad hub.
  gfx.box(52, 106, 22, 22, 0x00000000, 0x60203042)
  gfx.box(53, 107, 20, 20, EDGE, 0x40152030, 1)

  for i = 1, #BUTTON_ORDER do
    local name = BUTTON_ORDER[i]
    local def = FULL_LAYOUT[name]
    if def then
      draw_button(name, def, accent)
    end
  end

  draw_history(accent, 198)
end

local function draw_compact(accent)
  draw_pill(84, 18, 164, 27, EDGE, 0xB0080B12, 1)
  gfx.line(38, 8, 38, 28, 0x583E526D, 1)
  gfx.line(68, 8, 68, 28, 0x583E526D, 1)
  gfx.line(121, 8, 121, 28, 0x583E526D, 1)
  draw_bursts(COMPACT_LAYOUT)

  for i = 1, #BUTTON_ORDER do
    local name = BUTTON_ORDER[i]
    local def = COMPACT_LAYOUT[name]
    if def then
      draw_compact_button(name, def)
    end
  end

  draw_history(accent, 38, 6, 244)
end

function on_init()
  ui.header("Input")
  ui.checkbox("demo", "Demo without SNES", true)
  ui.select("layout", "Layout", { "Controller", "Compact" }, 1)

  ui.header("Visuals")
  ui.checkbox("backdrop", "Dim backdrop", true)
  ui.checkbox("ripples", "Press ripples", true)
  ui.checkbox("history", "Input history", true)
  ui.slider("glow", "Glow", 0, 100, 75)
  ui.color("accent", "Accent", 0xFF4DD8FF)

  ui.header("Actions")
  ui.button("clear_history", "Clear history")

  log.info("animated_input_viewer loaded; watching held pad mirror WRAM $008B")
end

function on_frame()
  gfx.canvas(BASE_W, BASE_H)

  if ui.pressed("clear_history") then
    history = {}
  end

  local input = read_input()
  update_state(input)

  local accent = setting("accent", 0xFF4DD8FF)

  if setting("layout", 1) == 2 then
    draw_compact(accent)
  else
    draw_background()
    draw_full(accent)
  end
end
