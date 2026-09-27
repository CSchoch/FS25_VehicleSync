--[[
    End-to-end multiplayer simulation: one server and several clients, each with its own copy of
    the vehicles. Every event travels through an in-memory stream (writeStream -> readStream), so
    the tests cover serialization, routing and the server's authority checks together.
]]

local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()
local V = dofile("tests/mocks/vehicles.lua")

local STATE = VehicleSyncController.STATE
local REASON = VehicleSyncController.REASON
local Spec = VehicleSyncSpec

local world

---Serializes an event and runs it on the given side
local function deliver(event, side, connection)
    local class = getmetatable(event)
    local stream = engine.createStream()
    event:writeStream(stream, connection)
    NetworkUtil.side = side
    class.emptyNew():readStream(stream, connection)
    NetworkUtil.side = "server"
end

---Delivers all pending server broadcasts to every client
local function flushBroadcasts()
    local pending = g_server.broadcasts
    g_server.broadcasts = {}
    for _, event in ipairs(pending) do
        if event.writeStream ~= nil then
            for _, client in ipairs(world.clients) do
                deliver(event, client.side, client.fromServer)
            end
        end
    end
end

---Delivers all requests the given client sent to the server
local function flushRequests(client)
    local pending = g_client.serverConnection.sent
    g_client.serverConnection.sent = {}
    for _, event in ipairs(pending) do
        -- the client object references are resolved to the server objects by network id
        NetworkUtil.side = client.side
        local stream = engine.createStream()
        event:writeStream(stream, client.toServer)
        NetworkUtil.side = "server"
        getmetatable(event).emptyNew():readStream(stream, client.toServer)
    end
    -- feedback events sent directly to this client
    local feedback = client.toServer.sent
    client.toServer.sent = {}
    for _, event in ipairs(feedback) do
        deliver(event, client.side, client.fromServer)
    end
    flushBroadcasts()
end

local function createClient(side, enteredVehicleName)
    local client = { side = side, toServer = engine.createConnection(false), fromServer = engine.createConnection(true) }
    client.leader = V.create({ name = "Harvester", networkId = 100, side = side, isServer = false, hasPipe = true,
        entered = enteredVehicleName == "Harvester" })
    client.follower = V.create({ name = "Tractor", networkId = 101, side = side, isServer = false,
        entered = enteredVehicleName == "Tractor" })
    return client
end

---Runs server frames: physics of the follower (player controlled) and onUpdate of both
local function serverFrames(n, dt)
    for _ = 1, n do
        world.follower:updateVehiclePhysics(0, 0, false, dt or 16)
        world.leader:onUpdate(dt or 16, false, false, false)
        world.follower:onUpdate(dt or 16, false, false, false)
    end
    flushBroadcasts()
end

