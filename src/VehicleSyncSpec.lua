--[[
    VehicleSyncSpec

    Vehicle specialization added to every drivable vehicle. A vehicle can take two roles:

    Leader (usually a harvester with a pipe)
        - opens / closes its sync network (saved with the savegame)
        - nudges the engaged cart forward / back / left / right, or releases it

    Follower (tractor with a grain cart, an operator stays in the cab)
        - joins the network of the nearest leader, engages / disengages the sync
        - stores its home point (cart position relative to the leader)

    Multiplayer: the server is authoritative. Clients only send requests
    (VehicleSyncRequestEvent) and receive the resulting state (VehicleSyncStateEvent). The
    follower is driven through the regular player driving path: the server runs
    Drivable:updateVehiclePhysics for every vehicle a player sits in, so this spec overrides it and
    replaces the operator's (neutral) steering / pedal input with the controller command. The
    moment the operator steers, uses a pedal or the cruise control, the sync drops back to
    CONNECTED and the input goes through untouched.
]]

---@class VehicleSyncSpec
VehicleSyncSpec = {}

VehicleSyncSpec.MOD_NAME = g_currentModName or "FS25_VehicleSync"
VehicleSyncSpec.SPEC_NAME = "vehicleSync"
VehicleSyncSpec.SPEC_FULL_NAME = VehicleSyncSpec.MOD_NAME .. ".vehicleSync"
VehicleSyncSpec.SPEC_TABLE_NAME = "spec_" .. VehicleSyncSpec.SPEC_FULL_NAME

VehicleSyncSpec.LIVE_UPDATE_INTERVAL = 250    -- ms between HUD value updates sent to clients
VehicleSyncSpec.PIPE_MEASURE_INTERVAL = 500   -- ms between pipe offset measurements
VehicleSyncSpec.PIPE_CHANGE_THRESHOLD = 0.2   -- m, pipe offset change that updates automatic home points
VehicleSyncSpec.NOTIFICATION_DURATION = 3000  -- ms
VehicleSyncSpec.ABORT_WARNING_DURATION = 500  -- ms, renewed with every live update while a fault counts down
VehicleSyncSpec.HOME_MARKER_DURATION = 5000   -- ms the home point is shown after it changed
VehicleSyncSpec.HOME_ARROW_TIP = 6           -- m above the terrain, clear of cart and pipe
VehicleSyncSpec.HOME_ARROW_LENGTH = 3        -- m from the tip to the tail
VehicleSyncSpec.HOME_ARROW_HEAD = 1          -- m, length of the arrow head
VehicleSyncSpec.HOME_ARROW_WIDTH = 0.6       -- m, half width of the arrow head
VehicleSyncSpec.HOME_ARROW_SHAFT = 0.08      -- m, spacing of the shaft lines
VehicleSyncSpec.HOME_MARKER_COLOR = { 0.2, 1, 0.2 }

VehicleSyncSpec.ACTION = {
    TOGGLE_NETWORK = 1,
    TOGGLE_CONNECT = 2,
    TOGGLE_ENGAGE = 3,
    SET_HOME = 4,
    NUDGE = 5,
    RELEASE = 6,
    OPERATOR_TAKEOVER = 7,
}
VehicleSyncSpec.NUM_ACTION_BITS = 4

local STATE = VehicleSyncController.STATE
local REASON = VehicleSyncController.REASON

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function VehicleSyncSpec.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
        and SpecializationUtil.hasSpecialization(Motorized, specializations)
        and not SpecializationUtil.hasSpecialization(Locomotive, specializations)
end

function VehicleSyncSpec.initSpecialization()
    local schema = Vehicle.xmlSchemaSavegame
    local key = "vehicles.vehicle(?)." .. VehicleSyncSpec.SPEC_FULL_NAME
    schema:register(XMLValueType.BOOL, key .. "#networkEnabled", "Sync network of this leader is open", false)
    schema:register(XMLValueType.FLOAT, key .. ".home#x", "Home point: lateral cart offset to the leader (left positive)")
    schema:register(XMLValueType.FLOAT, key .. ".home#z", "Home point: fore/aft cart offset to the leader (forward positive)")
end

function VehicleSyncSpec.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "vsGetState", VehicleSyncSpec.vsGetState)
    SpecializationUtil.registerFunction(vehicleType, "vsGetLeader", VehicleSyncSpec.vsGetLeader)
    SpecializationUtil.registerFunction(vehicleType, "vsGetHome", VehicleSyncSpec.vsGetHome)
    SpecializationUtil.registerFunction(vehicleType, "vsGetNetworkEnabled", VehicleSyncSpec.vsGetNetworkEnabled)
    SpecializationUtil.registerFunction(vehicleType, "vsGetFollowers", VehicleSyncSpec.vsGetFollowers)
    SpecializationUtil.registerFunction(vehicleType, "vsGetHasPipe", VehicleSyncSpec.vsGetHasPipe)
    SpecializationUtil.registerFunction(vehicleType, "vsApplyState", VehicleSyncSpec.vsApplyState)
    SpecializationUtil.registerFunction(vehicleType, "vsSetState", VehicleSyncSpec.vsSetState)
    SpecializationUtil.registerFunction(vehicleType, "vsSetNetworkEnabled", VehicleSyncSpec.vsSetNetworkEnabled)
    SpecializationUtil.registerFunction(vehicleType, "vsRequest", VehicleSyncSpec.vsRequest)
    SpecializationUtil.registerFunction(vehicleType, "vsShowReason", VehicleSyncSpec.vsShowReason)
end

function VehicleSyncSpec.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "updateVehiclePhysics", VehicleSyncSpec.updateVehiclePhysics)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "setSteeringInput", VehicleSyncSpec.setSteeringInput)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "setCruiseControlState", VehicleSyncSpec.setCruiseControlState)
end

function VehicleSyncSpec.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onDrawUIInfo", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", VehicleSyncSpec)
    SpecializationUtil.registerEventListener(vehicleType, "saveToXMLFile", VehicleSyncSpec)
end

-- ---------------------------------------------------------------------------
-- Helpers (static)
-- ---------------------------------------------------------------------------

---@return table|nil spec
function VehicleSyncSpec.getSpec(vehicle)
    if vehicle == nil then
        return nil
    end
    return vehicle[VehicleSyncSpec.SPEC_TABLE_NAME]
end

---True if the vehicle exists, is not being deleted and carries this specialization
function VehicleSyncSpec.isValidVehicle(vehicle)
    return vehicle ~= nil and not vehicle.isDeleted and not vehicle.isDeleting and VehicleSyncSpec.getSpec(vehicle) ~= nil
end

---Reference node used for poses and pipe offsets (AI direction node = steering center)
function VehicleSyncSpec.getReferenceNode(vehicle)
    if vehicle.getAIDirectionNode ~= nil then
        local node = vehicle:getAIDirectionNode()
        if node ~= nil then
            return node
        end
    end
    return vehicle.rootNode
end

---Pose of a vehicle in the x/z plane
---@return table {x, z, heading, speed (signed km/h)}
function VehicleSyncSpec.getPose(vehicle)
    local node = VehicleSyncSpec.getReferenceNode(vehicle)
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local speed = vehicle:getLastSpeed()
    if (vehicle.movingDirection or 1) < 0 then
        speed = -speed
    end
    return { x = x, z = z, heading = VehicleSyncMath.headingFromDirection(dx, dz), speed = speed }
