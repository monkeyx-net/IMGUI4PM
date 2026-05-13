-- main.lua – Portmaster Game Launcher (Love2D port of IMGUI4PM)

-- ── Palette ────────────────────────────────────────────────────────────────
local C_GREEN  = {0.29, 0.96, 0.15, 1}
local C_DIM    = {0.55, 0.55, 0.55, 1}
local C_BTN    = {0.08, 0.20, 0.06, 1}
local C_BTN_HV = {0.14, 0.35, 0.10, 1}
local C_BTN_PR = {0.04, 0.10, 0.03, 1}
local C_TITLE  = {0.05, 0.10, 0.05, 1}
local C_SEP    = {0.20, 0.60, 0.10, 0.40}

-- ── Layout dimensions ──────────────────────────────────────────────────────
-- All computed in love.load() relative to screen size (see init_layout).
-- Declared here so every function can see them as upvalues.
local SIDEBAR_W, BTN_W, BTN_H, PAD, FONT_SIZE, TAB_H
local OCT_BTN_W, OCT_NUM_W, OCT_H

-- ── Runtime state ──────────────────────────────────────────────────────────
local SW, SH
local font_norm, font_h1, font_h2
local bg_image, bg_quad, screenshot_image
local shoot_sound

local show_ip_window = false
local game_title     = ""
local max_players    = 4
local num_players    = 4
local desc_scroll    = 0
local ip_scroll      = 0
local player_name    = ""
local name_focused   = false

-- On-screen keyboard
local show_keyboard = false
local kb_row = 0    -- 0-indexed selected row
local kb_col = 0    -- 0-indexed selected column
local kb_shift = false  -- false = lowercase output, true = uppercase

local KB_ROWS = {
    {"Q","W","E","R","T","Y","U","I","O","P"},
    {"A","S","D","F","G","H","J","K","L"},
    {"Z","X","C","V","B","N","M"},
}
local KB_SPECIAL = {"SHIFT","SPACE","BKSP","DONE"}  -- bottom row
local KB_NUM_ROWS = #KB_ROWS + 1  -- 3 letter + 1 special

local KBW, KBH, KBGX, KBGY, KB_TOP  -- computed in love.load

-- IP data: index 0=server, 1-4=clients
local ip_current = {
    [0]={127,0,0,1}, [1]={127,0,0,2},
    [2]={127,0,0,3}, [3]={127,0,0,4},
    [4]={127,0,0,5},
}
-- Original string values loaded from config for display (1=server, 2-5=clients)
local ip_saved = {"127.0.0.1","127.0.0.2","127.0.0.3","127.0.0.4","127.0.0.5"}

local readme_md = {}
local instr_md  = {}
local config_path = ""

-- Immediate-mode click tracking
local mouse_pressed_now = false
local last_mouse_down   = false
local click_consumed    = false

-- Gamepad / keyboard focus navigation (suspended when on-screen keyboard is active)
local focus_idx  = 1   -- which focusable element is selected
local focus_max  = 0   -- total registered this frame (set at end of draw)
local focus_reg  = 0   -- counter reset at start of each draw frame
local gamepad_a_now  = false   -- true for one frame on first press of A or Enter
local last_gamepad_a = false
local a_consumed     = false   -- like click_consumed but for A / Enter
local enter_pending  = false   -- set by keypressed, consumed in update

-- ── Utility ────────────────────────────────────────────────────────────────

local function ip_str(arr)
    return arr[1].."."..arr[2].."."..arr[3].."."..arr[4]
end

local function parse_ip(s, arr)
    local i = 1
    for n in s:gmatch("[^.]+") do
        arr[i] = math.max(0, math.min(255, tonumber(n) or 0))
        i = i + 1
        if i > 4 then break end
    end
end

