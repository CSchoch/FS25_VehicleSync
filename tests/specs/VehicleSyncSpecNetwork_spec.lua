local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()
local V = dofile("tests/mocks/vehicles.lua")

local STATE = VehicleSyncController.STATE
local REASON = VehicleSyncController.REASON
local Spec = VehicleSyncSpec

describe("VehicleSyncSpec network", function()
    before_each(function()
        engine.reset()
        engine.loadTranslations()
        VehicleSyncSettings.reset()
    end)

    describe("join in progress (onWriteStream / onReadStream)", function()
        it("streams a connected follower with home point to a joining client", function()
            local leader = V.create({ name = "Harvester", networkId = 10 })
            local follower = V.create({ name = "Tractor", networkId = 11 })
            local spec = Spec.getSpec(follower)
            spec.state = STATE.TRACKING
            spec.leader = leader
            spec.home = { x = -6.5, z = 1 }
            spec.homeIsAuto = false

            local stream = engine.createStream()
            follower:onWriteStream(stream, engine.createConnection(false))

            -- the client streams the follower before its leader exists
            NetworkUtil.side = "client"
            local clientFollower = V.create({ name = "Tractor", networkId = 11, side = "client", isServer = false })
            clientFollower:onReadStream(stream, engine.createConnection(true))
            local clientSpec = Spec.getSpec(clientFollower)
            assert.equals(STATE.TRACKING, clientSpec.state)
            assert.equals(10, clientSpec.pendingLeaderId)
            assert.is_nil(clientSpec.leader)
            assert.near(-6.5, clientSpec.home.x)
            assert.is_false(clientSpec.homeIsAuto)

            local clientLeader = V.create({ name = "Harvester", networkId = 10, side = "client", isServer = false })
            assert.equals(clientLeader, clientFollower:vsGetLeader())
            assert.is_true(Spec.getSpec(clientLeader).followers[clientFollower])
            NetworkUtil.side = "server"
        end)
        it("streams an idle leader with open network and no home point", function()
            local leader = V.create({ networkId = 20 })
            Spec.getSpec(leader).networkEnabled = true
            local stream = engine.createStream()
            leader:onWriteStream(stream, nil)
            NetworkUtil.side = "client"
            local clientLeader = V.create({ networkId = 20, side = "client", isServer = false })
            clientLeader:onReadStream(stream, nil)
            NetworkUtil.side = "server"
            assert.is_true(clientLeader:vsGetNetworkEnabled())
            assert.equals(STATE.IDLE, clientLeader:vsGetState())
            assert.is_nil(clientLeader:vsGetHome())
            assert.is_nil(Spec.getSpec(clientLeader).pendingLeaderId)
        end)
        it("streams the automatic home flag", function()
            local follower = V.create({ networkId = 30 })
            local spec = Spec.getSpec(follower)
            spec.home = { x = 7, z = 2 }
            spec.homeIsAuto = true
            local stream = engine.createStream()
            follower:onWriteStream(stream, nil)
            NetworkUtil.side = "client"
            local client = V.create({ networkId = 30, side = "client", isServer = false })
            client:onReadStream(stream, nil)
            NetworkUtil.side = "server"
            assert.is_true(Spec.getSpec(client).homeIsAuto)
        end)
    end)

    describe("live values (onWriteUpdateStream / onReadUpdateStream)", function()
        it("sends the HUD values to clients when dirty", function()
            local follower = V.create({ networkId = 40 })
            local spec = Spec.getSpec(follower)
            spec.live = { lateralError = 0.4, alongError = -1.2, inZone = true }
            local stream = engine.createStream()
            follower:onWriteUpdateStream(stream, engine.createConnection(false), spec.dirtyFlag)

            local client = V.create({ networkId = 41, side = "client", isServer = false })
            client:onReadUpdateStream(stream, 0, engine.createConnection(true))
            local clientSpec = Spec.getSpec(client)
            assert.near(0.4, clientSpec.live.lateralError)
            assert.near(-1.2, clientSpec.live.alongError)
            assert.is_true(clientSpec.live.inZone)
        end)
        it("only writes a flag when not dirty", function()
            local follower = V.create({})
            local stream = engine.createStream()
            follower:onWriteUpdateStream(stream, engine.createConnection(false), 0)
            assert.equals(1, #stream.data)
            local client = V.create({ side = "client", isServer = false })
            client:onReadUpdateStream(stream, 0, engine.createConnection(true))
            assert.equals(0, Spec.getSpec(client).live.lateralError)
        end)
        it("never writes towards the server and never reads from clients", function()
            local v = V.create({})
            local stream = engine.createStream()
            v:onWriteUpdateStream(stream, engine.createConnection(true), 0xFFFF)
            assert.equals(0, #stream.data)
            v:onReadUpdateStream(stream, 0, engine.createConnection(false))
            assert.equals(1, stream.readPos)
        end)
    end)

    describe("broadcasting and feedback", function()
        it("does not broadcast without a server", function()
            local v = V.create({})
            g_server = nil
            assert.has_no_error(function() Spec.broadcastState(v) end)
        end)
        it("shows feedback locally for the server player", function()
            local v = V.create({ entered = true })
            Spec.sendFeedback(v, REASON.NOT_IN_ZONE, nil)
            Spec.sendFeedback(v, REASON.LEADER_BUSY, engine.createConnection(true))
            assert.equals(2, #g_currentMission.warnings)
        end)
        it("sends feedback to remote players", function()
            local v = V.create({})
            local connection = engine.createConnection(false)
            Spec.sendFeedback(v, REASON.NOT_IN_ZONE, connection)
            assert.equals(1, #connection.sent)
            assert.is_true(connection.sent[1].isFeedback)
        end)
        it("routes requests from clients through the server connection", function()
            local v = V.create({ isServer = false })
            v:vsRequest(VehicleSyncSpec.ACTION.TOGGLE_CONNECT)
            local sent = g_client.serverConnection.sent[1]
            assert.equals(v, sent.vehicle)
            assert.equals(VehicleSyncSpec.ACTION.TOGGLE_CONNECT, sent.action)
            assert.equals(0, sent.argument)
        end)
    end)

    describe("notifications", function()
        it("shows info in green and warnings blinking to the operator", function()
            local v = V.create({ entered = true })
            v:vsShowReason(REASON.CONNECTED)
            v:vsShowReason(REASON.CART_FULL)
            v:vsShowReason(REASON.NONE)
            assert.same({ "Connected to the sync network" }, g_currentMission.notifications)
            assert.same({ "Grain cart is full" }, g_currentMission.warnings)
        end)
        it("tells the leader operator which cart changed", function()
            local leader, follower = V.createScene({ leaderEntered = true, followerEntered = false })
            Spec.getSpec(follower).leader = leader
            follower:vsShowReason(REASON.LEADER_TURNING)
            assert.same({ "Tractor: Sync ended: harvester turning" }, g_currentMission.warnings)
        end)
        it("stays silent when nobody involved is in a vehicle", function()
            local leader, follower = V.createScene({ followerEntered = false })
            Spec.getSpec(follower).leader = leader
            follower:vsShowReason(REASON.ENGAGED)
            local lonely = V.create({})
            lonely:vsShowReason(REASON.ENGAGED)
            assert.equals(0, #g_currentMission.notifications)
            g_currentMission = nil
            assert.has_no_error(function() lonely:vsShowReason(REASON.ENGAGED) end)
        end)
        it("requests action event updates only on clients for live vehicles", function()
            local v = V.create({})
            Spec.requestActionEventUpdate(v)
            assert.equals(1, v.actionEventUpdates)
            v.isClient = false
            Spec.requestActionEventUpdate(v)
            assert.equals(1, v.actionEventUpdates)
            assert.has_no_error(function() Spec.requestActionEventUpdate(nil) end)
        end)
    end)
end)
