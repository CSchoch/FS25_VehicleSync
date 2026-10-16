--[[
    Renders the README preview of the Vehicle Sync terminal (docs/terminal.svg).

    Uses the real view model and layout (src/hud/VehicleSyncHudLayout.lua) with the English texts,
    and draws it the way VehicleSyncHud:render does, so the picture follows HUD changes. Glyphs
    are the shapes of tools/make_hud_icons.py as SVG.

    Usage (from the mod root):
        & "C:\Program Files (x86)\Lua\5.1\lua.exe" tools\render_hud_preview.lua
]]

local OUTPUT = "docs/terminal.svg"
local SCALE = 1.5           -- reference pixels -> SVG pixels
local MIN_TEXT_SCALE = 0.7  -- VehicleSyncHud.MIN_TEXT_SCALE
local FONT = "'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
local MARGIN = 16
local CAPTION = 34

dofile("src/VehicleSyncMath.lua")
dofile("src/VehicleSyncController.lua")
dofile("src/hud/VehicleSyncHudLayout.lua")

local L = VehicleSyncHudLayout
local STATE = VehicleSyncController.STATE
local REASON = VehicleSyncController.REASON
local C, S, ICON = L.COLOR, L.SIZE, L.ICON

-- ---------------------------------------------------------------------------
-- Texts
-- ---------------------------------------------------------------------------

local texts = {}
local file = assert(io.open("translations/translation_en.xml", "r"))
for name, text in file:read("*a"):gmatch('<text name="([^"]+)" text="([^"]*)"') do
    texts[name] = text:gsub("&quot;", '"'):gsub("&amp;", "&")
end
file:close()

local function getText(key)
    return assert(texts[key], "missing text " .. key)
end

-- ---------------------------------------------------------------------------
-- SVG primitives (layout y is up, SVG y is down)
-- ---------------------------------------------------------------------------

local out = {}
local function emit(fmt, ...)
    table.insert(out, string.format(fmt, ...))
end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

---linear engine colour -> sRGB hex and opacity
local function paint(color)
    local function channel(value)
        if value <= 0.0031308 then
            value = value * 12.92
        else
            value = 1.055 * value ^ (1 / 2.4) - 0.055
        end
        return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5)
    end
    return string.format("#%02X%02X%02X", channel(color[1]), channel(color[2]), channel(color[3])), color[4] or 1
end

local function fillAttr(color)
    local hex, alpha = paint(color)
    if alpha < 1 then
        return string.format('fill="%s" fill-opacity="%.2f"', hex, alpha)
    end
    return string.format('fill="%s"', hex)
end

local function rect(r, color)
    emit('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" %s/>', r.x, -(r.y + r.h), r.w, r.h, fillAttr(color))
end

local ALIGN = { left = "start", center = "middle", right = "end" }

local function text(x, y, size, value, color, align, bold, maxWidth)
    -- rough width estimate for the shrink-to-fit of VehicleSyncHud:drawText
    local width = #value * size * (bold and 0.58 or 0.53)
    if maxWidth ~= nil and width > maxWidth then
        size = size * math.max(MIN_TEXT_SCALE, maxWidth / width)
    end
    emit('<text x="%.2f" y="%.2f" font-size="%.2f" text-anchor="%s" dominant-baseline="central"%s %s>%s</text>',
        x, -y, size, ALIGN[align], bold and ' font-weight="600"' or "", fillAttr(color), escape(value))
end

local GLYPH_ID = {
    [ICON.HARVESTER] = "harvester", [ICON.CART] = "cart", [ICON.ARROW_UP] = "arrowUp", [ICON.ARROW_DOWN] = "arrowDown",
    [ICON.ARROW_LEFT] = "arrowLeft", [ICON.ARROW_RIGHT] = "arrowRight", [ICON.HOME] = "home", [ICON.CLOSE] = "close",
}

local function icon(glyph, centerX, centerY, w, h, color)
    if glyph == ICON.SOLID then
        rect({ x = centerX - w / 2, y = centerY - h / 2, w = w, h = h }, color)
        return
    end
    local hex, alpha = paint(color)
    emit('<g transform="translate(%.2f %.2f) scale(%.4f %.4f)" color="%s" opacity="%.2f"><use href="#%s" width="64" height="64"/></g>',
        centerX - w / 2, -(centerY + h / 2), w / 64, h / 64, hex, alpha, GLYPH_ID[glyph])
end