end

---Finds the receiving fill unit (grain cart) of a follower: the first attached vehicle with an
-- exact fill root node, i.e. a fill unit a pipe can overload into. The follower itself is used as
-- last option (self propelled wagons).
---@return table|nil {vehicle, node, fillUnitIndex}
function VehicleSyncSpec.findReceiver(vehicle)
    local candidates = {}
    if vehicle.getChildVehicles ~= nil then
        for _, child in ipairs(vehicle:getChildVehicles()) do
            if child ~= vehicle then
                table.insert(candidates, child)
            end
        end
    end
    table.insert(candidates, vehicle)

    for _, candidate in ipairs(candidates) do
        if candidate.spec_fillUnit ~= nil and candidate.getFillUnits ~= nil then
            for index, fillUnit in ipairs(candidate:getFillUnits()) do
                if fillUnit.exactFillRootNode ~= nil and (fillUnit.capacity or 0) > 0 then
                    return { vehicle = candidate, node = fillUnit.exactFillRootNode, fillUnitIndex = index }
                end
            end
        end
    end
    return nil
end

---Fill ratio (0..1) of the receiver
function VehicleSyncSpec.getReceiverFillRatio(receiver)
    if receiver == nil then
        return 0
    end
    local fillUnit = receiver.vehicle:getFillUnits()[receiver.fillUnitIndex]
    if fillUnit == nil or (fillUnit.capacity or 0) <= 0 then
        return 0
    end
    return fillUnit.fillLevel / fillUnit.capacity
end

---Width of a vehicle in meters (store size), defaults to 3 m
function VehicleSyncSpec.getWidth(vehicle)
    if vehicle ~= nil and vehicle.size ~= nil and vehicle.size.width ~= nil then
        return vehicle.size.width
    end
    return 3
end

---Measures the pipe outlet in the leader frame.
---@return table|nil offset {x, z} only when the pipe is in an unloading state
---@return number|nil side 1 = left, -1 = right, also when the pipe is folded
function VehicleSyncSpec.measurePipe(vehicle)
    local pipeSpec = vehicle.spec_pipe
    if pipeSpec == nil or vehicle.getPipeDischargeNodeIndex == nil or vehicle.getDischargeNodeByIndex == nil then
        return nil, nil
    end

    local dischargeNode = vehicle:getDischargeNodeByIndex(vehicle:getPipeDischargeNodeIndex())
    if dischargeNode == nil or dischargeNode.node == nil then
        return nil, nil
    end

    local x, _, z = localToLocal(dischargeNode.node, VehicleSyncSpec.getReferenceNode(vehicle), 0, 0, 0)
    local side = x < 0 and -1 or 1

    local isUnloading = pipeSpec.unloadingStates ~= nil and pipeSpec.unloadingStates[pipeSpec.currentState] == true
    if not isUnloading then
        return nil, side
    end
    return { x = x, z = z }, side
end

---Finds the nearest vehicle with an open sync network (server)
---@return table|nil leader
---@return number distance
function VehicleSyncSpec.findNearestLeader(follower)
    local best, bestDistance = nil, math.huge
    local vehicleSystem = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if vehicleSystem == nil then
        return nil, bestDistance
    end

    local followerPose = VehicleSyncSpec.getPose(follower)
    local childHash = {}
    if follower.getChildVehicles ~= nil then
        for _, child in ipairs(follower:getChildVehicles()) do
            childHash[child] = true
        end
    end

    for _, vehicle in ipairs(vehicleSystem.vehicles) do
        if not childHash[vehicle] and vehicle ~= follower and VehicleSyncSpec.isValidVehicle(vehicle) and vehicle:vsGetNetworkEnabled() then
            local pose = VehicleSyncSpec.getPose(vehicle)
            local distance = VehicleSyncMath.distance2D(followerPose.x, followerPose.z, pose.x, pose.z)
            if distance < bestDistance then
                best, bestDistance = vehicle, distance
            end
        end
    end
    return best, bestDistance
end

---Checks whether the two vehicles belong to farms that may work together
function VehicleSyncSpec.getIsSameFarm(follower, leader)
    local followerFarm = follower:getOwnerFarmId()
    local leaderFarm = leader:getOwnerFarmId()
    if followerFarm == leaderFarm then
        return true
    end
    local accessHandler = g_currentMission ~= nil and g_currentMission.accessHandler or nil
    if accessHandler ~= nil and accessHandler.canFarmAccessOtherId ~= nil then
        return accessHandler:canFarmAccessOtherId(followerFarm, leaderFarm)
    end
    return false
end

---Text for a reason code, nil if the reason has no message
function VehicleSyncSpec.getReasonText(reason)
    local key = VehicleSyncController.getReasonTextKey(reason)
    if key == nil then
        return nil
    end
    return g_i18n:getText(key, VehicleSyncSpec.MOD_NAME)
end

---Text for a state
function VehicleSyncSpec.getStateText(state)
    if state == STATE.CONNECTED then
        return g_i18n:getText("vs_state_connected", VehicleSyncSpec.MOD_NAME)
    elseif state == STATE.ACQUIRING then
        return g_i18n:getText("vs_state_acquiring", VehicleSyncSpec.MOD_NAME)
    elseif state == STATE.TRACKING then
        return g_i18n:getText("vs_state_tracking", VehicleSyncSpec.MOD_NAME)
    end
    return g_i18n:getText("vs_state_idle", VehicleSyncSpec.MOD_NAME)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function VehicleSyncSpec:onLoad(savegame)
    local spec = self[VehicleSyncSpec.SPEC_TABLE_NAME]
    self.spec_vehicleSync = spec

    spec.state = STATE.IDLE
    spec.leader = nil
    spec.pendingLeaderId = nil
    spec.home = nil
    spec.homeIsAuto = true
    spec.networkEnabled = false
    spec.followers = {}
    spec.lastReason = REASON.NONE
    spec.actionEvents = {}
    spec.takeoverRequested = false
    spec.homeMarkerUntil = nil

    spec.dirtyFlag = self:getNextDirtyFlag()
    -- live values for the operators (server -> clients every LIVE_UPDATE_INTERVAL). check is the
    -- answer to "what happens next": IDLE = checkConnect reason (CONNECTED = can join),
    -- CONNECTED = checkEngage reason (ENGAGED = can engage), engaged = machine fault counting down
    spec.live = { lateralError = 0, alongError = 0, inZone = false, check = REASON.NONE, abortRemaining = 0 }

    -- server only runtime data
    spec.abortTimer = 0
    spec.fault = REASON.NONE
    spec.liveTimer = 0
    spec.pipeTimer = 0
    spec.pipeOffset = nil
    spec.pipeSide = nil
    spec.curvature = VehicleSyncController.newCurvatureTracker()
    spec.operatorPedal = false
    spec.operatorCruise = false
    spec.receiver = nil

    if savegame ~= nil and savegame.xmlFile ~= nil then
        local key = savegame.key .. "." .. VehicleSyncSpec.SPEC_FULL_NAME
        spec.networkEnabled = savegame.xmlFile:getValue(key .. "#networkEnabled", false)
        local homeX = savegame.xmlFile:getValue(key .. ".home#x")
        local homeZ = savegame.xmlFile:getValue(key .. ".home#z")
        if homeX ~= nil and homeZ ~= nil then
            spec.home = { x = homeX, z = homeZ }
            spec.homeIsAuto = false
        end
    end
