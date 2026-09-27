--[[
    VehicleSyncHudLayout

    Pure part of the Vehicle Sync terminal: design tokens, the view model built from a snapshot of
    a vehicle's sync state, the screen layout and the hit test. No engine calls, so every rule can
    be tested without the game; VehicleSyncHud draws the result and handles the mouse.

    Units: sizes are reference pixels, layout() turns them into normalised screen coordinates
    (0..1, y up) with the unit sizes the HUD passes in. The plan view works in metres in the leader
    frame (+x left, +z forward) and is drawn with the leader pointing up.
]]

---@class VehicleSyncHudLayout
VehicleSyncHudLayout = {}

local STATE = VehicleSyncController.STATE
local REASON = VehicleSyncController.REASON

---Converts a sRGB hex colour to the linear colour the engine expects
---@return table {r, g, b, a}
function VehicleSyncHudLayout.fromHex(hex, alpha)
    local function channel(value)
        value = value / 255
        if value <= 0.04045 then
            return value / 12.92
        end
        return ((value + 0.055) / 1.055) ^ 2.4
    end
    return { channel(math.floor(hex / 65536) % 256), channel(math.floor(hex / 256) % 256), channel(hex % 256), alpha or 1 }
end

---Same colour with another alpha
function VehicleSyncHudLayout.withAlpha(color, alpha)
    return { color[1], color[2], color[3], alpha }
end

local fromHex = VehicleSyncHudLayout.fromHex

-- in-cab terminal: dark glass, a stubble field for the plan view, straw for zone and pipe line
VehicleSyncHudLayout.COLOR = {
    GLASS = fromHex(0x1B2124, 0.9),
    BEZEL = fromHex(0x2C3438),
    BEZEL_HOVER = fromHex(0x3A454A),
    BEZEL_DISABLED = fromHex(0x2C3438, 0.5),
    STUBBLE = fromHex(0x34321F),
    STRAW = fromHex(0xD6B85A),
    PAPER = fromHex(0xECE8DC),
    PAPER_DISABLED = fromHex(0xECE8DC, 0.35),
    INK = fromHex(0x1B2124),
    IDLE = fromHex(0x7A8387),
    CONNECTED = fromHex(0x8FB3D1),
    ACQUIRING = fromHex(0xE6A23C),
    TRACKING = fromHex(0x7FBF6A),
    WARNING = fromHex(0xD65A4A),
}

-- reference pixels
VehicleSyncHudLayout.SIZE = {
    WIDTH = 320,
    PADDING = 8,
    GAP = 6,
    HEADER = 26,
    BAND = 32,
    BAND_BAR = 6,
    PLAN = 180,
    PLAN_EMPTY = 64,  -- plan view that only shows a message
    BANNER = 26,      -- message banner across the top of the plan view
    READOUT = 24,
    BUTTON = 30,
    BUTTON_ICON = 18,
    CLOSE_ICON = 12,
    TEXT_TITLE = 13,
    TEXT_STATE = 17,
    TEXT_BODY = 12,
    TEXT_BUTTON = 12,
    LEADER_ICON_W = 22,
    LEADER_ICON_H = 36,
    CART_ICON_W = 16,
    CART_ICON_H = 24,
    HOME_ICON = 14,
    DOT = 2,
    DOT_SPACING = 6,
    PLAN_MARGIN = 2,  -- metres around the operational zone
}

-- plan view: the whole operational zone, or a close-up of harvester and cart while a cart is engaged
VehicleSyncHudLayout.ZOOM = { ZONE = "zone", CLOSE = "close" }
VehicleSyncHudLayout.CLOSE_WINDOW = { lateral = 12, front = 8, back = 14 }  -- metres around the leader

-- cells of textures/hud_icons.dds (4x4 grid, see tools/make_hud_icons.py)
VehicleSyncHudLayout.ICON = {
    HARVESTER = { 0, 0 },
    CART = { 1, 0 },
    ARROW_UP = { 2, 0 },
    ARROW_DOWN = { 3, 0 },
    ARROW_LEFT = { 0, 1 },
    ARROW_RIGHT = { 1, 1 },
    HOME = { 2, 1 },
    CLOSE = { 3, 1 },
    SOLID = { 0, 2 },
}
VehicleSyncHudLayout.ICON_GRID = 4

