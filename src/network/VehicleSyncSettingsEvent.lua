--[[
    VehicleSyncSettingsEvent

    The server settings in both directions:
    - server -> clients: all values, sent to a player who finished joining and to everybody after
      every change, so the terminal shows the values the server uses
    - client -> server: one terminal step of one setting. Only admins (master users) may change
      the settings; the server checks the sender and ignores everybody else.
]]

---@class VehicleSyncSettingsEvent
VehicleSyncSettingsEvent = {}
local VehicleSyncSettingsEvent_mt = Class(VehicleSyncSettingsEvent, Event)

InitEventClass(VehicleSyncSettingsEvent, "VehicleSyncSettingsEvent")

VehicleSyncSettingsEvent.NUM_INDEX_BITS = 4  -- index into VehicleSyncSettings.DEFINITIONS

function VehicleSyncSettingsEvent.emptyNew()
    return Event.new(VehicleSyncSettingsEvent_mt)
end

---server -> clients: a copy of all current values
function VehicleSyncSettingsEvent.new()
    local self = VehicleSyncSettingsEvent.emptyNew()
    self.isRequest = false
    self.values = {}
    for _, def in ipairs(VehicleSyncSettings.DEFINITIONS) do
        self.values[def.name] = VehicleSyncSettings.values[def.name]
    end
    return self
end

---client -> server: one step of a setting
---@param index number VehicleSyncSettings.DEFINITIONS index
---@param direction number 1 or -1
function VehicleSyncSettingsEvent.newRequest(index, direction)
    local self = VehicleSyncSettingsEvent.emptyNew()
    self.isRequest = true
    self.index = index
    self.direction = direction
    return self
end

function VehicleSyncSettingsEvent:writeStream(streamId, connection)
    if streamWriteBool(streamId, self.isRequest) then
        streamWriteUIntN(streamId, self.index, VehicleSyncSettingsEvent.NUM_INDEX_BITS)
        streamWriteBool(streamId, self.direction > 0)
        return
    end
    for _, def in ipairs(VehicleSyncSettings.DEFINITIONS) do
        if def.type == "boolean" then
            streamWriteBool(streamId, self.values[def.name])
        else
            streamWriteFloat32(streamId, self.values[def.name])
        end
    end
end

function VehicleSyncSettingsEvent:readStream(streamId, connection)
    self.isRequest = streamReadBool(streamId)
    if self.isRequest then
        self.index = streamReadUIntN(streamId, VehicleSyncSettingsEvent.NUM_INDEX_BITS)
        self.direction = streamReadBool(streamId) and 1 or -1
    else
        self.values = {}
        for _, def in ipairs(VehicleSyncSettings.DEFINITIONS) do
            if def.type == "boolean" then
                self.values[def.name] = streamReadBool(streamId)
            else
                self.values[def.name] = streamReadFloat32(streamId)
            end
        end
    end
    self:run(connection)
end

function VehicleSyncSettingsEvent:run(connection)
    if not self.isRequest then
        -- values are only accepted from the server
        if connection:getIsServer() then
            VehicleSyncSettings.applyValues(self.values)
        end
        return
    end

    -- requests are only executed on the server, and only for admins
    if connection:getIsServer() or not VehicleSyncSettingsEvent.getIsAdminConnection(connection) then
        return
    end
    local def = VehicleSyncSettings.DEFINITIONS[self.index]
    if def ~= nil then
        VehicleSyncSettingsEvent.applyStep(def.name, self.direction)
    end
end

---Server: true if the player behind this connection is an admin (master user)
function VehicleSyncSettingsEvent.getIsAdminConnection(connection)
    local userManager = g_currentMission ~= nil and g_currentMission.userManager or nil
    if userManager == nil then
        return false
    end
    local user = userManager:getUserByConnection(connection)
    return user ~= nil and user:getIsMasterUser()
end

---True if the local player may change the settings: the host / single player, or a logged in admin
function VehicleSyncSettingsEvent.getCanChangeLocally()
    if g_currentMission == nil then
        return false
    end
    return g_currentMission:getIsServer() or g_currentMission.isMasterUser == true
end

---Server: one step of a setting, then every client gets the new values
function VehicleSyncSettingsEvent.applyStep(name, direction)
    if VehicleSyncSettings.step(name, direction) then
        VehicleSyncSettingsEvent.broadcast()
    end
end

---Server: sends the current values to every client
function VehicleSyncSettingsEvent.broadcast()
    if g_server ~= nil then
        g_server:broadcastEvent(VehicleSyncSettingsEvent.new())
    end
end

---Terminal button: the server applies the step at once, a client asks the server
function VehicleSyncSettingsEvent.sendStep(name, direction)
    if g_server ~= nil then
        VehicleSyncSettingsEvent.applyStep(name, direction)
        return
    end
    local index = VehicleSyncSettings.getIndex(name)
    if index ~= nil then
        g_client:getServerConnection():sendEvent(VehicleSyncSettingsEvent.newRequest(index, direction))
    end
end

---Server (appended to FSBaseMission.onConnectionFinishedLoading): a joining player gets the values
function VehicleSyncSettingsEvent.onConnectionFinishedLoading(mission, connection)
    if connection ~= nil and g_server ~= nil then
        connection:sendEvent(VehicleSyncSettingsEvent.new())
    end
end
