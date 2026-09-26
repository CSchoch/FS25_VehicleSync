local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()

local function setupBootstrapMocks()
    local manager = { added = {}, objects = {} }
    function manager:getSpecializationByName(name) return self.added[name] end
    function manager:addSpecialization(name, className, filename, env)
        self.added[name] = { className = className, filename = filename }
        return true
    end
    function manager:getSpecializationObjectByName(name) return self.objects[name] end
    g_specializationManager = manager

    TypeManager = { validateCalls = 0 }
    function TypeManager.validateTypes(self)
        TypeManager.validateCalls = TypeManager.validateCalls + 1
    end
    FSCareerMissionInfo = { saveCalls = 0 }
    function FSCareerMissionInfo.saveToXMLFile(self)
        FSCareerMissionInfo.saveCalls = FSCareerMissionInfo.saveCalls + 1
    end

    local listeners = {}
    function addModEventListener(listener) table.insert(listeners, listener) end
    local commands = {}
    function addConsoleCommand(name, description, callback, target) commands[name] = { callback = callback, target = target } end
    function removeConsoleCommand(name) commands[name] = nil end
    return manager, listeners, commands
end

local function typeManager(types)
    local tm = { typeName = "vehicle", types = types, added = {} }
    function tm:getTypes() return self.types end
    function tm:addSpecialization(typeName, specName)
        table.insert(self.added, typeName)
        self.types[typeName].specializationsByName[specName] = true
    end
    return tm
end

describe("VehicleSync bootstrap", function()
    local manager, listeners, commands

    before_each(function()
        engine.reset()
        VehicleSyncSettings.reset()
        manager, listeners, commands = setupBootstrapMocks()
        g_currentModName = "FS25_VehicleSync"
        g_currentModDirectory = "C:/mods/FS25_VehicleSync/"
        dofile("src/VehicleSync.lua")
    end)

    it("registers the specialization with its literal file path", function()
        assert.equals("VehicleSyncSpec", manager.added.vehicleSync.className)
        assert.equals("C:/mods/FS25_VehicleSync/src/VehicleSyncSpec.lua", manager.added.vehicleSync.filename)
        assert.equals(VehicleSync, listeners[1])
    end)

    it("does not register the specialization twice", function()
        manager.added.vehicleSync = { className = "Other" }
        dofile("src/VehicleSync.lua")
        assert.equals("Other", manager.added.vehicleSync.className)
    end)

    it("adds the specialization to every drivable, motorized and enterable vehicle type", function()
        manager.objects["FS25_VehicleSync.vehicleSync"] = VehicleSyncSpec
        local tm = typeManager({
            tractor = { specializations = { Drivable, Enterable, Motorized }, specializationsByName = {} },
            trailer = { specializations = {}, specializationsByName = {} },
            train = { specializations = { Drivable, Enterable, Motorized, Locomotive }, specializationsByName = {} },
            already = { specializations = { Drivable, Enterable, Motorized }, specializationsByName = { ["FS25_VehicleSync.vehicleSync"] = true } },
        })
        TypeManager.validateTypes(tm)
        assert.same({ "tractor" }, tm.added)
        assert.equals(1, VehicleSync.numVehicleTypes)
        assert.equals(1, TypeManager.validateCalls)
    end)

    it("ignores other type managers", function()
        local tm = typeManager({})
        tm.typeName = "placeable"
        VehicleSync.addSpecializationToVehicleTypes(tm)
        assert.equals(0, #tm.added)
    end)

    it("logs an error when the specialization is missing", function()
        VehicleSync.addSpecializationToVehicleTypes(typeManager({}))
        assert.equals(1, #Logging.calls.error)
    end)

    it("loads the settings and adds console commands on the server", function()
        engine.files["sg/vehicleSync.xml"] = { ["vehicleSync.settings#maxSyncSpeed"] = 12 }
        g_currentMission.missionInfo.savegameDirectory = "sg"
        VehicleSync:loadMap("map.xml")
        assert.equals(12, VehicleSyncSettings.values.maxSyncSpeed)
        assert.not_equals(nil, commands.vsSettings)
        assert.not_equals(nil, commands.vsSet)
        -- loading a second map does not add the commands twice
        VehicleSync:loadMap("map.xml")
        VehicleSync:deleteMap()
        assert.is_nil(commands.vsSettings)
        assert.equals(16, VehicleSyncSettings.values.maxSyncSpeed)
        VehicleSync:deleteMap()
    end)

    it("uses defaults and no console commands on clients", function()
        VehicleSyncSettings.set("maxSyncSpeed", 30)
        g_server = nil
        VehicleSync:loadMap("map.xml")
        assert.equals(16, VehicleSyncSettings.values.maxSyncSpeed)
        assert.is_nil(commands.vsSettings)
    end)

    it("saves the settings with the career savegame on the server only", function()
        VehicleSyncSettings.set("stopTimeout", 5000)
        FSCareerMissionInfo.saveToXMLFile({ savegameDirectory = "slot1" })
        assert.equals(1, FSCareerMissionInfo.saveCalls)
        assert.equals(5000, engine.files["slot1/vehicleSync.xml"]["vehicleSync.settings#stopTimeout"])

        g_server = nil
        FSCareerMissionInfo.saveToXMLFile({ savegameDirectory = "slot2" })
        assert.is_nil(engine.files["slot2/vehicleSync.xml"])
        VehicleSync.onSaveCareerMissionInfo(nil)
    end)

    it("forwards draw and mouse events to the terminal and keeps its position per map", function()
        engine.files["modSettings/FS25_VehicleSync.xml"] = { ["vehicleSync.hud#left"] = 0.1, ["vehicleSync.hud#top"] = 0.9 }
        VehicleSync:loadMap("map.xml")
        assert.equals(0.1, VehicleSyncHud.left)

        local draw, mouseEvent = VehicleSyncHud.draw, VehicleSyncHud.mouseEvent
        local calls = {}
        VehicleSyncHud.draw = function(self) table.insert(calls, "draw") end
        VehicleSyncHud.mouseEvent = function(self, x, y, isDown, isUp, button) table.insert(calls, { x, y, isDown, isUp, button }) end
        VehicleSync:draw()
        VehicleSync:mouseEvent(0.2, 0.3, true, false, 1)
        VehicleSyncHud.draw, VehicleSyncHud.mouseEvent = draw, mouseEvent
        assert.same({ "draw", { 0.2, 0.3, true, false, 1 } }, calls)

        VehicleSync:deleteMap()
        assert.is_nil(VehicleSyncHud.left)
    end)

    it("implements the console commands", function()
        assert.contains(VehicleSync:consoleCommandSettings(), "maxSyncSpeed")
        assert.contains(VehicleSync:consoleCommandSet(nil, nil), "Usage")
        assert.contains(VehicleSync:consoleCommandSet("maxSyncSpeed", "abc"), "Error")
        assert.contains(VehicleSync:consoleCommandSet("maxSyncSpeed", "18"), "set to 18")
        assert.equals(18, VehicleSyncSettings.get().maxSyncSpeed)
    end)
end)