end

function VehicleSyncSpec:onDelete()
    local spec = VehicleSyncSpec.getSpec(self)
    if spec == nil then
        return
    end

    local leaderSpec = VehicleSyncSpec.getSpec(spec.leader)
    if leaderSpec ~= nil then
        leaderSpec.followers[self] = nil
    end

    for follower in pairs(spec.followers) do
        local followerSpec = VehicleSyncSpec.getSpec(follower)
        if followerSpec ~= nil and followerSpec.leader == self then
            followerSpec.leader = nil
            if self.isServer and VehicleSyncSpec.isValidVehicle(follower) then
                follower:vsSetState(STATE.IDLE, REASON.LEADER_LOST, nil)
            end
        end
    end
    spec.followers = {}
end

function VehicleSyncSpec:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = VehicleSyncSpec.getSpec(self)
    xmlFile:setValue(key .. "#networkEnabled", spec.networkEnabled)
    if spec.home ~= nil and not spec.homeIsAuto then
        xmlFile:setValue(key .. ".home#x", spec.home.x)
        xmlFile:setValue(key .. ".home#z", spec.home.z)
    end
end

-- ---------------------------------------------------------------------------
-- Getters
-- ---------------------------------------------------------------------------

function VehicleSyncSpec:vsGetState()
    return VehicleSyncSpec.getSpec(self).state
end

function VehicleSyncSpec:vsGetLeader()
    local spec = VehicleSyncSpec.getSpec(self)
    if spec.leader == nil and spec.pendingLeaderId ~= nil then
        local leader = NetworkUtil.getObject(spec.pendingLeaderId)
        if VehicleSyncSpec.isValidVehicle(leader) then
            spec.pendingLeaderId = nil
            spec.leader = leader
            VehicleSyncSpec.getSpec(leader).followers[self] = true
        end
    end
    return spec.leader
end

function VehicleSyncSpec:vsGetHome()
    return VehicleSyncSpec.getSpec(self).home
end

function VehicleSyncSpec:vsGetNetworkEnabled()
    return VehicleSyncSpec.getSpec(self).networkEnabled
end

---Followers linked to this leader, sorted by name for a stable HUD
function VehicleSyncSpec:vsGetFollowers()
    local list = {}
    for follower in pairs(VehicleSyncSpec.getSpec(self).followers) do
        if VehicleSyncSpec.isValidVehicle(follower) then
            table.insert(list, follower)
        end
    end
    table.sort(list, function(a, b)
        return a:getName() < b:getName()
    end)
    return list
end

function VehicleSyncSpec:vsGetHasPipe()
    return self.spec_pipe ~= nil
end

-- ---------------------------------------------------------------------------
-- State changes
-- ---------------------------------------------------------------------------

---Applies a state on this machine (server and clients). Keeps the leader's follower registry
-- consistent and shows the reason to the operators involved.
function VehicleSyncSpec:vsApplyState(state, leader, home, homeIsAuto, networkEnabled, reason)
    local spec = VehicleSyncSpec.getSpec(self)
    local oldState = spec.state
    local oldLeader = spec.leader
    local oldNetwork = spec.networkEnabled
    local oldHome = spec.home

    if state == STATE.IDLE then
        leader = nil
    end

    if oldLeader ~= leader then
        local oldLeaderSpec = VehicleSyncSpec.getSpec(oldLeader)
        if oldLeaderSpec ~= nil then
            oldLeaderSpec.followers[self] = nil
        end
        local newLeaderSpec = VehicleSyncSpec.getSpec(leader)
        if newLeaderSpec ~= nil then
            newLeaderSpec.followers[self] = true
        end
    end

    spec.state = state
    spec.leader = leader
    spec.pendingLeaderId = nil
    spec.home = home
    spec.homeIsAuto = homeIsAuto
    spec.networkEnabled = networkEnabled
    spec.lastReason = reason

    -- ACQUIRING <-> TRACKING keeps the timers, only engaging / disengaging resets them
    if VehicleSyncController.isEngaged(oldState) ~= VehicleSyncController.isEngaged(state) then
        spec.takeoverRequested = false
        spec.abortTimer = 0
        spec.fault = REASON.NONE
        spec.operatorPedal = false
        spec.operatorCruise = false
    end

    if not networkEnabled and oldNetwork then
        VehicleSyncController.resetCurvature(spec.curvature)
        spec.pipeOffset = nil
    end

    if reason ~= REASON.NONE then
        self:vsShowReason(reason)
    end

    -- the check of the old state means something else in the new one; refresh it right away
    if oldState ~= state then
        spec.live.check = REASON.NONE
        spec.live.abortRemaining = 0
        spec.liveTimer = 0
    end

    if VehicleSyncSpec.getIsHomeChange(oldHome, home, homeIsAuto, reason) then
        VehicleSyncSpec.showHomeMarker(self)
    end

    if oldState ~= state or oldNetwork ~= networkEnabled or oldLeader ~= leader then
        VehicleSyncSpec.requestActionEventUpdate(self)
        VehicleSyncSpec.requestActionEventUpdate(leader)
        VehicleSyncSpec.requestActionEventUpdate(oldLeader)
    end
end

---Server: changes the state, applies the side effects and replicates the result
---@param state number
---@param reason number
---@param leader table|nil defaults to the current leader
function VehicleSyncSpec:vsSetState(state, reason, leader)
    local spec = VehicleSyncSpec.getSpec(self)
    if leader == nil and state ~= STATE.IDLE then
        leader = spec.leader
    end

    local wasEngaged = VehicleSyncController.isEngaged(spec.state)
    local isEngaged = VehicleSyncController.isEngaged(state)
    local leaderSpeed = 0
    if VehicleSyncSpec.isValidVehicle(spec.leader) then
        leaderSpeed = VehicleSyncSpec.getPose(spec.leader).speed
    end

    self:vsApplyState(state, leader, spec.home, spec.homeIsAuto, spec.networkEnabled, reason)

    if isEngaged and not wasEngaged then
        -- the controller owns the speed from now on
        self:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF)
    elseif wasEngaged and not isEngaged then
        VehicleSyncSpec.onDisengaged(self, reason, leaderSpeed)
    end

    VehicleSyncSpec.broadcastState(self)
end

