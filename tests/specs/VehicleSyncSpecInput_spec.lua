local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()
local V = dofile("tests/mocks/vehicles.lua")

local STATE = VehicleSyncController.STATE
local ACTION = VehicleSyncSpec.ACTION
local NUDGE = VehicleSyncController.NUDGE
local Spec = VehicleSyncSpec

local function registered(vehicle)
    local names = {}
    for name in pairs(Spec.getSpec(vehicle).actionEvents) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

describe("VehicleSyncSpec input and HUD", function()
    before_each(function()
        engine.reset()
        engine.loadTranslations()
        VehicleSyncSettings.reset()
    end)

    describe("action events", function()
        it("registers nothing on dedicated servers or when not active for input", function()
            local v = V.create({ isClient = false })
            v:onRegisterActionEvents(true, true)
            assert.same({}, registered(v))
            local w = V.create({})
            w:onRegisterActionEvents(false, false)
            assert.same({}, registered(w))
        end)
        it("offers only the terminal while a helper drives the entered vehicle", function()
            local v = V.create({ hasPipe = true, entered = true })
            v.aiActive = true
            v:onRegisterActionEvents(false, false)
            assert.same({ "VS_TOGGLE_HUD" }, registered(v))
            assert.equals("Vehicle Sync terminal", g_inputBinding.texts.VS_TOGGLE_HUD)
        end)
        it("refreshes the actions when a helper starts or stops in the entered vehicle", function()
            local v = V.create({ entered = true })
            v:onUpdate(16)
            assert.is_nil(v.actionEventUpdates)
            v.aiActive = true
            v:onUpdate(16)
            v:onUpdate(16)
            assert.equals(1, v.actionEventUpdates)
            v.aiActive = false
            v:onUpdate(16)
            assert.equals(2, v.actionEventUpdates)
            local w = V.create({})
            w.aiActive = true
            w:onUpdate(16)
            assert.is_nil(w.actionEventUpdates)
        end)
        it("offers only 'join network' in a plain tractor", function()
            local v = V.create({})
            v:onRegisterActionEvents(true, true)
            assert.same({ "VS_CONNECT", "VS_TOGGLE_HUD" }, registered(v))
            assert.equals("Vehicle Sync terminal", g_inputBinding.texts.VS_TOGGLE_HUD)
            assert.equals("Join sync network", g_inputBinding.texts.VS_CONNECT)
        end)
        it("offers 'open network' in a harvester", function()
            local v = V.create({ hasPipe = true })
            v:onRegisterActionEvents(true, true)
            assert.same({ "VS_CONNECT", "VS_TOGGLE_HUD", "VS_TOGGLE_NETWORK" }, registered(v))
            assert.equals("Open sync network", g_inputBinding.texts.VS_TOGGLE_NETWORK)
        end)
        it("offers the leader controls once a cart is linked", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            leader:onRegisterActionEvents(true, true)
            assert.same({ "VS_TOGGLE_HUD", "VS_TOGGLE_NETWORK" }, registered(leader))
            assert.equals("Close sync network", g_inputBinding.texts.VS_TOGGLE_NETWORK)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            leader:onRegisterActionEvents(true, true)
            assert.same({ "VS_NUDGE_BACK", "VS_NUDGE_FORWARD", "VS_NUDGE_LEFT", "VS_NUDGE_RIGHT", "VS_RELEASE",
                "VS_TOGGLE_HUD", "VS_TOGGLE_NETWORK" }, registered(leader))
        end)
        it("offers the follower controls with state dependent texts", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            follower:onRegisterActionEvents(true, true)
            assert.same({ "VS_CONNECT", "VS_ENGAGE", "VS_SET_HOME", "VS_TOGGLE_HUD" }, registered(follower))
            assert.equals("Leave sync network", g_inputBinding.texts.VS_CONNECT)
            assert.equals("Engage sync", g_inputBinding.texts.VS_ENGAGE)
            assert.equals(GS_PRIO_HIGH, g_inputBinding.priorities.VS_ENGAGE)
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            follower:onRegisterActionEvents(true, true)
            assert.equals("Disengage sync", g_inputBinding.texts.VS_ENGAGE)
        end)
        it("skips actions that are unknown to the input system", function()
            local saved, savedHud = InputAction.VS_CONNECT, InputAction.VS_TOGGLE_HUD
            InputAction.VS_CONNECT, InputAction.VS_TOGGLE_HUD = nil, nil
            local v = V.create({})
            v:onRegisterActionEvents(true, true)
            InputAction.VS_CONNECT, InputAction.VS_TOGGLE_HUD = saved, savedHud
            assert.same({}, registered(v))
        end)
        it("tolerates a failed registration", function()
            local v = V.create({})
            v.addActionEvent = function() return false, nil end
            assert.has_no_error(function() v:onRegisterActionEvents(true, true) end)
        end)
        it("sends the matching request from every callback", function()
            local v = V.create({ isServer = false })
            local cases = {
                { Spec.actionEventToggleNetwork, ACTION.TOGGLE_NETWORK, 0 },
                { Spec.actionEventToggleConnect, ACTION.TOGGLE_CONNECT, 0 },
                { Spec.actionEventToggleEngage, ACTION.TOGGLE_ENGAGE, 0 },
                { Spec.actionEventSetHome, ACTION.SET_HOME, 0 },
                { Spec.actionEventNudgeLeft, ACTION.NUDGE, NUDGE.LEFT },
                { Spec.actionEventNudgeRight, ACTION.NUDGE, NUDGE.RIGHT },
                { Spec.actionEventNudgeForward, ACTION.NUDGE, NUDGE.FORWARD },
                { Spec.actionEventNudgeBack, ACTION.NUDGE, NUDGE.BACK },
                { Spec.actionEventRelease, ACTION.RELEASE, 0 },
            }
            for i, case in ipairs(cases) do
                case[1](v, "action", 1, nil, false)
                local sent = g_client.serverConnection.sent[i]
                assert.equals(case[2], sent.action, "callback " .. i)
                assert.equals(case[3], sent.argument, "callback " .. i)
            end
        end)
        it("opens the terminal from the terminal key", function()
            VehicleSyncHud:reset()
            local v = V.create({ entered = true })
            Spec.actionEventToggleHud(v, "VS_TOGGLE_HUD", 1, nil, false)
            assert.is_true(VehicleSyncHud.isOpen)
            assert.equals(v, VehicleSyncHud.vehicle)
            VehicleSyncHud:close()
        end)
    end)

    describe("steering takeover on the owner client", function()
        it("requests a takeover once for real steering input while engaged", function()
            local v = V.create({ isServer = false })
            Spec.getSpec(v).state = STATE.TRACKING
            v:setSteeringInput(0.05, true, nil)
            assert.equals(0, #g_client.serverConnection.sent)
            v:setSteeringInput(-0.6, true, nil)
            v:setSteeringInput(-1, true, nil)
            assert.equals(1, #g_client.serverConnection.sent)
            assert.equals(ACTION.OPERATOR_TAKEOVER, g_client.serverConnection.sent[1].action)
            -- the input always reaches the base game
            assert.same({ 0.05, -0.6, -1 }, v.steeringInputs)
        end)
        it("ignores steering while not engaged", function()
            local v = V.create({ isServer = false })
            Spec.getSpec(v).state = STATE.CONNECTED
            v:setSteeringInput(1, false, nil)
            assert.equals(0, #g_client.serverConnection.sent)
        end)
        it("handles the takeover directly for the server player", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            follower:setSteeringInput(1, false, nil)
            assert.equals(STATE.CONNECTED, follower:vsGetState())
            -- a second takeover after re-engaging is possible again
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            assert.is_false(Spec.getSpec(follower).takeoverRequested)
        end)
    end)

    describe("home point marker", function()
            local function connected(opts)
                local leader, follower = V.createScene(opts)
                leader:vsSetNetworkEnabled(true)
                Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
                return leader, follower
            end
            local function near(a, b) return math.abs(a - b) < 1e-6 end

            it("points an arrow at the home point for 5 seconds after it was set", function()
                local _, follower = connected()
                Spec.getSpec(follower).live.inZone = true
                Spec.handleRequest(follower, ACTION.SET_HOME, 0, nil)
                follower:onDrawUIInfo()
                -- 5 shaft lines, 4 head edges and the 4 sides of the head base
                assert.equals(13, #engine.drawn.lines)
                local home = follower:vsGetHome()
                local lowest, highest = math.huge, -math.huge
                for _, line in ipairs(engine.drawn.lines) do
                    lowest = math.min(lowest, line.y1, line.y2)
                    highest = math.max(highest, line.y1, line.y2)
                    assert.same(Spec.HOME_MARKER_COLOR, line.color)
                end
                assert.equals(Spec.HOME_ARROW_TIP, lowest)
                assert.equals(Spec.HOME_ARROW_TIP + Spec.HOME_ARROW_LENGTH, highest)
                -- the tip sits right above the home point
                local tip = engine.drawn.lines[6]
                assert.is_true(near(home.x, tip.x1) and near(home.z, tip.z1))
                assert.equals(Spec.HOME_ARROW_TIP, tip.y1)

                g_time = Spec.HOME_MARKER_DURATION
                engine.drawn.lines = {}
                follower:onDrawUIInfo()
                assert.equals(13, #engine.drawn.lines)
                g_time = Spec.HOME_MARKER_DURATION + 1
                engine.drawn.lines = {}
                follower:onDrawUIInfo()
                follower:onDrawUIInfo()
                assert.equals(0, #engine.drawn.lines)
                assert.is_nil(Spec.getSpec(follower).homeMarkerUntil)
            end)
            it("shows the arrow to the leader operator after a nudge", function()
                local leader, follower = connected({ leaderEntered = true, followerEntered = false })
                Spec.handleRequest(leader, ACTION.NUDGE, NUDGE.FORWARD, nil)
                follower:onDrawUIInfo()
                assert.equals(13, #engine.drawn.lines)
            end)
            it("shows nothing without a change, to other players, in menus or on servers", function()
                local leader, follower = connected()
                follower:onDrawUIInfo()
                Spec.showHomeMarker(follower)
                follower.entered = false
                follower:onDrawUIInfo()
                follower.entered = true
                g_gui.visible = true
                follower:onDrawUIInfo()
                g_gui.visible = false
                g_noHudModeEnabled = true
                follower:onDrawUIInfo()
                g_noHudModeEnabled = false
                follower.isClient = false
                follower:onDrawUIInfo()
                follower.isClient = true
                Spec.getSpec(follower).leader = nil
                follower:onDrawUIInfo()
                assert.equals(0, #engine.drawn.lines)
                local v = V.create({ entered = true })
                Spec.showHomeMarker(v)
                v:onDrawUIInfo()
                assert.equals(0, #engine.drawn.lines)
            end)
            it("detects home point changes received from the server", function()
                local REASON = VehicleSyncController.REASON
                local home = { x = 7, z = 2 }
                assert.is_true(Spec.getIsHomeChange(home, home, false, REASON.HOME_SET))
                assert.is_true(Spec.getIsHomeChange(home, { x = 7, z = 2.5 }, false, REASON.NONE))
                assert.is_true(Spec.getIsHomeChange(home, { x = 6.5, z = 2 }, false, REASON.NONE))
                assert.is_false(Spec.getIsHomeChange(home, { x = 7, z = 2 }, false, REASON.NONE))
                assert.is_false(Spec.getIsHomeChange(home, { x = 8, z = 2 }, true, REASON.NONE))
                assert.is_false(Spec.getIsHomeChange(nil, home, false, REASON.NONE))
                assert.is_false(Spec.getIsHomeChange(home, nil, true, REASON.NONE))

                local _, follower = connected()
                Spec.getSpec(follower).homeMarkerUntil = nil
                g_time = 1000
                follower:vsApplyState(STATE.CONNECTED, follower:vsGetLeader(), { x = 5, z = 1 }, false, false, REASON.NONE)
                assert.equals(1000 + Spec.HOME_MARKER_DURATION, Spec.getSpec(follower).homeMarkerUntil)
            end)
        it("skips deleted followers in the leader list", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            follower.isDeleted = true
            assert.equals(0, #leader:vsGetFollowers())
        end)
    end)
end)