describe("Multiplayer", function()
    before_each(function()
        engine.reset()
        engine.loadTranslations()
        VehicleSyncSettings.reset()
        world = {}
        world.leader, world.follower = V.createScene()
        -- network ids of the server objects
        NetworkUtil.objects.server = {}
        NetworkUtil.register("server", 100, world.leader)
        NetworkUtil.register("server", 101, world.follower)

        world.harvesterPlayer = createClient("clientHarvester", "Harvester")
        world.tractorPlayer = createClient("clientTractor", "Tractor")
        world.clients = { world.harvesterPlayer, world.tractorPlayer }
        world.leader.ownerConnection = world.harvesterPlayer.toServer
        world.follower.ownerConnection = world.tractorPlayer.toServer
    end)

    it("runs the complete unloading workflow between two players", function()
        local hp, tp = world.harvesterPlayer, world.tractorPlayer

        -- harvester player opens the network
        Spec.actionEventToggleNetwork(hp.leader)
        flushRequests(hp)
        assert.is_true(world.leader:vsGetNetworkEnabled())
        assert.is_true(hp.leader:vsGetNetworkEnabled())
        assert.is_true(tp.leader:vsGetNetworkEnabled())

        -- tractor player joins and engages
        Spec.actionEventToggleConnect(tp.follower)
        flushRequests(tp)
        assert.equals(STATE.CONNECTED, tp.follower:vsGetState())
        assert.equals(tp.leader, tp.follower:vsGetLeader())
        assert.equals(hp.leader, hp.follower:vsGetLeader())
        assert.contains(g_currentMission.notifications, "Connected to the sync network")

        Spec.actionEventToggleEngage(tp.follower)
        flushRequests(tp)
        assert.equals(STATE.ACQUIRING, tp.follower:vsGetState())
        assert.equals(STATE.ACQUIRING, hp.follower:vsGetState())

        -- the server drives: tracking reached and replicated
        serverFrames(3)
        assert.equals(STATE.TRACKING, world.follower:vsGetState())
        assert.equals(STATE.TRACKING, tp.follower:vsGetState())
        assert.equals(1, world.follower.physicsCalls[1].axisForward)

        -- harvester player nudges the cart; both clients see the new home point
        Spec.actionEventNudgeForward(hp.leader)
        Spec.actionEventNudgeRight(hp.leader)
        flushRequests(hp)
        assert.near(2.25, tp.follower:vsGetHome().z)
        assert.near(6.75, tp.follower:vsGetHome().x)
        assert.near(2.25, hp.follower:vsGetHome().z)

        -- tractor player steers: takeover, the tractor keeps the harvester speed
        tp.follower:setSteeringInput(1, false, nil)
        tp.follower:setSteeringInput(1, false, nil)
        flushRequests(tp)
        assert.equals(STATE.CONNECTED, world.follower:vsGetState())
        assert.equals(STATE.CONNECTED, tp.follower:vsGetState())
        assert.equals(8, world.follower.spec_drivable.cruiseControl.speed)
        assert.contains(g_currentMission.warnings, "Sync ended: operator steered")

        -- re-engage and let the harvester release the cart
        Spec.actionEventToggleEngage(tp.follower)
        flushRequests(tp)
        Spec.actionEventRelease(hp.leader)
        flushRequests(hp)
        assert.equals(STATE.CONNECTED, tp.follower:vsGetState())
        assert.contains(g_currentMission.warnings, "Cart released by the harvester")

        -- closing the network disconnects everybody
        Spec.actionEventToggleNetwork(hp.leader)
        flushRequests(hp)
        assert.equals(STATE.IDLE, tp.follower:vsGetState())
        assert.is_nil(tp.follower:vsGetLeader())
        assert.equals(0, #hp.leader:vsGetFollowers())
    end)

    it("rejects requests from a player who does not sit in the vehicle", function()
        local hp = world.harvesterPlayer
        world.leader:vsSetNetworkEnabled(true)
        flushBroadcasts()
        -- the harvester player tries to connect the tractor
        Spec.actionEventToggleConnect(hp.follower)
        flushRequests(hp)
        assert.equals(STATE.IDLE, world.follower:vsGetState())
        assert.equals(STATE.IDLE, world.tractorPlayer.follower:vsGetState())
        -- the tractor player tries to nudge / close the harvester network
        Spec.actionEventToggleNetwork(world.tractorPlayer.leader)
        flushRequests(world.tractorPlayer)
        assert.is_true(world.leader:vsGetNetworkEnabled())
    end)

    it("sends refusal feedback only to the requesting player", function()
        local tp = world.tractorPlayer
        Spec.actionEventToggleConnect(tp.follower)
        flushRequests(tp)
        assert.equals(STATE.IDLE, tp.follower:vsGetState())
        assert.contains(g_currentMission.warnings, "No sync partner available")
        assert.equals(0, #g_server.broadcasts)
    end)

    it("brings a player joining a running game up to date", function()
        local tp = world.tractorPlayer
        Spec.actionEventToggleNetwork(world.harvesterPlayer.leader)
        flushRequests(world.harvesterPlayer)
        Spec.actionEventToggleConnect(tp.follower)
        flushRequests(tp)
        Spec.actionEventToggleEngage(tp.follower)
        flushRequests(tp)
        serverFrames(2)

        -- a third player joins: vehicles are streamed follower first, leader later
        local streams = {}
        for _, vehicle in ipairs({ world.follower, world.leader }) do
            local stream = engine.createStream()
            vehicle:onWriteStream(stream, engine.createConnection(false))
            streams[vehicle.networkId] = stream
        end
        NetworkUtil.side = "clientLate"
        local lateFollower = V.create({ name = "Tractor", networkId = 101, side = "clientLate", isServer = false })
        lateFollower:onReadStream(streams[101], engine.createConnection(true))
        local lateLeader = V.create({ name = "Harvester", networkId = 100, side = "clientLate", isServer = false })
        lateLeader:onReadStream(streams[100], engine.createConnection(true))
        lateFollower:onUpdate(16, false, false, false)
        NetworkUtil.side = "server"

        assert.equals(STATE.TRACKING, lateFollower:vsGetState())
        assert.equals(lateLeader, lateFollower:vsGetLeader())
        assert.is_true(lateLeader:vsGetNetworkEnabled())
        assert.equals(1, #lateLeader:vsGetFollowers())
        assert.near(world.follower:vsGetHome().x, lateFollower:vsGetHome().x)
    end)

    it("replicates live HUD values with the update stream", function()
        local tp = world.tractorPlayer
        Spec.actionEventToggleNetwork(world.harvesterPlayer.leader)
        flushRequests(world.harvesterPlayer)
        Spec.actionEventToggleConnect(tp.follower)
        flushRequests(tp)
        V.setPose(world.follower, 8, 9, 0)
        serverFrames(1)

        local stream = engine.createStream()
        world.follower:onWriteUpdateStream(stream, engine.createConnection(false), world.follower.dirtyMask)
        tp.follower:onReadUpdateStream(stream, 0, tp.fromServer)
        local live = Spec.getSpec(tp.follower).live
        assert.near(1, live.lateralError, 1e-6)
        assert.near(1, live.alongError, 1e-6)
        assert.is_true(live.inZone)
    end)

    it("drops the sync on the server when the leader drives away and tells both players", function()
        local tp = world.tractorPlayer
        world.harvesterPlayer.leader.entered = true
        Spec.actionEventToggleNetwork(world.harvesterPlayer.leader)
        flushRequests(world.harvesterPlayer)
        Spec.actionEventToggleConnect(tp.follower)
        flushRequests(tp)
        Spec.actionEventToggleEngage(tp.follower)
        flushRequests(tp)
        world.leader.speed = 20
        serverFrames(1)
        assert.is_true(VehicleSyncController.isEngaged(tp.follower:vsGetState()))
        serverFrames(1, 5000)
        assert.equals(STATE.CONNECTED, tp.follower:vsGetState())
        assert.equals(REASON.LEADER_TOO_FAST, Spec.getSpec(tp.follower).lastReason)
        assert.contains(g_currentMission.warnings, "Sync ended: harvester too fast")
    end)
end)
