--[[
    VehicleSyncMath

    Engine-independent 2D geometry used by the sync controller. Everything works in the
    horizontal x/z plane of the GIANTS world with the engine's conventions:
      - local +z is "forward", local +x is "left"
      - a heading h (radians) is the Y rotation, forward = (sin h, cos h)
      - positive curvature turns left (see Wheels:getSteeringRotTimeByCurvature)

    No GIANTS API is used in this file so it can be unit tested with plain Lua 5.1.
]]

---@class VehicleSyncMath
VehicleSyncMath = {}

VehicleSyncMath.EPSILON = 0.0001

---Clamps value into [minValue, maxValue]
---@param value number
---@param minValue number
---@param maxValue number
---@return number
function VehicleSyncMath.clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

---Returns -1, 0 or 1
---@param value number
---@return number
function VehicleSyncMath.sign(value)
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

---Moves current towards target by at most maxDelta
---@param current number
---@param target number
---@param maxDelta number
---@return number
function VehicleSyncMath.moveTowards(current, target, maxDelta)
    local diff = target - current
    if math.abs(diff) <= maxDelta then
        return target
    end
    return current + VehicleSyncMath.sign(diff) * maxDelta
end

---Wraps an angle into (-pi, pi]
---@param angle number radians
---@return number
function VehicleSyncMath.normalizeAngle(angle)
    local twoPi = 2 * math.pi
    angle = math.fmod(angle, twoPi)
    if angle <= -math.pi then
        angle = angle + twoPi
    elseif angle > math.pi then
        angle = angle - twoPi
    end
    return angle
end

---Heading of a world direction vector (0 = +z)
---@param dx number
---@param dz number
---@return number radians
function VehicleSyncMath.headingFromDirection(dx, dz)
    return math.atan2(dx, dz)
end

---Signed difference b - a between two headings, wrapped into (-pi, pi]
---@param a number
---@param b number
---@return number
function VehicleSyncMath.headingDifference(a, b)
    return VehicleSyncMath.normalizeAngle(b - a)
end

---Transforms a world point into the local frame of (originX, originZ, heading)
---@return number localX (left positive)
---@return number localZ (forward positive)
function VehicleSyncMath.worldToLocal(originX, originZ, heading, worldX, worldZ)
    local dx = worldX - originX
    local dz = worldZ - originZ
    local cosH = math.cos(heading)
    local sinH = math.sin(heading)
    return dx * cosH - dz * sinH, dx * sinH + dz * cosH
end

---Transforms a local point of the frame (originX, originZ, heading) into world space
---@return number worldX
---@return number worldZ
function VehicleSyncMath.localToWorld(originX, originZ, heading, localX, localZ)
    local cosH = math.cos(heading)
    local sinH = math.sin(heading)
    return originX + localX * cosH + localZ * sinH, originZ - localX * sinH + localZ * cosH
end

---Pure pursuit curvature towards a look-ahead point given in the vehicle's local frame
---@param localX number
---@param localZ number
---@return number curvature 1/m, positive = left
function VehicleSyncMath.purePursuitCurvature(localX, localZ)
    local distanceSq = localX * localX + localZ * localZ
    if distanceSq < VehicleSyncMath.EPSILON then
        return 0
    end
    return 2 * localX / distanceSq
end

---Converts a desired steering rotTime into the axisSide value that Drivable:updateVehiclePhysics
-- maps back onto the same rotTime. This lets the follower steer through the regular physics path.
---@param rotTime number desired rotated time (positive = left)
---@param maxRotTime number vehicle.maxRotTime (> 0)
---@param minRotTime number vehicle.minRotTime (< 0)
---@param steeringDirection number vehicle:getSteeringDirection() (1 or -1)
---@return number axisSide in [-1, 1]
function VehicleSyncMath.rotTimeToAxisSide(rotTime, maxRotTime, minRotTime, steeringDirection)
    local axisSide = 0
    if rotTime > 0 then
        if maxRotTime ~= nil and maxRotTime > 0 then
            axisSide = -rotTime / maxRotTime
        end
    elseif rotTime < 0 then
        if minRotTime ~= nil and minRotTime < 0 then
            axisSide = rotTime / minRotTime
        end
    end

    axisSide = VehicleSyncMath.clamp(axisSide, -1, 1)

    if steeringDirection ~= nil and steeringDirection < 0 then
        axisSide = -axisSide
    end

    return axisSide
end

---Distance between two points in the x/z plane
---@return number
function VehicleSyncMath.distance2D(x1, z1, x2, z2)
    local dx = x2 - x1
    local dz = z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

---Rounds to the given step (e.g. 0.25 m nudge steps), keeps floats stable for network writes
---@param value number
---@param step number
---@return number
function VehicleSyncMath.roundToStep(value, step)
    if step == nil or step <= 0 then
        return value
    end
    return math.floor(value / step + 0.5) * step
end