---Server: what happens to the follower when the sync drops
function VehicleSyncSpec.onDisengaged(vehicle, reason, leaderSpeed)
    local settings = VehicleSyncSettings.get()
    -- steering takeover keeps the leader's speed so the cart does not brake hard under the pipe
    if reason == REASON.OPERATOR_STEERING and settings.keepSpeedOnSteering and leaderSpeed >= 1 then
        local drivableSpec = vehicle.spec_drivable
        vehicle:setCruiseControlMaxSpeed(math.floor(leaderSpeed + 0.5), nil)
        if drivableSpec ~= nil and drivableSpec.cruiseControl ~= nil then
            local cruiseControl = drivableSpec.cruiseControl
            if g_server ~= nil then
                g_server:broadcastEvent(SetCruiseControlSpeedEvent.new(vehicle, cruiseControl.speed, cruiseControl.speedReverse), nil, nil, vehicle)
            end
            cruiseControl.speedSent = cruiseControl.speed
            cruiseControl.speedReverseSent = cruiseControl.speedReverse
        end
        vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_ACTIVE)
    end
end

---Server: sends the full sync state of a vehicle to all clients
function VehicleSyncSpec.broadcastState(vehicle)
    if g_server ~= nil then
        local spec = VehicleSyncSpec.getSpec(vehicle)
        g_server:broadcastEvent(VehicleSyncStateEvent.new(vehicle, spec.state, spec.leader, spec.home, spec.homeIsAuto, spec.networkEnabled, spec.lastReason))
    end
end

---Server: sends a message (e.g. why a request was refused) to the requesting player only
function VehicleSyncSpec.sendFeedback(vehicle, reason, connection)
    if connection == nil or (connection.getIsServer ~= nil and connection:getIsServer()) then
        vehicle:vsShowReason(reason)
    else
        connection:sendEvent(VehicleSyncStateEvent.newFeedback(vehicle, reason))
    end
end

---Server: opens or closes the sync network of a leader
function VehicleSyncSpec:vsSetNetworkEnabled(enabled)
    local spec = VehicleSyncSpec.getSpec(self)
    if spec.networkEnabled == enabled then
        return
    end
    local reason = enabled and REASON.CONNECTED or REASON.NETWORK_CLOSED
    self:vsApplyState(spec.state, spec.leader, spec.home, spec.homeIsAuto, enabled, REASON.NONE)
    spec.lastReason = REASON.NONE
    VehicleSyncSpec.showLeaderNetworkText(self, enabled)
    VehicleSyncSpec.broadcastState(self)

    -- followers notice the closed network in their next evaluation; do it right away instead
    if not enabled then
        for _, follower in ipairs(self:vsGetFollowers()) do
            follower:vsSetState(STATE.IDLE, reason, nil)
        end
    end
end

---Shows the network open / closed text to the operator of the leader
function VehicleSyncSpec.showLeaderNetworkText(vehicle, enabled)
    if vehicle.getIsEntered ~= nil and vehicle:getIsEntered() and g_currentMission ~= nil then
        local key = enabled and "vs_network_opened" or "vs_network_closed"
        VehicleSyncSpec.showNotification(g_i18n:getText(key, VehicleSyncSpec.MOD_NAME), false, vehicle)
    end
end

---Shows a reason text to the operator of this vehicle and to the operator of its leader
function VehicleSyncSpec:vsShowReason(reason)
    local text = VehicleSyncSpec.getReasonText(reason)
    if text == nil or g_currentMission == nil then
        return
    end

    local isWarning = VehicleSyncController.isWarningReason(reason)
    if self.getIsEntered ~= nil and self:getIsEntered() then
        VehicleSyncSpec.showNotification(text, isWarning, self)
        return
    end

    local leader = VehicleSyncSpec.getSpec(self).leader
    if leader ~= nil and leader.getIsEntered ~= nil and leader:getIsEntered() then
        VehicleSyncSpec.showNotification(string.format("%s: %s", self:getName(), text), isWarning, leader)
    end
end

---Warns the operators of an engaged follower and its leader while a machine fault counts down
function VehicleSyncSpec.showAbortWarning(vehicle)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    if not VehicleSyncController.isEngaged(spec.state) or spec.live.check == REASON.NONE or g_currentMission == nil then
        return
    end
    local leader = spec.leader
    local isOperator = vehicle.getIsEntered ~= nil and vehicle:getIsEntered()
    local isLeaderOperator = leader ~= nil and leader.getIsEntered ~= nil and leader:getIsEntered()
    if not isOperator and not isLeaderOperator then
        return
    end
    -- an open terminal already counts down in its state band
    if VehicleSyncHud:getIsShowing(isOperator and vehicle or leader) then
        return
    end
    local fault = g_i18n:getText(VehicleSyncController.getFaultTextKey(spec.live.check), VehicleSyncSpec.MOD_NAME)
    local text = string.format(g_i18n:getText("vs_warning_ending", VehicleSyncSpec.MOD_NAME), math.ceil(spec.live.abortRemaining / 1000), fault)
    g_currentMission:showBlinkingWarning(text, VehicleSyncSpec.ABORT_WARNING_DURATION)
end

---Shows a message to the operator of `vehicle`: in the terminal while it is open, otherwise as a
-- game notification (warnings blink)
function VehicleSyncSpec.showNotification(text, isWarning, vehicle)
    if VehicleSyncHud:showMessage(vehicle, text, isWarning) then
        return
    end
    if isWarning then
        g_currentMission:showBlinkingWarning(text, VehicleSyncSpec.NOTIFICATION_DURATION)
    else
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
    end
end

function VehicleSyncSpec.requestActionEventUpdate(vehicle)
    if vehicle ~= nil and vehicle.isClient and vehicle.requestActionEventUpdate ~= nil and not vehicle.isDeleted then
        vehicle:requestActionEventUpdate()
    end
end

-- ---------------------------------------------------------------------------
-- Requests (client -> server)
-- ---------------------------------------------------------------------------

---Sends a request to the server, or handles it right away when this machine is the server
function VehicleSyncSpec:vsRequest(action, argument)
    if self.isServer then
        VehicleSyncSpec.handleRequest(self, action, argument or 0, nil)
    else
        g_client:getServerConnection():sendEvent(VehicleSyncRequestEvent.new(self, action, argument or 0))
    end
end

---Server: validates and executes a request
---@param connection table|nil nil for requests of the local (server) player
function VehicleSyncSpec.handleRequest(vehicle, action, argument, connection)
    if not VehicleSyncSpec.isValidVehicle(vehicle) then
        return
    end

    -- only the player sitting in the vehicle may operate it
    if connection ~= nil and not (connection.getIsServer ~= nil and connection:getIsServer()) then
        if vehicle:getOwnerConnection() ~= connection then
            return
        end
    end

    local spec = VehicleSyncSpec.getSpec(vehicle)
    local settings = VehicleSyncSettings.get()
    local ACTION = VehicleSyncSpec.ACTION

    if action == ACTION.TOGGLE_NETWORK then
        vehicle:vsSetNetworkEnabled(not spec.networkEnabled)

    elseif action == ACTION.TOGGLE_CONNECT then
        if spec.state == STATE.IDLE then
            VehicleSyncSpec.tryConnect(vehicle, settings, connection)
        else
            vehicle:vsSetState(STATE.IDLE, REASON.DISCONNECTED, nil)
        end

    elseif action == ACTION.TOGGLE_ENGAGE then
        if VehicleSyncController.isEngaged(spec.state) then
            vehicle:vsSetState(STATE.CONNECTED, REASON.DISENGAGED, nil)
        else
            VehicleSyncSpec.tryEngage(vehicle, settings, connection)
        end

    elseif action == ACTION.SET_HOME then
        VehicleSyncSpec.trySetHome(vehicle, settings, connection)

    elseif action == ACTION.NUDGE then
        VehicleSyncSpec.nudge(vehicle, argument, settings, connection)

    elseif action == ACTION.RELEASE then
        local released = false
        for _, follower in ipairs(vehicle:vsGetFollowers()) do
            if VehicleSyncController.isEngaged(follower:vsGetState()) then
                follower:vsSetState(STATE.CONNECTED, REASON.RELEASED_BY_LEADER, nil)
                released = true
            end
        end
        if not released then
            VehicleSyncSpec.sendFeedback(vehicle, REASON.NO_LEADER, connection)
        end

    elseif action == ACTION.OPERATOR_TAKEOVER then
        if VehicleSyncController.isEngaged(spec.state) then
            vehicle:vsSetState(STATE.CONNECTED, REASON.OPERATOR_STEERING, nil)
        end
    end
