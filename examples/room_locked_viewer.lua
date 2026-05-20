-- =============================================================================
-- Room Locked Viewer -- sni-lua Native High-Performance Overlay Script
-- =============================================================================
-- Features:
--   - Locks camera to show the whole room inside the canvas dynamically.
--   - Batch-reads WRAM tables using highly-efficient continuous memory watches.
--   - Prioritizes entities (Samus, Enemies, Sprites) at "realtime" tier.
--   - Implements a chunk-based prefetching caching system for room tiles.
--   - Tiles are read at "low" tier and unmodifiable chunks automatically go
--     dormant, saving substantial SNI link bandwidth during gameplay.
-- =============================================================================

local band, bor, bxor, bnot, lsh, rsh =
    bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift

-- Address wrapping helpers
local function cpuBankWrapAddress(p)
    return bor(band(p, 0xFF0000), band(p, 0xFFFF))
end

local function cpuBankWrappedOffsetAddress(p, offset)
    return bor(band(p, 0xFF0000), band(band(p, 0xFFFF) + offset, 0xFFFF))
end

-- Compatibility layer for bitwise ops
local xemu = {}
xemu.and_ = function(x, y) return band(x, y) end
xemu.or_  = function(x, y) return bor(x, y) end
xemu.xor  = function(x, y) return bxor(x, y) end
xemu.not_ = function(x)    return bnot(x) end
xemu.lshift = function(x, y) return lsh(x, y) end
xemu.rshift = function(x, y) return rsh(x, y) end

-- ---- Colors configuration (Premium Aesthetics) ----------------------------
local COL_SOLID       = 0xFF4A5A80
local FILL_SOLID      = 0x184A5A80

local COL_SLOPE       = 0xFF3CC47C
local FILL_SLOPE      = 0x223CC47C

local COL_SPIKE       = 0xFFFF4040
local FILL_SPIKE      = 0x22FF4040

local COL_DOOR        = 0xFF00D4FF
local FILL_DOOR       = 0x2000D4FF

local COL_MODIFIABLE  = 0xFFFFB200
local FILL_MODIFIABLE = 0x30FFB200

local COL_SPECIAL     = 0xFFD440FF
local FILL_SPECIAL    = 0x20D440FF

local COL_SAMUS       = 0xFF40D4FF
local FILL_SAMUS      = 0x3540D4FF

local COL_ENEMY       = 0xFFFF4040
local FILL_ENEMY      = 0x20FF4040

local COL_SPRITE      = 0xFFFF8000
local FILL_SPRITE     = 0x15FF8000

-- ---- Watches references -----------------------------------------------------
local room_pointer_watch = nil
local room_width_watch = nil
local room_height_watch = nil
local game_state_watch = nil

local samus_x_watch = nil
local samus_y_watch = nil
local samus_x_radius_watch = nil
local samus_y_radius_watch = nil

local n_enemies_watch = nil
local enemies_table_watch = nil

local sprite_ids_watch = nil
local sprite_xs_watch = nil
local sprite_ys_watch = nil

local slope_table_watch = nil

-- Fixed Pool for room map caching (100 chunks cover 12800 blocks max)
local CHUNK_SIZE = 128
local level_watches = {}
local bts_watches = {}

-- Local Room Cache State
local last_room_ptr = nil
local last_room_width = nil
local last_room_height = nil
local last_dynamic_canvas = nil
local room_level_data = {}
local room_bts_data = {}
local chunk_loaded = {}
local burst_frames_left = 0

-- Dynamic canvas aspect ratio calculation bounds
local function calculate_canvas_size(room_width, room_height)
    local room_ar = room_width / room_height

    -- Bounds for dynamic aspect ratio adjustment
    local max_w = 1200
    local max_h = 600
    local min_w = 400  -- Keep at least 400px wide to fit the dashboard and UI nicely
    local min_h = 300  -- Keep at least 300px high

    -- 1. Try to size to perfectly match room aspect ratio inside max bounds
    local canvas_w = max_w
    local canvas_h = math.floor(max_w / room_ar)

    if canvas_h > max_h then
        canvas_h = max_h
        canvas_w = math.floor(max_h * room_ar)
    end

    -- 2. Clamp to minimum bounds while preserving aspect ratio if possible, or allowing margins if we hit minimums
    if canvas_w < min_w then
        canvas_w = min_w
        canvas_h = math.min(max_h, math.floor(min_w / room_ar))
        canvas_h = math.max(canvas_h, min_h)
    end

    if canvas_h < min_h then
        canvas_h = min_h
        canvas_w = math.min(max_w, math.floor(min_h * room_ar))
        canvas_w = math.max(canvas_w, min_w)
    end

    return canvas_w, canvas_h