local function read_config(path)
    local f = io.open(path, "r")
    if not f then return end
    local key_to_idx = {server1_ip=0, client1_ip=1, client2_ip=2, client3_ip=3, client4_ip=4}
    local idx_to_saved = {[0]=1,[1]=2,[2]=3,[3]=4,[4]=5}
    for line in f:lines() do
        local k, v = line:match("^([^=]+)=(.+)$")
        if k and v then
            if k == "player_name" then
                player_name = v
            else
                local idx = key_to_idx[k]
                if idx ~= nil then
                    parse_ip(v, ip_current[idx])
                    ip_saved[idx_to_saved[idx]] = v
                end
            end
        end
    end
    f:close()
end

local function write_config(path)
    local f = io.open(path, "w")
    if not f then return end
    f:write("player_name=" .. player_name .. "\n")
    f:write("server1_ip=" .. ip_str(ip_current[0]) .. "\n")
    for i = 1, 4 do
        f:write("client"..i.."_ip=" .. ip_str(ip_current[i]) .. "\n")
    end
    f:close()
end

local function parse_md(text)
    local out = {}
    for line in (text.."\n"):gmatch("([^\n]*)\n") do
        if     line:match("^# ")   then out[#out+1] = {t="h1", s=line:sub(3)}
        elseif line:match("^## ")  then out[#out+1] = {t="h2", s=line:sub(4)}
        elseif line:match("^### ") then out[#out+1] = {t="h3", s=line:sub(5)}
        elseif line == ""          then out[#out+1] = {t="br"}
        else                            out[#out+1] = {t="p",  s=line}
        end
    end
    return out
end

local function play_ui_sound()
    if shoot_sound then
        local src = shoot_sound:clone()
        src:setVolume(1)
        love.audio.play(src)
    end
end

local function parse_cli_args()
    for i = 1, #arg do
        local a = arg[i]
        if (a == "-p" or a == "--players") and arg[i+1] then
            local p = tonumber(arg[i+1])
            if p and p >= 0 and p <= 4 then
                max_players = p
                num_players = p
            end
        elseif (a == "-t" or a == "--title") and arg[i+1] then
            game_title = arg[i+1]
        end
    end
end

-- ── On-screen keyboard helpers ─────────────────────────────────────────────

local function kb_get_key()
    if kb_row < #KB_ROWS then
        return KB_ROWS[kb_row + 1][kb_col + 1]
    else
        return KB_SPECIAL[kb_col + 1]
    end
end

local function kb_row_len(row)
    if row < #KB_ROWS then return #KB_ROWS[row + 1] end
    return #KB_SPECIAL
end

local function kb_press(key)
    if key == "DONE" then
        show_keyboard = false
        name_focused = false
    elseif key == "BKSP" then
        player_name = player_name:sub(1, -2)
    elseif key == "SHIFT" then
        kb_shift = not kb_shift
    elseif key == "SPACE" then
        player_name = player_name .. " "
    else
        player_name = player_name .. (kb_shift and key or key:lower())
    end
end

local function kb_move(dr, dc)
    kb_row = (kb_row + dr) % KB_NUM_ROWS
    kb_col = math.min(kb_col, kb_row_len(kb_row) - 1)
    if dc ~= 0 then
        local len = kb_row_len(kb_row)
        kb_col = (kb_col + dc + len) % len
    end
end

-- Returns this element's focus ID (0 = not participating, e.g. keyboard active)
local function next_fid()
    if show_keyboard then return 0 end
    focus_reg = focus_reg + 1
    return focus_reg
end

-- ── UI primitives ──────────────────────────────────────────────────────────

local function rect(x, y, w, h, c, mode)
    love.graphics.setColor(c)
    love.graphics.rectangle(mode or "fill", x, y, w, h)
end

local function hovered(x, y, w, h)
    local mx, my = love.mouse.getPosition()
    return mx >= x and mx < x+w and my >= y and my < y+h
end

local C_FOCUS = {1, 0.9, 0, 1}  -- yellow highlight for gamepad-focused element

-- Draw a button; returns true on the frame it is activated (click or gamepad A)
local function btn(label, x, y, w, h)
    local fid = next_fid()
    local foc = fid > 0 and fid == focus_idx
    local hov = hovered(x, y, w, h) or foc
    local clk = (hov and mouse_pressed_now and not click_consumed) or
                (foc and gamepad_a_now and not a_consumed)
    rect(x, y, w, h, clk and C_BTN_PR or (hov and C_BTN_HV or C_BTN))
    rect(x, y, w, h, foc and C_FOCUS or C_GREEN, "line")
    love.graphics.setFont(font_norm)
    love.graphics.setColor(foc and C_FOCUS or C_GREEN)
    local tw = font_norm:getWidth(label)
    local th = font_norm:getHeight()
    love.graphics.print(label, x + (w-tw)/2, y + (h-th)/2)
    if clk then
        if mouse_pressed_now then click_consumed = true end
        if gamepad_a_now     then a_consumed     = true end
        return true
    end
    return false
end

-- Compact button (same logic, lighter visual weight)
local function sbtn(label, x, y, w, h)
    local fid = next_fid()
    local foc = fid > 0 and fid == focus_idx
    local hov = hovered(x, y, w, h) or foc
    local clk = (hov and mouse_pressed_now and not click_consumed) or
                (foc and gamepad_a_now and not a_consumed)
    rect(x, y, w, h, clk and C_BTN_PR or (hov and C_BTN_HV or C_BTN))
    rect(x, y, w, h, foc and C_FOCUS or C_GREEN, "line")
    love.graphics.setFont(font_norm)
    love.graphics.setColor(foc and C_FOCUS or C_GREEN)
    local tw = font_norm:getWidth(label)
    local th = font_norm:getHeight()
    love.graphics.print(label, x + (w-tw)/2, y + (h-th)/2)
    if clk then
        if mouse_pressed_now then click_consumed = true end
        if gamepad_a_now     then a_consumed     = true end
        return true
    end
    return false
end

-- ── Markdown renderer ──────────────────────────────────────────────────────

local function draw_md(parsed, x, y, w)
    local cy = y
    for _, item in ipairs(parsed) do
        if item.t == "br" then
            cy = cy + font_norm:getHeight() * 0.5
        elseif item.t == "h1" then
            love.graphics.setFont(font_h1)
            love.graphics.setColor(C_GREEN)
            love.graphics.print(item.s, x, cy)
            cy = cy + font_h1:getHeight() + 6
        elseif item.t == "h2" then
            love.graphics.setFont(font_h2)
            love.graphics.setColor(C_DIM)
            love.graphics.print(item.s, x, cy)
            cy = cy + font_h2:getHeight() + 4
        elseif item.t == "h3" then
            love.graphics.setFont(font_h2)
            love.graphics.setColor(C_GREEN)
            love.graphics.print(item.s, x, cy)
            cy = cy + font_h2:getHeight() + 4
        else
            love.graphics.setFont(font_norm)
            love.graphics.setColor(C_GREEN)
            local _, lines = font_norm:getWrap(item.s, w)
            for _, ln in ipairs(lines) do
                love.graphics.print(ln, x, cy)
                cy = cy + font_norm:getHeight() + 2
            end
        end
    end
    return cy
end

-- ── IP row widget ──────────────────────────────────────────────────────────

-- Four-octet row with < > buttons; returns y below the row
local function ip_row(arr, label, x, y)
    love.graphics.setFont(font_norm)
    love.graphics.setColor(C_GREEN)
    love.graphics.print(label..":", x, y + (OCT_H - font_norm:getHeight())/2)
    local cx = x + font_norm:getWidth(label..":") + 12

    for oct = 1, 4 do
        if oct > 1 then
            love.graphics.setColor(C_GREEN)
            love.graphics.print(".", cx, y + (OCT_H - font_norm:getHeight())/2)
            cx = cx + font_norm:getWidth(".") + 2
        end
        -- Decrement
        if sbtn("<", cx, y, OCT_BTN_W, OCT_H) then
            arr[oct] = math.max(0, arr[oct] - 1)
        end
        cx = cx + OCT_BTN_W
        -- Value display
        rect(cx, y, OCT_NUM_W, OCT_H, {0.04, 0.08, 0.03, 1})
        rect(cx, y, OCT_NUM_W, OCT_H, C_GREEN, "line")
        love.graphics.setColor(C_GREEN)
        local ns = tostring(arr[oct])
        love.graphics.print(ns, cx + (OCT_NUM_W - font_norm:getWidth(ns))/2,
                                 y  + (OCT_H    - font_norm:getHeight())/2)
        cx = cx + OCT_NUM_W
        -- Increment
        if sbtn(">", cx, y, OCT_BTN_W, OCT_H) then
            arr[oct] = math.min(255, arr[oct] + 1)
        end
        cx = cx + OCT_BTN_W + 6
    end
    return y + OCT_H + 8
end

-- ── Main window ────────────────────────────────────────────────────────────

local function draw_main()
    local title_h = 30
    rect(0, 0, SW, title_h, C_TITLE)
    love.graphics.setFont(font_norm)
    love.graphics.setColor(C_GREEN)
    local ttl = "Portmaster - Game Launcher"
    if game_title ~= "" then ttl = ttl .. " - " .. game_title end
    love.graphics.print(ttl, PAD, (title_h - font_norm:getHeight())/2)

    -- Sidebar
    local sy = title_h
    rect(0, sy, SIDEBAR_W, SH-sy, {0.04, 0.07, 0.04, 0.90})
    rect(0, sy, SIDEBAR_W, SH-sy, C_GREEN, "line")

    local bx = (SIDEBAR_W - BTN_W) / 2
    if btn("Start Game", bx, sy+PAD, BTN_W, BTN_H) then
        os.exit(0)
    end
    if btn("Game Options", bx, sy+PAD*2+BTN_H, BTN_W, BTN_H) then
        show_ip_window = true
        focus_idx = 1
    end

    -- Right panel
    local rx = SIDEBAR_W + 2
    local ry = title_h
    local rw = SW - rx
    local rh = SH - ry
    rect(rx, ry, rw, rh, {0.02, 0.04, 0.02, 0.88})

    -- Tab strip
    rect(rx, ry, rw, TAB_H, {0.06, 0.10, 0.05, 1})
    rect(rx, ry, 130, TAB_H, {0.10, 0.18, 0.08, 1})
    rect(rx, ry, 130, TAB_H, C_GREEN, "line")
    love.graphics.setFont(font_norm)
    love.graphics.setColor(C_GREEN)
    love.graphics.print("Description", rx+12, ry + (TAB_H - font_norm:getHeight())/2)

    -- Scrollable content
    local cx = rx + PAD
    local cy_top = ry + TAB_H
    local cw = rw - PAD*2
    love.graphics.setScissor(rx, cy_top, rw, rh - TAB_H)

    local y = cy_top + PAD - desc_scroll

    if screenshot_image then
        local iw = screenshot_image:getWidth()
        local ih = screenshot_image:getHeight()
        local scale = math.min(1, (cw * 0.5) / iw, ((rh - TAB_H) * 0.35) / ih)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(screenshot_image, cx, y, 0, scale, scale)
        y = y + ih * scale + PAD
    end

    draw_md(readme_md, cx, y, cw)
    love.graphics.setScissor()
end

-- ── On-screen keyboard ─────────────────────────────────────────────────────

local function draw_keyboard()
    local panel_h = SH - KB_TOP
    rect(0, KB_TOP, SW, panel_h, {0.02, 0.05, 0.02, 0.97})
    -- Top border
    love.graphics.setColor(C_GREEN)
    love.graphics.rectangle("fill", 0, KB_TOP, SW, 2)

    -- Current name preview
    love.graphics.setFont(font_norm)
    local ny = KB_TOP + PAD
    love.graphics.setColor(C_DIM)
    love.graphics.print("Name:", PAD * 3, ny)
    love.graphics.setColor(C_GREEN)
    local cursor = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or " "
    local preview_x = PAD * 3 + font_norm:getWidth("Name:") + 8
    local preview_w = SW - preview_x - PAD * 3
    love.graphics.setScissor(preview_x, ny, preview_w, font_norm:getHeight() + 2)
    love.graphics.print(player_name .. cursor, preview_x, ny)
    love.graphics.setScissor()

    -- Helper: draw one key, return true if mouse-clicked this frame
    local function key_btn(label, kx, ky, kw, is_sel)
        local hov = is_sel or hovered(kx, ky, kw, KBH)
        local clk = hov and mouse_pressed_now and not click_consumed
        local bg  = clk and C_BTN_PR or (hov and C_BTN_HV or C_BTN)
        rect(kx, ky, kw, KBH, bg)
        rect(kx, ky, kw, KBH, is_sel and {1, 0.9, 0, 1} or C_GREEN, "line")
        love.graphics.setFont(font_norm)
        love.graphics.setColor(is_sel and {1, 0.9, 0, 1} or C_GREEN)
        love.graphics.print(label,
            kx + (kw - font_norm:getWidth(label)) / 2,
            ky + (KBH - font_norm:getHeight()) / 2)
        if clk then click_consumed = true; return true end
        return false
    end

    -- Letter rows
    local ky = KB_TOP + PAD + font_norm:getHeight() + PAD * 2
    for ri, row in ipairs(KB_ROWS) do
        local row_w = #row * KBW + (#row - 1) * KBGX
        local rx = math.floor((SW - row_w) / 2)
        for ci, letter in ipairs(row) do
            local lbl = kb_shift and letter or letter:lower()
            local kx  = rx + (ci - 1) * (KBW + KBGX)
            if key_btn(lbl, kx, ky, KBW, kb_row == ri-1 and kb_col == ci-1) then
                kb_press(letter)
            end
        end
        ky = ky + KBH + KBGY
    end

    -- Special row: SHIFT  [     SPACE     ]  BKSP  DONE
    -- Widths in key-unit multiples so the row spans the same total as 10-key rows.
    local shift_w = 2 * KBW + KBGX
    local bksp_w  = 2 * KBW + KBGX
    local done_w  = 2 * KBW + KBGX
    local space_w = 4 * KBW + 3 * KBGX
    local sp_total = shift_w + KBGX + space_w + KBGX + bksp_w + KBGX + done_w
    local rx = math.floor((SW - sp_total) / 2)

    local sp_keys  = {"SHIFT",               "SPACE", "BKSP", "DONE"}
    local sp_lbls  = {kb_shift and "ABC" or "abc", "SPACE", "<--",  "DONE"}
    local sp_ws    = {shift_w, space_w, bksp_w, done_w}

    for ci, key in ipairs(sp_keys) do
        if key_btn(sp_lbls[ci], rx, ky, sp_ws[ci],
                   kb_row == #KB_ROWS and kb_col == ci-1) then
            kb_press(key)
        end
        rx = rx + sp_ws[ci] + KBGX
    end
end

-- ── IP config window ───────────────────────────────────────────────────────

local function draw_ip_win()
    rect(0, 0, SW, SH, {0, 0, 0, 0.92})
    local title_h = 30
    rect(0, 0, SW, title_h, C_TITLE)
    love.graphics.setFont(font_norm)
    love.graphics.setColor(C_GREEN)
    love.graphics.print("Change IP Address", PAD, (title_h - font_norm:getHeight())/2)

    local btn_area_h = BTN_H + PAD*2
    local clip_top = title_h
    local clip_h   = SH - clip_top - btn_area_h
    local cx = PAD * 3
    local cw = SW - cx * 2

    love.graphics.setScissor(0, clip_top, SW, clip_h)
    local y = clip_top + PAD - ip_scroll

    -- Game title heading
    if game_title ~= "" then
        love.graphics.setFont(font_h1)
        love.graphics.setColor(C_GREEN)
        love.graphics.print(game_title, cx, y)
        y = y + font_h1:getHeight() + PAD
    end

    -- Name text box
    local name_label = "Name:"
    love.graphics.setFont(font_norm)
    love.graphics.setColor(C_GREEN)
    love.graphics.print(name_label, cx, y + (OCT_H - font_norm:getHeight())/2)
    local nlx = cx + font_norm:getWidth(name_label) + 10
    local nlw = math.floor(SW * 0.30)
    -- Register for gamepad focus
    local name_fid = next_fid()
    local name_gp  = name_fid > 0 and name_fid == focus_idx
    -- Activate via mouse click
    if mouse_pressed_now then
        if hovered(nlx, y, nlw, OCT_H) and not click_consumed then
            name_focused = true
            show_keyboard = true
            click_consumed = true
        elseif not (show_keyboard and hovered(0, KB_TOP, SW, SH - KB_TOP)) then
            name_focused = false
            show_keyboard = false
        end
    end
    -- Activate via gamepad A
    if name_gp and gamepad_a_now and not a_consumed then
        name_focused = true
        show_keyboard = true
        a_consumed = true
    end
    rect(nlx, y, nlw, OCT_H, {0.04, 0.08, 0.03, 1})
    rect(nlx, y, nlw, OCT_H,
         name_focused and C_GREEN or (name_gp and C_FOCUS or C_DIM), "line")
    love.graphics.setColor(C_GREEN)
    local cursor = name_focused and (math.floor(love.timer.getTime() * 2) % 2 == 0 and "|" or " ") or ""
    love.graphics.setScissor(nlx + 2, math.max(clip_top, y), nlw - 4, OCT_H)
    love.graphics.print(player_name .. cursor, nlx + 4, y + (OCT_H - font_norm:getHeight())/2)
    love.graphics.setScissor(0, clip_top, SW, clip_h)
    y = y + OCT_H + PAD * 2

    -- Instructions
    y = draw_md(instr_md, cx, y, cw) + PAD

    -- Separator
    rect(cx, y, cw, 1, C_SEP)
    y = y + PAD

    -- Number of players spinner
    love.graphics.setFont(font_norm)
    love.graphics.setColor(C_GREEN)
    love.graphics.print("Number of Players:", cx, y + (OCT_H - font_norm:getHeight())/2)
    local px = cx + font_norm:getWidth("Number of Players:") + 12

    if sbtn("<", px, y, OCT_BTN_W, OCT_H) then
        num_players = math.max(0, num_players - 1)
        play_ui_sound()
    end
    px = px + OCT_BTN_W + 4

    rect(px, y, OCT_NUM_W, OCT_H, {0.04, 0.08, 0.03, 1})
    rect(px, y, OCT_NUM_W, OCT_H, C_GREEN, "line")
    love.graphics.setColor(C_GREEN)
    local ns = tostring(num_players)
    love.graphics.print(ns, px + (OCT_NUM_W - font_norm:getWidth(ns))/2,
                             y  + (OCT_H    - font_norm:getHeight())/2)
    px = px + OCT_NUM_W + 4

    if sbtn(">", px, y, OCT_BTN_W, OCT_H) then
        num_players = math.min(max_players, num_players + 1)
        play_ui_sound()
    end
    y = y + OCT_H + PAD*2

    -- IP rows
    if num_players == 0 then
        love.graphics.setFont(font_norm)
        love.graphics.setColor(C_DIM)
        love.graphics.print("Currently set Server IP: " .. ip_saved[1], cx, y)
        y = y + font_norm:getHeight() + 4
        y = ip_row(ip_current[0], "Server IP", cx, y)
    end

    for p = 1, num_players do
        rect(cx, y, cw, 1, C_SEP)
        y = y + PAD
        love.graphics.setFont(font_norm)
        love.graphics.setColor(C_DIM)
        love.graphics.print("Currently set Player "..p.." IP: "..(ip_saved[p+1] or ""), cx, y)
        y = y + font_norm:getHeight() + 4
        y = ip_row(ip_current[p], "Player "..p.." IP", cx, y)
    end

    love.graphics.setScissor()

    -- Action buttons pinned to bottom
    local by = SH - BTN_H - PAD
    if btn("Save IP Address & Start Game", PAD, by, 350, BTN_H) then
        write_config(config_path)
        os.exit(120 + num_players)
    end
    if btn("Close and no Save", PAD + 350 + PAD, by, 200, BTN_H) then
        show_ip_window = false
        name_focused   = false
        show_keyboard  = false
        focus_idx      = 1
    end
end

-- ── Love2D callbacks ───────────────────────────────────────────────────────

function love.load()
    SW, SH = love.graphics.getDimensions()

    -- Scale all UI dimensions to the screen.
    -- Reference resolution: 1280x720.  Everything is proportional to height.
    do
        local s = math.min(1.2, SH / 720)  -- cap growth at 1.2× above 720p
        FONT_SIZE = math.max(10, math.floor(18 * s))
        PAD       = math.max(3,  math.floor(10 * s))
        SIDEBAR_W = math.max(110, math.floor(160 * s))
        BTN_H     = math.max(28, math.floor(50  * s))
        BTN_W     = SIDEBAR_W - PAD * 2
        TAB_H     = math.max(18, math.floor(28  * s))
        OCT_H     = math.max(18, math.floor(28  * s))
        OCT_BTN_W = math.max(14, math.floor(24  * s))
        OCT_NUM_W = math.max(26, math.floor(46  * s))
    end

    -- Assets/ is a symlink inside the love2d dir pointing to ../src/Assets,
    -- so love.filesystem finds it automatically.
    -- Derive the real on-disk Assets path for io.open (config write).
    local src = love.filesystem.getSource()  -- e.g. /project/love2d
    local assets_real = src .. "/Assets"     -- resolves through symlink
    config_path = assets_real .. "/config.txt"

    -- Mount the project root (parent of love2d/) so screenshot.png/jpg can
    -- be loaded via love.filesystem as "root/screenshot.*".
    local project_root = src:match("^(.*)/[^/]+$") or src
    love.filesystem.mount(project_root, "root")

    parse_cli_args()
    read_config(config_path)

    font_norm = love.graphics.newFont("Assets/Fonts/Roboto-Medium.ttf", FONT_SIZE)
    font_h1   = love.graphics.newFont("Assets/Fonts/Roboto-Medium.ttf", math.floor(FONT_SIZE * 1.4))
    font_h2   = love.graphics.newFont("Assets/Fonts/Roboto-Medium.ttf", math.floor(FONT_SIZE * 1.15))

    -- Keyboard sizing: keyboard occupies the bottom ~42% of the screen
    do
        local kb_panel_h = math.floor(SH * 0.42)
        local text_h     = font_norm:getHeight() + PAD * 3
        KBGX = math.max(3, math.floor(SW * 0.003))
        KBGY = KBGX
        local avail_h = kb_panel_h - text_h - (KB_NUM_ROWS - 1) * KBGY - PAD
        KBH  = math.floor(avail_h / KB_NUM_ROWS)
        -- Fit 10 standard-width keys horizontally in 76% of screen
        KBW  = math.floor((SW * 0.76 - 9 * KBGX) / 10)
        KB_TOP = SH - kb_panel_h
    end

    if love.filesystem.getInfo("Assets/Images/battlezone.png") then
        bg_image = love.graphics.newImage("Assets/Images/battlezone.png")
        bg_image:setWrap("repeat", "repeat")
        local iw, ih = bg_image:getDimensions()
        bg_quad = love.graphics.newQuad(0, 0, SW, SH, iw, ih)
    end

    for _, ext in ipairs({"png", "jpg"}) do
        local name = "root/screenshot." .. ext
        if love.filesystem.getInfo(name) then
            screenshot_image = love.graphics.newImage(name)
            break
        end
    end

    if love.filesystem.getInfo("Assets/Sounds/shoot.wav") then
        shoot_sound = love.audio.newSource("Assets/Sounds/shoot.wav", "static")
    end

    local readme_raw = love.filesystem.read("Assets/README.md") or ""
    local instr_raw  = love.filesystem.read("Assets/instructions.txt") or ""
    readme_md = parse_md(readme_raw)
    instr_md  = parse_md(instr_raw)
end

function love.update(dt)
    local down = love.mouse.isDown(1)
    mouse_pressed_now = down and not last_mouse_down
    last_mouse_down   = down

    -- Gamepad A edge detection + keyboard Enter (both activate focused element)
    local js = love.joystick.getJoysticks()[1]
    local a  = js ~= nil and js:isGamepadDown("a") or false
    gamepad_a_now  = (a and not last_gamepad_a) or enter_pending
    last_gamepad_a = a
    enter_pending  = false
end

function love.draw()
    click_consumed = false
    a_consumed     = false
    focus_reg      = 0

    if bg_image and bg_quad then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(bg_image, bg_quad, 0, 0)
    else
        rect(0, 0, SW, SH, {0.06, 0.08, 0.05, 1})
    end

    if show_ip_window then
        draw_ip_win()
    else
        draw_main()
    end

    if show_keyboard then
        draw_keyboard()
    end

    -- Finalise focus count; clamp index in case element list shrank
    focus_max = focus_reg
    if focus_max > 0 and focus_idx > focus_max then
        focus_idx = focus_max
    end
end

function love.textinput(t)
    if name_focused and not show_keyboard then
        player_name = player_name .. t
    end
end

function love.keypressed(key)
    -- On-screen keyboard navigation takes priority
    if show_keyboard then
        if     key == "up"    then kb_move(-1, 0)
        elseif key == "down"  then kb_move( 1, 0)
        elseif key == "left"  then kb_move( 0,-1)
        elseif key == "right" then kb_move( 0, 1)
        elseif key == "return" or key == "kpenter" then
            kb_press(kb_get_key())
        elseif key == "backspace" then
            player_name = player_name:sub(1, -2)
        elseif key == "escape" then
            show_keyboard = false
            name_focused  = false
        end
        return
    end

    -- Name field physical keyboard input
    if name_focused then
        if key == "backspace" then
            player_name = player_name:sub(1, -2)
            return
        elseif key == "return" or key == "kpenter" or key == "tab" or key == "escape" then
            name_focused = false
            return
        end
    end

    -- Arrow keys navigate focus (mirrors D-pad)
    if key == "down" or key == "right" then
        play_ui_sound()
        if focus_max > 0 then
            focus_idx = (focus_idx % focus_max) + 1
        end
    elseif key == "up" or key == "left" then
        play_ui_sound()
        if focus_max > 0 then
            focus_idx = ((focus_idx - 2 + focus_max) % focus_max) + 1
        end
    -- Enter / numpad Enter activate the focused element
    elseif key == "return" or key == "kpenter" then
        enter_pending = true
    elseif key == "f3" then
        show_ip_window = not show_ip_window
    elseif key == "f2" and show_ip_window then
        write_config(config_path)
        os.exit(120 + num_players)
    elseif key == "escape" then
        if show_ip_window then
            show_ip_window = false
            show_keyboard  = false
            name_focused   = false
            focus_idx      = 1
        else
            os.exit(0)
        end
    end
end

function love.gamepadpressed(joystick, button)
    if show_keyboard then
        if     button == "dpup"    then kb_move(-1, 0)
        elseif button == "dpdown"  then kb_move( 1, 0)
        elseif button == "dpleft"  then kb_move( 0,-1)
        elseif button == "dpright" then kb_move( 0, 1)
        elseif button == "a" then
            kb_press(kb_get_key())
        elseif button == "b" then
            player_name = player_name:sub(1, -2)
        elseif button == "x" then
            kb_press("SPACE")
        elseif button == "back" or button == "y" then
            show_keyboard = false
            name_focused  = false
        end
        return
    end

    if button == "start" then
        os.exit(0)
    elseif button == "dpdown" or button == "dpright" then
        play_ui_sound()
        if focus_max > 0 then
            focus_idx = (focus_idx % focus_max) + 1
        end
    elseif button == "dpup" or button == "dpleft" then
        play_ui_sound()
        if focus_max > 0 then
            focus_idx = ((focus_idx - 2 + focus_max) % focus_max) + 1
        end
    end
end

function love.wheelmoved(x, y)
    local delta = y * 40
    if show_ip_window then
        ip_scroll = math.max(0, ip_scroll - delta)
    else
        desc_scroll = math.max(0, desc_scroll - delta)
    end
end
