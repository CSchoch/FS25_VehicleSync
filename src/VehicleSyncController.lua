--[[
    VehicleSyncController

    Engine-independent core of Vehicle Sync: the follower state machine, the operational zone,
    the disengage rules and the steering / speed control law. Modelled on real-world
    leader/follower machine synchronisation used for unloading harvesters on the go:

      IDLE        follower is not linked to any leader
      CONNECTED   follower joined the leader's sync network, the operator still drives manually
      ACQUIRING   sync engaged, the follower is steered / accelerated towards its home point
      TRACKING    follower holds the home point, speed and heading follow the leader

    The real systems disengage when the operator steers or uses the pedals, when the leader leaves
    the speed window (0.5 - 16 km/h) and when the leader's path bends more than 0.5 deg per meter
    (headland turn). A disengage always falls back to CONNECTED so the operator can re-engage.

    The functions in here only work on plain tables so they can be unit tested without the game.
    All positions are 2D (x/z); see VehicleSyncMath for the frame conventions.
]]

---@class VehicleSyncController
VehicleSyncController = {}

VehicleSyncController.STATE = {
    IDLE = 0,
    CONNECTED = 1,
    ACQUIRING = 2,
    TRACKING = 3,
}
VehicleSyncController.NUM_STATE_BITS = 2

-- Reason codes are sent over the network (UInt8) and map onto l10n keys "vs_reason_<name>"
VehicleSyncController.REASON = {
    NONE = 0,
    CONNECTED = 1,
    DISCONNECTED = 2,
    ENGAGED = 3,
    DISENGAGED = 4,
    OPERATOR_STEERING = 5,
    OPERATOR_PEDAL = 6,
    OPERATOR_CRUISE = 7,
    LEADER_STOPPED = 8,
    LEADER_TOO_FAST = 9,
    LEADER_TURNING = 10,
    LEADER_REVERSING = 11,
    POSITION_LOST = 12,
    OUT_OF_RANGE = 13,
    LEADER_LOST = 14,
    CART_FULL = 15,
    OPERATOR_LEFT = 16,
    RELEASED_BY_LEADER = 17,
    NETWORK_CLOSED = 18,
    NOT_IN_ZONE = 19,
    NO_LEADER = 20,
    LEADER_BUSY = 21,
    NOT_ALLOWED = 22,
    HOME_SET = 23,
    LEADER_SPEED_WINDOW = 24,
    MOTOR_OFF = 25,
}

VehicleSyncController.REASON_NAMES = {}
for name, value in pairs(VehicleSyncController.REASON) do
    VehicleSyncController.REASON_NAMES[value] = name
end

-- Nudge directions, as seen from the leader's seat
VehicleSyncController.NUDGE = {
    LEFT = 1,
    RIGHT = 2,
    FORWARD = 3,
    BACK = 4,
}

