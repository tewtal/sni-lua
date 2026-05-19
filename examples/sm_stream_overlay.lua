-- Super Metroid stream overlay concept
--
-- Designed for the app's Streaming output mode: capture the detached output
-- window in OBS and chroma-key the background. This script draws a compact
-- viewer-facing telemetry layout from live cached SNI data.
--
-- What this example tracks now:
--   * current room time and recent room splits
--   * session-best room times while the script is loaded
--   * boss encounter timers and kill history
--   * boss health, damage pace, and generic AI-state "RNG proxy" stats
--   * resource bars and cache staleness warnings
--
-- Notes:
--   * Room/boss history is session-only here to keep the example focused.
--     To persist personal-best room times across runs, use the `store.*`
--     API (see examples/store_http_demo.lua) — e.g. store.get/set keyed by
--     room id, loaded in on_init and written when a split improves.
--   * sni-lua reads cached SNES/FxPak memory; APU/ARAM (true SM music RNG)
--     is not exposed, so this script uses boss AI variables as a practical
--     on-stream RNG proxy.
--   * Add more boss enemy IDs below as they are verified for your route or
--     ROM hack. Unknown boss rooms still fall back to the highest-health
--     active enemy while $7E179C says a boss is active.

local FPS = 60
local MAX_ENEMY_SLOTS = 16
local ROOM_HISTORY_LIMIT = 8
local BOSS_HISTORY_LIMIT = 5

local COLOR = {
  panel       = 0xC0101418,
  panel2      = 0xD0182028,
  border      = 0xFF405060,
  text        = 0xFFE8F0F8,
  dim         = 0xFF90A0A8,
  shadow      = 0xB0000000,
  cyan        = 0xFF40D8FF,
  green       = 0xFF50F080,
  yellow      = 0xFFFFD050,
  orange      = 0xFFFF9040,
  red         = 0xFFFF5050,
  magenta     = 0xFFFF58B8,
  blue        = 0xFF70A0FF,
  bar_bg      = 0x80405058,
}

-- Verified in the bundled hitbox script. Extend this table as you verify
-- more fight actors; the generic boss-number fallback still works without it.
local BOSS_IDS = {
  [0xE2BF] = "Kraid",
  [0xEC7F] = "Mother Brain",
}

local W = {
  frame_lo    = snes.watch(0x05B8, 2, "realtime"),
  frame_hi    = snes.watch(0x05BA, 2, "realtime"),
  game_state  = snes.watch(0x0998, 2, "realtime"),
  room_ptr    = snes.watch(0x079B, 2, "high"),
  room_w      = snes.watch(0x07A5, 2, "low"),
  room_h      = snes.watch(0x07A7, 2, "low"),
  boss_number = snes.watch(0x179C, 2, "high"),

  hp          = snes.watch(0x09C2, 2, "normal"),
  max_hp      = snes.watch(0x09C4, 2, "low"),
  missiles    = snes.watch(0x09C6, 2, "normal"),
  max_missiles= snes.watch(0x09C8, 2, "low"),
  supers      = snes.watch(0x09CA, 2, "normal"),
  max_supers  = snes.watch(0x09CC, 2, "low"),
  pbs         = snes.watch(0x09CE, 2, "normal"),
  max_pbs     = snes.watch(0x09D0, 2, "low"),
}

W.enemy = {}
for i = 0, MAX_ENEMY_SLOTS - 1 do
  local base = 0x0F78 + i * 0x40
  W.enemy[i + 1] = {
    id     = snes.watch(base + 0x00, 2, "normal"),
    x      = snes.watch(base + 0x02, 2, "normal"),
    y      = snes.watch(base + 0x06, 2, "normal"),
    hp     = snes.watch(base + 0x14, 2, "high"),
    timer  = snes.watch(base + 0x18, 2, "normal"),
    instr  = snes.watch(base + 0x1A, 2, "normal"),
    invuln = snes.watch(base + 0x24, 2, "normal"),
    frame  = snes.watch(base + 0x2C, 2, "normal"),
    ai0    = snes.watch(base + 0x30, 2, "normal"),
    ai1    = snes.watch(base + 0x32, 2, "normal"),
    ai2    = snes.watch(base + 0x34, 2, "normal"),
  }
