-- esports_input_viewer.lua
-- A highly polished, extremely premium vector input viewer built using native sni-lua primitives.
-- Fully responsive, customizable presets, neon/glassmorphic animations, APM heat, and traveling circuit pulses.

local pad_watch = snes.watch(0x008B, 2, "realtime")
snes.tier(pad_watch, "realtime")

local btn_keys = {"A", "B", "X", "Y", "L", "R", "Start", "Select", "Up", "Down", "Left", "Right"}
local btn_states = {}
local btn_vels = {}
local prev_btns = {}
for _, k in ipairs(btn_keys) do 
    btn_states[k] = 0.0 
    btn_vels[k] = 0.0
    prev_btns[k] = false
end

local history_log = {}
local ripples = {}
local pulses = {}
local press_times = {}

-- Preset color palettes for ultimate user choices
local themes = {
    -- Cyberpunk (Neon)
    {
        shell_fill = 0xFF120024,
        shell_out = 0xFF3D0080,
        idle = 0xFF1D0930,
        outline = 0xFF6315A8,
        active = 0xFF00E5FF,
        text = 0xFFFFFFFF,
        a = 0xFFFF0055,
        b = 0xFFFFCC00,
        x = 0xFF0088FF,
        y = 0xFF00FF66
    },
    -- Classic SNES (Retro)
    {
        shell_fill = 0xFFC2C2D6,
        shell_out = 0xFF87879C,
        idle = 0xFFA5A5B8,
        outline = 0xFF717187,
        active = 0xFF5858E6,
        text = 0xFF15151C,
        a = 0xFFFF2A2A,
        b = 0xFFFFCC00,
        x = 0xFF0077FF,
        y = 0xFF00B03B
    },
    -- Monochrome Sleek
    {
        shell_fill = 0xFF08080A,
        shell_out = 0xFF202024,
        idle = 0xFF101012,
        outline = 0xFF2C2C32,
        active = 0xFFFFFFFF,
        text = 0xFFEEEEEE,
        a = 0xFFDDDDDD,
        b = 0xFFCCCCCC,
        x = 0xFFBBBBBB,
        y = 0xFFAAAAAA
    },
    -- Forest Moss
    {
        shell_fill = 0xFF122012,
        shell_out = 0xFF2A3A2A,
        idle = 0xFF1C2E1C,
        outline = 0xFF3A583A,
        active = 0xFF7FFF00,
        text = 0xFFE5FFE5,
        a = 0xFF9ACD32,
        b = 0xFFD4AF37,
        x = 0xFF2E8B57,
        y = 0xFF6B8E23
    },
    -- Crimson Gold
    {
        shell_fill = 0xFF240404,
        shell_out = 0xFF4A0808,
        idle = 0xFF300A0A,
        outline = 0xFF6E1818,
        active = 0xFFFFD700,
        text = 0xFFFFF5EE,
        a = 0xFFFF3E3E,
        b = 0xFFFFA500,
        x = 0xFFFFD700,
        y = 0xFFB8860B
    }
}

-- Balanced SNES controller layout. Origin (0,0) is the center of the controller.
-- Coords sit in the tapered dogbone shell lobes perfectly.
local btn_coords = {
    A = {260, 37}, B = {168, 65}, X = {232, -55}, Y = {140, -27},
    L = {-175, -135}, R = {175, -135},
    Start = {55, 45}, Select = {-55, 45}
}