---Default tuning. Settings (VehicleSyncSettings) override the user facing values.
VehicleSyncController.DEFAULTS = {
    minSyncSpeed = 0.5,              -- km/h, below this the leader counts as stopped
    maxSyncSpeed = 16,               -- km/h, sync window upper limit
    maxLeaderCurvature = 0.5,        -- deg per meter of leader travel
    curvatureWindow = 3,             -- meters of travel the curvature is averaged over
    stopTimeout = 3000,              -- ms the leader may stand still before sync disengages
    radioRange = 500,                -- m, sync network range
    connectRange = 60,               -- m, max. distance to join a network
    zoneLateral = 25,                -- m, operational zone: max. lateral distance to the leader
    zoneFront = 15,                  -- m, operational zone: max. distance in front of the leader
    zoneBack = 40,                   -- m, operational zone: max. distance behind the leader
    engageMaxHeading = 30,           -- deg, max. heading difference to engage
    disengageHeading = 60,           -- deg, heading difference that drops the sync
    trackingLateralTolerance = 0.5,  -- m, ACQUIRING -> TRACKING
    trackingAlongTolerance = 1.0,    -- m, ACQUIRING -> TRACKING
    reacquireLateral = 2.5,          -- m, TRACKING -> ACQUIRING
    reacquireAlong = 4.0,            -- m, TRACKING -> ACQUIRING
    positionLostLateral = 15,        -- m, drop the sync
    positionLostAlong = 30,          -- m, drop the sync
    speedGainAlong = 1.2,            -- km/h per m of along-track error
    maxCatchUpSpeed = 6,             -- km/h above leader speed while acquiring
    maxTrackingCorrection = 3,       -- km/h above/below leader speed while tracking
    lookAheadMin = 6,                -- m
    lookAheadMax = 14,               -- m
    lookAheadPerKmh = 0.6,           -- m per km/h
    nudgeStepLateral = 0.25,         -- m
    nudgeStepAlong = 0.25,           -- m
    largeNudgeAlong = 0.66,          -- m, total fore/aft nudge that triggers the operator hint
    minLateralClearance = 1.0,       -- m, gap between the leader and the cart that nudges keep
    maxLateralOffset = 20,           -- m
    maxAlongOffset = 20,             -- m
    cartFullThreshold = 0.995,       -- fill ratio
    disengageOnCartFull = true,
    keepSpeedOnSteering = true,      -- steering takeover keeps the leader's speed on cruise control
    operatorSteerThreshold = 0.15,   -- analog steering input that counts as takeover
    operatorPedalThreshold = 0.1,    -- pedal input that counts as takeover
    stopSpeed = 0.5,                 -- km/h, commanded speeds below this brake to a stop
    fallbackLateralMargin = 1.5,     -- m, gap used when the pipe was never measured
}

---Returns a settings table with every key of DEFAULTS, using values from overrides where present
---@param overrides table|nil
---@return table
function VehicleSyncController.buildSettings(overrides)
    local settings = {}
    for key, value in pairs(VehicleSyncController.DEFAULTS) do
        settings[key] = value
    end
    if overrides ~= nil then
        for key, value in pairs(overrides) do
            if settings[key] ~= nil and type(value) == type(settings[key]) then
                settings[key] = value
            end
        end
    end
    return settings
end

---@param state number
---@return boolean
function VehicleSyncController.isEngaged(state)
    return state == VehicleSyncController.STATE.ACQUIRING or state == VehicleSyncController.STATE.TRACKING
end

---@param state number
---@return boolean
function VehicleSyncController.isLinked(state)
    return state ~= nil and state ~= VehicleSyncController.STATE.IDLE
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

---Computes the relative geometry between leader, follower and cart.
-- leader:   {x, z, heading}
-- follower: {x, z, heading}           tractor that is steered
-- cart:     {x, z} | nil              receiving point (grain cart), defaults to the follower
-- home:     {x, z}                    desired cart position in the leader frame
---@return table geometry
function VehicleSyncController.computeGeometry(leader, follower, cart, home)
    cart = cart or follower

    local tractorX, tractorZ = VehicleSyncMath.worldToLocal(leader.x, leader.z, leader.heading, follower.x, follower.z)
    local cartX, cartZ = VehicleSyncMath.worldToLocal(leader.x, leader.z, leader.heading, cart.x, cart.z)

    local geometry = {
        tractorLocalX = tractorX,
        tractorLocalZ = tractorZ,
        cartLocalX = cartX,
        cartLocalZ = cartZ,
        -- the tractor drives on the home line, the cart trails on the same line
        lateralError = tractorX - home.x,
        -- speed is controlled on the cart position, positive = cart ahead of the home point
        alongError = cartZ - home.z,
        headingError = VehicleSyncMath.headingDifference(leader.heading, follower.heading),
        distance = VehicleSyncMath.distance2D(leader.x, leader.z, follower.x, follower.z),
        -- tractor ahead of its cart along the leader axis; used to place the look-ahead point
        cartToTractorAlong = tractorZ - cartZ,
    }

    return geometry