-- atlas glyphs on a 64 px cell, white = currentColor, cut-outs via masks (see tools/make_hud_icons.py)
local GLYPHS = [[
<mask id="m-harvester" maskUnits="userSpaceOnUse" x="0" y="0" width="64" height="64">
  <rect x="6" y="5" width="52" height="8" rx="2" fill="#fff"/><rect x="27" y="12" width="10" height="7" fill="#fff"/>
  <rect x="18" y="17" width="28" height="42" rx="6" fill="#fff"/>
  <rect x="23" y="21" width="18" height="10" rx="3" fill="#000"/><rect x="23" y="36" width="18" height="18" rx="3" fill="#000"/>
  <rect x="26" y="39" width="12" height="12" rx="2" fill="#fff"/>
</mask>
<mask id="m-cart" maskUnits="userSpaceOnUse" x="0" y="0" width="64" height="64">
  <rect x="30" y="4" width="4" height="14" fill="#fff"/><rect x="16" y="16" width="32" height="44" rx="5" fill="#fff"/>
  <rect x="21" y="21" width="22" height="34" rx="3" fill="#000"/><rect x="25" y="25" width="14" height="26" rx="2" fill="#fff"/>
</mask>
<symbol id="harvester" viewBox="0 0 64 64"><rect width="64" height="64" fill="currentColor" mask="url(#m-harvester)"/></symbol>
<symbol id="cart" viewBox="0 0 64 64"><rect width="64" height="64" fill="currentColor" mask="url(#m-cart)"/></symbol>
<symbol id="arrowUp" viewBox="0 0 64 64"><g fill="currentColor"><polygon points="32,7 56,34 8,34"/><rect x="23" y="33" width="18" height="24"/></g></symbol>
<symbol id="arrowDown" viewBox="0 0 64 64"><use href="#arrowUp" width="64" height="64" transform="rotate(180 32 32)"/></symbol>
<symbol id="arrowLeft" viewBox="0 0 64 64"><use href="#arrowUp" width="64" height="64" transform="rotate(-90 32 32)"/></symbol>
<symbol id="arrowRight" viewBox="0 0 64 64"><use href="#arrowUp" width="64" height="64" transform="rotate(90 32 32)"/></symbol>
<symbol id="home" viewBox="0 0 64 64"><g stroke="currentColor" stroke-width="5" fill="none"><circle cx="32" cy="32" r="16.5"/>
  <path d="M32 4V22M32 42V60M4 32H22M42 32H60"/></g></symbol>
<symbol id="close" viewBox="0 0 64 64"><path d="M14 14L50 50M50 14L14 50" stroke="currentColor" stroke-width="8"/></symbol>
]]

-- ---------------------------------------------------------------------------
-- Terminal (mirrors VehicleSyncHud:render, renderPlan, renderButton)
-- ---------------------------------------------------------------------------

local function renderPlan(plan, lay)
    local r = lay.plan
    rect(r, C.STUBBLE)
    if plan.empty ~= nil then
        text(r.x + r.w / 2, r.y + r.h / 2, S.TEXT_BODY, plan.empty, C.PAPER, "center", false, r.w - 2 * S.PADDING)
        return
    end

    if plan.zoom ~= L.ZOOM.CLOSE then
        local zone = L.getZoneRect(lay)
        local outline = L.withAlpha(C.STRAW, 0.8)
        rect(zone, L.withAlpha(C.STRAW, 0.06))
        rect({ x = zone.x, y = zone.y, w = zone.w, h = 1 }, outline)
        rect({ x = zone.x, y = zone.y + zone.h - 1, w = zone.w, h = 1 }, outline)
        rect({ x = zone.x, y = zone.y, w = 1, h = zone.h }, outline)
        rect({ x = zone.x + zone.w - 1, y = zone.y, w = 1, h = zone.h }, outline)
    end

    local leaderX, leaderY = L.project(lay, 0, 0)
    icon(ICON.HARVESTER, leaderX, leaderY, S.LEADER_ICON_W, S.LEADER_ICON_H, C.PAPER)

    for _, item in ipairs(plan.carts) do
        local homeX, homeY = L.project(lay, item.home.x, item.home.z)
        if plan.pipe ~= nil then
            local side = plan.pipe.x < 0 and 1 or -1
            local _, pipeY = L.project(lay, plan.pipe.x, plan.pipe.z)
            local x1, y1 = leaderX + side * S.LEADER_ICON_W / 2, pipeY
            local count = math.floor(math.sqrt((homeX - x1) ^ 2 + (homeY - y1) ^ 2) / S.DOT_SPACING)
            for i = 0, count do
                local t = count > 0 and i / count or 0
                icon(ICON.SOLID, x1 + (homeX - x1) * t, y1 + (homeY - y1) * t, S.DOT, S.DOT, C.STRAW)
            end
        end
        local cartX, cartY = L.project(lay, item.cart.x, item.cart.z)
        icon(ICON.CART, cartX, cartY, S.CART_ICON_W, S.CART_ICON_H, item.color)
        icon(ICON.HOME, homeX, homeY, S.HOME_ICON, S.HOME_ICON, C.STRAW)
    end
end

local function renderButton(item)
    local b, r = item.button, item.rect
    local face, ink = C.BEZEL, C.PAPER
    if not b.enabled then
        face, ink = C.BEZEL_DISABLED, C.PAPER_DISABLED
    elseif b.primary then
        face, ink = b.color, C.INK
    end
    rect(r, face)
    local centerX, centerY = r.x + r.w / 2, r.y + r.h / 2
    if b.icon ~= nil then
        icon(b.icon, centerX, centerY, S.BUTTON_ICON, S.BUTTON_ICON, ink)
    else
        text(centerX, centerY, S.TEXT_BUTTON, b.text, ink, "center", true, r.w - S.PADDING)
    end
