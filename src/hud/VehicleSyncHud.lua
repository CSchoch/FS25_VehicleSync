--[[
    VehicleSyncHud

    The Vehicle Sync terminal: a draggable panel that shows the sync state of the vehicle the local
    player sits in and offers every operator action as a mouse button.

    Keys and mouse:
    - VS_TOGGLE_HUD (Left Alt + Y) opens the terminal with the mouse cursor. While it is open, the
      key only brings the cursor back; it never closes the terminal.
    - Right click hides the cursor (mouse look again), the terminal stays open.
    - The close button closes the terminal. Leaving the vehicle closes it as well.

    Buttons only send requests (vehicle:vsRequest), so the server stays authoritative. The layout
    and the view model live in VehicleSyncHudLayout; this file draws them with one overlay on the
    icon atlas (its solid cell is used for all plain rectangles).
]]

---@class VehicleSyncHud
VehicleSyncHud = {}

VehicleSyncHud.MOD_NAME = g_currentModName or "FS25_VehicleSync"
VehicleSyncHud.MOD_DIRECTORY = g_currentModDirectory or ""
VehicleSyncHud.ICON_FILENAME = "textures/hud_icons.dds"
VehicleSyncHud.SETTINGS_FILENAME = "FS25_VehicleSync.xml"
VehicleSyncHud.XML_ROOT = "vehicleSync"
VehicleSyncHud.DEFAULT_LEFT = 0.8
VehicleSyncHud.DEFAULT_TOP = 0.8
VehicleSyncHud.MIN_TEXT_SCALE = 0.7
VehicleSyncHud.MESSAGE_DURATION = 4000  -- ms a message stays in the banner

---Resets the runtime state (file load and delete)
function VehicleSyncHud:reset()
    self.isOpen = false
    self.vehicle = nil
    self.cursorOwned = false
    self.lockedCameras = nil
    self.isDragging = false
    self.dragOffsetX = 0
    self.dragOffsetY = 0
    self.hoverId = nil
    self.hits = {}
    self.width = 0
    self.height = 0
    self.left = nil
    self.top = nil
    self.message = nil
end

VehicleSyncHud:reset()

-- ---------------------------------------------------------------------------
-- Opening, closing, cursor
-- ---------------------------------------------------------------------------

---VS_TOGGLE_HUD: opens the terminal, or brings the cursor back while it is open
function VehicleSyncHud:toggle(vehicle)
    if self.isOpen and self.vehicle ~= vehicle then
        self:setCursor(false)
    end
    self.isOpen = true
    self.vehicle = vehicle
    self:setCursor(true)
end

function VehicleSyncHud:close()
    self:setCursor(false)
    self.isOpen = false
    self.vehicle = nil
    self.isDragging = false
    self.hoverId = nil
    self.message = nil
end

---Shows or hides the mouse cursor. A cursor this HUD did not show is never hidden.
function VehicleSyncHud:setCursor(show)
    if show == self.cursorOwned then
        return
    end
    self.cursorOwned = show
    g_inputBinding:setShowMouseCursor(show)
    self:lockCamera(show)
    if not show then
        self.isDragging = false
        self.hoverId = nil
    end
end

---Mouse look would turn the camera while the cursor moves over the panel
function VehicleSyncHud:lockCamera(lock)
    if lock then
        self.lockedCameras = {}
        local enterable = self.vehicle ~= nil and self.vehicle.spec_enterable or nil
        if enterable ~= nil and enterable.cameras ~= nil then
            for _, camera in ipairs(enterable.cameras) do
                table.insert(self.lockedCameras, { camera = camera, isRotatable = camera.isRotatable })
                camera.isRotatable = false
            end
        end
    elseif self.lockedCameras ~= nil then
        for _, entry in ipairs(self.lockedCameras) do
            entry.camera.isRotatable = entry.isRotatable
        end
        self.lockedCameras = nil
    end
end

function VehicleSyncHud:getIsBlocked()
    return g_gui:getIsGuiVisible() or g_noHudModeEnabled
end

---True if the terminal is visible for this vehicle
function VehicleSyncHud:getIsShowing(vehicle)
    return self.isOpen and vehicle ~= nil and self.vehicle == vehicle and not self:getIsBlocked()
end

