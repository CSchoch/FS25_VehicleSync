local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()
local V = dofile("tests/mocks/vehicles.lua")

local Hud = VehicleSyncHud
local Layout = VehicleSyncHudLayout
local Spec = VehicleSyncSpec
local STATE = VehicleSyncController.STATE
local ACTION = Spec.ACTION
local NUDGE = VehicleSyncController.NUDGE
local LEFT, RIGHT = Input.MOUSE_BUTTON_LEFT, Input.MOUSE_BUTTON_RIGHT
local SETTINGS_PATH = "modSettings/FS25_VehicleSync.xml"

local function drawnTexts()
    local list = {}
    for _, t in ipairs(engine.drawn.texts) do
        list[t.text] = t
    end
    return list
end

local function center(r)
    return r.x + r.w / 2, r.y + r.h / 2
end

local function hitById(id)
    for _, hit in ipairs(Hud.hits) do
        if hit.id == id then
            return hit
        end
    end
    return nil
end

local function click(id)
    local x, y = center(hitById(id).rect)
    Hud:mouseEvent(x, y, true, false, LEFT)
    Hud:mouseEvent(x, y, false, true, LEFT)
end

local function recordRequests(vehicle)
    local calls = {}
    vehicle.vsRequest = function(self, action, argument)
        table.insert(calls, { action = action, argument = argument })
    end
    return calls
end

local function rectsWithColor(color)
    local count = 0
    for _, r in ipairs(engine.drawn.rects) do
        if r.color[1] == color[1] and r.color[2] == color[2] and r.color[3] == color[3] and r.color[4] == color[4] then
            count = count + 1
        end
    end
    return count
end

local function connectedScene(opts)
    local leader, follower = V.createScene(opts)
    leader:vsSetNetworkEnabled(true)
    Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
    return leader, follower
end

