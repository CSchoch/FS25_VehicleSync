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
        it("offers only 'join network' in a plain tractor", function()
            local v = V.create({})
            v:onRegisterActionEvents(true, true)
            assert.same({ "VS_CONNECT" }, registered(v))
            assert.equals("Join sync network", g_inputBinding.texts.VS_CONNECT)
        end)
        it("offers 'open network' in a harvester", function()
            local v = V.create({ hasPipe = true })
            v:onRegisterActionEvents(true, true)
            assert.same({ "VS_CONNECT", "VS_TOGGLE_NETWORK" }, registered(v))
            assert.equals("Open sync network", g_inputBinding.texts.VS_TOGGLE_NETWORK)
        end)
        it("offers the leader controls once a cart is linked", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            leader:onRegisterActionEvents(true, true)
            assert.same({ "VS_TOGGLE_NETWORK" }, registered(leader))
            assert.equals("Close sync network", g_inputBinding.texts.VS_TOGGLE_NETWORK)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            leader:onRegisterActionEvents(true, true)
            assert.same({ "VS_NUDGE_BACK", "VS_NUDGE_FORWARD", "VS_NUDGE_LEFT", "VS_NUDGE_RIGHT", "VS_RELEASE",
                "VS_TOGGLE_NETWORK" }, registered(leader))
        end)
        it("offers the follower controls with state dependent texts", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            follower:onRegisterActionEvents(true, true)
            assert.same({ "VS_CONNECT", "VS_ENGAGE", "VS_SET_HOME" }, registered(follower))
            assert.equals("Leave sync network", g_inputBinding.texts.VS_CONNECT)
            assert.equals("Engage sync", g_inputBinding.texts.VS_ENGAGE)
            assert.equals(GS_PRIO_HIGH, g_inputBinding.priorities.VS_ENGAGE)
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            follower:onRegisterActionEvents(true, true)
            assert.equals("Disengage sync", g_inputBinding.texts.VS_ENGAGE)
        end)
        it("skips actions that are unknown to the input system", function()
            local saved = InputAction.VS_CONNECT
            InputAction.VS_CONNECT = nil
            local v = V.create({})
            v:onRegisterActionEvents(true, true)
            InputAction.VS_CONNECT = saved
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

    describe("HUD", function()
        it("draws nothing when not entered or on a dedicated server", function()
            local v = V.create({})
            v:onDraw(true, true, true)
            v.entered = true
            v.isClient = false
            v:onDraw(true, true, true)
            assert.equals(0, #g_currentMission.extraPrintTexts)
        end)
        it("draws nothing for an idle tractor", function()
            local v = V.create({ entered = true })
            v:onDraw(true, true, true)
            assert.equals(0, #g_currentMission.extraPrintTexts)
        end)
        it("shows state, leader, home point and zone hint for a connected follower", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            Spec.getSpec(follower).live.inZone = true
            follower:onDraw(true, true, true)
            assert.same({
                "Vehicle Sync: Connected - Harvester",
                "Home point: 7.00 m left, 2.00 m fore/aft",
                "In the operational zone - sync can be engaged",
            }, g_currentMission.extraPrintTexts)
        end)
        it("shows the deviation while engaged", function()
            local leader, follower = V.createScene()
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            Spec.handleRequest(follower, ACTION.TOGGLE_ENGAGE, 0, nil)
            Spec.getSpec(follower).live = { lateralError = 0.25, alongError = -1.5, inZone = true }
            local lines = Spec.getHudLines(follower)
            assert.equals("Vehicle Sync: Acquiring - Harvester", lines[1])
            assert.equals("Deviation: 0.25 m lateral, -1.50 m fore/aft", lines[3])
        end)
        it("handles a missing leader and home point", function()
            local v = V.create({ entered = true })
            local spec = Spec.getSpec(v)
            spec.state = STATE.CONNECTED
            local lines = Spec.getHudLines(v)
            assert.same({ "Vehicle Sync: Connected - -" }, lines)
        end)
        it("lists the carts of an open network for the leader operator", function()
            local leader, follower = V.createScene({ leaderEntered = true })
            leader:vsSetNetworkEnabled(true)
            Spec.handleRequest(follower, ACTION.TOGGLE_CONNECT, 0, nil)
            local second = V.create({ name = "Another Tractor", x = -7, z = 8, entered = true, controlled = true })
            Spec.handleRequest(second, ACTION.TOGGLE_CONNECT, 0, nil)
            Spec.getSpec(second).home = nil
            local lines = Spec.getHudLines(leader)
            assert.same({
                "Sync network open - carts: 2",
                "  Another Tractor: Connected",
                "  Tractor: Connected (7.00 m left, 2.00 m)",
            }, lines)
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