function on_init()
    -- Lighter, performant 720p canvas for sub-pixel smooth primitive rendering
    gfx.canvas(1280, 720)

    ui.header("Theme Selection")
    ui.select("theme", "Active Preset Theme", { 
        "Cyberpunk (Neon)", 
        "Classic SNES (Retro)", 
        "Monochrome Sleek", 
        "Forest Moss", 
        "Crimson Gold",
        "Custom Colors" 
    }, 1)

    ui.header("Graphics & Style Options")
    ui.select("button_style", "Button Render Style", { 
        "Glassmorphic Glow", 
        "Solid Minimalist", 
        "Neon Wireframe" 
    }, 1)
    ui.checkbox("show_shell", "Show Controller Shell", true)
    ui.checkbox("show_grid", "Show Background Grid", true)
    ui.checkbox("show_circuits", "Show Circuit Background Traces", true)
    ui.checkbox("show_ripples", "Show Pressed Ripples", true)
    ui.slider("ripple_size", "Ripple Size Scale (%)", 20, 200, 100)
    ui.slider("ripple_opacity", "Ripple Brightness (%)", 10, 100, 60)
    ui.checkbox("show_dpad_arrows", "Show D-Pad Arrow Markers", true)
    ui.select("font_style", "Typography Face", { "Normal 8x8 Pixel", "Small 5x7 Pixel" }, 1)

    ui.header("Controller Positioning & Scale")
    ui.slider("scale_x", "Controller Position X", 0, 1280, 640)
    ui.slider("scale_y", "Controller Position Y", 0, 720, 360)
    ui.slider("ctrl_scale", "Controller Size Scale (%)", 20, 200, 100)

    ui.header("APM Placement & Sizing")
    ui.select("apm_pos_mode", "APM Position Mode", { "Absolute Coordinates", "Attached to Controller", "Hidden" }, 2)
    ui.select("apm_pos", "APM Side (Attached Mode)", { "Left Side", "Right Side" }, 1)
    ui.slider("apm_x", "APM Absolute X", 0, 1280, 80)
    ui.slider("apm_y", "APM Absolute Y", 0, 720, 630)
    ui.slider("apm_scale", "APM Size Scale (%)", 20, 200, 100)
    ui.slider("apm_max", "APM Max Value", 100, 600, 300)

    ui.header("History Log Placement & Sizing")
    ui.select("history_pos_mode", "History Position Mode", { "Absolute Coordinates", "Attached to Controller", "Hidden" }, 2)
    ui.select("history_pos", "History Side (Attached Mode)", { "Right Side", "Left Side" }, 1)
    ui.slider("history_x", "History Absolute X", 0, 1280, 1160)
    ui.slider("history_y", "History Absolute Y", 0, 720, 630)
    ui.slider("history_scale", "History Size Scale (%)", 20, 200, 100)
    ui.slider("history_len", "History Capacity", 5, 20, 12)
    ui.select("history_dir", "History Scroll Direction", { "Vertical Up", "Vertical Down", "Horizontal Left", "Horizontal Right" }, 1)

    ui.header("Custom Colors Override (Preset: Custom Colors)")
    ui.color("color_idle", "Resting Base Color", 0xFF222226)
    ui.color("color_outline", "Wireframe Color", 0xFF666677)
    ui.color("color_active", "Global Accent (D-Pad)", 0xFF00E5FF)
    ui.color("color_text", "Text Fill", 0xFFFFFFFF)
    ui.color("color_a", "Btn A (Red)", 0xFFFF3333)
    ui.color("color_b", "Btn B (Yellow)", 0xFFFFCC00)
    ui.color("color_x", "Btn X (Blue)", 0xFF0088FF)
    ui.color("color_y", "Btn Y (Green)", 0xFF00CC44)

    ui.header("Engine Dynamics")
    ui.slider("spring_stiffness", "Spring Stiffness (Tension)", 10, 300, 90)
    ui.slider("spring_damping", "Spring Damping (Friction)", 5, 80, 18)
end

-- ============================================================================
-- CORE RENDERING HELPERS
-- ============================================================================

local function color_with_alpha(color, alpha_float)
    local a = math.floor(anim.clamp(alpha_float, 0, 1) * 255)
    local r = bit.band(bit.rshift(color, 16), 0xFF)
    local g = bit.band(bit.rshift(color, 8), 0xFF)
    local b = bit.band(color, 0xFF)
    return gfx.argb(a, r, g, b)
end

local function get_theme_val(key)
    local theme_idx = ui.get("theme")
    if theme_idx <= 5 then
        return themes[theme_idx][key]
    else
        -- Custom Palette Fallbacks
        if key == "shell_fill" then return 0xFF14141A end
        if key == "shell_out" then return ui.get("color_outline") end
        if key == "idle" then return ui.get("color_idle") end
        if key == "outline" then return ui.get("color_outline") end
        if key == "active" then return ui.get("color_active") end
        if key == "text" then return ui.get("color_text") end
        if key == "a" then return ui.get("color_a") end
        if key == "b" then return ui.get("color_b") end
        if key == "x" then return ui.get("color_x") end
        if key == "y" then return ui.get("color_y") end
        return ui.get("color_active")
    end
end

local function get_btn_color(btn)
    if btn == "A" then return get_theme_val("a") end
    if btn == "B" then return get_theme_val("b") end
    if btn == "X" then return get_theme_val("x") end
    if btn == "Y" then return get_theme_val("y") end
    return get_theme_val("active")
end

local function draw_text_centered(x, y, str, color, alpha, text_scale)
    local font = (ui.get("font_style") == 1 and "normal" or "small")
    gfx.font(font)
    local scale = text_scale or 1.0
    local c = color_with_alpha(color, alpha or 1.0)
    local out_c = color_with_alpha(0xFF000000, (alpha or 1.0) * 0.8)
    
    -- Utilize native text alignment parameters for absolute centering
    gfx.text(x, y, str, c, { scale = scale, outline = out_c, align = "center", valign = "middle" })
end

local function spawn_pulse(start_x, start_y, end_x, end_y, color)
    if not ui.get("show_circuits") then return end
    table.insert(pulses, {
        sx = start_x, sy = start_y,
        ex = end_x, ey = end_y,
        prog = 0.0,
        speed = 2.4, -- travels the trace in 0.4 seconds
        color = color
    })
end

-- ============================================================================
-- ADVANCED COMPOSITE WIDGETS
-- ============================================================================