end

local state = {
  start_frame = nil,
  last_frame = nil,
  last_room = nil,
  room_start = nil,
  room_history = {},
  room_best = {},
  boss = nil,
  boss_history = {},
}

local function u16(w, fallback)
  local v = snes.u16(w)
  if v == nil then return fallback end
  return v
end

local function age(w)
  return snes.age(w) or 999
end

local function frame_count()
  local lo = snes.u16(W.frame_lo)
  local hi = snes.u16(W.frame_hi)
  if lo == nil or hi == nil then return nil end
  return lo + hi * 65536
end

local function frame_delta(a, b)
  if a == nil or b == nil then return 0 end
  if b >= a then return b - a end
  return b + 4294967296 - a
end

local function fmt_time(frames)
  frames = math.max(0, math.floor(frames or 0))
  local total_seconds = math.floor(frames / FPS)
  local minutes = math.floor(total_seconds / 60)
  local seconds = total_seconds - minutes * 60
  local centis = math.floor(((frames % FPS) * 100) / FPS)
  return ("%02d:%02d.%02d"):format(minutes, seconds, centis)
end

local function fmt_delta(frames)
  if frames == nil then return "--" end
  local sign = frames < 0 and "-" or "+"
  return sign .. fmt_time(math.abs(frames))
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function push_front(t, item, limit)
  table.insert(t, 1, item)
  while #t > limit do table.remove(t) end
end

local function text(x, y, s, color, scale)
  gfx.text(x + 1, y + 1, tostring(s), COLOR.shadow, scale)
  gfx.text(x, y, tostring(s), color or COLOR.text, scale)
end

local function panel(x, y, w, h, title, accent)
  gfx.box(x, y, w, h, COLOR.border, COLOR.panel, 1.0)
  gfx.box(x, y, w, 9, accent or COLOR.blue, COLOR.panel2, 1.0)
  gfx.font("small")
  text(x + 4, y + 2, title, COLOR.text)
end

local function kv(x, y, k, v, color)
  text(x, y, k, COLOR.dim)
  text(x + 58, y, v, color or COLOR.text)
end

local function bar(x, y, w, h, value, max_value, color)
  local ratio = 0
  if max_value and max_value > 0 and value then
    ratio = clamp(value / max_value, 0, 1)
  end
  gfx.box(x, y, w, h, COLOR.bar_bg, COLOR.bar_bg, 1.0)
  if ratio > 0 then
    gfx.box(x, y, math.max(1, w * ratio), h, color, color, 1.0)
  end
  gfx.box(x, y, w, h, COLOR.border, nil, 1.0)
end

local function read_enemy(slot)
  local ew = W.enemy[slot + 1]
  local id = u16(ew.id, 0)
  local hp = u16(ew.hp, 0)
  return {
    slot = slot,
    id = id,
    x = u16(ew.x, 0),
    y = u16(ew.y, 0),
    hp = hp,
    timer = u16(ew.timer, 0),
    instr = u16(ew.instr, 0),
    invuln = u16(ew.invuln, 0),
    frame = u16(ew.frame, 0),
    ai0 = u16(ew.ai0, 0),
    ai1 = u16(ew.ai1, 0),
    ai2 = u16(ew.ai2, 0),
  }
end

local function boss_pattern(e)
  if e == nil then return "----:----:----" end
  return ("%04X:%04X:%04X"):format(e.instr or 0, e.ai0 or 0, e.ai1 or 0)
end

local function best_pattern(patterns)
  local best_key, best_count = nil, 0
  for k, v in pairs(patterns or {}) do
    if v > best_count then
      best_key, best_count = k, v
    end
  end
  return best_key, best_count