---Shows a message in the banner of the terminal instead of a game notification
---@return boolean shown false if the terminal is not visible for this vehicle
function VehicleSyncHud:showMessage(vehicle, text, isWarning)
    if not self:getIsShowing(vehicle) then
        return false
    end
    self.message = { text = text, isWarning = isWarning == true, untilTime = g_time + VehicleSyncHud.MESSAGE_DURATION }
    return true
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

function VehicleSyncHud:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.isOpen or not self.cursorOwned or self:getIsBlocked() then
        return
    end

    if isDown and button == Input.MOUSE_BUTTON_RIGHT then
        self:setCursor(false)
        return
    end

    if self.isDragging then
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            self.isDragging = false
            self:savePosition()
            return
        end
        self.left, self.top = VehicleSyncHudLayout.clampPanel(posX - self.dragOffsetX, posY - self.dragOffsetY, self.width, self.height)
        return
    end

    local hit = VehicleSyncHudLayout.hitTest(self.hits, posX, posY)
    self.hoverId = hit ~= nil and hit.id or nil
    if hit == nil or not isDown or button ~= Input.MOUSE_BUTTON_LEFT then
        return
    end

    if hit.id == "close" then
        self:close()
    elseif hit.id == "header" then
        self.isDragging = true
        self.dragOffsetX = posX - self.left
        self.dragOffsetY = posY - self.top
    elseif hit.button ~= nil and hit.button.enabled then
        self.vehicle:vsRequest(VehicleSyncSpec.ACTION[hit.button.action], hit.button.argument)
    end
end

-- ---------------------------------------------------------------------------
-- Position (per player, in modSettings)
-- ---------------------------------------------------------------------------

function VehicleSyncHud.getSettingsPath()
    if g_modSettingsDirectory == nil then
        return nil
    end
    return g_modSettingsDirectory .. VehicleSyncHud.SETTINGS_FILENAME
end

function VehicleSyncHud:loadPosition()
    local path = VehicleSyncHud.getSettingsPath()
    if path == nil then
        return
    end
    local xmlFile = XMLFile.loadIfExists("vehicleSyncHud", path)
    if xmlFile == nil then
        return
    end
    local left = xmlFile:getFloat(VehicleSyncHud.XML_ROOT .. ".hud#left")
    local top = xmlFile:getFloat(VehicleSyncHud.XML_ROOT .. ".hud#top")
    if left ~= nil and top ~= nil then
        self.left, self.top = left, top
    end
    xmlFile:delete()
end

function VehicleSyncHud:savePosition()
    local path = VehicleSyncHud.getSettingsPath()
    if path == nil or self.left == nil then
        return
    end
    createFolder(g_modSettingsDirectory)
    local xmlFile = XMLFile.create("vehicleSyncHud", path, VehicleSyncHud.XML_ROOT)
    if xmlFile == nil then
        return
    end
    xmlFile:setFloat(VehicleSyncHud.XML_ROOT .. ".hud#left", self.left)
    xmlFile:setFloat(VehicleSyncHud.XML_ROOT .. ".hud#top", self.top)
    xmlFile:save()
    xmlFile:delete()
end

-- ---------------------------------------------------------------------------
-- Snapshot of the vehicle state
-- ---------------------------------------------------------------------------

local function getFillRatio(vehicle)
    local receiver = VehicleSyncSpec.findReceiver(vehicle)
    if receiver == nil then
        return nil
    end
    return VehicleSyncSpec.getReceiverFillRatio(receiver)
end