local function render_glow_circle(cx, cy, r, label, progress, custom_color, cscale)
    local c_idle = get_theme_val("idle")
    local c_out = get_theme_val("outline")
    local c_active = custom_color or get_theme_val("active")
    local c_text = get_theme_val("text")
    local style = ui.get("button_style")
    
    local x = cx * cscale
    local y = cy * cscale
    local pop_r = (r + (progress * 8)) * cscale

    local current_outline = gfx.color_lerp(c_out, c_active, progress)
    local current_fill
    local rect_opts = nil

    if progress > 0.01 then
        rect_opts = { shadow = { blur = 30 * progress * cscale, spread = 2 * progress * cscale, color = color_with_alpha(c_active, 0.4 * progress) } }
    end

    if style == 1 then
        -- Glassmorphic Glow
        current_fill = color_with_alpha(gfx.color_lerp(c_idle, c_active, progress), 0.75 + (0.25 * progress))
        -- Main base
        gfx.round_rect(x - pop_r, y - pop_r, pop_r * 2, pop_r * 2, pop_r, current_outline, current_fill, 4 * cscale, rect_opts)
        -- Glass reflection crescent highlight (sleek, high position, transparent border!)
        gfx.round_rect(x - pop_r * 0.45, y - pop_r * 0.78, pop_r * 0.9, pop_r * 0.12, pop_r * 0.06, 0x00000000, color_with_alpha(0xFFFFFFFF, 0.18 * (1.0 - progress * 0.4)), 1)
    elseif style == 2 then
        -- Solid Minimalist
        current_fill = gfx.color_lerp(c_idle, c_active, progress)
        gfx.round_rect(x - pop_r, y - pop_r, pop_r * 2, pop_r * 2, pop_r, current_outline, current_fill, 4 * cscale, rect_opts)
    else
        -- Neon Wireframe
        current_fill = color_with_alpha(c_active, 0.12 * progress)
        gfx.round_rect(x - pop_r, y - pop_r, pop_r * 2, pop_r * 2, pop_r, current_outline, current_fill, 2.5 * cscale, rect_opts)
    end

    if label ~= "" then
        draw_text_centered(x, y, label, c_text, 1.0, (1.30 + progress * 0.20) * cscale)
    end
end

local function render_glow_rect(cx, cy, w, h, r, label, progress, scale_text, cscale)
    local c_idle = get_theme_val("idle")
    local c_out = get_theme_val("outline")
    local c_active = get_theme_val("active")
    local c_text = get_theme_val("text")
    local style = ui.get("button_style")
    
    local pop = 8 * progress
    local bx = (cx - w/2 - pop) * cscale
    local by = (cy - h/2 - pop) * cscale
    local bw = (w + pop * 2) * cscale
    local bh = (h + pop * 2) * cscale
    local br = (r + pop) * cscale

    local current_outline = gfx.color_lerp(c_out, c_active, progress)
    local current_fill
    local rect_opts = nil
    if progress > 0.01 then
        rect_opts = { shadow = { blur = 30 * progress * cscale, spread = 2 * progress * cscale, color = color_with_alpha(c_active, 0.4 * progress) } }
    end

    if style == 1 then
        -- Glassmorphic Glow
        current_fill = color_with_alpha(gfx.color_lerp(c_idle, c_active, progress), 0.75 + (0.25 * progress))
        gfx.round_rect(bx, by, bw, bh, br, current_outline, current_fill, 4 * cscale, rect_opts)
        -- Glass reflection highlight (sleek top bar, transparent border!)
        gfx.round_rect(bx + bw * 0.1, by + bh * 0.08, bw * 0.8, bh * 0.12, br * 0.1, 0x00000000, color_with_alpha(0xFFFFFFFF, 0.18 * (1.0 - progress * 0.4)), 1)
    elseif style == 2 then
        -- Solid Minimalist
        current_fill = gfx.color_lerp(c_idle, c_active, progress)
        gfx.round_rect(bx, by, bw, bh, br, current_outline, current_fill, 4 * cscale, rect_opts)
    else
        -- Neon Wireframe
        current_fill = color_with_alpha(c_active, 0.12 * progress)
        gfx.round_rect(bx, by, bw, bh, br, current_outline, current_fill, 2.5 * cscale, rect_opts)
    end

    if label ~= "" then
        draw_text_centered(cx * cscale, cy * cscale, label, c_text, 1.0, (scale_text + progress * 0.20) * cscale)
    end
end