end

---Checks whether the follower is inside the operational zone of the leader
---@param geometry table
---@param settings table
---@return boolean
function VehicleSyncController.isInOperationalZone(geometry, settings)
    local x = geometry.cartLocalX
    local z = geometry.cartLocalZ
    if math.abs(x) > settings.zoneLateral then
        return false
    end
    if z > settings.zoneFront or z < -settings.zoneBack then
        return false
    end
    return math.abs(math.deg(geometry.headingError)) <= settings.engageMaxHeading
end

-- ---------------------------------------------------------------------------
-- Home point
-- ---------------------------------------------------------------------------

---Minimum lateral distance of the cart center to the leader center
---@param leaderWidth number|nil
---@param cartWidth number|nil
---@param settings table
---@return number
function VehicleSyncController.getMinLateral(leaderWidth, cartWidth, settings)
    return (leaderWidth or 3) * 0.5 + (cartWidth or 3) * 0.5 + settings.minLateralClearance
end

---Clamps a home point so the cart never overlaps the leader and never gets unreasonably far away.
-- The side (sign of x) is preserved; x == 0 is treated as the left side.
---@return table home {x, z}
function VehicleSyncController.clampHome(home, leaderWidth, cartWidth, settings, side)
    side = side or (home.x < 0 and -1 or 1)
    local minLateral = VehicleSyncController.getMinLateral(leaderWidth, cartWidth, settings)
    local maxLateral = math.max(settings.maxLateralOffset, minLateral)
    local lateral = VehicleSyncMath.clamp(math.abs(home.x), minLateral, maxLateral)
    local along = VehicleSyncMath.clamp(home.z, -settings.maxAlongOffset, settings.maxAlongOffset)
    return { x = side * lateral, z = along }
end

---Default home point: cart center right below the pipe outlet if the pipe was measured,
-- otherwise alongside the leader on the pipe side.
---@param pipeOffset table|nil {x, z} discharge node in the leader frame (measured with the pipe unfolded)
---@param pipeSide number|nil 1 = left, -1 = right, used when pipeOffset is nil
---@return table home {x, z}
function VehicleSyncController.getDefaultHome(pipeOffset, pipeSide, leaderWidth, cartWidth, settings)
    local home
    if pipeOffset ~= nil then
        home = { x = pipeOffset.x, z = pipeOffset.z }
    else
        local side = (pipeSide ~= nil and pipeSide < 0) and -1 or 1
        local lateral = VehicleSyncController.getMinLateral(leaderWidth, cartWidth, settings) + settings.fallbackLateralMargin
        home = { x = side * lateral, z = 0 }
    end
    return VehicleSyncController.clampHome(home, leaderWidth, cartWidth, settings)
end

---Applies a nudge from the leader operator.
-- "LEFT"/"RIGHT" are seen from the leader's seat: LEFT moves the cart towards +x.
---@return table home {x, z}
---@return number alongDelta how far the cart was moved fore/aft (for the large-nudge hint)
function VehicleSyncController.applyNudge(home, direction, leaderWidth, cartWidth, settings)
    local nudge = VehicleSyncController.NUDGE
    local x, z = home.x, home.z
    if direction == nudge.LEFT then
        x = x + settings.nudgeStepLateral
    elseif direction == nudge.RIGHT then
        x = x - settings.nudgeStepLateral
    elseif direction == nudge.FORWARD then
        z = z + settings.nudgeStepAlong
    elseif direction == nudge.BACK then
        z = z - settings.nudgeStepAlong
    end

    -- nudging never pushes the cart across or into the leader: it stays on its side and
    -- clampHome enforces the minimum clearance
    local side = home.x < 0 and -1 or 1
    local newHome = VehicleSyncController.clampHome({ x = x, z = z }, leaderWidth, cartWidth, settings, side)
    newHome.x = VehicleSyncMath.roundToStep(newHome.x, 0.01)
    newHome.z = VehicleSyncMath.roundToStep(newHome.z, 0.01)

    return newHome, newHome.z - home.z