describe("VehicleSyncHud", function()
    before_each(function()
        engine.reset()
        engine.loadTranslations()
        VehicleSyncSettings.reset()
        Hud:reset()
        Hud.overlay = nil
    end)

    describe("opening, cursor and closing", function()
        it("opens with the cursor and locks the cameras; the key again only brings the cursor back", function()
            local v = V.create({ entered = true })
            local cameraA, cameraB = { isRotatable = true }, { isRotatable = false }
            v.spec_enterable = { cameras = { cameraA, cameraB } }

            Hud:toggle(v)
            assert.is_true(Hud.isOpen)
            assert.is_true(g_inputBinding.showMouseCursor)
            assert.is_false(cameraA.isRotatable)

            Hud:toggle(v)
            assert.same({ true }, g_inputBinding.cursorCalls)

            -- right click: mouse look again, the terminal stays open
            Hud:mouseEvent(0.5, 0.5, true, false, RIGHT)
            assert.is_true(Hud.isOpen)
            assert.is_false(g_inputBinding.showMouseCursor)
            assert.is_true(cameraA.isRotatable)
            assert.is_false(cameraB.isRotatable)

            Hud:toggle(v)
            assert.is_true(g_inputBinding.showMouseCursor)
            assert.is_true(Hud.isOpen)
        end)
        it("closes only with the close button and releases the cursor", function()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            Hud:draw()
            click("close")
            assert.is_false(Hud.isOpen)
            assert.is_false(g_inputBinding.showMouseCursor)
            assert.is_nil(Hud.vehicle)
        end)
        it("never hides a cursor it did not show", function()
            Hud:close()
            Hud:setCursor(false)
            assert.same({}, g_inputBinding.cursorCalls)
        end)
        it("moves to another vehicle and releases the cameras of the first one", function()
            local first, second = V.create({ entered = true }), V.create({ entered = true })
            local camera = { isRotatable = true }
            first.spec_enterable = { cameras = { camera } }
            Hud:toggle(first)
            Hud:toggle(second)
            assert.equals(second, Hud.vehicle)
            assert.is_true(camera.isRotatable)
            assert.is_true(g_inputBinding.showMouseCursor)
        end)
        it("closes itself when the vehicle is left or deleted", function()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            v.entered = false
            Hud:draw()
            assert.is_false(Hud.isOpen)
            assert.is_false(g_inputBinding.showMouseCursor)
            Hud:toggle(v)
            v.isDeleted = true
            Hud:draw()
            assert.is_false(Hud.isOpen)
        end)
        it("deletes its overlay and state", function()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            Hud:draw()
            local overlay = Hud.overlay
            Hud:delete()
            assert.is_true(overlay.deleted)
            assert.is_nil(Hud.overlay)
            assert.is_false(Hud.isOpen)
            assert.is_false(g_inputBinding.showMouseCursor)
            Hud:delete()
        end)
    end)

    describe("drawing", function()
        it("draws nothing while closed, in menus or in no-HUD mode", function()
            Hud:draw()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            g_gui.visible = true
            Hud:draw()
            g_gui.visible = false
            g_noHudModeEnabled = true
            Hud:draw()
            assert.equals(0, #engine.drawn.rects)
            assert.is_true(Hud.isOpen)
        end)
        it("draws the terminal of a follower with its plan view", function()
            local _, follower = connectedScene()
            Spec.getSpec(follower).live.inZone = true
            Hud:toggle(follower)
            Hud:draw()

            assert.equals("textures/hud_icons.dds", Hud.overlay.filename)
            local t = drawnTexts()
            for _, text in ipairs({ "Vehicle Sync", "Harvester", "Connected", "Cart 0 %", "In the operational zone",
                "Leave", "Engage", "Set home" }) do
                assert.is_not_nil(t[text], text)
            end
            assert.is_true(t["Vehicle Sync"].bold)
            assert.equals(RenderText.ALIGN_RIGHT, t["Harvester"].alignment)
            -- the primary button is drawn with dark ink on the tracking colour
            assert.same(Layout.COLOR.INK, t["Engage"].color)
            assert.is_true(rectsWithColor(Layout.COLOR.TRACKING) >= 1)
            -- plan view: stubble ground, zone outline, harvester, dotted pipe line, home and cart
            assert.equals(1, rectsWithColor(Layout.COLOR.STUBBLE))
            assert.equals(4, rectsWithColor(Layout.withAlpha(Layout.COLOR.STRAW, 0.8)))
            -- grain stream dots from the harvester to the home point plus the home crosshair
            assert.is_greater(2, rectsWithColor(Layout.COLOR.STRAW))
            -- text state is reset for the rest of the game HUD
            assert.equals(RenderText.VERTICAL_ALIGN_BASELINE, engine.textState.verticalAlignment)
            assert.is_false(engine.textState.bold)
            -- default position, kept on the screen
            assert.equals(Hud.DEFAULT_TOP, Hud.top)
            assert.is_true(Hud.left + Hud.width <= 1)
        end)
        it("shows the deviation while engaged and skips the pipe line with a folded pipe", function()
            local leader, follower = connectedScene()
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            Spec.getSpec(follower).live = { lateralError = 0.25, alongError = -1.5, inZone = true, check = 0, abortRemaining = 0 }
            V.setPipe(leader, 7, 2, false)
            Hud:toggle(follower)
            Hud:draw()
            local t = drawnTexts()
            assert.is_not_nil(t["Lateral"])
            assert.is_not_nil(t["+0.25 m"])
            assert.is_not_nil(t["-1.50 m"])
            assert.is_not_nil(t["Disengage"])
            assert.same(Layout.COLOR.INK, t["Disengage"].color)
            -- close-up: no zone outline, and no grain stream with a folded pipe
            assert.equals(0, rectsWithColor(Layout.withAlpha(Layout.COLOR.STRAW, 0.8)))
            assert.equals(1, rectsWithColor(Layout.COLOR.STRAW))
        end)
        it("draws the leader's terminal with the nudge pad", function()
            local leader, follower = connectedScene({ leaderEntered = true })
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            Hud:toggle(leader)
            Hud:draw()
            local t = drawnTexts()
            for _, text in ipairs({ "Network open", "Carts: 1", "Close network", "Release cart", "Cart 0 %" }) do
                assert.is_not_nil(t[text], text)
            end
            local arrows = 0
            local up = Layout.getIconUVs(Layout.ICON.ARROW_UP)
            for _, r in ipairs(engine.drawn.rects) do
                if r.uvs ~= nil and r.uvs[1] == up[1] and r.uvs[2] == up[2] then
                    arrows = arrows + 1
                end
            end
            assert.equals(1, arrows)
        end)
        it("shows a closed harvester and a tractor looking for a network", function()
            local harvester = V.create({ hasPipe = true, entered = true })
            Hud:toggle(harvester)
            Hud:draw()
            local t = drawnTexts()
            assert.is_not_nil(t["Network closed"])
            assert.is_not_nil(t["Open the network so a cart can join"])
            assert.equals(RenderText.ALIGN_CENTER, t["Open network"].alignment)

            local leader, tractor = V.createScene()
            Hud:toggle(tractor)
            engine.drawn.texts = {}
            Hud:draw()
            assert.is_not_nil(drawnTexts()["No open sync network nearby"])
            leader:vsSetNetworkEnabled(true)
            engine.drawn.texts = {}
            Hud:draw()
            assert.is_not_nil(drawnTexts()["Nearest network: Harvester, 11 m"])
        end)
        it("draws a follower without leader or cart", function()
            local v = V.create({ entered = true })
            Spec.getSpec(v).state = STATE.CONNECTED
            Hud:toggle(v)
            Hud:draw()
            assert.is_not_nil(drawnTexts()["-"])
        end)
        it("shrinks texts that do not fit", function()
            local leader, follower = connectedScene()
            leader.name = "A harvester with a really very long name that does not fit"
            Hud:toggle(follower)
            Hud:draw()
            local partner = drawnTexts()[leader.name]
            assert.near(Layout.SIZE.TEXT_BODY / 1080 * Hud.MIN_TEXT_SCALE, partner.size)
        end)
        it("scales with the UI scale", function()
            g_gameSettings.values.uiScale = 1.5
            local unitX, unitY = Hud.getUnits()
            assert.near(1.5 / 1920, unitX)
            assert.near(1.5 / 1080, unitY)
            g_gameSettings.values.uiScale = nil
            assert.near(1 / 1920, (Hud.getUnits()))
            local saved = g_gameSettings
            g_gameSettings = nil
            assert.near(1 / 1080, select(2, Hud.getUnits()))
            g_gameSettings = saved
        end)
    end)

    describe("mouse", function()
        it("sends the request of a clicked button", function()
            local leader, follower = connectedScene({ leaderEntered = true })
            local calls = recordRequests(leader)
            Hud:toggle(leader)
            Hud:draw()
            click("button1")
            click("button3")
            click("button6")
            -- release is disabled while no cart is engaged
            click("button2")
            assert.same({
                { action = ACTION.TOGGLE_NETWORK, argument = 0 },
                { action = ACTION.NUDGE, argument = NUDGE.FORWARD },
                { action = ACTION.NUDGE, argument = NUDGE.RIGHT },
            }, calls)
        end)
        it("highlights the hovered button and ignores clicks on the panel", function()
            local _, follower = connectedScene()
            local calls = recordRequests(follower)
            Hud:toggle(follower)
            Hud:draw()
            local x, y = center(hitById("button1").rect)
            Hud:mouseEvent(x, y, false, false, 0)
            assert.equals("button1", Hud.hoverId)
            engine.drawn.rects = {}
            Hud:draw()
            assert.equals(1, rectsWithColor(Layout.COLOR.BEZEL_HOVER))
            click("panel")
            Hud:mouseEvent(0.001, 0.001, true, false, LEFT)
            assert.is_nil(Hud.hoverId)
            assert.same({}, calls)
        end)
        it("ignores the mouse while closed, without the cursor or in menus", function()
            local _, follower = connectedScene()
            local calls = recordRequests(follower)
            Hud:mouseEvent(0.5, 0.5, true, false, LEFT)
            Hud:toggle(follower)
            Hud:draw()
            local x, y = center(hitById("button1").rect)
            g_gui.visible = true
            Hud:mouseEvent(x, y, true, false, LEFT)
            g_gui.visible = false
            Hud:mouseEvent(x, y, true, false, RIGHT)
            Hud:mouseEvent(x, y, true, false, LEFT)
            assert.same({}, calls)
            assert.is_true(Hud.isOpen)
        end)
        it("drags the panel by its header, keeps it on the screen and saves the position", function()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            Hud:draw()
            local x, y = center(hitById("header").rect)
            local startLeft, startTop = Hud.left, Hud.top
            Hud:mouseEvent(x, y, true, false, LEFT)
            assert.is_true(Hud.isDragging)
            Hud:mouseEvent(x - 0.2, y - 0.1, false, false, 0)
            assert.near(startLeft - 0.2, Hud.left)
            assert.near(startTop - 0.1, Hud.top)
            -- a right button release does not end the drag
            Hud:mouseEvent(x - 5, y + 5, false, true, 0)
            assert.equals(0, Hud.left)
            assert.equals(1, Hud.top)
            Hud:mouseEvent(x - 5, y + 5, false, true, LEFT)
            assert.is_false(Hud.isDragging)
            assert.same({ "modSettings/" }, engine.createdFolders)
            assert.equals(0, engine.files[SETTINGS_PATH]["vehicleSync.hud#left"])
            assert.equals(1, engine.files[SETTINGS_PATH]["vehicleSync.hud#top"])

            Hud:reset()
            Hud:loadPosition()
            assert.equals(0, Hud.left)
            assert.equals(1, Hud.top)
        end)
        it("stops dragging when the cursor is hidden", function()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            Hud:draw()
            local x, y = center(hitById("header").rect)
            Hud:mouseEvent(x, y, true, false, LEFT)
            Hud:mouseEvent(x, y, true, false, RIGHT)
            assert.is_false(Hud.isDragging)
        end)
    end)

    describe("messages", function()
        local function bannerTexts()
            local list = {}
            for _, t in ipairs(engine.drawn.texts) do
                table.insert(list, t.text)
            end
            return list
        end

        it("takes messages only while the terminal is visible for that vehicle", function()
            local v, other = V.create({ entered = true }), V.create({ entered = true })
            assert.is_false(Hud:showMessage(v, "text", false))
            Hud:toggle(v)
            assert.is_false(Hud:showMessage(other, "text", false))
            assert.is_false(Hud:showMessage(nil, "text", false))
            g_gui.visible = true
            assert.is_false(Hud:showMessage(v, "text", false))
            g_gui.visible = false
            assert.is_true(Hud:showMessage(v, "text", false))
            assert.is_true(Hud:getIsShowing(v))
        end)
        it("draws warnings red and other messages green for four seconds", function()
            local v = V.create({ entered = true })
            Hud:toggle(v)
            Hud:showMessage(v, "Sync ended: harvester too fast", true)
            Hud:draw()
            assert.contains(bannerTexts(), "Sync ended: harvester too fast")
            assert.equals(1, rectsWithColor(Layout.withAlpha(Layout.COLOR.WARNING, 0.92)))
            assert.same(Layout.COLOR.PAPER, drawnTexts()["Sync ended: harvester too fast"].color)

            Hud:showMessage(v, "Home point saved", false)
            engine.drawn = { lines = {}, rects = {}, texts = {} }
            Hud:draw()
            assert.equals(1, rectsWithColor(Layout.withAlpha(Layout.COLOR.TRACKING, 0.92)))
            assert.same(Layout.COLOR.INK, drawnTexts()["Home point saved"].color)

            g_time = Hud.MESSAGE_DURATION + 1
            engine.drawn = { lines = {}, rects = {}, texts = {} }
            Hud:draw()
            assert.not_contains(bannerTexts(), "Home point saved")
            assert.is_nil(Hud.message)
        end)
        it("replaces the game notifications of both operators while the terminal is open", function()
            local leader, follower = connectedScene({ leaderEntered = true })
            g_currentMission.notifications, g_currentMission.warnings = {}, {}
            Hud:toggle(follower)
            follower:vsShowReason(VehicleSyncController.REASON.LEADER_TOO_FAST)
            assert.equals("Sync ended: harvester too fast", Hud.message.text)
            assert.is_true(Hud.message.isWarning)
            assert.same({}, g_currentMission.warnings)

            -- the harvester driver sees the cart's message in his terminal, named by the cart
            follower.entered = false
            Hud:toggle(leader)
            follower:vsShowReason(VehicleSyncController.REASON.HOME_SET)
            assert.equals("Tractor: Home point saved", Hud.message.text)
            Spec.showLeaderNetworkText(leader, true)
            assert.equals("Sync network opened", Hud.message.text)
            assert.same({}, g_currentMission.notifications)

            -- closed terminal: the game shows them
            Hud:close()
            follower:vsShowReason(VehicleSyncController.REASON.HOME_SET)
            assert.same({ "Tractor: Home point saved" }, g_currentMission.notifications)
        end)
        it("leaves the abort countdown to an open terminal", function()
            local _, follower = connectedScene()
            local spec = Spec.getSpec(follower)
            spec.state = STATE.TRACKING
            spec.live.check, spec.live.abortRemaining = VehicleSyncController.REASON.LEADER_STOPPED, 2000
            Hud:toggle(follower)
            Spec.showAbortWarning(follower)
            assert.same({}, g_currentMission.warnings)
            Hud:close()
            Spec.showAbortWarning(follower)
            assert.same({ "Sync ends in 2 s: Harvester stopped" }, g_currentMission.warnings)
        end)
    end)

    describe("position file", function()
        it("keeps the default without a file, a directory or a complete entry", function()
            Hud:loadPosition()
            assert.is_nil(Hud.left)
            engine.files[SETTINGS_PATH] = { ["vehicleSync.hud#left"] = 0.2 }
            Hud:loadPosition()
            assert.is_nil(Hud.left)
            g_modSettingsDirectory = nil
            Hud:loadPosition()
            Hud.left, Hud.top = 0.1, 0.9
            Hud:savePosition()
            assert.equals(0.2, engine.files[SETTINGS_PATH]["vehicleSync.hud#left"])
        end)
        it("saves nothing before the panel was placed or when the file cannot be created", function()
            Hud:savePosition()
            assert.is_nil(engine.files[SETTINGS_PATH])
            local create = XMLFile.create
            XMLFile.create = function() return nil end
            Hud.left, Hud.top = 0.1, 0.9
            Hud:savePosition()
            XMLFile.create = create
            assert.is_nil(engine.files[SETTINGS_PATH])
        end)
    end)
end)