-- A mathematically perfect vector cross built utilizing path unions
local function draw_seamless_dpad(dcx, dcy, states, cscale)
    local cx = dcx * cscale
    local cy = dcy * cscale
    local w = 34 * cscale -- Half-width of an arm
    local l = 95 * cscale -- Distance from center to tip
    local r = 11 * cscale  -- Outer corner rounding
    
    local c_idle = get_theme_val("idle")
    local c_out = get_theme_val("outline")
    local c_active = get_theme_val("active")
    local style = ui.get("button_style")
    local center_press = math.max(states.Up, states.Down, states.Left, states.Right)

    -- 1. Draw solid background base using path unions
    gfx.begin_path()
    gfx.path_round_rect(cx - w, cy - l, w*2, l*2, r) -- Vertical Arm
    gfx.path_round_rect(cx - l, cy - w, l*2, w*2, r) -- Horizontal Arm
    if style == 3 then
        gfx.fill_path(color_with_alpha(c_active, 0.05))
    else
        gfx.fill_path(color_with_alpha(c_idle, 0.8))
    end

    -- 2. Add glowing fills for pressed directions natively
    if states.Up > 0 then gfx.round_rect(cx - w, cy - l, w*2, l - w + 2 * cscale, r, nil, color_with_alpha(c_active, states.Up * 0.9)) end
    if states.Down > 0 then gfx.round_rect(cx - w, cy + w - 2 * cscale, w*2, l - w + 2 * cscale, r, nil, color_with_alpha(c_active, states.Down * 0.9)) end
    if states.Left > 0 then gfx.round_rect(cx - l, cy - w, l - w + 2 * cscale, w*2, r, nil, color_with_alpha(c_active, states.Left * 0.9)) end
    if states.Right > 0 then gfx.round_rect(cx + w - 2 * cscale, cy - w, l - w + 2 * cscale, w*2, r, nil, color_with_alpha(c_active, states.Right * 0.9)) end

    -- 3. Draw mathematically continuous outer stroke
    local current_out = gfx.color_lerp(c_out, c_active, center_press)
    gfx.begin_path()
    gfx.path_round_rect(cx - w, cy - l, w*2, l*2, r)
    gfx.path_round_rect(cx - l, cy - w, l*2, w*2, r)
    gfx.stroke_path(current_out, (style == 3 and 2.5 or 4) * cscale)

    -- Dynamic center circular indentation
    gfx.circle(cx, cy, 22 * cscale, current_out, color_with_alpha(c_idle, 0.9), 2 * cscale)

    -- 4. Draw glowing direction arrows / chevrons (gfx.triangle)
    if ui.get("show_dpad_arrows") then
        local size = 9 * cscale
        local arrow_color = get_theme_val("text")
        
        -- Up Arrow
        local uy = cy - 58 * cscale
        local u_press = states.Up
        local u_col = gfx.color_lerp(color_with_alpha(arrow_color, 0.4), c_active, u_press)
        local u_fill = u_press > 0.01 and color_with_alpha(c_active, u_press * 0.6) or nil
        gfx.triangle(cx, uy - size * 0.8, cx - size, uy + size * 0.6, cx + size, uy + size * 0.6, u_col, u_fill, 2 * cscale)

        -- Down Arrow
        local dy = cy + 58 * cscale
        local d_press = states.Down
        local d_col = gfx.color_lerp(color_with_alpha(arrow_color, 0.4), c_active, d_press)
        local d_fill = d_press > 0.01 and color_with_alpha(c_active, d_press * 0.6) or nil
        gfx.triangle(cx, dy + size * 0.8, cx - size, dy - size * 0.6, cx + size, dy - size * 0.6, d_col, d_fill, 2 * cscale)

        -- Left Arrow
        local lx = cx - 58 * cscale
        local l_press = states.Left
        local l_col = gfx.color_lerp(color_with_alpha(arrow_color, 0.4), c_active, l_press)
        local l_fill = l_press > 0.01 and color_with_alpha(c_active, l_press * 0.6) or nil
        gfx.triangle(lx - size * 0.8, cy, lx + size * 0.6, cy - size, lx + size * 0.6, cy + size, l_col, l_fill, 2 * cscale)

        -- Right Arrow
        local rx = cx + 58 * cscale
        local r_press = states.Right
        local r_col = gfx.color_lerp(color_with_alpha(arrow_color, 0.4), c_active, r_press)
        local r_fill = r_press > 0.01 and color_with_alpha(c_active, r_press * 0.6) or nil
        gfx.triangle(rx + size * 0.8, cy, rx - size * 0.6, cy - size, rx - size * 0.6, cy + size, r_col, r_fill, 2 * cscale)
    end

    -- Dynamic Center Dot (analog vector movement indicator)
    local dx = (states.Right - states.Left) * 14 * cscale
    local dy = (states.Down - states.Up) * 14 * cscale
    local pip_opts = nil
    if center_press > 0.01 then
        pip_opts = { shadow = { blur = 15 * cscale, spread = 2 * cscale, color = color_with_alpha(c_active, center_press) } }
    end
    gfx.round_rect(cx + dx - 8 * cscale, cy + dy - 8 * cscale, 16 * cscale, 16 * cscale, 8 * cscale, color_with_alpha(c_active, center_press), color_with_alpha(0xFFFFFFFF, center_press), 3 * cscale, pip_opts)
end

