--[[
    Vehicle factory for the Vehicle Sync tests.

    Builds vehicles the way the engine does: a vehicle type is filled through the real
    VehicleSyncSpec.registerFunctions / registerOverwrittenFunctions / registerEventListeners and
    overwritten functions are chained onto a small Drivable-like base implementation.
]]

-- engine.lua must be loaded first (dofile), it publishes itself as TestEngine
local engine = TestEngine

local V = {}
V.nextId = 1

local function baseFunctions()
    local base = {}

    function base:updateVehiclePhysics(axisForward, axisSide, doHandbrake, dt)
        self.physicsCalls = self.physicsCalls or {}
        table.insert(self.physicsCalls, { axisForward = axisForward, axisSide = axisSide, doHandbrake = doHandbrake, dt = dt })
        return axisForward
    end
    function base:setSteeringInput(inputValue, isAnalog, deviceCategory)
        self.steeringInputs = self.steeringInputs or {}
        table.insert(self.steeringInputs, inputValue)
    end
    function base:setCruiseControlState(state, noEventSend)
        self.spec_drivable.cruiseControl.state = state
    end
    function base:setCruiseControlMaxSpeed(speed, speedReverse)
        self.spec_drivable.cruiseControl.speed = speed
        if speedReverse ~= nil then
            self.spec_drivable.cruiseControl.speedReverse = speedReverse
        end
    end
    function base:getLastSpeed() return math.abs(self.speed or 0) end
    function base:getOwnerFarmId() return self.farmId end
    function base:getOwnerConnection() return self.ownerConnection end
    function base:getName() return self.name end
    function base:getIsEntered() return self.entered == true end
    function base:getIsControlled() return self.controlled == true end
    function base:getIsAIActive() return self.aiActive == true end
    function base:getIsActiveForInput(_, activeForAI)
        return self:getIsEntered() and (activeForAI == true or not self:getIsAIActive())
    end
    function base:getIsMotorStarted() return self.motorStarted ~= false end
    function base:getChildVehicles() return self.childVehicles end
    function base:getSpeedLimit(onlyIfWorking) return self.speedLimit or 40, true end
    function base:getMotor() return self.motor end
    function base:getSteeringRotTimeByCurvature(curvature) return curvature * 10 end
    function base:getAISteeringSpeed() return 0.001 end
    function base:getSteeringDirection() return self.steeringDirection or 1 end
    function base:getReverserDirection() return self.reverser or 1 end
    function base:getAIDirectionNode() return self.directionNode end
    function base:getNextDirtyFlag()
        self.nextDirtyFlag = (self.nextDirtyFlag or 1) * 2
        return self.nextDirtyFlag
    end
    function base:raiseDirtyFlags(flag)
        self.dirtyRaised = (self.dirtyRaised or 0) + 1
        self.dirtyMask = flag
    end
    function base:requestActionEventUpdate()
        self.actionEventUpdates = (self.actionEventUpdates or 0) + 1
    end
    function base:clearActionEventsTable(t)
        for k in pairs(t) do t[k] = nil end
    end
    function base:addActionEvent(t, action, target, callback, triggerUp, triggerDown, triggerAlways, startActive, callbackState)
        t[action] = { callback = callback, target = target }
        return true, action
    end
    function base:getFillUnits() return self.fillUnits end
    function base:raiseActive() self.activeRaised = (self.activeRaised or 0) + 1 end
    return base
end