end

---Server: builds the geometry between a follower and its (candidate) leader
---@return table geometry
---@return table leaderPose
---@return table followerPose
function VehicleSyncSpec.buildGeometry(follower, leader, settings)
    local spec = VehicleSyncSpec.getSpec(follower)
    local leaderPose = VehicleSyncSpec.getPose(leader)
    local followerPose = VehicleSyncSpec.getPose(follower)

    spec.receiver = VehicleSyncSpec.findReceiver(follower)
    local cartPose = nil
    if spec.receiver ~= nil then
        local x, _, z = getWorldTranslation(spec.receiver.node)
        cartPose = { x = x, z = z }
    end

    if spec.home == nil then
        VehicleSyncSpec.updateAutoHome(follower, leader, settings)
    end

    return VehicleSyncController.computeGeometry(leaderPose, followerPose, cartPose, spec.home), leaderPose, followerPose
end

---Server: (re)computes the automatic home point from the leader's pipe
function VehicleSyncSpec.updateAutoHome(follower, leader, settings)
    local spec = VehicleSyncSpec.getSpec(follower)
    local leaderSpec = VehicleSyncSpec.getSpec(leader)
    local cartWidth = VehicleSyncSpec.getWidth(spec.receiver ~= nil and spec.receiver.vehicle or follower)
    local pipeOffset, pipeSide = leaderSpec.pipeOffset, leaderSpec.pipeSide
    if pipeOffset == nil then
        pipeOffset, pipeSide = VehicleSyncSpec.measurePipe(leader)
    end
    spec.home = VehicleSyncController.getDefaultHome(pipeOffset, pipeSide, VehicleSyncSpec.getWidth(leader), cartWidth, settings)
    spec.homeIsAuto = true
end

---Server: requirements to join the nearest open network
---@return boolean ok
---@return number reason
---@return table|nil leader
function VehicleSyncSpec.checkConnect(vehicle, settings)
    local leader, distance = VehicleSyncSpec.findNearestLeader(vehicle)
    local ok, reason = VehicleSyncController.checkConnect({
        leaderExists = leader ~= nil,
        isSelf = leader == vehicle,
        networkEnabled = leader ~= nil and leader:vsGetNetworkEnabled(),
        sameFarm = leader ~= nil and VehicleSyncSpec.getIsSameFarm(vehicle, leader),
        distance = distance,
    }, settings)
    return ok, reason, leader
end

function VehicleSyncSpec.tryConnect(vehicle, settings, connection)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local ok, reason, leader = VehicleSyncSpec.checkConnect(vehicle, settings)

    if not ok then
        VehicleSyncSpec.sendFeedback(vehicle, reason, connection)
        return false
    end

    if spec.homeIsAuto then
        spec.home = nil
    end
    spec.receiver = VehicleSyncSpec.findReceiver(vehicle)
    if spec.home == nil then
        VehicleSyncSpec.updateAutoHome(vehicle, leader, settings)
    end
    vehicle:vsSetState(STATE.CONNECTED, reason, leader)
    return true
end

---True if another follower of the leader is engaged
function VehicleSyncSpec.getIsLeaderBusy(leader, follower)
    for _, other in ipairs(leader:vsGetFollowers()) do
        if other ~= follower and VehicleSyncController.isEngaged(other:vsGetState()) then
            return true
        end
    end
    return false
end

---Server: requirements to engage, exactly as pressing Engage would check them
---@return boolean ok
---@return number reason
function VehicleSyncSpec.checkEngage(vehicle, leader, geometry, leaderPose, settings)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local operatorPresent = vehicle:getIsControlled() and not vehicle:getIsAIActive()
    if vehicle.getReverserDirection ~= nil and vehicle:getReverserDirection() < 0 then
        operatorPresent = false
    end

    return VehicleSyncController.checkEngage({
        state = spec.state,
        geometry = geometry,
        leaderSpeed = leaderPose.speed,
        leaderBusy = VehicleSyncSpec.getIsLeaderBusy(leader, vehicle),
        operatorPresent = operatorPresent,
        motorStarted = vehicle:getIsMotorStarted(),
        cartFull = VehicleSyncSpec.getReceiverFillRatio(spec.receiver) >= settings.cartFullThreshold,
    }, settings)
end

function VehicleSyncSpec.tryEngage(vehicle, settings, connection)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local leader = spec.leader

    if spec.state ~= STATE.CONNECTED or not VehicleSyncSpec.isValidVehicle(leader) then
        VehicleSyncSpec.sendFeedback(vehicle, REASON.NO_LEADER, connection)
        return false
    end

    local geometry, leaderPose = VehicleSyncSpec.buildGeometry(vehicle, leader, settings)
    local ok, reason = VehicleSyncSpec.checkEngage(vehicle, leader, geometry, leaderPose, settings)

    if not ok then
        VehicleSyncSpec.sendFeedback(vehicle, reason, connection)
        return false
    end

    VehicleSyncController.resetCurvature(VehicleSyncSpec.getSpec(leader).curvature)
    vehicle:vsSetState(STATE.ACQUIRING, reason, leader)
    return true
end

function VehicleSyncSpec.trySetHome(vehicle, settings, connection)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local leader = spec.leader
    if not VehicleSyncController.isLinked(spec.state) or not VehicleSyncSpec.isValidVehicle(leader) then
        VehicleSyncSpec.sendFeedback(vehicle, REASON.NO_LEADER, connection)
        return false
    end

    local geometry = VehicleSyncSpec.buildGeometry(vehicle, leader, settings)
    if not VehicleSyncController.isInOperationalZone(geometry, settings) then
        VehicleSyncSpec.sendFeedback(vehicle, REASON.NOT_IN_ZONE, connection)
        return false
    end

    local cartWidth = VehicleSyncSpec.getWidth(spec.receiver ~= nil and spec.receiver.vehicle or vehicle)
    spec.home = VehicleSyncController.homeFromGeometry(geometry, VehicleSyncSpec.getWidth(leader), cartWidth, settings)
    spec.homeIsAuto = false
    spec.lastReason = REASON.HOME_SET
    vehicle:vsShowReason(REASON.HOME_SET)
    VehicleSyncSpec.showHomeMarker(vehicle)
    VehicleSyncSpec.broadcastState(vehicle)
    return true