end

local function renderTerminal(view, lay)
    local padX = S.PADDING
    rect(lay.panel, C.GLASS)

    local header = lay.header
    local headerY = header.y + header.h / 2
    rect(header, C.BEZEL)
    text(header.x + padX, headerY, S.TEXT_TITLE, view.title, C.PAPER, "left", true)
    if view.partner ~= nil then
        text(lay.close.x, headerY, S.TEXT_BODY, view.partner, C.PAPER, "right", false, header.w / 2)
    end
    icon(ICON.CLOSE, lay.close.x + lay.close.w / 2, headerY, S.CLOSE_ICON, S.CLOSE_ICON, C.PAPER)

    local band = lay.band
    local bandY = band.y + band.h / 2
    rect(band, L.withAlpha(view.stateColor, 0.18))
    rect(lay.bar, view.stateColor)
    text(lay.bar.x + lay.bar.w + padX, bandY, S.TEXT_STATE, view.stateText, C.PAPER, "left", true)
    if view.fillText ~= nil then
        text(band.x + band.w - padX, bandY, S.TEXT_BODY, view.fillText, C.PAPER, "right", true)
    end

    renderPlan(view.plan, lay)

    if lay.readout ~= nil then
        local readout = lay.readout
        local readoutY = readout.y + readout.h / 2
        if view.readout.message ~= nil then
            local color = view.readout.warning and C.WARNING or C.PAPER
            text(readout.x, readoutY, S.TEXT_BODY, view.readout.message, color, "left", view.readout.warning == true, readout.w)
        else
            local half = readout.w / 2
            for i, entry in ipairs({ view.readout.left, view.readout.right }) do
                local x = readout.x + (i - 1) * half
                text(x, readoutY, S.TEXT_BODY, entry.label, C.PAPER, "left", false)
                text(x + half - padX, readoutY, S.TEXT_BODY, entry.value, C.PAPER, "right", true)
            end
        end
    end

    for _, item in ipairs(lay.buttons) do
        renderButton(item)
    end
end

-- ---------------------------------------------------------------------------
-- Scenes
-- ---------------------------------------------------------------------------

-- pipe on the left of the harvester, home point below its outlet
local PIPE = { x = 7.2, z = 1.0 }
local HOME = { x = 7.2, z = 0.4 }

local function live(lateral, along, check, inZone, abortRemaining)
    return { lateralError = lateral, alongError = along, inZone = inZone ~= false, check = check or REASON.NONE,
        abortRemaining = abortRemaining or 0 }
end

local SCENES = {
    {
        caption = "Tractor: connected, ready to engage",
        snapshot = { role = L.ROLE.FOLLOWER, state = STATE.CONNECTED, stateText = getText("vs_state_connected"),
            partnerName = "Harvester", home = HOME, live = live(3.5, -16, REASON.ENGAGED), fillRatio = 0.08, pipe = PIPE },
    },
    {
        caption = "Tractor: tracking below the pipe",
        snapshot = { role = L.ROLE.FOLLOWER, state = STATE.TRACKING, stateText = getText("vs_state_tracking"),
            partnerName = "Harvester", home = HOME, live = live(0.14, -0.32), fillRatio = 0.62, pipe = PIPE },
    },
    {
        caption = "Harvester: nudge or release the cart",
        snapshot = { role = L.ROLE.LEADER, pipe = PIPE,
            followers = { { state = STATE.TRACKING, home = HOME, live = live(-0.21, 0.45), fillRatio = 0.62 } } },
    },
}

local panels, width, height = {}, MARGIN, 0
for _, scene in ipairs(SCENES) do
    local view = L.buildView(scene.snapshot, getText)
    local lay = L.layout(view, 0, 0, 1, 1)
    table.insert(panels, { view = view, lay = lay, caption = scene.caption, left = width })
    width = width + lay.width * SCALE + MARGIN
    height = math.max(height, lay.height * SCALE)
end
height = MARGIN + height + CAPTION

emit('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%d" height="%d" viewBox="0 0 %d %d" font-family="%s">',
    width, height, width, height, FONT)
emit("<title>Vehicle Sync terminal</title>")
emit("<defs>%s</defs>", GLYPHS)
for _, panel in ipairs(panels) do
    emit('<g transform="translate(%.2f %d) scale(%.2f)">', panel.left, MARGIN, SCALE)
    renderTerminal(panel.view, panel.lay)
    emit("</g>")
    emit('<text x="%.2f" y="%.2f" font-size="14" text-anchor="middle" fill="#8B949E">%s</text>',
        panel.left + panel.lay.width * SCALE / 2, height - CAPTION / 2 + 4, escape(panel.caption))
end
emit("</svg>")

local svg = assert(io.open(OUTPUT, "w"))
svg:write(table.concat(out, "\n"), "\n")
svg:close()
print("wrote " .. OUTPUT)