end

-- ---- Initialisation ---------------------------------------------------------
function on_init()
    gfx.canvas(864, 486) -- Request a beautiful 16:9 widescreen canvas (864x486 px) to maximize room view on widescreen setups
    
    ui.header("Room Locked Viewer Settings")
    ui.checkbox("dynamic_canvas", "Dynamic Widescreen Canvas", true)
    ui.checkbox("show_blocks", "Show Room Geometry", true)
    ui.checkbox("show_samus", "Show Samus Hitbox", true)
    ui.checkbox("show_enemies", "Show Enemy Hitboxes", true)
    ui.checkbox("enemy_show_hp", "  - Show Enemy HP Text", true)
    ui.checkbox("enemy_show_frozen", "  - Show Frozen Timers", true)
    ui.checkbox("enemy_show_inv", "  - Show Invincibility Timers", true)
    ui.checkbox("show_sprites", "Show Sprite Objects", true)
    ui.checkbox("show_hud", "Show Info Overlay Dashboard", true)
    ui.slider("padding", "Room Screen Padding", 4, 32, 10)
    ui.slider("line_thickness", "Block Border Thickness (0=none)", 0, 20, 8)
    
    print("Room Locked Viewer script loaded.")
    
    -- Realtime & high priority WRAM registers (Samus, viewport, controllers)
    room_pointer_watch = snes.watch(0x079B, 2, "realtime")
    room_width_watch   = snes.watch(0x07A5, 2, "normal")
    room_height_watch  = snes.watch(0x07A7, 2, "normal")
    game_state_watch   = snes.watch(0x0998, 2, "realtime")
    
    samus_x_watch        = snes.watch(0x0AF6, 2, "realtime")
    samus_y_watch        = snes.watch(0x0AFA, 2, "realtime")
    samus_x_radius_watch = snes.watch(0x0AFE, 2, "high")
    samus_y_radius_watch = snes.watch(0x0B00, 2, "high")
    
    n_enemies_watch     = snes.watch(0x0E4E, 2, "realtime")
    
    -- Continuously read the entire active enemy WRAM array in one single batch (768 bytes)
    enemies_table_watch = snes.watch(0x0F78, 768, "realtime")
    
    -- Sprite objects (32 slots)
    sprite_ids_watch = snes.watch(0x7EEF78, 64, "realtime")
    sprite_xs_watch  = snes.watch(0x7EF0F8, 64, "realtime")
    sprite_ys_watch  = snes.watch(0x7EF1F8, 64, "realtime")
    
    -- Slope ROM table (static 512 bytes starting at linear CPU offset 0x0A0B2B)
    slope_table_watch = snes.watch_abs(0x0A0B2B, 512, "low")
    
    -- Static pool of WRAM map watches covering level and BTS maps.
    -- Level WRAM map is at 0x7F0002 (offset 0x10002). Size of each chunk is 256 bytes (128 words).
    -- BTS WRAM map is at 0x7F6402 (offset 0x16402). Size of each chunk is 128 bytes.
    for c = 0, 99 do
        level_watches[c] = snes.watch(0x10002 + c * 256, 256, "low")
        bts_watches[c] = snes.watch(0x16402 + c * 128, 128, "low")
    end
    
    print("Static watch pools registered successfully.")
end

-- ---- Block Classification & Resolution --------------------------------------