end

---Server: leader operator nudges its engaged follower (or the nearest connected one)
function VehicleSyncSpec.nudge(leader, direction, settings, connection)
    local target = nil
    local nearestDistance = math.huge
    local leaderPose = VehicleSyncSpec.getPose(leader)
    for _, follower in ipairs(leader:vsGetFollowers()) do
        if VehicleSyncController.isEngaged(follower:vsGetState()) then
            target = follower
            break
        end
        local pose = VehicleSyncSpec.getPose(follower)
        local distance = VehicleSyncMath.distance2D(leaderPose.x, leaderPose.z, pose.x, pose.z)
        if distance < nearestDistance then
            target, nearestDistance = follower, distance
        end
    end

    if target == nil then
        VehicleSyncSpec.sendFeedback(leader, REASON.NO_LEADER, connection)
        return false
    end

    local spec = VehicleSyncSpec.getSpec(target)
    if spec.home == nil then
        VehicleSyncSpec.updateAutoHome(target, leader, settings)
    end
    local cartWidth = VehicleSyncSpec.getWidth(spec.receiver ~= nil and spec.receiver.vehicle or target)
    spec.home = VehicleSyncController.applyNudge(spec.home, direction, VehicleSyncSpec.getWidth(leader), cartWidth, settings)
    spec.homeIsAuto = false
    spec.lastReason = REASON.NONE
    VehicleSyncSpec.showHomeMarker(target)
    VehicleSyncSpec.broadcastState(target)
    return true
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

function VehicleSyncSpec:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = VehicleSyncSpec.getSpec(self)

    if not self.isServer then
        -- clients resolve a leader that was not loaded yet when this vehicle was streamed
        if spec.pendingLeaderId ~= nil then
            self:vsGetLeader()
        end
        return
    end

    local settings = VehicleSyncSettings.get()

    if spec.networkEnabled then
        VehicleSyncSpec.updateLeader(self, dt, settings)
    end

    local isIdleOperated = spec.state == STATE.IDLE and not spec.networkEnabled and self:getIsControlled()
    if spec.state ~= STATE.IDLE then
        VehicleSyncSpec.updateFollower(self, dt, settings)
    elseif isIdleOperated then
        VehicleSyncSpec.updateIdle(self, dt, settings)
    end

    -- idle vehicles drop out of the update loop; linked and operated ones keep checking
    if (spec.networkEnabled or spec.state ~= STATE.IDLE or isIdleOperated) and self.raiseActive ~= nil then
        self:raiseActive()
    end
end

---Server: leader bookkeeping (path curvature and pipe offset)
function VehicleSyncSpec.updateLeader(vehicle, dt, settings)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local pose = VehicleSyncSpec.getPose(vehicle)

    if math.abs(pose.speed) >= settings.minSyncSpeed then
        VehicleSyncController.updateCurvature(spec.curvature, pose.x, pose.z, pose.heading, settings.curvatureWindow)
    else
        VehicleSyncController.resetCurvature(spec.curvature)
    end

    spec.pipeTimer = spec.pipeTimer - dt
    if spec.pipeTimer <= 0 then
        spec.pipeTimer = VehicleSyncSpec.PIPE_MEASURE_INTERVAL
        local offset, side = VehicleSyncSpec.measurePipe(vehicle)
        spec.pipeSide = side or spec.pipeSide
        if offset ~= nil then
            local changed = spec.pipeOffset == nil
                or math.abs(spec.pipeOffset.x - offset.x) > VehicleSyncSpec.PIPE_CHANGE_THRESHOLD
                or math.abs(spec.pipeOffset.z - offset.z) > VehicleSyncSpec.PIPE_CHANGE_THRESHOLD
            spec.pipeOffset = offset
            if changed then
                -- followers that still use the automatic home point move under the real pipe outlet
                for _, follower in ipairs(vehicle:vsGetFollowers()) do
                    local followerSpec = VehicleSyncSpec.getSpec(follower)
                    if followerSpec.homeIsAuto then
                        VehicleSyncSpec.updateAutoHome(follower, vehicle, settings)
                        VehicleSyncSpec.broadcastState(follower)
                    end
                end
            end
        end
    end
end

---Server: tells the operator of an idle vehicle whether joining would work (live.check)
function VehicleSyncSpec.updateIdle(vehicle, dt, settings)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    spec.liveTimer = spec.liveTimer - dt
    if spec.liveTimer > 0 then
        return
    end
    spec.liveTimer = VehicleSyncSpec.LIVE_UPDATE_INTERVAL
    local _, reason = VehicleSyncSpec.checkConnect(vehicle, settings)
    if reason ~= spec.live.check then
        spec.live.check = reason
        vehicle:raiseDirtyFlags(spec.dirtyFlag)
    end
end

---Server: follower rules; the actual driving happens in updateVehiclePhysics
function VehicleSyncSpec.updateFollower(vehicle, dt, settings)
    local spec = VehicleSyncSpec.getSpec(vehicle)
    local leader = spec.leader

    local leaderExists = VehicleSyncSpec.isValidVehicle(leader)
    local ctx = {
        state = spec.state,
        dt = dt,
        leaderExists = leaderExists,
        networkEnabled = leaderExists and leader:vsGetNetworkEnabled(),
        distance = 0,
        operatorPresent = vehicle:getIsControlled() and not vehicle:getIsAIActive(),
        motorStarted = vehicle:getIsMotorStarted(),
        operatorSteering = false,
        operatorPedal = spec.operatorPedal,
        operatorCruise = spec.operatorCruise,
        abortTimer = spec.abortTimer,
        leaderSpeed = 0,
        leaderCurvature = 0,
        cartFull = false,
    }

    local geometry, leaderPose = nil, nil
    if leaderExists then
        geometry, leaderPose = VehicleSyncSpec.buildGeometry(vehicle, leader, settings)
        ctx.geometry = geometry
        ctx.distance = geometry.distance
        ctx.leaderSpeed = leaderPose.speed
        ctx.leaderCurvature = VehicleSyncSpec.getSpec(leader).curvature.value
        ctx.cartFull = VehicleSyncSpec.getReceiverFillRatio(spec.receiver) >= settings.cartFullThreshold
    end

    local newState, reason, abortTimer, fault = VehicleSyncController.evaluate(ctx, settings)
    spec.abortTimer = abortTimer
    spec.fault = fault
    spec.operatorPedal = false
    spec.operatorCruise = false

    if newState ~= spec.state then
        vehicle:vsSetState(newState, reason, nil)
    end

    if geometry ~= nil and spec.state ~= STATE.IDLE then
        spec.liveTimer = spec.liveTimer - dt
        if spec.liveTimer <= 0 then
            spec.liveTimer = VehicleSyncSpec.LIVE_UPDATE_INTERVAL
            spec.live.lateralError = geometry.lateralError
            spec.live.alongError = geometry.alongError
            spec.live.inZone = VehicleSyncController.isInOperationalZone(geometry, settings)
            if spec.state == STATE.CONNECTED then
                local _, engageReason = VehicleSyncSpec.checkEngage(vehicle, leader, geometry, leaderPose, settings)
                spec.live.check = engageReason
                spec.live.abortRemaining = 0
            else
                spec.live.check = spec.fault
                spec.live.abortRemaining = spec.fault ~= REASON.NONE and math.max(0, settings.abortDelay - spec.abortTimer) or 0
            end
            vehicle:raiseDirtyFlags(spec.dirtyFlag)
            VehicleSyncSpec.showAbortWarning(vehicle)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Driving (overwritten functions)