VehicleSyncHudLayout.ROLE = {
    LEADER = "leader",        -- network open
    FOLLOWER = "follower",    -- member of a network
    HARVESTER = "harvester",  -- vehicle with a pipe, network closed
    TRACTOR = "tractor",      -- anything else, not connected
}

-- button layouts: one row of equal buttons, one full-width button, or the leader's nudge pad
VehicleSyncHudLayout.BUTTONS = { ROW = "row", SINGLE = "single", LEADER = "leader" }

---UVs of an atlas cell in the GuiUtils.getUVs order. The solid cell is sampled in its centre so
-- filtering never picks up a neighbouring glyph.
---@return table uvs {u1, v1, u2, v2, u3, v3, u4, v4}
function VehicleSyncHudLayout.getIconUVs(icon)
    local cell = 1 / VehicleSyncHudLayout.ICON_GRID
    local inset = icon == VehicleSyncHudLayout.ICON.SOLID and cell * 0.25 or 0
    local x0 = icon[1] * cell + inset
    local x1 = (icon[1] + 1) * cell - inset
    local yTop = icon[2] * cell + inset
    local yBottom = (icon[2] + 1) * cell - inset
    return { x0, 1 - yBottom, x0, 1 - yTop, x1, 1 - yBottom, x1, 1 - yTop }
end

function VehicleSyncHudLayout.getStateColor(state)
    local color = VehicleSyncHudLayout.COLOR
    if state == STATE.CONNECTED then
        return color.CONNECTED
    elseif state == STATE.ACQUIRING then
        return color.ACQUIRING
    elseif state == STATE.TRACKING then
        return color.TRACKING
    end
    return color.IDLE
end

---What the terminal shows for a vehicle
---Visible part of the leader frame in metres: {lateral, front, back}
function VehicleSyncHudLayout.getWindow(zoom)
    if zoom == VehicleSyncHudLayout.ZOOM.CLOSE then
        return VehicleSyncHudLayout.CLOSE_WINDOW
    end
    local defaults = VehicleSyncController.DEFAULTS
    local margin = VehicleSyncHudLayout.SIZE.PLAN_MARGIN
    return { lateral = defaults.zoneLateral + margin, front = defaults.zoneFront + margin, back = defaults.zoneBack + margin }
end

function VehicleSyncHudLayout.getRole(networkEnabled, state, hasPipe)
    local role = VehicleSyncHudLayout.ROLE
    if networkEnabled then
        return role.LEADER
    elseif state ~= STATE.IDLE then
        return role.FOLLOWER
    elseif hasPipe then
        return role.HARVESTER
    end
    return role.TRACTOR
end

-- ---------------------------------------------------------------------------
-- View model
-- ---------------------------------------------------------------------------

local function fillText(ratio, getText)
    if ratio == nil then
        return nil
    end
    return string.format(getText("vs_hud_cartFill"), math.floor(ratio * 100 + 0.5))
end

local function deviation(live, getText)
    return {
        left = { label = getText("vs_hud_lateral"), value = string.format("%+.2f m", live.lateralError) },
        right = { label = getText("vs_hud_foreAft"), value = string.format("%+.2f m", live.alongError) },
    }
end

local function cartItem(home, live, state)
    return {
        home = home,
        -- the tractor drives on the home line and the cart trails on it (see computeGeometry)
        cart = { x = home.x + live.lateralError, z = home.z + live.alongError },
        color = VehicleSyncHudLayout.getStateColor(state),
    }
end

---Engaged: a machine fault counts down (live.check) -> warning band and the fault instead of the deviation
local function applyEngagedLive(view, live, getText)
    if live.check == REASON.NONE then
        view.readout = deviation(live, getText)
        return
    end
    view.stateText = string.format(getText("vs_hud_ending"), math.ceil(live.abortRemaining / 1000))
    view.stateColor = VehicleSyncHudLayout.COLOR.WARNING
    view.readout = { message = getText(VehicleSyncController.getFaultTextKey(live.check)), warning = true }