local function resolve_block(block_index, room_width, level_data, bts_data, depth)
    depth = depth or 0
    if depth > 8 then return 0x00, 0 end -- prevent stack overflow on loops
    
    local level_datum = level_data[block_index]
    if not level_datum then return 0x00, 0 end
    
    local block_type = rsh(level_datum, 12)
    local bts = bts_data[block_index] or 0
    
    if block_type == 0x05 then
        -- Horizontal extension block. BTS is signed offset to source block.
        local offset = bts
        if offset >= 128 then offset = offset - 256 end
        if offset == 0 then return 0x00, 0 end
        return resolve_block(block_index + offset, room_width, level_data, bts_data, depth + 1)
    elseif block_type == 0x0D then
        -- Vertical extension block. BTS is signed vertical offset in rows.
        local offset = bts
        if offset >= 128 then offset = offset - 256 end
        if offset == 0 then return 0x00, 0 end
        return resolve_block(block_index + offset * room_width, room_width, level_data, bts_data, depth + 1)
    end
    
    return block_type, bts
end

local function is_modifiable_block(block_type)
    -- Block types modified by normal gameplay:
    --   0x03: Special Air (crumbles, item triggers)
    --   0x04: Shootable Air
    --   0x07: Bombable Air
    --   0x0C: Shootable Block (shot blocks, doorscap caps)
    --   0x0F: Bombable Block (bomb/power bomb blocks)
    if block_type == 0x03 or block_type == 0x04 or block_type == 0x07 or 
       block_type == 0x0C or block_type == 0x0F then
        return true
    end
    return false
end

-- ---- Main Render Loop -------------------------------------------------------