---Collects everything the view model needs (works on clients: all values are replicated)
function VehicleSyncHud.buildSnapshot(vehicle)
    local ROLE = VehicleSyncHudLayout.ROLE
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local snapshot = {
        role = VehicleSyncHudLayout.getRole(spec.networkEnabled, spec.state, vehicle:vsGetHasPipe()),
        state = spec.state,
        stateText = VehicleSyncSpec.getStateText(spec.state),
        home = spec.home,
        live = spec.live,
        followers = {},
    }

    if snapshot.role == ROLE.FOLLOWER then
        local leader = vehicle:vsGetLeader()
        snapshot.partnerName = leader ~= nil and leader:getName() or "-"
        snapshot.fillRatio = getFillRatio(vehicle)
        if leader ~= nil then
            snapshot.pipe = (VehicleSyncSpec.measurePipe(leader))
        end
    elseif snapshot.role == ROLE.LEADER then
        snapshot.pipe = (VehicleSyncSpec.measurePipe(vehicle))
        for _, follower in ipairs(vehicle:vsGetFollowers()) do
            local followerSpec = VehicleSyncSpec.getSpec(follower)
            table.insert(snapshot.followers, { state = followerSpec.state, home = followerSpec.home,
                live = followerSpec.live, fillRatio = getFillRatio(follower) })
        end
    elseif snapshot.role == ROLE.TRACTOR then
        local leader, distance = VehicleSyncSpec.findNearestLeader(vehicle)
        if leader ~= nil then
            snapshot.nearest = { name = leader:getName(), distance = distance }
        end
    end

    return snapshot
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

function VehicleSyncHud.getText(key)
    return g_i18n:getText(key, VehicleSyncHud.MOD_NAME)
end

---Normalised size of one reference pixel, UI scale included
function VehicleSyncHud.getUnits()
    local unitX, unitY = getNormalizedScreenValues(1, 1)
    local scale = 1
    if g_gameSettings ~= nil then
        scale = g_gameSettings:getValue("uiScale") or 1
    end
    return unitX * scale, unitY * scale
end

function VehicleSyncHud:draw()
    if not self.isOpen then
        return
    end
    local vehicle = self.vehicle
    if not VehicleSyncSpec.isValidVehicle(vehicle) or not vehicle:getIsEntered() then
        self:close()
        return
    end
    if self:getIsBlocked() then
        return
    end

    if self.overlay == nil then
        self.overlay = Overlay.new(Utils.getFilename(VehicleSyncHud.ICON_FILENAME, VehicleSyncHud.MOD_DIRECTORY), 0, 0, 1, 1)
    end

    local view = VehicleSyncHudLayout.buildView(VehicleSyncHud.buildSnapshot(vehicle), VehicleSyncHud.getText)
    local unitX, unitY = VehicleSyncHud.getUnits()
    local lay = VehicleSyncHudLayout.layout(view, 0, 1, unitX, unitY)
    self.width, self.height = lay.width, lay.height
    self.left, self.top = VehicleSyncHudLayout.clampPanel(self.left or VehicleSyncHud.DEFAULT_LEFT,
        self.top or VehicleSyncHud.DEFAULT_TOP, lay.width, lay.height)
    lay = VehicleSyncHudLayout.layout(view, self.left, self.top, unitX, unitY)
    self.hits = lay.hits

    self:render(view, lay)
end

---Draws an atlas cell into a rectangle
function VehicleSyncHud:drawIcon(icon, x, y, w, h, color)
    local overlay = self.overlay
    overlay:setUVs(VehicleSyncHudLayout.getIconUVs(icon))
    overlay:setPosition(x, y)
    overlay:setDimension(w, h)
    overlay:setColor(color[1], color[2], color[3], color[4])
    overlay:render()
end

function VehicleSyncHud:drawRect(r, color)
    self:drawIcon(VehicleSyncHudLayout.ICON.SOLID, r.x, r.y, r.w, r.h, color)
end

---Draws an icon of the given reference size centred on a point
function VehicleSyncHud:drawIconAt(icon, x, y, sizeX, sizeY, lay, color)
    local w, h = sizeX * lay.unitX, sizeY * lay.unitY
    self:drawIcon(icon, x - w / 2, y - h / 2, w, h, color)
end

---Renders a text vertically centred on y; shrinks it (down to MIN_TEXT_SCALE) to fit maxWidth
function VehicleSyncHud:drawText(x, y, sizePx, text, color, alignment, bold, maxWidth, lay)
    local size = sizePx * lay.unitY
    if maxWidth ~= nil then
        local width = getTextWidth(size, text)
        if width > maxWidth then
            size = size * math.max(VehicleSyncHud.MIN_TEXT_SCALE, maxWidth / width)
        end
    end
    setTextBold(bold == true)
    setTextColor(color[1], color[2], color[3], color[4])
    setTextAlignment(alignment)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    renderText(x, y, size, text)
end