end

---Home point from the current cart position, used by "set home point"
---@return table home {x, z}
function VehicleSyncController.homeFromGeometry(geometry, leaderWidth, cartWidth, settings)
    local home = { x = geometry.cartLocalX, z = geometry.cartLocalZ }
    home = VehicleSyncController.clampHome(home, leaderWidth, cartWidth, settings)
    home.x = VehicleSyncMath.roundToStep(home.x, 0.01)
    home.z = VehicleSyncMath.roundToStep(home.z, 0.01)
    return home
end

-- ---------------------------------------------------------------------------
-- Leader path curvature
-- ---------------------------------------------------------------------------

---Creates a curvature tracker (deg per meter of travel, averaged over settings.curvatureWindow)
---@return table
function VehicleSyncController.newCurvatureTracker()
    return { lastX = nil, lastZ = nil, lastHeading = nil, accumulatedAngle = 0, accumulatedDistance = 0, value = 0 }
end

---Feeds a new leader pose into the tracker and returns the current curvature
---@return number degreesPerMeter
function VehicleSyncController.updateCurvature(tracker, x, z, heading, window)
    if tracker.lastX ~= nil then
        local distance = VehicleSyncMath.distance2D(tracker.lastX, tracker.lastZ, x, z)
        local angle = math.abs(math.deg(VehicleSyncMath.headingDifference(tracker.lastHeading, heading)))
        tracker.accumulatedDistance = tracker.accumulatedDistance + distance
        tracker.accumulatedAngle = tracker.accumulatedAngle + angle
        if tracker.accumulatedDistance >= window then
            tracker.value = tracker.accumulatedAngle / tracker.accumulatedDistance
            tracker.accumulatedAngle = 0
            tracker.accumulatedDistance = 0
        end
    end
    tracker.lastX = x
    tracker.lastZ = z
    tracker.lastHeading = heading
    return tracker.value
end

---Resets the tracker, e.g. after the leader stood still or was teleported
function VehicleSyncController.resetCurvature(tracker)
    tracker.lastX = nil
    tracker.lastZ = nil
    tracker.lastHeading = nil
    tracker.accumulatedAngle = 0
    tracker.accumulatedDistance = 0
    tracker.value = 0
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

---Checks the requirements to join a leader's network
-- ctx: {leaderExists, networkEnabled, sameFarm, isSelf, distance}
---@return boolean ok
---@return number reason
function VehicleSyncController.checkConnect(ctx, settings)
    local reason = VehicleSyncController.REASON
    if not ctx.leaderExists or ctx.isSelf then
        return false, reason.NO_LEADER
    end
    if not ctx.networkEnabled then
        return false, reason.NETWORK_CLOSED
    end
    if not ctx.sameFarm then
        return false, reason.NOT_ALLOWED
    end
    if ctx.distance > settings.connectRange then
        return false, reason.OUT_OF_RANGE
    end
    return true, reason.CONNECTED
end

---Checks the requirements to engage the sync
-- ctx: {state, geometry, leaderSpeed (signed km/h), leaderBusy, operatorPresent, motorStarted, cartFull}
---@return boolean ok
---@return number reason
function VehicleSyncController.checkEngage(ctx, settings)
    local reason = VehicleSyncController.REASON
    local state = VehicleSyncController.STATE
    if ctx.state ~= state.CONNECTED then
        return false, reason.NO_LEADER
    end
    if not ctx.operatorPresent then
        return false, reason.OPERATOR_LEFT
    end
    if not ctx.motorStarted then
        return false, reason.MOTOR_OFF
    end
    if ctx.leaderBusy then
        return false, reason.LEADER_BUSY
    end
    if ctx.cartFull and settings.disengageOnCartFull then
        return false, reason.CART_FULL
    end
    if ctx.leaderSpeed < settings.minSyncSpeed or ctx.leaderSpeed > settings.maxSyncSpeed then
        return false, reason.LEADER_SPEED_WINDOW
    end
    if not VehicleSyncController.isInOperationalZone(ctx.geometry, settings) then
        return false, reason.NOT_IN_ZONE
    end
    return true, reason.ENGAGED