function on_frame()
    -- Read critical variables
    local room_ptr    = snes.u16(room_pointer_watch)
    local room_width  = snes.u16(room_width_watch)
    local room_height = snes.u16(room_height_watch)
    local game_state  = snes.u16(game_state_watch)
    
    if not room_ptr or not room_width or not room_height or room_width == 0 or room_height == 0 then
        -- Game is loading or in intro state
        gfx.text(8, 8, "Waiting for game active room pointer...")
        return
    end
    
    -- Retrieve dynamic canvas setting from UI
    local dynamic_canvas = ui.get("dynamic_canvas")
    if dynamic_canvas == nil then dynamic_canvas = true end
    
    local size_changed = false
    
    -- Room transition detection: clear cache if room pointer changes
    if room_ptr ~= last_room_ptr then
        room_level_data = {}
        room_bts_data   = {}
        chunk_loaded    = {}
        last_room_ptr   = room_ptr
        size_changed = true
        
        -- Trigger high-priority burst to quickly fetch the new room map
        burst_frames_left = 120
        for c = 0, 99 do
            if level_watches[c] and bts_watches[c] then
                snes.tier(level_watches[c], "high")
                snes.tier(bts_watches[c], "high")
            end
        end
        print(string.format("Entered Room: 0x%04X, Size: %dx%d blocks. Triggering high-priority prefetch burst...", room_ptr, room_width, room_height))
    end
    
    -- Track room size changes (which can occur shortly after room_ptr updates due to asynchronous watch updates)
    if room_width ~= last_room_width or room_height ~= last_room_height then
        last_room_width = room_width
        last_room_height = room_height
        size_changed = true
    end
    
    -- Track dynamic canvas setting toggle
    if dynamic_canvas ~= last_dynamic_canvas then
        last_dynamic_canvas = dynamic_canvas
        size_changed = true
    end
    
    -- Recalculate canvas size if any of the dimensions or settings changed
    if size_changed then
        local canvas_w, canvas_h
        if dynamic_canvas then
            canvas_w, canvas_h = calculate_canvas_size(room_width, room_height)
        else
            canvas_w, canvas_h = 864, 486
        end
        gfx.canvas(canvas_w, canvas_h)
        print(string.format("Canvas size adjusted to %dx%d (Dynamic Widescreen: %s)", canvas_w, canvas_h, tostring(dynamic_canvas)))
    end
    
    -- Only countdown the prefetch burst during active gameplay (game_state == 8)
    if game_state == 8 and burst_frames_left > 0 then
        burst_frames_left = burst_frames_left - 1
    end
    
    local N = room_width * room_height
    local num_active_chunks = math.min(100, math.ceil(N / CHUNK_SIZE))
    
    -- Prefetch level chunks
    for c = 0, num_active_chunks - 1 do
        if not chunk_loaded[c] and level_watches[c] and bts_watches[c] then
            -- Query active watches
            local level_bytes = snes.bytes(level_watches[c])
            local bts_bytes   = snes.bytes(bts_watches[c])
            
            if level_bytes and bts_bytes then
                local start_block = c * CHUNK_SIZE
                local num_blocks_in_chunk = math.min(CHUNK_SIZE, N - start_block)
                
                -- Parse and cache data
                for i = 0, num_blocks_in_chunk - 1 do
                    local b_idx = start_block + i
                    local lo = level_bytes[i * 2 + 1]
                    local hi = level_bytes[i * 2 + 2]
                    room_level_data[b_idx] = lo + hi * 256
                    room_bts_data[b_idx]   = bts_bytes[i + 1]
                end
                
                -- Only consider locking/dormancy once the burst has finished AND game state is active gameplay (0x08)
                if burst_frames_left == 0 and game_state == 8 then
                    -- Check if chunk contains modifiable blocks.
                    -- If it has absolutely none, we cache it permanently and STOP calling snes.bytes()!
                    -- This will make this chunk's watches go dormant automatically.
                    local has_modifiable = false
                    for i = 0, num_blocks_in_chunk - 1 do
                        local b_idx = start_block + i
                        local b_type = resolve_block(b_idx, room_width, room_level_data, room_bts_data)
                        if is_modifiable_block(b_type) then
                            has_modifiable = true
                            break
                        end
                    end
                    
                    if not has_modifiable then
                        chunk_loaded[c] = true
                        -- Demote static chunks to low priority so they go dormant in the background
                        snes.tier(level_watches[c], "low")
                        snes.tier(bts_watches[c], "low")
                    end
                end
            end
        end
    end
    
    -- Calculate metrics for GUI
    local num_dormant = 0
    for c = 0, num_active_chunks - 1 do
        if chunk_loaded[c] then
            num_dormant = num_dormant + 1
        end
    end
    local bandwidth_saved = 0
    if num_active_chunks > 0 then
        bandwidth_saved = math.floor((num_dormant / num_active_chunks) * 100)
    end
    
    -- ---- Dynamic Aspect-Ratio-Aware Viewport Math ----------------------------
    local CW = gfx.width()
    local CH = gfx.height()
    local RW_px = room_width * 16
    local RH_px = room_height * 16
    
    local pad = ui.get("padding") or 10
    local scale_x = (CW - pad * 2) / RW_px
    local scale_y = (CH - pad * 2) / RH_px
    local scale = math.min(scale_x, scale_y)
    
    local offset_x = pad + (CW - pad * 2 - RW_px * scale) / 2
    local offset_y = pad + (CH - pad * 2 - RH_px * scale) / 2
    
    local function to_canvas(x, y)
        return offset_x + x * scale, offset_y + y * scale
    end
    
    -- Dynamic Aspect-Ratio Scale-Aware Line Thickness calculation
    local line_mult = (ui.get("line_thickness") or 8) / 10
    local border_thickness = math.max(0.3, math.min(1.2, scale * 1.2)) * line_mult
    if line_mult == 0 then
        border_thickness = 0
    end
    
    -- ---- Render Geometry Blocks ---------------------------------------------
    if ui.get("show_blocks") then
        local slope_bytes = snes.bytes(slope_table_watch)
        
        for b_idx = 0, N - 1 do
            local level_datum = room_level_data[b_idx]
            if level_datum then
                local bx = (b_idx % room_width) * 16
                local by = math.floor(b_idx / room_width) * 16
                
                -- Resolve horizontal/vertical extensions recursively
                local r_type, r_bts = resolve_block(b_idx, room_width, room_level_data, room_bts_data)
                
                local cx1, cy1 = to_canvas(bx, by)
                local cx2, cy2 = to_canvas(bx + 16, by + 16)
                local cw = cx2 - cx1
                local ch = cy2 - cy1
                
                if r_type == 0x08 then
                    -- Solid geometry
                    gfx.box(cx1, cy1, cw, ch, COL_SOLID, FILL_SOLID, border_thickness)
                elseif r_type == 0x09 then
                    -- Transition / Door block
                    gfx.box(cx1, cy1, cw, ch, COL_DOOR, FILL_DOOR, border_thickness)
                elseif r_type == 0x0A then
                    -- Spikes
                    gfx.box(cx1, cy1, cw, ch, COL_SPIKE, FILL_SPIKE, border_thickness)
                elseif r_type == 0x0B then
                    -- Special unmodifiable
                    gfx.box(cx1, cy1, cw, ch, COL_SPECIAL, FILL_SPECIAL, border_thickness)
                elseif r_type == 0x0C or r_type == 0x0F or r_type == 0x0E then
                    -- Modifiable blocks (shot blocks, bomb blocks, grapple blocks)
                    gfx.box(cx1, cy1, cw, ch, COL_MODIFIABLE, FILL_MODIFIABLE, border_thickness)
                elseif r_type == 0x03 or r_type == 0x04 or r_type == 0x07 then
                    -- Special air (crumbles, shootable air)
                    gfx.box(cx1, cy1, cw, ch, COL_MODIFIABLE, FILL_MODIFIABLE, border_thickness)
                elseif r_type == 0x01 and slope_bytes then
                    -- Slope Block: Render beautiful aspect-ratio scaled slope polygons
                    local i_slope = band(r_bts, 0x1F)
                    local flip_x  = band(r_bts, 0x40) ~= 0
                    local flip_y  = band(r_bts, 0x80) ~= 0
                    
                    local p_slope_offset = i_slope * 16
                    local ys = {}
                    local has_collision = false
                    for x = 0, 15 do
                        local val = slope_bytes[p_slope_offset + x + 1] or 0
                        ys[x] = val
                        if val <= 16 then has_collision = true end
                    end
                    
                    if has_collision then
                        local surface_pts = {}
                        local y_base = flip_y and 0 or 16
                        for x = 0, 15 do
                            local orig_x = flip_x and (15 - x) or x
                            local sy = ys[orig_x]
                            if sy > 16 then
                                sy = y_base
                            else
                                if flip_y then sy = 16 - sy end
                            end
                            table.insert(surface_pts, { bx + x, by + sy })
                        end
                        
                        local last_orig_x = flip_x and 0 or 15
                        local last_sy = ys[last_orig_x]
                        if last_sy > 16 then
                            last_sy = y_base
                        else
                            if flip_y then last_sy = 16 - last_sy end
                        end
                        table.insert(surface_pts, { bx + 16, by + last_sy })
                        
                        -- Build scaled base polygon points
                        local pts = {}
                        table.insert(pts, { bx, by + y_base })
                        for _, pt in ipairs(surface_pts) do table.insert(pts, pt) end
                        table.insert(pts, { bx + 16, by + y_base })
                        
                        local scaled_pts = {}
                        for _, pt in ipairs(pts) do
                            local scx, scy = to_canvas(pt[1], pt[2])
                            table.insert(scaled_pts, { scx, scy })
                        end
                        
                        local scaled_surface_pts = {}
                        for _, pt in ipairs(surface_pts) do
                            local scx, scy = to_canvas(pt[1], pt[2])
                            table.insert(scaled_surface_pts, { scx, scy })
                        end
                        
                        -- Draw slope fill + surface lines
                        gfx.poly(scaled_pts, 0, FILL_SLOPE, 0, true)
                        gfx.poly(scaled_surface_pts, COL_SLOPE, 0, border_thickness, false)
                        
                        -- Draw vertical support walls
                        local sy0 = surface_pts[1][2] - by
                        local sy16 = surface_pts[17][2] - by
                        if not flip_y then
                            if sy0 < 16 then
                                local wx, wy1 = to_canvas(bx, by + 16)
                                local _, wy2 = to_canvas(bx, by + sy0)
                                gfx.line(wx, wy1, wx, wy2, COL_SLOPE, border_thickness)
                            end
                            if sy16 < 16 then
                                local wx, wy1 = to_canvas(bx + 16, by + 16)
                                local _, wy2 = to_canvas(bx + 16, by + sy16)
                                gfx.line(wx, wy1, wx, wy2, COL_SLOPE, border_thickness)
                            end
                        else
                            if sy0 > 0 then
                                local wx, wy1 = to_canvas(bx, by)
                                local _, wy2 = to_canvas(bx, by + sy0)
                                gfx.line(wx, wy1, wx, wy2, COL_SLOPE, border_thickness)
                            end
                            if sy16 > 0 then
                                local wx, wy1 = to_canvas(bx + 16, by)
                                local _, wy2 = to_canvas(bx + 16, by + sy16)
                                gfx.line(wx, wy1, wx, wy2, COL_SLOPE, border_thickness)
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- ---- Render Samus Player Hitbox ------------------------------------------
    if ui.get("show_samus") then
        local samus_x     = snes.u16(samus_x_watch)
        local samus_y     = snes.u16(samus_y_watch)
        local samus_x_rad = snes.u16(samus_x_radius_watch) or 8
        local samus_y_rad = snes.u16(samus_y_radius_watch) or 16
        
        if samus_x and samus_y then
            local left   = samus_x - samus_x_rad
            local right  = samus_x + samus_x_rad
            local top    = samus_y - samus_y_rad
            local bottom = samus_y + samus_y_rad
            
            local cx1, cy1 = to_canvas(left, top)
            local cx2, cy2 = to_canvas(right, bottom)
            
            gfx.box(cx1, cy1, cx2 - cx1, cy2 - cy1, COL_SAMUS, FILL_SAMUS, border_thickness * 1.5)
            
            -- Samus center crosshair
            local ccx, ccy = to_canvas(samus_x, samus_y)
            gfx.line(ccx - 4, ccy, ccx + 4, ccy, COL_SAMUS, border_thickness)
            gfx.line(ccx, ccy - 4, ccx, ccy + 4, COL_SAMUS, border_thickness)
        end
    end
    
    -- ---- Render Enemies (Batch watched array) -------------------------------
    if ui.get("show_enemies") then
        local n_enemies   = snes.u16(n_enemies_watch) or 0
        local enemy_bytes = snes.bytes(enemies_table_watch)
        
        if n_enemies > 0 and enemy_bytes then
            for i = 0, math.min(n_enemies, 12) - 1 do
                local offset = i * 64
                local enemy_id = enemy_bytes[offset + 1] + enemy_bytes[offset + 2] * 256
                
                if enemy_id ~= 0 then
                    local enemy_x = enemy_bytes[offset + 3] + enemy_bytes[offset + 4] * 256
                    local enemy_y = enemy_bytes[offset + 7] + enemy_bytes[offset + 8] * 256
                    local enemy_x_rad = enemy_bytes[offset + 11] + enemy_bytes[offset + 12] * 256
                    local enemy_y_rad = enemy_bytes[offset + 13] + enemy_bytes[offset + 14] * 256
                    local enemy_hp = enemy_bytes[offset + 21] + enemy_bytes[offset + 22] * 256
                    
                    local left   = enemy_x - enemy_x_rad
                    local right  = enemy_x + enemy_x_rad
                    local top    = enemy_y - enemy_y_rad
                    local bottom = enemy_y + enemy_y_rad
                    
                    local cx1, cy1 = to_canvas(left, top)
                    local cx2, cy2 = to_canvas(right, bottom)
                    local cw = cx2 - cx1
                    local ch = cy2 - cy1
                    
                    -- Enemy bounding box
                    gfx.box(cx1, cy1, cw, ch, COL_ENEMY, FILL_ENEMY, border_thickness)
                    
                    -- Small health indicator overlay
                    if enemy_hp > 0 and cw > 6 then
                        gfx.box(cx1, cy1 - 3, cw, 2, 0x80900000, 0x80900000, border_thickness)
                        gfx.box(cx1, cy1 - 3, cw, 2, 0xFFFF4040, 0xFFFF4040, border_thickness)
                    end
                    
                    -- Optional detailed numerical HP tags (drawn above box)
                    if ui.get("enemy_show_hp") and enemy_hp > 0 then
                        local hp_text = string.format("%d HP", enemy_hp)
                        gfx.text(cx1 + cw / 2, cy1 - 12, hp_text, 0xFF40FF40, { align = "center", valign = "bottom", outline = 0xFF000000, scale = 0.75 })
                    end
                    
                    -- Optional frozen status timer (drawn below box)
                    local enemy_frozen_timer = enemy_bytes[offset + 39] + enemy_bytes[offset + 40] * 256
                    if ui.get("enemy_show_frozen") and enemy_frozen_timer > 0 then
                        local frz_text = string.format("[FRZ:%df]", enemy_frozen_timer)
                        gfx.text(cx1 + cw / 2, cy2 + 2, frz_text, 0xFF40D4FF, { align = "center", valign = "top", outline = 0xFF000000, scale = 0.75 })
                    end
                    
                    -- Optional invincibility timer (drawn below box after frozen timer)
                    local enemy_inv = enemy_bytes[offset + 37] + enemy_bytes[offset + 38] * 256
                    if ui.get("enemy_show_inv") and enemy_inv > 0 then
                        local y_offset = enemy_frozen_timer > 0 and 12 or 2
                        local inv_text = string.format("[INV:%df]", enemy_inv)
                        gfx.text(cx1 + cw / 2, cy2 + y_offset, inv_text, 0xFFFFB200, { align = "center", valign = "top", outline = 0xFF000000, scale = 0.75 })
                    end
                    
                    -- Draw enemy identifier index
                    local ccx, ccy = to_canvas(enemy_x, enemy_y)
                    gfx.text(ccx, ccy, tostring(i), COL_ENEMY, { align = "center", valign = "middle", outline = 0xFF000000 })
                end
            end
        end
    end
    
    -- ---- Render Sprites (Particles / dynamic items) --------------------------
    if ui.get("show_sprites") then
        local sprite_ids = snes.bytes(sprite_ids_watch)
        local sprite_xs  = snes.bytes(sprite_xs_watch)
        local sprite_ys  = snes.bytes(sprite_ys_watch)
        
        if sprite_ids and sprite_xs and sprite_ys then
            for i = 0, 31 do
                local id = sprite_ids[i * 2 + 1] + sprite_ids[i * 2 + 2] * 256
                if id ~= 0 then
                    local sx = sprite_xs[i * 2 + 1] + sprite_xs[i * 2 + 2] * 256
                    local sy = sprite_ys[i * 2 + 1] + sprite_ys[i * 2 + 2] * 256
                    
                    -- Standard sprite dimensions (8x8 px)
                    local cx1, cy1 = to_canvas(sx - 4, sy - 4)
                    local cx2, cy2 = to_canvas(sx + 4, sy + 4)
                    
                    gfx.box(cx1, cy1, cx2 - cx1, cy2 - cy1, COL_SPRITE, FILL_SPRITE, border_thickness)
                    
                    local ccx, ccy = to_canvas(sx, sy)
                    gfx.text(ccx, ccy, tostring(i), COL_SPRITE, { align = "center", valign = "middle", outline = 0xFF000000, scale = 0.8 })
                end
            end
        end
    end
    
    -- ---- Statistics Info Dashboard ------------------------------------------
    if ui.get("show_hud") then
        local sprite_ids = snes.bytes(sprite_ids_watch)
        local n_sprites = 0
        if sprite_ids then
            for i = 0, 31 do
                local id = sprite_ids[i * 2 + 1] + sprite_ids[i * 2 + 2] * 256
                if id ~= 0 then
                    n_sprites = n_sprites + 1
                end
            end
        end
        
        -- Floating Compact Dashboard panel design (150x42 px)
        gfx.round_rect(10, 10, 150, 42, 4, 0x80506080, 0xC0101018, 1, { shadow = true })
        
        gfx.font("small")
        gfx.text(16, 15, string.format("Room: 0x%04X", room_ptr), 0xFFFFFFFF)
        gfx.text(16, 27, string.format("Sprites: %d / 32", n_sprites), 0xFFFFFFFF)
        
        -- Tiny status indicator badge on the top right of the box
        local eff_color = 0xFF40FF40
        if bandwidth_saved < 50 then eff_color = 0xFFFFB200 end
        
        if burst_frames_left > 0 then
            gfx.text(102, 15, "PF (" .. tostring(burst_frames_left) .. ")", 0xFF00D4FF)
        else
            gfx.text(102, 15, tostring(bandwidth_saved) .. "% D", eff_color)
        end
    end
end
