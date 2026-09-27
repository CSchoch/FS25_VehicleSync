local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()

local Layout = VehicleSyncHudLayout
local STATE = VehicleSyncController.STATE
local NUDGE = VehicleSyncController.NUDGE
local ROLE = Layout.ROLE
local COLOR = Layout.COLOR
local ICON = Layout.ICON

local UNIT_X, UNIT_Y = 1 / 1920, 1 / 1080

local function getText(key)
    return g_i18n:getText(key)
end

local REASON = VehicleSyncController.REASON

local function live(lateral, along, inZone, check, abortRemaining)
    return { lateralError = lateral or 0, alongError = along or 0, inZone = inZone == true,
        check = check or REASON.NONE, abortRemaining = abortRemaining or 0 }
end

local function follower(opts)
    opts = opts or {}
    return {
        role = ROLE.FOLLOWER,
        state = opts.state or STATE.CONNECTED,
        stateText = "Connected",
        partnerName = "Harvester",
        home = opts.home,
        live = opts.live or live(),
        fillRatio = opts.fillRatio,
        pipe = opts.pipe,
        followers = {},
    }
end

local function leader(followers)
    return { role = ROLE.LEADER, state = STATE.IDLE, stateText = "Off", live = live(), followers = followers or {}, pipe = { x = 7, z = 2 } }
end

local function texts(buttons)
    local list = {}
    for _, b in ipairs(buttons) do
        table.insert(list, b.text or "icon")
    end
    return list
end

local function near(a, b)
    return math.abs(a - b) < 1e-9
end