end

---Evaluates the connection / sync rules for one server tick.
-- ctx fields:
--   state, dt (ms)
--   leaderExists, networkEnabled, distance (m)
--   operatorPresent, motorStarted
--   geometry (only needed while engaged)
--   leaderSpeed (signed km/h), leaderCurvature (deg/m)
--   operatorSteering, operatorPedal, operatorCruise (booleans)
--   cartFull
--   stopTimer (ms the leader already stands still)
---@return number newState
---@return number reason REASON.NONE if nothing changed
---@return number stopTimer updated stop timer
function VehicleSyncController.evaluate(ctx, settings)
    local state = VehicleSyncController.STATE
    local reason = VehicleSyncController.REASON
    local current = ctx.state
    local stopTimer = ctx.stopTimer or 0

    if current == state.IDLE then
        return current, reason.NONE, 0
    end

    -- connection level rules, valid for every linked state
    if not ctx.leaderExists then
        return state.IDLE, reason.LEADER_LOST, 0
    end
    if not ctx.networkEnabled then
        return state.IDLE, reason.NETWORK_CLOSED, 0
    end
    if ctx.distance > settings.radioRange then
        return state.IDLE, reason.OUT_OF_RANGE, 0
    end

    if current == state.CONNECTED then
        return current, reason.NONE, 0
    end

    -- engaged rules: every fault falls back to CONNECTED
    if not ctx.operatorPresent then
        return state.CONNECTED, reason.OPERATOR_LEFT, 0
    end
    if ctx.operatorSteering then
        return state.CONNECTED, reason.OPERATOR_STEERING, 0
    end
    if ctx.operatorPedal then
        return state.CONNECTED, reason.OPERATOR_PEDAL, 0
    end
    if ctx.operatorCruise then
        return state.CONNECTED, reason.OPERATOR_CRUISE, 0
    end
    if not ctx.motorStarted then
        return state.CONNECTED, reason.MOTOR_OFF, 0
    end
    if ctx.cartFull and settings.disengageOnCartFull then
        return state.CONNECTED, reason.CART_FULL, 0
    end

    local leaderSpeed = ctx.leaderSpeed
    if leaderSpeed < -settings.minSyncSpeed then
        return state.CONNECTED, reason.LEADER_REVERSING, 0
    end
    if leaderSpeed > settings.maxSyncSpeed then
        return state.CONNECTED, reason.LEADER_TOO_FAST, 0
    end
    if leaderSpeed < settings.minSyncSpeed then
        stopTimer = stopTimer + (ctx.dt or 0)
        if stopTimer >= settings.stopTimeout then
            return state.CONNECTED, reason.LEADER_STOPPED, 0
        end
    else
        stopTimer = 0
    end
    if (ctx.leaderCurvature or 0) > settings.maxLeaderCurvature then
        return state.CONNECTED, reason.LEADER_TURNING, 0
    end

    local geometry = ctx.geometry
    if math.abs(math.deg(geometry.headingError)) > settings.disengageHeading then
        return state.CONNECTED, reason.LEADER_TURNING, 0
    end
    if math.abs(geometry.lateralError) > settings.positionLostLateral or math.abs(geometry.alongError) > settings.positionLostAlong then
        return state.CONNECTED, reason.POSITION_LOST, 0
    end

    if current == state.ACQUIRING then
        if math.abs(geometry.lateralError) <= settings.trackingLateralTolerance and math.abs(geometry.alongError) <= settings.trackingAlongTolerance then
            return state.TRACKING, reason.NONE, stopTimer
        end
    elseif current == state.TRACKING then
        if math.abs(geometry.lateralError) > settings.reacquireLateral or math.abs(geometry.alongError) > settings.reacquireAlong then
            return state.ACQUIRING, reason.NONE, stopTimer
        end
    end

    return current, reason.NONE, stopTimer