-- Interconnected living circuit traces
local function draw_circuit_traces(sc, circuit_c)
    -- Center Node
    gfx.circle(0, 0, sc(14), circuit_c, nil, sc(2.5))
    
    -- Trace to D-pad (ends at D-pad center -200, 0)
    local dpad_active = math.max(btn_states.Up, btn_states.Down, btn_states.Left, btn_states.Right)
    local dpad_color = gfx.color_lerp(circuit_c, get_theme_val("active"), dpad_active)
    local dpad_thick = sc(2.5 + dpad_active * 2.0)
    gfx.line(0, 0, sc(-200), 0, dpad_color, dpad_thick)
    gfx.circle(sc(-200), 0, sc(6), dpad_color, nil, sc(1.5))
    
    -- Trace to Select (ends at -55, 45)
    local sel_color = gfx.color_lerp(circuit_c, get_theme_val("active"), btn_states.Select)
    local sel_thick = sc(2.5 + btn_states.Select * 2.0)
    gfx.line(0, 0, sc(-55), 0, sel_color, sel_thick)
    gfx.line(sc(-55), 0, sc(-55), sc(45), sel_color, sel_thick)
    
    -- Trace to Start (ends at 55, 45)
    local str_color = gfx.color_lerp(circuit_c, get_theme_val("active"), btn_states.Start)
    local str_thick = sc(2.5 + btn_states.Start * 2.0)
    gfx.line(0, 0, sc(55), 0, str_color, str_thick)
    gfx.line(sc(55), 0, sc(55), sc(45), str_color, str_thick)
    
    -- Trace to Face Buttons center (200, 5)
    local face_active = math.max(btn_states.A, btn_states.B, btn_states.X, btn_states.Y)
    local face_color = gfx.color_lerp(circuit_c, get_theme_val("active"), face_active)
    local face_thick = sc(2.5 + face_active * 2.0)
    gfx.line(0, 0, sc(200), sc(5), face_color, face_thick)
    gfx.circle(sc(200), sc(5), sc(6), face_color, nil, sc(1.5))
    
    -- Trace from Face Buttons center (200, 5) to individual buttons
    local y_color = gfx.color_lerp(circuit_c, get_btn_color("Y"), btn_states.Y)
    gfx.line(sc(200), sc(5), sc(140), sc(-27), y_color, sc(2 + btn_states.Y * 1.5))
    
    local a_color = gfx.color_lerp(circuit_c, get_btn_color("A"), btn_states.A)
    gfx.line(sc(200), sc(5), sc(260), sc(37), a_color, sc(2 + btn_states.A * 1.5))
    
    local x_color = gfx.color_lerp(circuit_c, get_btn_color("X"), btn_states.X)
    gfx.line(sc(200), sc(5), sc(232), sc(-55), x_color, sc(2 + btn_states.X * 1.5))
    
    local b_color = gfx.color_lerp(circuit_c, get_btn_color("B"), btn_states.B)
    gfx.line(sc(200), sc(5), sc(168), sc(65), b_color, sc(2 + btn_states.B * 1.5))
    
    -- Trace from D-pad center (-200, 0) up to L shoulder (-175, -135)
    local l_color = gfx.color_lerp(circuit_c, get_btn_color("L"), btn_states.L)
    local l_thick = sc(2 + btn_states.L * 1.5)
    gfx.line(sc(-200), 0, sc(-200), sc(-70), l_color, l_thick)
    gfx.line(sc(-200), sc(-70), sc(-175), sc(-135), l_color, l_thick)
    
    -- Trace from Face center (200, 5) up to R shoulder (175, -135)
    local r_color = gfx.color_lerp(circuit_c, get_btn_color("R"), btn_states.R)
    local r_thick = sc(2 + btn_states.R * 1.5)
    gfx.line(sc(200), sc(5), sc(200), sc(-70), r_color, r_thick)
    gfx.line(sc(200), sc(-70), sc(175), sc(-135), r_color, r_thick)
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================