describe("VehicleSyncHudLayout", function()
    before_each(function()
        engine.reset()
        engine.loadTranslations()
    end)

    describe("tokens", function()
        it("converts sRGB hex colours to linear colours", function()
            assert.same({ 1, 1, 1, 1 }, Layout.fromHex(0xFFFFFF))
            assert.same({ 0, 0, 0, 0.5 }, Layout.fromHex(0x000000, 0.5))
            local dark = Layout.fromHex(0x0A0000)
            assert.near(10 / 255 / 12.92, dark[1])
            assert.near(0.2159, Layout.fromHex(0x808080)[2], 1e-3)
        end)
        it("replaces the alpha of a colour", function()
            assert.same({ 0.1, 0.2, 0.3, 0.4 }, Layout.withAlpha({ 0.1, 0.2, 0.3, 1 }, 0.4))
        end)
        it("maps atlas cells to UVs, sampling the solid cell in its centre", function()
            assert.same({ 0, 0.75, 0, 1, 0.25, 0.75, 0.25, 1 }, Layout.getIconUVs(ICON.HARVESTER))
            assert.same({ 0.75, 0.5, 0.75, 0.75, 1, 0.5, 1, 0.75 }, Layout.getIconUVs(ICON.CLOSE))
            local solid = Layout.getIconUVs(ICON.SOLID)
            assert.near(0.0625, solid[1])
            assert.near(0.1875, solid[5])
            assert.near(0.3125, solid[2])
            assert.near(0.4375, solid[4])
        end)
        it("gives every state its colour", function()
            assert.equals(COLOR.IDLE, Layout.getStateColor(STATE.IDLE))
            assert.equals(COLOR.CONNECTED, Layout.getStateColor(STATE.CONNECTED))
            assert.equals(COLOR.ACQUIRING, Layout.getStateColor(STATE.ACQUIRING))
            assert.equals(COLOR.TRACKING, Layout.getStateColor(STATE.TRACKING))
        end)
        it("picks the role of a vehicle", function()
            assert.equals(ROLE.LEADER, Layout.getRole(true, STATE.IDLE, true))
            assert.equals(ROLE.FOLLOWER, Layout.getRole(false, STATE.TRACKING, false))
            assert.equals(ROLE.HARVESTER, Layout.getRole(false, STATE.IDLE, true))
            assert.equals(ROLE.TRACTOR, Layout.getRole(false, STATE.IDLE, false))
        end)
    end)

    describe("view model", function()
        it("shows a connected follower outside the zone", function()
            local view = Layout.buildView(follower({ home = { x = 7, z = 2 }, live = live(1, -3, false), fillRatio = 0.624, pipe = { x = 7, z = 2 } }), getText)
            assert.equals("Vehicle Sync", view.title)
            assert.equals("Harvester", view.partner)
            assert.equals("Connected", view.stateText)
            assert.equals(COLOR.CONNECTED, view.stateColor)
            assert.equals("Cart 62 %", view.fillText)
            assert.same({ x = 7, z = 2 }, view.plan.pipe)
            assert.equals(Layout.ZOOM.ZONE, view.plan.zoom)
            assert.same({ x = 8, z = -1 }, view.plan.carts[1].cart)
            assert.equals("Drive into the operational zone", view.readout.message)
            assert.equals(Layout.BUTTONS.ROW, view.buttonLayout)
            assert.same({ "Leave", "Engage", "Set home" }, texts(view.buttons))
            assert.same({ "TOGGLE_CONNECT", "TOGGLE_ENGAGE", "SET_HOME" },
                { view.buttons[1].action, view.buttons[2].action, view.buttons[3].action })
            assert.is_true(view.buttons[2].primary)
            assert.equals(COLOR.TRACKING, view.buttons[2].color)
            assert.is_false(view.buttons[3].enabled)
        end)
        it("allows setting the home point inside the zone", function()
            local view = Layout.buildView(follower({ live = live(0, 0, true) }), getText)
            assert.equals("In the operational zone", view.readout.message)
            assert.is_true(view.buttons[3].enabled)
            -- no home point yet: nothing to draw, no fill without a cart
            assert.equals(0, #view.plan.carts)
            assert.is_nil(view.fillText)
        end)
        it("shows the deviation and a disengage button while engaged", function()
            local view = Layout.buildView(follower({ state = STATE.TRACKING, live = live(0.25, -1.5, true) }), getText)
            assert.equals(COLOR.TRACKING, view.stateColor)
            assert.same({ label = "Lateral", value = "+0.25 m" }, view.readout.left)
            assert.same({ label = "Fore/aft", value = "-1.50 m" }, view.readout.right)
            assert.equals("Disengage", view.buttons[2].text)
            assert.equals(Layout.ZOOM.CLOSE, view.plan.zoom)
            assert.equals(COLOR.WARNING, view.buttons[2].color)
        end)
        it("shows a waiting leader with disabled cart controls", function()
            local view = Layout.buildView(leader(), getText)
            assert.equals("Carts: 0", view.partner)
            assert.equals("Network open", view.stateText)
            assert.equals(COLOR.CONNECTED, view.stateColor)
            assert.equals("Waiting for a cart to join", view.readout.message)
            assert.equals(Layout.BUTTONS.LEADER, view.buttonLayout)
            assert.same({ "Close network", "Release cart", "icon", "icon", "icon", "icon" }, texts(view.buttons))
            for i = 2, 6 do
                assert.is_false(view.buttons[i].enabled, "button " .. i)
            end
            assert.is_true(view.buttons[1].enabled)
        end)
        it("shows the engaged cart of the leader and enables the nudge pad", function()
            local view = Layout.buildView(leader({
                { state = STATE.CONNECTED, home = nil, live = live(), fillRatio = 0.1 },
                { state = STATE.TRACKING, home = { x = 7, z = 2 }, live = live(0.5, 1, true), fillRatio = 0.5 },
            }), getText)
            assert.equals("Carts: 2", view.partner)
            assert.equals(COLOR.TRACKING, view.stateColor)
            assert.equals("Cart 50 %", view.fillText)
            assert.equals(Layout.ZOOM.CLOSE, view.plan.zoom)
            assert.equals("+0.50 m", view.readout.left.value)
            assert.equals(1, #view.plan.carts)
            assert.is_true(view.buttons[2].enabled)
            assert.same({ NUDGE.FORWARD, NUDGE.LEFT, NUDGE.BACK, NUDGE.RIGHT },
                { view.buttons[3].argument, view.buttons[4].argument, view.buttons[5].argument, view.buttons[6].argument })
            assert.equals(ICON.ARROW_UP, view.buttons[3].icon)
            assert.is_true(view.buttons[6].enabled)
        end)
        it("tells the leader when no cart is engaged", function()
            local view = Layout.buildView(leader({ { state = STATE.CONNECTED, home = { x = 7, z = 2 }, live = live() } }), getText)
            assert.equals("No cart engaged", view.readout.message)
            assert.equals(Layout.ZOOM.ZONE, view.plan.zoom)
            assert.is_nil(view.fillText)
            assert.is_false(view.buttons[2].enabled)
            assert.is_true(view.buttons[3].enabled)
        end)
        it("offers to open the network of a harvester", function()
            local view = Layout.buildView({ role = ROLE.HARVESTER, state = STATE.IDLE, live = live() }, getText)
            assert.equals("Network closed", view.stateText)
            assert.equals(COLOR.IDLE, view.stateColor)
            assert.equals("Open the network so a cart can join", view.plan.empty)
            assert.is_nil(view.readout)
            assert.same({ "Open network" }, texts(view.buttons))
            assert.equals("TOGGLE_NETWORK", view.buttons[1].action)
        end)
        it("promises Engage only when the server's check passes", function()
            local view = Layout.buildView(follower({ live = live(0, 0, true, REASON.ENGAGED) }), getText)
            assert.equals("Ready to engage", view.readout.message)
            assert.is_true(view.buttons[2].enabled)
            view = Layout.buildView(follower({ live = live(0, 0, true, REASON.LEADER_SPEED_WINDOW) }), getText)
            assert.equals("Harvester speed is outside the sync range", view.readout.message)
            assert.is_false(view.buttons[2].enabled)
            -- set home only needs the zone
            assert.is_true(view.buttons[3].enabled)
            view = Layout.buildView(follower({ live = live(30, 0, false, REASON.NOT_IN_ZONE) }), getText)
            assert.equals("Not in the operational zone of the harvester", view.readout.message)
        end)
        it("counts a machine fault down instead of showing the deviation", function()
            local view = Layout.buildView(follower({ state = STATE.TRACKING, live = live(0.2, 0, true, REASON.LEADER_TURNING, 2100) }), getText)
            assert.equals("Ends in 3 s", view.stateText)
            assert.equals(COLOR.WARNING, view.stateColor)
            assert.equals("Harvester is turning", view.readout.message)
            assert.is_true(view.readout.warning)
            assert.is_true(view.buttons[2].enabled)
            view = Layout.buildView(leader({ { state = STATE.ACQUIRING, home = { x = 7, z = 2 },
                live = live(0, 0, true, REASON.LEADER_STOPPED, 4000) } }), getText)
            assert.equals("Ends in 4 s", view.stateText)
            assert.equals("Harvester stopped", view.readout.message)
        end)
        it("lets a tractor join only when the server's check passes", function()
            local function tractor(check, nearest)
                return Layout.buildView({ role = ROLE.TRACTOR, state = STATE.IDLE, stateText = "Off",
                    live = live(0, 0, false, check), nearest = nearest }, getText)
            end
            local harvester = { name = "Harvester", distance = 99.6 }
            local view = tractor(REASON.OUT_OF_RANGE, harvester)
            assert.equals("Nearest network: Harvester, 100 m - drive closer to join", view.plan.empty)
            assert.is_false(view.buttons[1].enabled)
            view = tractor(REASON.CONNECTED, { name = "Harvester", distance = 20 })
            assert.equals("Nearest network: Harvester, 20 m", view.plan.empty)
            assert.is_true(view.buttons[1].enabled)
            view = tractor(REASON.NOT_ALLOWED, harvester)
            assert.equals("No access to this vehicle", view.plan.empty)
            assert.is_false(view.buttons[1].enabled)
            view = tractor(REASON.NETWORK_CLOSED, nil)
            assert.equals("No open sync network nearby", view.plan.empty)
            assert.is_false(view.buttons[1].enabled)
            -- before the first server answer the nearest network decides
            assert.is_false(tractor(REASON.NONE, nil).buttons[1].enabled)
            assert.is_true(tractor(REASON.NONE, harvester).buttons[1].enabled)
        end)
        it("shows a tractor the nearest open network", function()
            local view = Layout.buildView({ role = ROLE.TRACTOR, state = STATE.IDLE, stateText = "Off", live = live(),
                nearest = { name = "Harvester", distance = 120.6 } }, getText)
            assert.equals("Off", view.stateText)
            assert.equals("Nearest network: Harvester, 121 m", view.plan.empty)
            assert.same({ "Join network" }, texts(view.buttons))
            view = Layout.buildView({ role = ROLE.TRACTOR, state = STATE.IDLE, stateText = "Off", live = live() }, getText)
            assert.equals("No open sync network nearby", view.plan.empty)
        end)
    end)

    describe("layout", function()
        local function px(h) return h * UNIT_Y end

        it("stacks header, state band, plan view, readout and one button row", function()
            local view = Layout.buildView(follower({ live = live(0, 0, true) }), getText)
            local lay = Layout.layout(view, 0.1, 0.9, UNIT_X, UNIT_Y)
            local S = Layout.SIZE
            assert.near(S.WIDTH * UNIT_X, lay.width)
            assert.near(px(S.HEADER + S.BAND + S.PADDING + S.PLAN + S.READOUT + S.BUTTON + S.PADDING), lay.height)
            assert.near(0.9 - lay.height, lay.panel.y)
            assert.near(0.9 - px(S.HEADER), lay.header.y)
            assert.near(lay.header.x + lay.header.w, lay.close.x + lay.close.w)
            assert.is_not_nil(lay.readout)
            assert.equals(3, #lay.buttons)
            local first, last = lay.buttons[1].rect, lay.buttons[3].rect
            assert.near(first.w, last.w)
            assert.near(lay.plan.x, first.x)
            assert.near(lay.plan.x + lay.plan.w, last.x + last.w)
            assert.same({ "close", "header", "button1", "button2", "button3", "panel" },
                { lay.hits[1].id, lay.hits[2].id, lay.hits[3].id, lay.hits[4].id, lay.hits[5].id, lay.hits[6].id })
            assert.equals(view.buttons[2], lay.hits[4].button)
        end)
        it("uses a gap instead of the readout and a full width button without a readout", function()
            local view = Layout.buildView({ role = ROLE.HARVESTER, state = STATE.IDLE, live = live() }, getText)
            local lay = Layout.layout(view, 0, 1, UNIT_X, UNIT_Y)
            local S = Layout.SIZE
            assert.is_nil(lay.readout)
            assert.near(px(S.HEADER + S.BAND + S.PADDING + S.PLAN_EMPTY + S.GAP + S.BUTTON + S.PADDING), lay.height)
            assert.near(lay.plan.w, lay.buttons[1].rect.w)
        end)
        it("places the leader's nudge pad right of two wide buttons", function()
            local view = Layout.buildView(leader(), getText)
            local lay = Layout.layout(view, 0, 1, UNIT_X, UNIT_Y)
            local S = Layout.SIZE
            assert.near(px(S.HEADER + S.BAND + S.PADDING + S.PLAN + S.READOUT + S.BUTTON + S.GAP + S.BUTTON + S.PADDING), lay.height)
            local close, release = lay.buttons[1].rect, lay.buttons[2].rect
            local up, left, back, right = lay.buttons[3].rect, lay.buttons[4].rect, lay.buttons[5].rect, lay.buttons[6].rect
            assert.near(close.x, release.x)
            assert.is_greater(release.y, close.y)
            assert.near(up.x, back.x)
            assert.near(close.y, up.y)
            assert.near(release.y, left.y)
            assert.is_less(back.x, left.x)
            assert.is_less(right.x, back.x)
            assert.near(lay.plan.x + lay.plan.w, right.x + right.w)
            assert.is_less(up.x, close.x + close.w)
        end)
        it("projects the leader frame into the plan view with the leader pointing up", function()
            local lay = Layout.layout(Layout.buildView(leader(), getText), 0, 1, UNIT_X, UNIT_Y)
            local plan = lay.plan
            local x, y, clamped = Layout.project(lay, 0, 0)
            assert.near(plan.x + plan.w / 2, x)
            assert.is_false(clamped)
            local leftX = Layout.project(lay, 5, 0)
            assert.is_less(x, leftX)
            local _, frontY = Layout.project(lay, 0, 5)
            assert.is_greater(y, frontY)
            -- metres are square on the screen
            local x5 = Layout.project(lay, -5, 0)
            local _, y5 = Layout.project(lay, 0, 5)
            assert.near((x5 - x) / UNIT_X, (y5 - y) / UNIT_Y)
            local farX, farY, far = Layout.project(lay, -500, 500)
            assert.is_true(far)
            assert.near(plan.x + plan.w, farX)
            assert.near(plan.y + plan.h, farY)
        end)
        it("zooms in on harvester and cart while a cart is engaged", function()
            local view = Layout.buildView(follower({ state = STATE.TRACKING, home = { x = 7, z = 2 } }), getText)
            local lay = Layout.layout(view, 0, 1, UNIT_X, UNIT_Y)
            assert.equals(Layout.CLOSE_WINDOW, lay.window)
            local zoneLay = Layout.layout(Layout.buildView(leader(), getText), 0, 1, UNIT_X, UNIT_Y)
            assert.is_greater(2 * zoneLay.pixelsPerMetre, lay.pixelsPerMetre)
            -- the home point beside the harvester stays inside the close-up
            local _, _, clamped = Layout.project(lay, 7, 2)
            assert.is_false(clamped)
        end)
        it("fits the operational zone into the plan view", function()
            local lay = Layout.layout(Layout.buildView(leader(), getText), 0, 1, UNIT_X, UNIT_Y)
            local zone = Layout.getZoneRect(lay)
            local defaults = VehicleSyncController.DEFAULTS
            assert.near(2 * defaults.zoneLateral * lay.pixelsPerMetre * UNIT_X, zone.w)
            assert.near((defaults.zoneFront + defaults.zoneBack) * lay.pixelsPerMetre * UNIT_Y, zone.h)
            assert.is_true(zone.x >= lay.plan.x and zone.y >= lay.plan.y)
            assert.is_true(zone.x + zone.w <= lay.plan.x + lay.plan.w + 1e-9)
            assert.is_true(zone.y + zone.h <= lay.plan.y + lay.plan.h + 1e-9)
        end)
    end)

    describe("hit test and panel position", function()
        it("finds the close button before the header and nothing outside", function()
            local lay = Layout.layout(Layout.buildView(leader(), getText), 0, 1, UNIT_X, UNIT_Y)
            local close = lay.close
            assert.equals("close", Layout.hitTest(lay.hits, close.x + close.w / 2, close.y + close.h / 2).id)
            assert.equals("header", Layout.hitTest(lay.hits, lay.header.x + 0.001, lay.header.y + 0.001).id)
            local b = lay.buttons[1].rect
            assert.equals("button1", Layout.hitTest(lay.hits, b.x + b.w / 2, b.y + b.h / 2).id)
            assert.equals("panel", Layout.hitTest(lay.hits, lay.plan.x + 0.001, lay.plan.y + 0.001).id)
            assert.is_nil(Layout.hitTest(lay.hits, 0.9, 0.1))
        end)
        it("keeps the panel on the screen", function()
            local left, top = Layout.clampPanel(-0.2, 1.3, 0.2, 0.3)
            assert.equals(0, left)
            assert.equals(1, top)
            left, top = Layout.clampPanel(0.95, 0.1, 0.2, 0.3)
            assert.is_true(near(0.8, left))
            assert.equals(0.3, top)
            left, top = Layout.clampPanel(0.4, 0.6, 0.2, 0.3)
            assert.same({ 0.4, 0.6 }, { left, top })
        end)
    end)
end)
