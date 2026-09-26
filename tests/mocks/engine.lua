--[[
    Minimal GIANTS engine / FS25 API mock for the Vehicle Sync tests.

    Only what the mod touches is implemented. Scene graph nodes are plain tables:
        { x, z, heading }                      world node
        { parent = node, lx, lz, lheading }    child node, local transform relative to parent
    Streams are in-memory FIFO queues, NetworkUtil maps ids to objects per "side" so a server
    object and its client copy can share one network id.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Lua helpers the game provides
-- ---------------------------------------------------------------------------

function math.clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

function table.size(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

bit32 = bit32 or {}
function bit32.band(a, b)
    local result, bitValue = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bitValue
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitValue = bitValue * 2
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Logging / i18n / misc globals
-- ---------------------------------------------------------------------------

Logging = { calls = { error = {}, warning = {}, info = {} } }
function Logging.error(fmt, ...) table.insert(Logging.calls.error, string.format(fmt, ...)) end
function Logging.warning(fmt, ...) table.insert(Logging.calls.warning, string.format(fmt, ...)) end
function Logging.info(fmt, ...) table.insert(Logging.calls.info, string.format(fmt, ...)) end

M.texts = {}
g_i18n = {}
function g_i18n:getText(key, modName)
    if M.texts[key] ~= nil then
        return M.texts[key]
    end
    return "[" .. tostring(key) .. "]"
end

---Loads the English translation file of the mod into the i18n mock
function M.loadTranslations(path)
    local fh = io.open(path or "translations/translation_en.xml", "r")
    if fh == nil then return end
    local content = fh:read("*a")
    fh:close()
    for name, text in content:gmatch('<text name="([^"]+)" text="([^"]*)"') do
        text = text:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
        M.texts[name] = text
    end
end

Utils = {}
function Utils.getNoNil(v, default)
    if v == nil then return default end
    return v
end
function Utils.getFilename(filename, baseDir)
    return (baseDir or "") .. filename
end
function Utils.appendedFunction(original, appended)
    return function(...)
        local r = { original(...) }
        appended(...)
        return unpack(r)
    end
end
function Utils.prependedFunction(original, prepended)
    return function(...)
        prepended(...)
        return original(...)
    end
end

-- world drawing: circles and lines are recorded
M.drawn = { circles = {}, lines = {} }
g_time = 0
g_terrainNode = 1
g_gui = { visible = false, getIsGuiVisible = function(self) return self.visible end }
g_noHudModeEnabled = false
function getTerrainHeightAtWorldPos(terrainNode, x, y, z) return 0 end
DebugUtil = {}
function DebugUtil.drawDebugCircle(x, y, z, radius, steps, color, alignToTerrain)
    table.insert(M.drawn.circles, { x = x, y = y, z = z, radius = radius, color = color })
end
function drawDebugLine(x1, y1, z1, r1, g1, b1, x2, y2, z2, r2, g2, b2)
    table.insert(M.drawn.lines, { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2, color = { r1, g1, b1 } })
end

GS_PRIO_VERY_HIGH, GS_PRIO_HIGH, GS_PRIO_NORMAL, GS_PRIO_LOW, GS_PRIO_VERY_LOW = 1, 2, 3, 4, 5

InputAction = {}
for _, name in ipairs({ "VS_TOGGLE_NETWORK", "VS_CONNECT", "VS_ENGAGE", "VS_SET_HOME", "VS_NUDGE_LEFT",
    "VS_NUDGE_RIGHT", "VS_NUDGE_FORWARD", "VS_NUDGE_BACK", "VS_RELEASE" }) do
    InputAction[name] = name
end

g_inputBinding = { texts = {}, priorities = {} }
function g_inputBinding:setActionEventText(id, text) self.texts[id] = text end
function g_inputBinding:setActionEventTextPriority(id, prio) self.priorities[id] = prio end

FSBaseMission = { INGAME_NOTIFICATION_OK = "ok", INGAME_NOTIFICATION_CRITICAL = "critical" }

Drivable = { CRUISECONTROL_STATE_OFF = 0, CRUISECONTROL_STATE_ACTIVE = 1, CRUISECONTROL_STATE_FULL = 2 }
Enterable = { name = "enterable" }
Motorized = { name = "motorized" }
Locomotive = { name = "locomotive" }

XMLValueType = { BOOL = "bool", FLOAT = "float", INT = "int", STRING = "string" }
Vehicle = { xmlSchemaSavegame = { registered = {} } }
function Vehicle.xmlSchemaSavegame:register(valueType, path, description, default)
    table.insert(self.registered, { valueType = valueType, path = path, default = default })
end

SpecializationUtil = {}
function SpecializationUtil.hasSpecialization(spec, specializations)
    for _, s in ipairs(specializations) do
        if s == spec then return true end
    end
    return false
end
function SpecializationUtil.registerFunction(vehicleType, name, func)
    vehicleType.functions[name] = func
end
function SpecializationUtil.registerOverwrittenFunction(vehicleType, name, func)
    vehicleType.overwritten[name] = func
end
function SpecializationUtil.registerEventListener(vehicleType, name, spec)
    vehicleType.listeners[name] = spec
end

-- ---------------------------------------------------------------------------
-- Scene graph
-- ---------------------------------------------------------------------------

function M.createNode(x, z, heading)
    return { x = x or 0, z = z or 0, heading = heading or 0 }
end

function M.createChildNode(parent, lx, lz, lheading)
    return { parent = parent, lx = lx or 0, lz = lz or 0, lheading = lheading or 0 }
end

function M.getWorldPose(node)
    if node.parent == nil then
        return node.x, node.z, node.heading
    end
    local px, pz, ph = M.getWorldPose(node.parent)
    local cosH, sinH = math.cos(ph), math.sin(ph)
    return px + node.lx * cosH + node.lz * sinH, pz - node.lx * sinH + node.lz * cosH, ph + node.lheading
end

function getWorldTranslation(node)
    local x, z = M.getWorldPose(node)
    return x, 0, z
end

function localDirectionToWorld(node, dx, dy, dz)
    local _, _, h = M.getWorldPose(node)
    local cosH, sinH = math.cos(h), math.sin(h)
    return dx * cosH + dz * sinH, dy, -dx * sinH + dz * cosH
end

function localToWorld(node, x, y, z)
    local px, pz, ph = M.getWorldPose(node)
    local cosH, sinH = math.cos(ph), math.sin(ph)
    return px + x * cosH + z * sinH, y, pz - x * sinH + z * cosH
end

function localToLocal(nodeA, nodeB, x, y, z)
    local ax, az, ah = M.getWorldPose(nodeA)
    local cosA, sinA = math.cos(ah), math.sin(ah)
    local wx, wz = ax + x * cosA + z * sinA, az - x * sinA + z * cosA
    local bx, bz, bh = M.getWorldPose(nodeB)
    local dx, dz = wx - bx, wz - bz
    local cosB, sinB = math.cos(bh), math.sin(bh)
    return dx * cosB - dz * sinB, y, dx * sinB + dz * cosB
end

-- ---------------------------------------------------------------------------
-- Streams / network
-- ---------------------------------------------------------------------------

function M.createStream()
    return { data = {}, readPos = 1 }
end

local function push(stream, v) table.insert(stream.data, v) return v end
local function pop(stream)
    local v = stream.data[stream.readPos]
    stream.readPos = stream.readPos + 1
    return v
end

function streamWriteBool(s, v) push(s, v == true) return v == true end
function streamReadBool(s) return pop(s) end
function streamWriteFloat32(s, v) push(s, v) end
function streamReadFloat32(s) return pop(s) end
function streamWriteUInt8(s, v)
    assert(v >= 0 and v <= 255 and math.floor(v) == v, "UInt8 out of range: " .. tostring(v))
    push(s, v)
end
function streamReadUInt8(s) return pop(s) end
function streamWriteUIntN(s, v, bits)
    assert(v >= 0 and v < 2 ^ bits and math.floor(v) == v, "UIntN out of range: " .. tostring(v) .. " bits " .. bits)
    push(s, v)
end
function streamReadUIntN(s, bits) return pop(s) end

NetworkUtil = { objects = { server = {}, client = {} }, side = "server" }
function NetworkUtil.register(side, id, object)
    object.networkId = id
    NetworkUtil.objects[side] = NetworkUtil.objects[side] or {}
    NetworkUtil.objects[side][id] = object
end
function NetworkUtil.getObject(id)
    local objects = NetworkUtil.objects[NetworkUtil.side]
    return objects ~= nil and objects[id] or nil
end
function NetworkUtil.writeNodeObject(s, object)
    push(s, object ~= nil and object.networkId or 0)
end
function NetworkUtil.readNodeObjectId(s)
    return pop(s)
end
function NetworkUtil.readNodeObject(s)
    return NetworkUtil.getObject(pop(s))
end

-- connections
function M.createConnection(isServer)
    local c = { isServerConnection = isServer, sent = {} }
    function c:getIsServer() return self.isServerConnection end
    function c:sendEvent(event) table.insert(self.sent, event) end
    return c
end

-- Event base class
Event = {}
Event.__index = Event
function Class(class, base)
    class.__index = class
    if base ~= nil then
        setmetatable(class, { __index = base })
    end
    return class
end
function Event.new(mt)
    return setmetatable({}, mt)
end
M.eventClasses = {}
function InitEventClass(class, name)
    M.eventClasses[name] = class
end

SetCruiseControlSpeedEvent = {}
function SetCruiseControlSpeedEvent.new(vehicle, speed, speedReverse)
    return { eventName = "SetCruiseControlSpeedEvent", vehicle = vehicle, speed = speed, speedReverse = speedReverse }
end

-- ---------------------------------------------------------------------------
-- Mission / server / client
-- ---------------------------------------------------------------------------

function M.resetMission()
    g_currentMission = {
        vehicleSystem = { vehicles = {} },
        missionInfo = { savegameDirectory = nil },
        notifications = {},
        warnings = {},
        extraPrintTexts = {},
        accessHandler = { access = {} },
    }
    function g_currentMission:addIngameNotification(kind, text) table.insert(self.notifications, text) end
    function g_currentMission:showBlinkingWarning(text, duration) table.insert(self.warnings, text) end
    function g_currentMission:addExtraPrintText(text) table.insert(self.extraPrintTexts, text) end
    function g_currentMission.accessHandler:canFarmAccessOtherId(a, b)
        return self.access[a .. ":" .. b] == true
    end

    g_server = { broadcasts = {} }
    function g_server:broadcastEvent(event, sendLocal, ignoreConnection, ghostObject)
        table.insert(self.broadcasts, event)
    end

    g_client = { serverConnection = M.createConnection(true) }
    function g_client:getServerConnection() return self.serverConnection end

    NetworkUtil.objects = { server = {}, client = {} }
    NetworkUtil.side = "server"
end

-- ---------------------------------------------------------------------------
-- XML (in memory)
-- ---------------------------------------------------------------------------

M.files = {}

XMLFile = {}
XMLFile.__index = XMLFile
function XMLFile.create(objectName, path, root)
    local f = setmetatable({ path = path, root = root, values = {}, deleted = false }, XMLFile)
    return f
end
function XMLFile.loadIfExists(objectName, path)
    local stored = M.files[path]
    if stored == nil then
        return nil
    end
    local f = setmetatable({ path = path, values = {}, deleted = false }, XMLFile)
    for k, v in pairs(stored) do f.values[k] = v end
    return f
end
function XMLFile:getBool(key) local v = self.values[key] if type(v) == "boolean" then return v end return nil end
function XMLFile:getFloat(key) local v = self.values[key] if type(v) == "number" then return v end return nil end
function XMLFile:setBool(key, v) self.values[key] = v end
function XMLFile:setFloat(key, v) self.values[key] = v end
function XMLFile:getValue(key, default)
    local v = self.values[key]
    if v == nil then return default end
    return v
end
function XMLFile:setValue(key, v) self.values[key] = v end
function XMLFile:save()
    local copy = {}
    for k, v in pairs(self.values) do copy[k] = v end
    M.files[self.path] = copy
end
function XMLFile:delete() self.deleted = true end

function fileExists(path) return M.files[path] ~= nil end

-- ---------------------------------------------------------------------------
-- Mod loading
-- ---------------------------------------------------------------------------

M.SOURCE_ORDER = {
    "src/VehicleSyncMath.lua",
    "src/VehicleSyncController.lua",
    "src/VehicleSyncSettings.lua",
    "src/network/VehicleSyncRequestEvent.lua",
    "src/network/VehicleSyncStateEvent.lua",
    "src/VehicleSyncSpec.lua",
}

---Loads the pure logic and the specialization (without the VehicleSync bootstrap)
function M.loadMod()
    g_currentModName = "FS25_VehicleSync"
    g_currentModDirectory = ""
    for _, file in ipairs(M.SOURCE_ORDER) do
        dofile(file)
    end
end

---Loads only the engine independent core
function M.loadCore()
    dofile("src/VehicleSyncMath.lua")
    dofile("src/VehicleSyncController.lua")
end

function M.reset()
    M.resetMission()
    M.files = {}
    M.texts = {}
    M.eventClasses = {}
    Logging.calls = { error = {}, warning = {}, info = {} }
    g_inputBinding.texts = {}
    g_inputBinding.priorities = {}
    M.drawn = { circles = {}, lines = {} }
    g_time = 0
    g_gui.visible = false
    g_noHudModeEnabled = false
    Vehicle.xmlSchemaSavegame.registered = {}
end

M.reset()

TestEngine = M
return M