function on_frame()
    local buttons = snes.buttons(pad_watch)
    if not buttons then return end 

    local current_time = time.now()
    local dt = time.dt()
    if dt <= 0 or dt > 0.1 then dt = 1/60 end

    local speed = ui.get("spring_stiffness")
    local damping = ui.get("spring_damping")

    -- Broadcast Grid Background
    if ui.get("show_grid") then
        local grid_c = color_with_alpha(0xFFFFFFFF, 0.02)
        local w, h = gfx.width(), gfx.height()
        for x = 0, w, 120 do gfx.line(x, 0, x, h, grid_c, 2) end
        for y = 0, h, 120 do gfx.line(0, y, w, y, grid_c, 2) end
    end

    -- Input State Management & Spring-Mass-Damper Dynamics
    for _, btn in ipairs(btn_keys) do
        local is_pressed = buttons[btn]
        
        if is_pressed and not prev_btns[btn] then
            table.insert(press_times, current_time)
            local btn_color = get_btn_color(btn)
            
            table.insert(history_log, { 
                btn = btn, time = current_time, alpha = 1.0, color = btn_color 
            })
            local history_cap = ui.get("history_len")
            if #history_log > history_cap then table.remove(history_log, 1) end

            local bx, by = btn_coords[btn] and btn_coords[btn][1] or -200, btn_coords[btn] and btn_coords[btn][2] or 0
            if ui.get("show_ripples") then
                table.insert(ripples, { x = bx, y = by, radius = 20, alpha = 1.0, color = btn_color })
            end

            -- Spawn travelers along background traces
            if ui.get("show_circuits") then
                spawn_pulse(0, 0, bx, by, btn_color)
            end
        end
        
        prev_btns[btn] = is_pressed
        local target = is_pressed and 1.0 or 0.0
        
        -- Spring Physics calculation: accel = -k * (x - x_target) - c * v
        local accel = -speed * (btn_states[btn] - target) - damping * btn_vels[btn]
        btn_vels[btn] = btn_vels[btn] + accel * dt
        btn_states[btn] = btn_states[btn] + btn_vels[btn] * dt
        -- Clamp to prevent physics explosions while maintaining clean overshoot
        btn_states[btn] = anim.clamp(btn_states[btn], 0, 1.25)
    end

    -- --- 1. APM METER ---
    local apm_pos_mode = ui.get("apm_pos_mode")
    if apm_pos_mode ~= 3 then -- Not Hidden
        while #press_times > 0 and (current_time - press_times[1]) > 5.0 do
            table.remove(press_times, 1)
        end
        
        local current_apm = math.floor((#press_times / 5) * 60)
        local apm_max = ui.get("apm_max")
        local apm_ratio = anim.clamp(current_apm / apm_max, 0, 1)
        
        local scale_x = ui.get("scale_x")
        local scale_y = ui.get("scale_y")
        local cscale = ui.get("ctrl_scale") / 100.0
        local function sc(val) return val * cscale end

        -- Settle exact coordinates based on mode
        local m_x, m_y
        local apm_scale = (ui.get("apm_scale") or 100) / 100.0
        local m_h = 450 * apm_scale

        if apm_pos_mode == 1 then -- Absolute Coordinates
            m_x = ui.get("apm_x")
            m_y = ui.get("apm_y")
        else -- Attached to Controller
            local side = ui.get("apm_pos")
            m_x = (side == 1) and (scale_x - sc(420)) or (scale_x + sc(420))
            m_y = scale_y + sc(180)
        end

        -- Outer shell vertical capsule
        gfx.round_rect(m_x - 14 * apm_scale, m_y - m_h, 28 * apm_scale, m_h, 14 * apm_scale, get_theme_val("outline"), color_with_alpha(get_theme_val("idle"), 0.8), 4 * apm_scale)
        
        -- Gradient APM Fill
        local m_active = get_theme_val("active")
        if apm_ratio > 0 then
            local fill_h = m_h * apm_ratio
            gfx.gradient_rect(m_x - 14 * apm_scale, m_y - fill_h, 28 * apm_scale, fill_h, 
                color_with_alpha(m_active, 0.2), 
                color_with_alpha(m_active, 0.85), 
                { radius = 14 * apm_scale, vertical = true, shadow = { blur = 20 * apm_scale, spread = 2 * apm_scale, color = color_with_alpha(m_active, 0.5) } }
            )
        end
        
        -- Dynamic heat elements (APM glows hot red at full ratio, pulsing text size!)
        local scale_mult = 1.0 + (apm_ratio * 0.35)
        local apm_val_color = gfx.color_lerp(m_active, 0xFFFF0033, apm_ratio)
        
        draw_text_centered(m_x, m_y + 40 * apm_scale, "APM", get_theme_val("text"), 1.0, 1.4 * apm_scale)
        draw_text_centered(m_x, m_y - m_h - 40 * apm_scale, tostring(current_apm), apm_val_color, 1.0, 2.2 * scale_mult * apm_scale)
    end

    -- --- 2. HISTORY LOG ---
    local history_pos_mode = ui.get("history_pos_mode")
    if history_pos_mode ~= 3 then -- Not Hidden
        local scale_x = ui.get("scale_x")
        local scale_y = ui.get("scale_y")
        local cscale = ui.get("ctrl_scale") / 100.0
        local function sc(val) return val * cscale end

        local feed_x, feed_start_y
        local h_scale = (ui.get("history_scale") or 100) / 100.0
        local side = ui.get("history_pos")

        if history_pos_mode == 1 then -- Absolute Coordinates
            feed_x = ui.get("history_x")
            feed_start_y = ui.get("history_y")
        else -- Attached to Controller
            feed_x = (side == 1) and (scale_x + sc(420)) or (scale_x - sc(420))
            feed_start_y = scale_y + sc(180)
        end
        
        local m_active = get_theme_val("active")
        local h_dir = ui.get("history_dir") -- 1 = Vertical Up, 2 = Vertical Down, 3 = Horizontal Left, 4 = Horizontal Right
        
        -- Separation indicator trace (Only for vertical feeds - compact, overlap-free position)
        local sep_x = (side == 1) and (feed_x - 30 * h_scale) or (feed_x + 30 * h_scale)
        if h_dir <= 2 and history_pos_mode == 2 then
            local y1 = (h_dir == 1) and (feed_start_y - 800 * h_scale) or (feed_start_y - 100 * h_scale)
            local y2 = (h_dir == 1) and (feed_start_y + 100 * h_scale) or (feed_start_y + 800 * h_scale)
            local c1 = (h_dir == 1) and color_with_alpha(m_active, 0.0) or color_with_alpha(m_active, 0.55)
            local c2 = (h_dir == 1) and color_with_alpha(m_active, 0.55) or color_with_alpha(m_active, 0.0)
            gfx.gradient_line(sep_x, y1, sep_x, y2, c1, c2, 4 * h_scale)
        end

        local font = (ui.get("font_style") == 1 and "normal" or "small")
        gfx.font(font)

        -- 1. Precalculate perfect non-overlapping targets for all history items (cumulative width layout)
        local targets = {}
        local gap = 12 * h_scale
        
        if h_dir == 1 then -- Vertical Up
            for i = #history_log, 1, -1 do
                local index_offset = #history_log - i
                targets[i] = feed_start_y - (index_offset * 64 * h_scale)
            end
        elseif h_dir == 2 then -- Vertical Down
            for i = #history_log, 1, -1 do
                local index_offset = #history_log - i
                targets[i] = feed_start_y + (index_offset * 64 * h_scale)
            end
        elseif h_dir == 3 then -- Horizontal Left
            local current_pos = feed_x
            for i = #history_log, 1, -1 do
                local item = history_log[i]
                local text_w = gfx.text_width(item.btn) * h_scale * 1.6
                local box_w = text_w + 24 * h_scale
                if i == #history_log then
                    targets[i] = feed_x
                    current_pos = feed_x
                else
                    targets[i] = current_pos - gap - box_w
                    current_pos = targets[i]
                end
            end
        else -- Horizontal Right (h_dir == 4)
            local current_pos = feed_x
            local prev_w = 0
            for i = #history_log, 1, -1 do
                local item = history_log[i]
                local text_w = gfx.text_width(item.btn) * h_scale * 1.6
                local box_w = text_w + 24 * h_scale
                if i == #history_log then
                    targets[i] = feed_x
                    current_pos = feed_x
                else
                    targets[i] = current_pos + prev_w + gap
                    current_pos = targets[i]
                end
                prev_w = box_w
            end
        end

        -- 2. Render and animate history log items smoothly
        for i = #history_log, 1, -1 do
            local item = history_log[i]
            local age = current_time - item.time
            item.alpha = math.max(0, 1.0 - (age / 3.0))
            
            if item.alpha > 0 then
                local box_h = 42 * h_scale
                local text_w = gfx.text_width(item.btn) * h_scale * 1.6
                local box_w = text_w + 24 * h_scale
                
                local bx, by
                local target_pos = targets[i]
                
                -- Initialize yOffset on first frame to prevent flying in from (0,0)
                if not item.yOffset then
                    item.yOffset = target_pos
                end
                
                -- Smoothly interpolate towards target
                item.yOffset = item.yOffset + (target_pos - item.yOffset) * math.min(1, dt * 15)
                
                if h_dir <= 2 then -- Vertical modes
                    by = item.yOffset - box_h / 2
                    -- Ensure pills grow OUTWARDS (away from the controller shell) to avoid overlapping it
                    bx = (side == 1) and feed_x or (feed_x - box_w)
                else -- Horizontal modes
                    bx = item.yOffset
                    by = feed_start_y - box_h / 2
                end
                
                -- Draw dynamic non-overflowing history log pill
                gfx.round_rect(bx, by, box_w, box_h, 14 * h_scale, 
                    color_with_alpha(item.color, item.alpha * 0.8), 
                    color_with_alpha(item.color, item.alpha * 0.22), 2 * h_scale)

                draw_text_centered(bx + box_w/2, by + box_h/2, item.btn, get_theme_val("text"), item.alpha, 1.6 * h_scale)

                -- Visual link to vertical connector
                if h_dir <= 2 and history_pos_mode == 2 then
                    gfx.circle(sep_x, item.yOffset, 6 * h_scale, nil, color_with_alpha(item.color, item.alpha))
                    local line_start = sep_x
                    local line_end = (side == 1) and bx or (bx + box_w)
                    gfx.line(line_start, item.yOffset, line_end, item.yOffset, color_with_alpha(item.color, item.alpha * 0.55), 2 * h_scale)
                end
            end
        end
    end

    -- --- 3. CONTROLLER CANVAS ---
    local scale_x = ui.get("scale_x")
    local scale_y = ui.get("scale_y")
    local cscale = ui.get("ctrl_scale") / 100.0
    local function sc(val) return val * cscale end

    gfx.push_origin(scale_x, scale_y)

    -- Vector Controller Shell (Beautiful retro dogbone capsule)
    if ui.get("show_shell") then
        local sh_fill = get_theme_val("shell_fill")
        local sh_out = get_theme_val("shell_out")

        -- Render soft drop shadow under the controller for maximum premium look (Glassmorphic style exclusive)
        if ui.get("button_style") == 1 then
            local glow_color = color_with_alpha(get_theme_val("active"), 0.22)
            gfx.round_rect(sc(-350), sc(-120), sc(700), sc(240), sc(120), 0x00000000, 0x00000000, 1, 
                { shadow = { blur = sc(60), spread = sc(12), color = glow_color } })
        end

        -- 1. Assemble the tapered dogbone shell mathematically continuous outline via path unions
        gfx.begin_path()
        gfx.path_circle(sc(-200), sc(0), sc(158)) -- Left ergonomic lobe
        gfx.path_circle(sc(200), sc(0), sc(158)) -- Right ergonomic lobe
        gfx.path_round_rect(sc(-200), sc(-118), sc(400), sc(236), sc(30)) -- Tapered middle bridge
        gfx.fill_path(sh_fill)
        gfx.stroke_path(sh_out, sc(5.5))
        
        -- 2. Retro detail ring / two-tone panels (SNES Retro theme exclusive)
        if ui.get("theme") == 2 then 
            -- Left side circular indentation for D-pad
            gfx.circle(sc(-200), 0, sc(115), 0xFF8A8A9E, 0xFF9E9EB2, sc(2))
            -- Right side slanted button housing plate (tilted pill behind face buttons)
            gfx.round_rect(sc(115), sc(-90), sc(160), sc(180), sc(80), 0xFF8A8A9E, 0xFF9E9EB2, sc(2))
        end

        -- 3. Inset 3D groove slots behind Select and Start buttons!
        local groove_c = color_with_alpha(sh_out, 0.4)
        local groove_fill = color_with_alpha(sh_fill, 0.85)
        gfx.round_rect(sc(-95), sc(32), sc(80), sc(26), sc(13), groove_c, groove_fill, sc(1.5))
        gfx.round_rect(sc(15), sc(32), sc(80), sc(26), sc(13), groove_c, groove_fill, sc(1.5))
    end

    -- Render Shoulder Bumpers (L & R) on top of the controller shell
    render_glow_rect(btn_coords.L[1], btn_coords.L[2], 170, 42, 18, "L", btn_states.L, 1.4, cscale)
    render_glow_rect(btn_coords.R[1], btn_coords.R[2], 170, 42, 18, "R", btn_states.R, 1.4, cscale)

    -- Background Circuit Traces (Living interconnected nodes)
    if ui.get("show_circuits") then
        local circuit_c = color_with_alpha(get_theme_val("active"), 0.30)
        draw_circuit_traces(sc, circuit_c)
    end

    -- Shockwave Ripples
    local rip_size_mult = (ui.get("ripple_size") or 100) / 100.0
    local rip_alpha_mult = (ui.get("ripple_opacity") or 60) / 100.0
    for i = #ripples, 1, -1 do
        local r = ripples[i]
        r.radius = r.radius + (dt * 400 * cscale * rip_size_mult)
        r.alpha = r.alpha - (dt * 1.5)
        
        if r.alpha <= 0 then
            table.remove(ripples, i)
        else
            gfx.circle(sc(r.x), sc(r.y), r.radius, color_with_alpha(r.color, r.alpha * rip_alpha_mult), nil, sc(4))
        end
    end

    -- Traveling pulses along background circuit lines (Comet Sparks!)
    for i = #pulses, 1, -1 do
        local p = pulses[i]
        p.prog = p.prog + dt * p.speed
        if p.prog >= 1.0 then
            table.remove(pulses, i)
        else
            local tail_prog = math.max(0, p.prog - 0.22)
            local px1 = sc(p.sx + (p.ex - p.sx) * tail_prog)
            local py1 = sc(p.sy + (p.ey - p.sy) * tail_prog)
            local px2 = sc(p.sx + (p.ex - p.sx) * p.prog)
            local py2 = sc(p.sy + (p.ey - p.sy) * p.prog)
            
            local head_color = color_with_alpha(p.color, 1.0 - p.prog)
            local tail_color = color_with_alpha(p.color, 0.0)
            
            -- Draw electric comet streak
            gfx.gradient_line(px1, py1, px2, py2, tail_color, head_color, sc(4.5 * (1.0 - p.prog)))
            -- Draw comet head
            local size = sc(6.5 * (1.0 - p.prog))
            gfx.circle(px2, py2, size, nil, head_color)
        end
    end

    -- Render Select & Start slanted pill buttons nestled inside grooves
    render_glow_rect(btn_coords.Select[1], btn_coords.Select[2], 70, 20, 10, "SEL", btn_states.Select, 1.15, cscale)
    render_glow_rect(btn_coords.Start[1], btn_coords.Start[2], 70, 20, 10, "STR", btn_states.Start, 1.15, cscale)

    -- Draw seamless directional D-pad centered in left lobe
    draw_seamless_dpad(-200, 0, btn_states, cscale)

    -- Render face buttons (X, Y, A, B) mathematically slanted clockwise by 28 degrees!
    local face_r = 34
    render_glow_circle(btn_coords.X[1], btn_coords.X[2], face_r, "X", btn_states.X, get_theme_val("x"), cscale)
    render_glow_circle(btn_coords.B[1], btn_coords.B[2], face_r, "B", btn_states.B, get_theme_val("b"), cscale)
    render_glow_circle(btn_coords.Y[1], btn_coords.Y[2], face_r, "Y", btn_states.Y, get_theme_val("y"), cscale)
    render_glow_circle(btn_coords.A[1], btn_coords.A[2], face_r, "A", btn_states.A, get_theme_val("a"), cscale)

    gfx.pop_origin()
end