end

local function button(getText, textKey, action, argument, enabled, icon)
    return { text = textKey ~= nil and getText(textKey) or nil, action = action, argument = argument or 0,
        enabled = enabled ~= false, icon = icon }
end

local function buildFollower(view, s, getText)
    local color = VehicleSyncHudLayout.COLOR
    local engaged = VehicleSyncController.isEngaged(s.state)
    view.partner = s.partnerName
    view.stateText = s.stateText
    view.stateColor = VehicleSyncHudLayout.getStateColor(s.state)
    view.fillText = fillText(s.fillRatio, getText)
    view.plan.pipe = s.pipe
    view.plan.zoom = engaged and VehicleSyncHudLayout.ZOOM.CLOSE or VehicleSyncHudLayout.ZOOM.ZONE
    if s.home ~= nil then
        table.insert(view.plan.carts, cartItem(s.home, s.live, s.state))
    end
    -- the server's engage check (live.check) is the truth; before its first update only the zone is known
    local canEngage = true
    local check = s.live.check
    if engaged then
        applyEngagedLive(view, s.live, getText)
    elseif check == REASON.ENGAGED then
        view.readout = { message = getText("vs_hud_ready") }
    elseif check == REASON.NONE then
        view.readout = { message = getText(s.live.inZone and "vs_hud_inZone" or "vs_hud_driveIntoZone") }
    else
        view.readout = { message = getText(VehicleSyncController.getReasonTextKey(check)) }
        canEngage = false
    end

    local engage = button(getText, engaged and "vs_button_disengage" or "vs_button_engage", "TOGGLE_ENGAGE", 0, canEngage)
    engage.primary = true
    engage.color = engaged and color.WARNING or color.TRACKING
    view.buttonLayout = VehicleSyncHudLayout.BUTTONS.ROW
    view.buttons = {
        button(getText, "vs_button_leave", "TOGGLE_CONNECT"),
        engage,
        button(getText, "vs_button_setHome", "SET_HOME", 0, s.live.inZone),
    }
end

local function buildLeader(view, s, getText)
    local icon = VehicleSyncHudLayout.ICON
    local nudge = VehicleSyncController.NUDGE
    local count = #s.followers
    local engaged = nil
    for _, follower in ipairs(s.followers) do
        if follower.home ~= nil then
            table.insert(view.plan.carts, cartItem(follower.home, follower.live, follower.state))
        end
        if engaged == nil and VehicleSyncController.isEngaged(follower.state) then
            engaged = follower
        end
    end

    view.partner = string.format(getText("vs_hud_carts"), count)
    view.stateText = getText("vs_hud_networkOpen")
    view.stateColor = engaged ~= nil and VehicleSyncHudLayout.getStateColor(engaged.state) or VehicleSyncHudLayout.COLOR.CONNECTED
    view.fillText = engaged ~= nil and fillText(engaged.fillRatio, getText) or nil
    view.plan.pipe = s.pipe
    view.plan.zoom = engaged ~= nil and VehicleSyncHudLayout.ZOOM.CLOSE or VehicleSyncHudLayout.ZOOM.ZONE
    if engaged ~= nil then
        applyEngagedLive(view, engaged.live, getText)
    else
        view.readout = { message = getText(count == 0 and "vs_hud_waiting" or "vs_hud_noneEngaged") }
    end

    local canNudge = count > 0
    view.buttonLayout = VehicleSyncHudLayout.BUTTONS.LEADER
    view.buttons = {
        button(getText, "vs_button_closeNetwork", "TOGGLE_NETWORK"),
        button(getText, "vs_button_release", "RELEASE", 0, engaged ~= nil),
        button(getText, nil, "NUDGE", nudge.FORWARD, canNudge, icon.ARROW_UP),
        button(getText, nil, "NUDGE", nudge.LEFT, canNudge, icon.ARROW_LEFT),
        button(getText, nil, "NUDGE", nudge.BACK, canNudge, icon.ARROW_DOWN),
        button(getText, nil, "NUDGE", nudge.RIGHT, canNudge, icon.ARROW_RIGHT),
    }