function VehicleSyncHud:render(view, lay)
    local C = VehicleSyncHudLayout.COLOR
    local S = VehicleSyncHudLayout.SIZE
    local padX = S.PADDING * lay.unitX

    self:drawRect(lay.panel, C.GLASS)

    -- header: drag handle, title, partner, close
    local header = lay.header
    local headerY = header.y + header.h / 2
    self:drawRect(header, (self.isDragging or self.hoverId == "header") and C.BEZEL_HOVER or C.BEZEL)
    self:drawText(header.x + padX, headerY, S.TEXT_TITLE, view.title, C.PAPER, RenderText.ALIGN_LEFT, true, nil, lay)
    if view.partner ~= nil then
        self:drawText(lay.close.x, headerY, S.TEXT_BODY, view.partner, C.PAPER, RenderText.ALIGN_RIGHT, false, header.w / 2, lay)
    end
    local close = lay.close
    self:drawIconAt(VehicleSyncHudLayout.ICON.CLOSE, close.x + close.w / 2, headerY, S.CLOSE_ICON, S.CLOSE_ICON, lay,
        self.hoverId == "close" and C.WARNING or C.PAPER)

    -- state band
    local band = lay.band
    local bandY = band.y + band.h / 2
    self:drawRect(band, VehicleSyncHudLayout.withAlpha(view.stateColor, 0.18))
    self:drawRect(lay.bar, view.stateColor)
    self:drawText(lay.bar.x + lay.bar.w + padX, bandY, S.TEXT_STATE, view.stateText, C.PAPER, RenderText.ALIGN_LEFT, true, nil, lay)
    if view.fillText ~= nil then
        self:drawText(band.x + band.w - padX, bandY, S.TEXT_BODY, view.fillText, C.PAPER, RenderText.ALIGN_RIGHT, true, nil, lay)
    end

    self:renderPlan(view.plan, lay)
    self:renderMessage(lay)

    if lay.readout ~= nil then
        local readout = lay.readout
        local readoutY = readout.y + readout.h / 2
        if view.readout.message ~= nil then
            local color = view.readout.warning and C.WARNING or C.PAPER
            self:drawText(readout.x, readoutY, S.TEXT_BODY, view.readout.message, color, RenderText.ALIGN_LEFT, view.readout.warning == true, readout.w, lay)
        else
            local half = readout.w / 2
            for i, entry in ipairs({ view.readout.left, view.readout.right }) do
                local x = readout.x + (i - 1) * half
                self:drawText(x, readoutY, S.TEXT_BODY, entry.label, C.PAPER, RenderText.ALIGN_LEFT, false, nil, lay)
                self:drawText(x + half - padX, readoutY, S.TEXT_BODY, entry.value, C.PAPER, RenderText.ALIGN_RIGHT, true, nil, lay)
            end
        end
    end

    for i, item in ipairs(lay.buttons) do
        self:renderButton(item, self.hoverId == "button" .. i, lay)
    end

    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
end