-- ---------------------------------------------------------------------------

---Server: replaces the operator's neutral input with the controller command while engaged
function VehicleSyncSpec:updateVehiclePhysics(superFunc, axisForward, axisSide, doHandbrake, dt)
    local spec = VehicleSyncSpec.getSpec(self)
    if spec == nil or not self.isServer or not VehicleSyncController.isEngaged(spec.state) then
        return superFunc(self, axisForward, axisSide, doHandbrake, dt)
    end

    local settings = VehicleSyncSettings.get()
    local leader = spec.leader

    -- pedal input = takeover; the rules drop the sync in the same frame (onUpdate runs after Drivable)
    if math.abs(axisForward) > settings.operatorPedalThreshold or not VehicleSyncSpec.isValidVehicle(leader) then
        spec.operatorPedal = VehicleSyncSpec.isValidVehicle(leader)
        return superFunc(self, axisForward, axisSide, doHandbrake, dt)
    end

    local geometry, leaderPose, followerPose = VehicleSyncSpec.buildGeometry(self, leader, settings)
    local command = VehicleSyncController.computeCommand(spec.state, leaderPose, followerPose, geometry, spec.home, settings)

    -- steering
    local targetRotTime = 0
    if self.getSteeringRotTimeByCurvature ~= nil then
        targetRotTime = self:getSteeringRotTimeByCurvature(command.curvature)
    end
    targetRotTime = VehicleSyncMath.clamp(targetRotTime, self.minRotTime or 0, self.maxRotTime or 0)
    local steeringSpeed = 0.001
    if self.getAISteeringSpeed ~= nil then
        steeringSpeed = self:getAISteeringSpeed()
    end
    local rotTime = VehicleSyncMath.moveTowards(self.rotatedTime or 0, targetRotTime, dt * steeringSpeed)
    local steeringDirection = 1
    if self.getSteeringDirection ~= nil then
        steeringDirection = self:getSteeringDirection()
    end
    local newAxisSide = VehicleSyncMath.rotTimeToAxisSide(rotTime, self.maxRotTime, self.minRotTime, steeringDirection)

    -- speed
    local newAxisForward = 0
    local newHandbrake = false
    if command.brake then
        newHandbrake = true
    else
        newAxisForward = 1
        local speedLimit = self:getSpeedLimit(true)
        self:getMotor():setSpeedLimit(math.min(command.targetSpeed, speedLimit))
    end

    return superFunc(self, newAxisForward, newAxisSide, newHandbrake, dt)
end

---Owner client: any steering input while engaged is a takeover
function VehicleSyncSpec:setSteeringInput(superFunc, inputValue, isAnalog, deviceCategory)
    local spec = VehicleSyncSpec.getSpec(self)
    if spec ~= nil and VehicleSyncController.isEngaged(spec.state) and not spec.takeoverRequested then
        if math.abs(inputValue) >= VehicleSyncController.DEFAULTS.operatorSteerThreshold then
            spec.takeoverRequested = true
            self:vsRequest(VehicleSyncSpec.ACTION.OPERATOR_TAKEOVER, 0)
        end
    end
    return superFunc(self, inputValue, isAnalog, deviceCategory)
end

---Server: switching the cruise control on while engaged is a takeover
function VehicleSyncSpec:setCruiseControlState(superFunc, state, noEventSend)
    local spec = VehicleSyncSpec.getSpec(self)
    if spec ~= nil and self.isServer and state ~= Drivable.CRUISECONTROL_STATE_OFF and VehicleSyncController.isEngaged(spec.state) then
        spec.operatorCruise = true
    end
    return superFunc(self, state, noEventSend)
end

-- ---------------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------------

function VehicleSyncSpec:onWriteStream(streamId, connection)
    local spec = VehicleSyncSpec.getSpec(self)
    streamWriteBool(streamId, spec.networkEnabled)
    streamWriteUIntN(streamId, spec.state, VehicleSyncController.NUM_STATE_BITS)
    if spec.state ~= STATE.IDLE then
        NetworkUtil.writeNodeObject(streamId, spec.leader)
    end
    if streamWriteBool(streamId, spec.home ~= nil) then
        streamWriteFloat32(streamId, spec.home.x)
        streamWriteFloat32(streamId, spec.home.z)
        streamWriteBool(streamId, spec.homeIsAuto)
    end
end

function VehicleSyncSpec:onReadStream(streamId, connection)
    local spec = VehicleSyncSpec.getSpec(self)
    local networkEnabled = streamReadBool(streamId)
    local state = streamReadUIntN(streamId, VehicleSyncController.NUM_STATE_BITS)
    local leaderId = nil
    if state ~= STATE.IDLE then
        leaderId = NetworkUtil.readNodeObjectId(streamId)
    end
    local home, homeIsAuto = nil, true
    if streamReadBool(streamId) then
        home = { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId) }
        homeIsAuto = streamReadBool(streamId)
    end

    self:vsApplyState(state, nil, home, homeIsAuto, networkEnabled, REASON.NONE)
    spec.state = state
    -- the leader may be streamed after this vehicle: resolve lazily
    spec.pendingLeaderId = leaderId
    self:vsGetLeader()
end

function VehicleSyncSpec:onWriteUpdateStream(streamId, connection, dirtyMask)
    if connection:getIsServer() then
        return
    end
    local spec = VehicleSyncSpec.getSpec(self)
    if streamWriteBool(streamId, bit32.band(dirtyMask, spec.dirtyFlag) ~= 0) then
        streamWriteFloat32(streamId, spec.live.lateralError)
        streamWriteFloat32(streamId, spec.live.alongError)
        streamWriteBool(streamId, spec.live.inZone)
        streamWriteUInt8(streamId, spec.live.check)
        streamWriteFloat32(streamId, spec.live.abortRemaining)
    end
end

