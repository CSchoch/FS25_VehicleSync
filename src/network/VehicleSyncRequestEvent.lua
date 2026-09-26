--[[
    VehicleSyncRequestEvent (client -> server)

    An operator action (open network, connect, engage, set home, nudge, release, takeover).
    The server validates the sender in VehicleSyncSpec.handleRequest: only the player sitting in
    the vehicle may operate it.
]]

---@class VehicleSyncRequestEvent
VehicleSyncRequestEvent = {}
local VehicleSyncRequestEvent_mt = Class(VehicleSyncRequestEvent, Event)

InitEventClass(VehicleSyncRequestEvent, "VehicleSyncRequestEvent")

function VehicleSyncRequestEvent.emptyNew()
    return Event.new(VehicleSyncRequestEvent_mt)
end

---@param vehicle table
---@param action number VehicleSyncSpec.ACTION
---@param argument number action argument (nudge direction), 0 if unused
function VehicleSyncRequestEvent.new(vehicle, action, argument)
    local self = VehicleSyncRequestEvent.emptyNew()
    self.vehicle = vehicle
    self.action = action
    self.argument = argument or 0
    return self
end

function VehicleSyncRequestEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.action, VehicleSyncSpec.NUM_ACTION_BITS)
    streamWriteUInt8(streamId, self.argument)
end

function VehicleSyncRequestEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.action = streamReadUIntN(streamId, VehicleSyncSpec.NUM_ACTION_BITS)
    self.argument = streamReadUInt8(streamId)
    self:run(connection)
end

function VehicleSyncRequestEvent:run(connection)
    -- requests are only executed on the server
    if connection:getIsServer() then
        return
    end
    if self.vehicle ~= nil then
        VehicleSyncSpec.handleRequest(self.vehicle, self.action, self.argument, connection)
    end
end