function VehicleSyncHud:renderPlan(plan, lay)
    local C = VehicleSyncHudLayout.COLOR
    local S = VehicleSyncHudLayout.SIZE
    local ICON = VehicleSyncHudLayout.ICON
    local r = lay.plan
    self:drawRect(r, C.STUBBLE)

    if plan.empty ~= nil then
        self:drawText(r.x + r.w / 2, r.y + r.h / 2, S.TEXT_BODY, plan.empty, C.PAPER, RenderText.ALIGN_CENTER, false,
            r.w - 2 * S.PADDING * lay.unitX, lay)
        return
    end

    -- operational zone (only in the zone view; the close-up lies inside it): faint fill and outline
    if plan.zoom ~= VehicleSyncHudLayout.ZOOM.CLOSE then
        local zone = VehicleSyncHudLayout.getZoneRect(lay)
        local lineX, lineY = lay.unitX, lay.unitY
        local outline = VehicleSyncHudLayout.withAlpha(C.STRAW, 0.8)
        self:drawRect(zone, VehicleSyncHudLayout.withAlpha(C.STRAW, 0.06))
        self:drawRect({ x = zone.x, y = zone.y, w = zone.w, h = lineY }, outline)
        self:drawRect({ x = zone.x, y = zone.y + zone.h - lineY, w = zone.w, h = lineY }, outline)
        self:drawRect({ x = zone.x, y = zone.y, w = lineX, h = zone.h }, outline)
        self:drawRect({ x = zone.x + zone.w - lineX, y = zone.y, w = lineX, h = zone.h }, outline)
    end

    local leaderX, leaderY = VehicleSyncHudLayout.project(lay, 0, 0)
    self:drawIconAt(ICON.HARVESTER, leaderX, leaderY, S.LEADER_ICON_W, S.LEADER_ICON_H, lay, C.PAPER)

    for _, item in ipairs(plan.carts) do
        local homeX, homeY = VehicleSyncHudLayout.project(lay, item.home.x, item.home.z)
        if plan.pipe ~= nil then
            -- grain stream: from the harvester's side at the height of the pipe outlet to the home point
            local side = plan.pipe.x < 0 and 1 or -1
            local _, pipeY = VehicleSyncHudLayout.project(lay, plan.pipe.x, plan.pipe.z)
            self:drawDottedLine(leaderX + side * S.LEADER_ICON_W / 2 * lay.unitX, pipeY, homeX, homeY, lay)
        end
        local cartX, cartY = VehicleSyncHudLayout.project(lay, item.cart.x, item.cart.z)
        self:drawIconAt(ICON.CART, cartX, cartY, S.CART_ICON_W, S.CART_ICON_H, lay, item.color)
        -- the target on top: the cart has to be moved below it
        self:drawIconAt(ICON.HOME, homeX, homeY, S.HOME_ICON, S.HOME_ICON, lay, C.STRAW)
    end
end

---Message banner across the top of the plan view (red for warnings, green otherwise)
function VehicleSyncHud:renderMessage(lay)
    local message = self.message
    if message == nil then
        return
    end
    if g_time > message.untilTime then
        self.message = nil
        return
    end
    local C = VehicleSyncHudLayout.COLOR
    local S = VehicleSyncHudLayout.SIZE
    local banner = lay.banner
    local fill = message.isWarning and C.WARNING or C.TRACKING
    local ink = message.isWarning and C.PAPER or C.INK
    self:drawRect(banner, VehicleSyncHudLayout.withAlpha(fill, 0.92))
    self:drawText(banner.x + banner.w / 2, banner.y + banner.h / 2, S.TEXT_BODY, message.text, ink, RenderText.ALIGN_CENTER, true,
        banner.w - 2 * S.PADDING * lay.unitX, lay)
end

---Straw dots from the harvester to the home point
function VehicleSyncHud:drawDottedLine(x1, y1, x2, y2, lay)
    local S = VehicleSyncHudLayout.SIZE
    local dx, dy = (x2 - x1) / lay.unitX, (y2 - y1) / lay.unitY
    local count = math.floor(math.sqrt(dx * dx + dy * dy) / S.DOT_SPACING)
    for i = 0, count do
        local t = count > 0 and i / count or 0
        self:drawIconAt(VehicleSyncHudLayout.ICON.SOLID, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, S.DOT, S.DOT, lay,
            VehicleSyncHudLayout.COLOR.STRAW)
    end
end

function VehicleSyncHud:renderButton(item, hovered, lay)
    local C = VehicleSyncHudLayout.COLOR
    local S = VehicleSyncHudLayout.SIZE
    local b, r = item.button, item.rect

    local face, ink = C.BEZEL, C.PAPER
    if not b.enabled then
        face, ink = C.BEZEL_DISABLED, C.PAPER_DISABLED
    elseif b.primary then
        face, ink = b.color, C.INK
    elseif hovered then
        face = C.BEZEL_HOVER
    end
    self:drawRect(r, face)

    local centerX, centerY = r.x + r.w / 2, r.y + r.h / 2
    if b.icon ~= nil then
        self:drawIconAt(b.icon, centerX, centerY, S.BUTTON_ICON, S.BUTTON_ICON, lay, ink)
    else
        self:drawText(centerX, centerY, S.TEXT_BUTTON, b.text, ink, RenderText.ALIGN_CENTER, true,
            r.w - S.PADDING * lay.unitX, lay)
    end
end

function VehicleSyncHud:delete()
    self:close()
    if self.overlay ~= nil then
        self.overlay:delete()
        self.overlay = nil
    end
    self:reset()
end