end

---Builds what the terminal shows from a snapshot of the vehicle
-- snapshot: {role, state, stateText, partnerName, home, live {lateralError, alongError, inZone, check, abortRemaining},
--            fillRatio, pipe {x, z}, followers {{state, home, live, fillRatio}}, nearest {name, distance}}
---@param getText function key -> localised text
---@return table view
function VehicleSyncHudLayout.buildView(s, getText)
    local role = VehicleSyncHudLayout.ROLE
    local view = { title = getText("vs_hud_title"), buttons = {}, plan = { carts = {} } }

    if s.role == role.FOLLOWER then
        buildFollower(view, s, getText)
    elseif s.role == role.LEADER then
        buildLeader(view, s, getText)
    elseif s.role == role.HARVESTER then
        view.stateText = getText("vs_hud_networkClosed")
        view.stateColor = VehicleSyncHudLayout.COLOR.IDLE
        view.plan.empty = getText("vs_hud_emptyClosed")
        view.buttonLayout = VehicleSyncHudLayout.BUTTONS.SINGLE
        view.buttons = { button(getText, "vs_button_openNetwork", "TOGGLE_NETWORK") }
    else
        -- the server's join check (live.check) decides; before its first update the nearest network counts
        local check = s.live.check
        view.stateText = s.stateText
        view.stateColor = VehicleSyncHudLayout.COLOR.IDLE
        if check == REASON.NOT_ALLOWED then
            view.plan.empty = getText(VehicleSyncController.getReasonTextKey(check))
        elseif s.nearest == nil then
            view.plan.empty = getText("vs_hud_noNetwork")
        else
            local key = check == REASON.OUT_OF_RANGE and "vs_hud_nearestFar" or "vs_hud_nearest"
            view.plan.empty = string.format(getText(key), s.nearest.name, math.floor(s.nearest.distance + 0.5))
        end
        local canJoin = check == REASON.CONNECTED or (check == REASON.NONE and s.nearest ~= nil)
        view.buttonLayout = VehicleSyncHudLayout.BUTTONS.SINGLE
        view.buttons = { button(getText, "vs_button_join", "TOGGLE_CONNECT", 0, canJoin) }
    end

    return view
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local function rect(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
end

---Positions every element of the panel. `left` / `top` is the top left corner of the panel.
---@return table layout {panel, header, close, band, bar, plan, banner, readout, buttons {{rect, button}}, hits, width, height, unitX, unitY, pixelsPerMetre}
function VehicleSyncHudLayout.layout(view, left, top, unitX, unitY)
    local S = VehicleSyncHudLayout.SIZE
    local width = S.WIDTH * unitX
    local padX, padY = S.PADDING * unitX, S.PADDING * unitY
    local gapX, gapY = S.GAP * unitX, S.GAP * unitY
    local contentX, contentW = left + padX, width - 2 * padX
    local lay = { width = width, unitX = unitX, unitY = unitY, buttons = {}, hits = {} }

    local y = top - S.HEADER * unitY
    lay.header = rect(left, y, width, S.HEADER * unitY)
    lay.close = rect(left + width - S.HEADER * unitX, y, S.HEADER * unitX, S.HEADER * unitY)

    y = y - S.BAND * unitY
    lay.band = rect(left, y, width, S.BAND * unitY)
    lay.bar = rect(left, y, S.BAND_BAR * unitX, S.BAND * unitY)

    local planHeight = view.plan.empty ~= nil and S.PLAN_EMPTY or S.PLAN
    y = y - padY - planHeight * unitY
    lay.plan = rect(contentX, y, contentW, planHeight * unitY)
    lay.banner = rect(contentX, y + (planHeight - S.BANNER) * unitY, contentW, S.BANNER * unitY)
    lay.window = VehicleSyncHudLayout.getWindow(view.plan.zoom)
    lay.pixelsPerMetre = math.min(contentW / unitX / (2 * lay.window.lateral), planHeight / (lay.window.front + lay.window.back))

    if view.readout ~= nil then
        y = y - S.READOUT * unitY
        lay.readout = rect(contentX, y, contentW, S.READOUT * unitY)
    else
        y = y - gapY
    end

    local buttonH = S.BUTTON * unitY
    local buttons = view.buttons
    if view.buttonLayout == VehicleSyncHudLayout.BUTTONS.LEADER then
        local square = S.BUTTON * unitX
        local padW = 3 * square + 2 * gapX
        local wideW = contentW - padW - gapX
        local padLeft = contentX + contentW - padW
        local upperY = y - buttonH
        local lowerY = upperY - gapY - buttonH
        local rects = {
            rect(contentX, upperY, wideW, buttonH),
            rect(contentX, lowerY, wideW, buttonH),
            rect(padLeft + square + gapX, upperY, square, buttonH),
            rect(padLeft, lowerY, square, buttonH),
            rect(padLeft + square + gapX, lowerY, square, buttonH),
            rect(padLeft + 2 * (square + gapX), lowerY, square, buttonH),
        }
        for i, b in ipairs(buttons) do
            table.insert(lay.buttons, { rect = rects[i], button = b })
        end
        y = lowerY
    else
        local count = #buttons
        local buttonW = (contentW - (count - 1) * gapX) / count
        y = y - buttonH
        for i, b in ipairs(buttons) do
            table.insert(lay.buttons, { rect = rect(contentX + (i - 1) * (buttonW + gapX), y, buttonW, buttonH), button = b })
        end
    end

    y = y - padY
    lay.height = top - y
    lay.panel = rect(left, y, width, lay.height)

    -- the close button lies on the header, so it is tested first
    table.insert(lay.hits, { id = "close", rect = lay.close })
    table.insert(lay.hits, { id = "header", rect = lay.header })
    for i, item in ipairs(lay.buttons) do
        table.insert(lay.hits, { id = "button" .. i, rect = item.rect, button = item.button })
    end
    table.insert(lay.hits, { id = "panel", rect = lay.panel })

    return lay
end

---Maps a point of the leader frame (metres) into the plan view; points outside are kept on its edge
---@return number x
---@return number y
---@return boolean clamped
function VehicleSyncHudLayout.project(lay, localX, localZ)
    local plan = lay.plan
    local middleZ = (lay.window.front - lay.window.back) / 2
    local x = plan.x + plan.w / 2 - localX * lay.pixelsPerMetre * lay.unitX
    local y = plan.y + plan.h / 2 + (localZ - middleZ) * lay.pixelsPerMetre * lay.unitY
    local clampedX = math.max(plan.x, math.min(plan.x + plan.w, x))
    local clampedY = math.max(plan.y, math.min(plan.y + plan.h, y))
    return clampedX, clampedY, clampedX ~= x or clampedY ~= y
end

---Operational zone of the plan view
function VehicleSyncHudLayout.getZoneRect(lay)
    local defaults = VehicleSyncController.DEFAULTS
    local x1, y1 = VehicleSyncHudLayout.project(lay, defaults.zoneLateral, -defaults.zoneBack)
    local x2, y2 = VehicleSyncHudLayout.project(lay, -defaults.zoneLateral, defaults.zoneFront)
    return rect(x1, y1, x2 - x1, y2 - y1)
end

---First hit region containing the point, nil if none
function VehicleSyncHudLayout.hitTest(hits, posX, posY)
    for _, hit in ipairs(hits) do
        local r = hit.rect
        if posX >= r.x and posX <= r.x + r.w and posY >= r.y and posY <= r.y + r.h then
            return hit
        end
    end
    return nil
end

---Keeps the panel on the screen
---@return number left
---@return number top
function VehicleSyncHudLayout.clampPanel(left, top, width, height)
    left = math.max(0, math.min(1 - width, left))
    top = math.max(height, math.min(1, top))
    return left, top
end