end

local function scan_boss()
  local boss_number = u16(W.boss_number, 0)
  local known = {}
  local fallback = nil

  for slot = 0, MAX_ENEMY_SLOTS - 1 do
    local e = read_enemy(slot)
    if e.id ~= 0 and e.hp > 0 then
      local name = BOSS_IDS[e.id]
      if name then
        known[#known + 1] = { enemy = e, name = name }
      elseif boss_number and boss_number > 0 then
        if fallback == nil or e.hp > fallback.enemy.hp then
          fallback = { enemy = e, name = ("Boss #%d"):format(boss_number) }
        end
      end
    end
  end

  if #known > 0 then
    local primary = known[1].enemy
    local name = known[1].name
    local total_hp = 0
    for _, entry in ipairs(known) do
      if entry.name == name then
        total_hp = total_hp + entry.enemy.hp
        if entry.enemy.hp > primary.hp then primary = entry.enemy end
      end
    end
    return { name = name, hp = total_hp, primary = primary, boss_number = boss_number }
  end

  if fallback then
    return {
      name = fallback.name,
      hp = fallback.enemy.hp,
      primary = fallback.enemy,
      boss_number = boss_number,
    }
  end

  return nil
end

local function update_rooms(frame)
  local room = u16(W.room_ptr, nil)
  if room == nil then return end

  if state.last_room == nil then
    state.last_room = room
    state.room_start = frame
    return
  end

  if room ~= state.last_room then
    local elapsed = frame_delta(state.room_start, frame)
    if elapsed > 15 then
      local best = state.room_best[state.last_room]
      local delta = best and (elapsed - best) or nil
      if best == nil or elapsed < best then
        state.room_best[state.last_room] = elapsed
      end
      push_front(state.room_history, {
        room = state.last_room,
        frames = elapsed,
        delta = delta,
        new_best = best == nil or elapsed < best,
      }, ROOM_HISTORY_LIMIT)
    end
    state.last_room = room
    state.room_start = frame
  end
end

local function finish_boss(frame, reason)
  local b = state.boss
  if b == nil then return end
  local elapsed = frame_delta(b.start_frame, frame)
  if elapsed > FPS then
    push_front(state.boss_history, {
      name = b.name,
      frames = elapsed,
      damage = b.damage,
      transitions = b.transitions,
      distinct = b.distinct_patterns,
      reason = reason or "done",
    }, BOSS_HISTORY_LIMIT)
  end
  state.boss = nil
end

local function update_boss(frame)
  local current = scan_boss()

  if current == nil then
    if state.boss ~= nil then finish_boss(frame, "clear") end
    return
  end

  local e = current.primary
  if state.boss == nil or state.boss.name ~= current.name then
    state.boss = {
      name = current.name,
      start_frame = frame,
      start_room = state.last_room,
      max_hp = math.max(1, current.hp),
      last_hp = current.hp,
      damage = 0,
      transitions = 0,
      distinct_patterns = 0,
      patterns = {},
      last_pattern = nil,
      last_enemy = e,
    }
  end

  local b = state.boss
  b.max_hp = math.max(b.max_hp, current.hp)
  if current.hp < b.last_hp then
    b.damage = b.damage + (b.last_hp - current.hp)
  end
  b.last_hp = current.hp
  b.last_enemy = e

  local pat = boss_pattern(e)
  if b.last_pattern ~= nil and b.last_pattern ~= pat then
    b.transitions = b.transitions + 1
  end
  if b.patterns[pat] == nil then
    b.patterns[pat] = 0
    b.distinct_patterns = b.distinct_patterns + 1
  end
  b.patterns[pat] = b.patterns[pat] + 1
  b.last_pattern = pat
end

local function draw_resources(x, y, w, h)
  panel(x, y, w, h, "SAMUS", COLOR.green)
  local hp, max_hp = u16(W.hp, 0), u16(W.max_hp, 0)
  local missiles, max_missiles = u16(W.missiles, 0), u16(W.max_missiles, 0)
  local supers, max_supers = u16(W.supers, 0), u16(W.max_supers, 0)
  local pbs, max_pbs = u16(W.pbs, 0), u16(W.max_pbs, 0)
  local hp_color = hp <= 30 and COLOR.red or (hp <= 99 and COLOR.yellow or COLOR.green)

  kv(x + 6, y + 16, "Energy", ("%d/%d"):format(hp, max_hp), hp_color)
  bar(x + 6, y + 27, w - 12, 5, hp, math.max(1, max_hp), hp_color)
  kv(x + 6, y + 38, "Missile", ("%d/%d"):format(missiles, max_missiles), COLOR.cyan)
  kv(x + 6, y + 49, "Super", ("%d/%d"):format(supers, max_supers), COLOR.yellow)
  kv(x + 6, y + 60, "PB", ("%d/%d"):format(pbs, max_pbs), COLOR.magenta)
end

local function draw_room_panel(x, y, w, h, frame)
  panel(x, y, w, h, "ROOM SPLITS", COLOR.cyan)
  local room = state.last_room or u16(W.room_ptr, 0)
  local elapsed = frame_delta(state.room_start, frame)
  local best = state.room_best[room]

  text(x + 6, y + 16, ("Room $%04X"):format(room or 0), COLOR.text)
  text(x + w - 74, y + 16, fmt_time(elapsed), COLOR.cyan)
  if best then
    local delta = elapsed - best
    local dc = delta <= 0 and COLOR.green or COLOR.orange
    text(x + w - 74, y + 27, fmt_delta(delta), dc)
  else
    text(x + w - 74, y + 27, "new room", COLOR.dim)
  end

  local row_y = y + 43
  for i, r in ipairs(state.room_history) do
    if row_y > y + h - 9 then break end
    local dc = r.new_best and COLOR.green or ((r.delta or 0) <= 0 and COLOR.green or COLOR.orange)
    text(x + 6, row_y, ("$%04X"):format(r.room), COLOR.dim)
    text(x + 50, row_y, fmt_time(r.frames), COLOR.text)
    text(x + w - 56, row_y, r.new_best and "best" or fmt_delta(r.delta), dc)
    row_y = row_y + 10
  end
end

local function draw_boss_panel(x, y, w, h, frame)
  panel(x, y, w, h, "BOSS TRACKER", COLOR.red)
  local b = state.boss

  if b == nil then
    text(x + 6, y + 17, "No active boss", COLOR.dim)
    local row_y = y + 34
    for _, k in ipairs(state.boss_history) do
      if row_y > y + h - 9 then break end
      text(x + 6, row_y, k.name, COLOR.text)
      text(x + w - 128, row_y, fmt_time(k.frames), COLOR.cyan)
      text(x + w - 66, row_y, ("%d pat"):format(k.distinct), COLOR.dim)
      row_y = row_y + 10
    end
    return
  end

  local elapsed = frame_delta(b.start_frame, frame)
  local hp_color = b.last_hp <= b.max_hp * 0.25 and COLOR.red
    or (b.last_hp <= b.max_hp * 0.5 and COLOR.yellow or COLOR.green)
  text(x + 6, y + 16, b.name, COLOR.text)
  text(x + w - 74, y + 16, fmt_time(elapsed), COLOR.cyan)
  bar(x + 6, y + 29, w - 12, 6, b.last_hp, b.max_hp, hp_color)
  text(x + 6, y + 40, ("HP %d/%d"):format(b.last_hp, b.max_hp), hp_color)
  text(x + w - 96, y + 40, ("DMG %d"):format(b.damage), COLOR.orange)

  local rate = 0
  if elapsed > 0 then rate = b.damage * FPS / elapsed end
  text(x + 6, y + 52, ("Pace %.1f dmg/s"):format(rate), COLOR.dim)
  if b.last_enemy then
    text(x + 6, y + 64, ("Slot %d | inv %d | t %d"):format(
      b.last_enemy.slot, b.last_enemy.invuln or 0, b.last_enemy.timer or 0
    ), COLOR.dim)
  end
end

local function draw_rng_panel(x, y, w, h)
  panel(x, y, w, h, "BOSS RNG PROXY", COLOR.magenta)
  local b = state.boss
  if b == nil then
    text(x + 6, y + 17, "Waiting for fight data", COLOR.dim)
    text(x + 6, y + 29, "Tracks AI state changes", COLOR.dim)
    return
  end

  local best, count = best_pattern(b.patterns)
  text(x + 6, y + 16, ("States %d"):format(b.distinct_patterns), COLOR.text)
  text(x + w - 96, y + 16, ("Changes %d"):format(b.transitions), COLOR.cyan)
  text(x + 6, y + 30, "Current", COLOR.dim)
  text(x + 58, y + 30, b.last_pattern or "----", COLOR.yellow)
  text(x + 6, y + 42, "Common", COLOR.dim)
  text(x + 58, y + 42, best or "----", COLOR.text)
  text(x + w - 38, y + 42, ("x%d"):format(count or 0), COLOR.dim)
end

local function draw_session_panel(x, y, w, h, frame)
  panel(x, y, w, h, "RUN CONTEXT", COLOR.blue)
  local session_frames = frame_delta(state.start_frame, frame)
  local game_state = u16(W.game_state, 0)
  local boss_number = u16(W.boss_number, 0)
  local room_w = u16(W.room_w, 0)
  local room_h = u16(W.room_h, 0)

  kv(x + 6, y + 16, "Session", fmt_time(session_frames), COLOR.cyan)
  kv(x + 6, y + 28, "Game", ("$%04X"):format(game_state), COLOR.dim)
  kv(x + 6, y + 40, "Boss no", ("%d"):format(boss_number), boss_number > 0 and COLOR.red or COLOR.dim)
  kv(x + 6, y + 52, "Room sz", ("%dx%d"):format(room_w, room_h), COLOR.dim)
end

local function draw_data_health(x, y, w)
  local worst = math.max(age(W.frame_lo), age(W.room_ptr), age(W.hp), age(W.boss_number))
  local color = worst > 12 and COLOR.orange or COLOR.dim
  local msg = ("data age max %d cycles | true ARAM RNG: needs API"):format(worst)
  text(x, y, msg, color)
  gfx.line(x, y - 3, x + w, y - 3, 0x60405060, 1.0)
end

function on_init()
  gfx.scale(2)
  print("sm_stream_overlay.lua loaded")
  print("Streaming overlay concept: room splits, boss timers, AI-state RNG proxy")
end

function on_frame()
  gfx.font("small")
  local frame = frame_count()
  if frame == nil then
    text(8, 8, "waiting for SNI frame counter...", COLOR.yellow)
    return
  end

  if state.start_frame == nil then
    state.start_frame = frame
    state.room_start = frame
  end

  update_rooms(frame)
  update_boss(frame)
  state.last_frame = frame

  local w, h = gfx.width(), gfx.height()
  if w >= 420 then
    draw_session_panel(8, 8, 132, 74, frame)
    draw_resources(148, 8, 132, 74)
    draw_rng_panel(288, 8, w - 296, 74)
    draw_room_panel(8, 90, 228, h - 114, frame)
    draw_boss_panel(244, 90, w - 252, h - 114, frame)
    draw_data_health(8, h - 14, w - 16)
  else
    draw_session_panel(6, 6, w - 12, 70, frame)
    draw_resources(6, 82, w - 12, 70)
    draw_room_panel(6, 158, w - 12, math.max(58, h - 236), frame)
    draw_boss_panel(6, h - 72, w - 12, 58, frame)
  end
end
