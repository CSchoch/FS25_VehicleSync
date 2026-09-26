--[[
    VehicleSyncStateEvent (server -> clients)

    Full sync state of one vehicle: follower state, leader, home point and the leader's network
    flag, plus the reason of the change so every operator involved sees the same message.
    A "feedback" event only carries a reason (e.g. why a request was refused) and is sent to the
    requesting player alone; it does not change any state.
]]

---@class VehicleSyncStateEvent
VehicleSyncStateEvent = {}
local VehicleSyncStateEvent_mt = Class(VehicleSyncStateEvent, Event)

InitEventClass(VehicleSyncStateEvent, "VehicleSyncStateEvent")

function VehicleSyncStateEvent.emptyNew()
    return Event.new(VehicleSyncStateEvent_mt)
end

function VehicleSyncStateEvent.new(vehicle, state, leader, home, homeIsAuto, networkEnabled, reason)
    local self = VehicleSyncStateEvent.emptyNew()
    self.vehicle = vehicle
    self.isFeedback = false
    self.state = state
    self.leader = leader
    self.home = home
    self.homeIsAuto = homeIsAuto
    self.networkEnabled = networkEnabled
    self.reason = reason or VehicleSyncController.REASON.NONE
    return self
end

function VehicleSyncStateEvent.newFeedback(vehicle, reason)
    local self = VehicleSyncStateEvent.emptyNew()
    self.vehicle = vehicle
    self.isFeedback = true
    self.reason = reason
    return self
end

function VehicleSyncStateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUInt8(streamId, self.reason)
    if streamWriteBool(streamId, self.isFeedback) then
        return
    end

    streamWriteUIntN(streamId, self.state, VehicleSyncController.NUM_STATE_BITS)
    if self.state ~= VehicleSyncController.STATE.IDLE then
        NetworkUtil.writeNodeObject(streamId, self.leader)
    end
    if streamWriteBool(streamId, self.home ~= nil) then
        streamWriteFloat32(streamId, self.home.x)
        streamWriteFloat32(streamId, self.home.z)
        streamWriteBool(streamId, self.homeIsAuto)
    end
    streamWriteBool(streamId, self.networkEnabled)
end

function VehicleSyncStateEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.reason = streamReadUInt8(streamId)
    self.isFeedback = streamReadBool(streamId)

    if not self.isFeedback then
        self.state = streamReadUIntN(streamId, VehicleSyncController.NUM_STATE_BITS)
        if self.state ~= VehicleSyncController.STATE.IDLE then
            self.leader = NetworkUtil.readNodeObject(streamId)
        end
        self.homeIsAuto = true
        if streamReadBool(streamId) then
            self.home = { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId) }
            self.homeIsAuto = streamReadBool(streamId)
        end
        self.networkEnabled = streamReadBool(streamId)
    end

    self:run(connection)
end

function VehicleSyncStateEvent:run(connection)
    -- state is only accepted from the server
    if not connection:getIsServer() or self.vehicle == nil or VehicleSyncSpec.getSpec(self.vehicle) == nil then
        return
    end

    if self.isFeedback then
        self.vehicle:vsShowReason(self.reason)
        return
    end

    local wasNetworkEnabled = self.vehicle:vsGetNetworkEnabled()
    self.vehicle:vsApplyState(self.state, self.leader, self.home, self.homeIsAuto, self.networkEnabled, self.reason)
    if wasNetworkEnabled ~= self.networkEnabled then
        VehicleSyncSpec.showLeaderNetworkText(self.vehicle, self.networkEnabled)
    end
end