function VehicleSyncSpec:onReadUpdateStream(streamId, timestamp, connection)
    if not connection:getIsServer() then
        return
    end
    local spec = VehicleSyncSpec.getSpec(self)
    if streamReadBool(streamId) then
        spec.live.lateralError = streamReadFloat32(streamId)
        spec.live.alongError = streamReadFloat32(streamId)
        spec.live.inZone = streamReadBool(streamId)
        spec.live.check = streamReadUInt8(streamId)
        spec.live.abortRemaining = streamReadFloat32(streamId)
        VehicleSyncSpec.showAbortWarning(self)
    end
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function VehicleSyncSpec:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if not self.isClient then
        return
    end
    local spec = VehicleSyncSpec.getSpec(self)
    self:clearActionEventsTable(spec.actionEvents)

    if not isActiveForInputIgnoreSelection then
        return
    end

    local function add(actionName, callback, text, priority)
        local inputAction = InputAction[actionName]
        if inputAction == nil then
            return
        end
        local _, actionEventId = self:addActionEvent(spec.actionEvents, inputAction, self, callback, false, true, false, true, nil)
        if actionEventId ~= nil then
            g_inputBinding:setActionEventText(actionEventId, g_i18n:getText(text, VehicleSyncSpec.MOD_NAME))
            g_inputBinding:setActionEventTextPriority(actionEventId, priority or GS_PRIO_NORMAL)
        end
    end

    -- the terminal (the only action with a default key)
    add("VS_TOGGLE_HUD", VehicleSyncSpec.actionEventToggleHud, "vs_action_toggleHud", GS_PRIO_NORMAL)

    -- leader actions
    if spec.networkEnabled or self:vsGetHasPipe() then
        add("VS_TOGGLE_NETWORK", VehicleSyncSpec.actionEventToggleNetwork,
            spec.networkEnabled and "vs_action_closeNetwork" or "vs_action_openNetwork", GS_PRIO_LOW)
    end
    if spec.networkEnabled and next(spec.followers) ~= nil then
        add("VS_NUDGE_LEFT", VehicleSyncSpec.actionEventNudgeLeft, "vs_action_nudgeLeft", GS_PRIO_VERY_LOW)
        add("VS_NUDGE_RIGHT", VehicleSyncSpec.actionEventNudgeRight, "vs_action_nudgeRight", GS_PRIO_VERY_LOW)
        add("VS_NUDGE_FORWARD", VehicleSyncSpec.actionEventNudgeForward, "vs_action_nudgeForward", GS_PRIO_VERY_LOW)
        add("VS_NUDGE_BACK", VehicleSyncSpec.actionEventNudgeBack, "vs_action_nudgeBack", GS_PRIO_VERY_LOW)
        add("VS_RELEASE", VehicleSyncSpec.actionEventRelease, "vs_action_release", GS_PRIO_LOW)
    end

    -- follower actions
    if not spec.networkEnabled then
        add("VS_CONNECT", VehicleSyncSpec.actionEventToggleConnect,
            spec.state == STATE.IDLE and "vs_action_connect" or "vs_action_disconnect", GS_PRIO_LOW)
    end
    if spec.state ~= STATE.IDLE then
        add("VS_ENGAGE", VehicleSyncSpec.actionEventToggleEngage,
            VehicleSyncController.isEngaged(spec.state) and "vs_action_disengage" or "vs_action_engage", GS_PRIO_HIGH)
        add("VS_SET_HOME", VehicleSyncSpec.actionEventSetHome, "vs_action_setHome", GS_PRIO_LOW)
    end
end

function VehicleSyncSpec.actionEventToggleHud(self, actionName, inputValue, callbackState, isAnalog)
    VehicleSyncHud:toggle(self)
end

function VehicleSyncSpec.actionEventToggleNetwork(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.TOGGLE_NETWORK, 0)
end

function VehicleSyncSpec.actionEventToggleConnect(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.TOGGLE_CONNECT, 0)
end

function VehicleSyncSpec.actionEventToggleEngage(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.TOGGLE_ENGAGE, 0)
end

function VehicleSyncSpec.actionEventSetHome(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.SET_HOME, 0)
end

function VehicleSyncSpec.actionEventNudgeLeft(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.NUDGE, VehicleSyncController.NUDGE.LEFT)
end

function VehicleSyncSpec.actionEventNudgeRight(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.NUDGE, VehicleSyncController.NUDGE.RIGHT)
end

function VehicleSyncSpec.actionEventNudgeForward(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.NUDGE, VehicleSyncController.NUDGE.FORWARD)
end

function VehicleSyncSpec.actionEventNudgeBack(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.NUDGE, VehicleSyncController.NUDGE.BACK)
end

function VehicleSyncSpec.actionEventRelease(self, actionName, inputValue, callbackState, isAnalog)
    self:vsRequest(VehicleSyncSpec.ACTION.RELEASE, 0)
end

-- ---------------------------------------------------------------------------
-- Home point marker (the terminal itself is VehicleSyncHud)
-- ---------------------------------------------------------------------------

---Shows the home point marker for HOME_MARKER_DURATION (called on every machine the change reaches)
function VehicleSyncSpec.showHomeMarker(vehicle)
    VehicleSyncSpec.getSpec(vehicle).homeMarkerUntil = g_time + VehicleSyncSpec.HOME_MARKER_DURATION
end

---True if a changed home point should be shown: set by the operator, or moved by a nudge
function VehicleSyncSpec.getIsHomeChange(oldHome, home, homeIsAuto, reason)
    if reason == REASON.HOME_SET then
        return true
    end
    if home == nil or homeIsAuto or oldHome == nil then
        return false
    end
    return oldHome.x ~= home.x or oldHome.z ~= home.z
end

---Draws the home point for a few seconds after it changed: an arrow high above the point where the
---cart's fill point should be, pointing down at it. Only the operators of the follower and of its
---leader see it. Called for every enterable vehicle by VehicleSystem:draw.
function VehicleSyncSpec:onDrawUIInfo()
    local spec = VehicleSyncSpec.getSpec(self)
    if not self.isClient or spec.homeMarkerUntil == nil or spec.home == nil then
        return
    end
    if g_time > spec.homeMarkerUntil then
        spec.homeMarkerUntil = nil
        return
    end
    local leader = self:vsGetLeader()
    if not VehicleSyncSpec.isValidVehicle(leader) or not (self:getIsEntered() or leader:getIsEntered()) then
        return
    end
    if g_gui:getIsGuiVisible() or g_noHudModeEnabled then
        return
    end

    local x, _, z = localToWorld(VehicleSyncSpec.getReferenceNode(leader), spec.home.x, 0, spec.home.z)
    VehicleSyncSpec.drawArrow(x, getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + VehicleSyncSpec.HOME_ARROW_TIP, z,
        VehicleSyncSpec.HOME_MARKER_COLOR)
end

---Draws a downward arrow whose tip is at (x, tipY, z): a four sided head and a shaft of parallel lines
function VehicleSyncSpec.drawArrow(x, tipY, z, color)
    local r, g, b = color[1], color[2], color[3]
    local headY = tipY + VehicleSyncSpec.HOME_ARROW_HEAD
    local tailY = tipY + VehicleSyncSpec.HOME_ARROW_LENGTH
    local width = VehicleSyncSpec.HOME_ARROW_WIDTH
    local shaft = VehicleSyncSpec.HOME_ARROW_SHAFT

    for _, offset in ipairs({ { 0, 0 }, { shaft, 0 }, { -shaft, 0 }, { 0, shaft }, { 0, -shaft } }) do
        drawDebugLine(x + offset[1], headY, z + offset[2], r, g, b, x + offset[1], tailY, z + offset[2], r, g, b)
    end

    local corners = { { width, 0 }, { 0, width }, { -width, 0 }, { 0, -width } }
    for i, corner in ipairs(corners) do
        local nextCorner = corners[i % #corners + 1]
        drawDebugLine(x, tipY, z, r, g, b, x + corner[1], headY, z + corner[2], r, g, b)
        drawDebugLine(x + corner[1], headY, z + corner[2], r, g, b, x + nextCorner[1], headY, z + nextCorner[2], r, g, b)
    end
end