---Creates a drivable vehicle with the Vehicle Sync specialization
---@param opts table
function V.create(opts)
    opts = opts or {}
    local id = opts.networkId or V.nextId
    V.nextId = math.max(V.nextId, id) + 1

    local node = engine.createNode(opts.x or 0, opts.z or 0, opts.heading or 0)
    local vehicle = {
        name = opts.name or ("Vehicle" .. id),
        rootNode = node,
        directionNode = opts.noDirectionNode and nil or node,
        isServer = opts.isServer ~= false,
        isClient = opts.isClient ~= false,
        speed = opts.speed or 0,
        movingDirection = 1,
        farmId = opts.farmId or 1,
        entered = opts.entered,
        controlled = opts.controlled,
        motorStarted = opts.motorStarted,
        size = { width = opts.width or 3, length = 8 },
        maxRotTime = 1,
        minRotTime = -1,
        rotatedTime = 0,
        speedLimit = opts.speedLimit,
        motor = { speedLimit = math.huge },
        spec_drivable = { cruiseControl = { state = 0, speed = 10, speedReverse = 5 } },
        finishedFirstUpdate = true,
    }
    function vehicle.motor:setSpeedLimit(limit) self.speedLimit = limit end

    if opts.noDirectionNode then
        vehicle.directionNode = nil
    end
    if opts.speed ~= nil and opts.speed < 0 then
        vehicle.movingDirection = -1
    end
    vehicle.childVehicles = { vehicle }

    local vehicleType = { functions = {}, overwritten = {}, listeners = {} }
    VehicleSyncSpec.registerFunctions(vehicleType)
    VehicleSyncSpec.registerOverwrittenFunctions(vehicleType)
    VehicleSyncSpec.registerEventListeners(vehicleType)
    vehicle.vehicleType = vehicleType

    for name, fn in pairs(baseFunctions()) do
        vehicle[name] = fn
    end
    if opts.noAIDirectionFunction then
        vehicle.getAIDirectionNode = nil
    end
    for name, fn in pairs(vehicleType.overwritten) do
        local superFunc = vehicle[name]
        vehicle[name] = function(self, ...)
            return fn(self, superFunc, ...)
        end
    end
    for name, fn in pairs(vehicleType.functions) do
        vehicle[name] = fn
    end
    -- event listeners are callable like SpecializationUtil.raiseEvent would call them
    for name, spec in pairs(vehicleType.listeners) do
        vehicle[name] = function(self, ...)
            return spec[name](self, ...)
        end
    end

    if opts.hasPipe then
        V.addPipe(vehicle, opts.pipeX or 7, opts.pipeZ or 2, opts.pipeUnfolded)
    end

    vehicle[VehicleSyncSpec.SPEC_TABLE_NAME] = {}
    VehicleSyncSpec.onLoad(vehicle, opts.savegame)

    local side = opts.side or "server"
    NetworkUtil.register(side, id, vehicle)
    if side == "server" or opts.registerInMission then
        table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
    end

    return vehicle
end

---Adds a pipe whose discharge node sits at (x, z) in the vehicle frame
function V.addPipe(vehicle, x, z, unfolded)
    local pipeNode = engine.createChildNode(vehicle.rootNode, x, z, 0)
    vehicle.pipeNode = pipeNode
    vehicle.spec_pipe = { currentState = unfolded and 2 or 1, unloadingStates = { [2] = true } }
    function vehicle:getPipeDischargeNodeIndex() return 1 end
    function vehicle:getDischargeNodeByIndex(index)
        if index == 1 then
            return { node = self.pipeNode }
        end
        return nil
    end
end

---Moves the pipe node (e.g. folded position)
function V.setPipe(vehicle, x, z, unfolded)
    vehicle.pipeNode.lx = x
    vehicle.pipeNode.lz = z
    vehicle.spec_pipe.currentState = unfolded and 2 or 1
end

---Attaches a grain cart whose fill point trails the tractor by `distance` meters
function V.attachCart(tractor, distance, capacity, fillLevel, width)
    local cartNode = engine.createChildNode(tractor.rootNode, 0, -(distance or 6), 0)
    local cart = {
        name = "Cart",
        rootNode = cartNode,
        size = { width = width or 3 },
        spec_fillUnit = {},
        fillUnits = {
            { capacity = 500, fillLevel = 0 },  -- e.g. a unit without an exact fill root node
            { capacity = capacity or 20000, fillLevel = fillLevel or 0, exactFillRootNode = cartNode },
        },
    }
    function cart:getFillUnits() return self.fillUnits end
    tractor.childVehicles = { tractor, cart }
    tractor.cart = cart
    return cart
end

---Sets the pose of a vehicle
function V.setPose(vehicle, x, z, heading, speed)
    vehicle.rootNode.x = x
    vehicle.rootNode.z = z
    vehicle.rootNode.heading = heading or vehicle.rootNode.heading
    if speed ~= nil then
        vehicle.speed = speed
        vehicle.movingDirection = speed < 0 and -1 or 1
    end
end

---Standard scene: leader harvester heading north (+z) at 8 km/h, follower tractor with a cart on
-- the pipe side (left, +x), cart already at the home point below the unfolded pipe.
function V.createScene(opts)
    opts = opts or {}
    local leader = V.create({ name = "Harvester", x = 0, z = 0, heading = 0, speed = opts.leaderSpeed or 8,
        hasPipe = true, pipeX = 7, pipeZ = 2, pipeUnfolded = opts.pipeUnfolded ~= false, width = 3.5,
        entered = opts.leaderEntered, controlled = opts.leaderEntered })
    local cartDistance = 6
    local follower = V.create({ name = "Tractor", x = opts.followerX or 7, z = opts.followerZ or (2 + cartDistance),
        heading = opts.followerHeading or 0, speed = opts.followerSpeed or 8, width = 2.5,
        entered = opts.followerEntered ~= false, controlled = opts.followerEntered ~= false })
    V.attachCart(follower, cartDistance, 20000, opts.cartFill or 0, 3)
    return leader, follower
end

return V