end

-- ---------------------------------------------------------------------------
-- Control law
-- ---------------------------------------------------------------------------

---Look-ahead distance for the steering controller
---@param speed number km/h
---@return number meters
function VehicleSyncController.getLookAhead(speed, settings)
    return VehicleSyncMath.clamp(math.abs(speed) * settings.lookAheadPerKmh, settings.lookAheadMin, settings.lookAheadMax)
end

---Target speed of the follower in km/h (>= 0)
---@param state number
---@param leaderSpeed number km/h (signed)
---@param alongError number m, positive = cart ahead of the home point
---@return number
function VehicleSyncController.getTargetSpeed(state, leaderSpeed, alongError, settings)
    local baseSpeed = math.max(leaderSpeed, 0)
    local correction = -alongError * settings.speedGainAlong

    local maxCorrection = settings.maxTrackingCorrection
    if state == VehicleSyncController.STATE.ACQUIRING then
        maxCorrection = settings.maxCatchUpSpeed
    end
    correction = VehicleSyncMath.clamp(correction, -maxCorrection, maxCorrection)

    local speed = baseSpeed + correction
    local maxSpeed = settings.maxSyncSpeed + maxCorrection
    speed = VehicleSyncMath.clamp(speed, 0, maxSpeed)

    -- the leader stands still: only creep closer if we are behind, never overtake the home point
    if baseSpeed < settings.minSyncSpeed and alongError > -settings.trackingAlongTolerance then
        speed = 0
    end

    if speed < settings.stopSpeed then
        speed = 0
    end

    return speed
end

---Computes the drive command for an engaged follower.
-- leader:   {x, z, heading, speed}
-- follower: {x, z, heading, speed}
---@return table command {curvature, targetSpeed, brake, lookAhead}
function VehicleSyncController.computeCommand(state, leader, follower, geometry, home, settings)
    local lookAhead = VehicleSyncController.getLookAhead(math.max(leader.speed, follower.speed or 0), settings)

    -- look-ahead point on the home line (parallel to the leader), measured from the tractor
    local targetLocalX = home.x
    local targetLocalZ = geometry.tractorLocalZ + lookAhead
    local worldX, worldZ = VehicleSyncMath.localToWorld(leader.x, leader.z, leader.heading, targetLocalX, targetLocalZ)
    local followerX, followerZ = VehicleSyncMath.worldToLocal(follower.x, follower.z, follower.heading, worldX, worldZ)

    local curvature = VehicleSyncMath.purePursuitCurvature(followerX, followerZ)
    local targetSpeed = VehicleSyncController.getTargetSpeed(state, leader.speed, geometry.alongError, settings)

    return {
        curvature = curvature,
        targetSpeed = targetSpeed,
        brake = targetSpeed <= 0,
        lookAhead = lookAhead,
    }
end

---Returns the l10n key for a reason
---@param reasonCode number
---@return string|nil
function VehicleSyncController.getReasonTextKey(reasonCode)
    local name = VehicleSyncController.REASON_NAMES[reasonCode]
    if name == nil or reasonCode == VehicleSyncController.REASON.NONE then
        return nil
    end
    return "vs_reason_" .. string.lower(name)
end

---Returns true if the reason should be shown as a warning (red) instead of an info (green)
---@param reasonCode number
---@return boolean
function VehicleSyncController.isWarningReason(reasonCode)
    local reason = VehicleSyncController.REASON
    return reasonCode ~= reason.CONNECTED and reasonCode ~= reason.ENGAGED
        and reasonCode ~= reason.DISENGAGED and reasonCode ~= reason.DISCONNECTED
        and reasonCode ~= reason.HOME_SET and reasonCode ~= reason.NONE
end
