--[[
    VehicleSync

    Mod entry point: registers the vehicle specialization for every drivable vehicle type,
    loads / saves the server settings with the savegame and provides the console commands.
]]

---@class VehicleSync
VehicleSync = {}

VehicleSync.MOD_NAME = g_currentModName or "FS25_VehicleSync"
VehicleSync.MOD_DIRECTORY = g_currentModDirectory or ""
VehicleSync.SPEC_NAME = "vehicleSync"
VehicleSync.SPEC_FILENAME = "src/VehicleSyncSpec.lua"

VehicleSync.numVehicleTypes = 0
VehicleSync.consoleCommandsAdded = false

---Adds the specialization to every vehicle type that fulfils its prerequisites
---@param typeManager table
function VehicleSync.addSpecializationToVehicleTypes(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local fullName = VehicleSync.MOD_NAME .. "." .. VehicleSync.SPEC_NAME
    local specialization = g_specializationManager:getSpecializationObjectByName(fullName)
    if specialization == nil then
        Logging.error("[VehicleSync] Specialization '%s' not found", fullName)
        return
    end

    local count = 0
    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        if typeEntry.specializationsByName[fullName] == nil and specialization.prerequisitesPresent(typeEntry.specializations) then
            typeManager:addSpecialization(typeName, fullName)
            count = count + 1
        end
    end
    VehicleSync.numVehicleTypes = VehicleSync.numVehicleTypes + count
end

---Registers the specialization and the type hook (called once at file load)
function VehicleSync.init()
    if g_specializationManager:getSpecializationByName(VehicleSync.SPEC_NAME) == nil then
        g_specializationManager:addSpecialization(VehicleSync.SPEC_NAME, "VehicleSyncSpec",
            Utils.getFilename(VehicleSync.SPEC_FILENAME, VehicleSync.MOD_DIRECTORY), nil)
    end

    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, VehicleSync.addSpecializationToVehicleTypes)
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, VehicleSync.onSaveCareerMissionInfo)
end

---Mod event: map loaded
function VehicleSync:loadMap(filename)
    if g_server ~= nil then
        VehicleSyncSettings.loadFromSavegame()
        if not VehicleSync.consoleCommandsAdded then
            addConsoleCommand("vsSettings", "Lists the Vehicle Sync settings", "consoleCommandSettings", VehicleSync)
            addConsoleCommand("vsSet", "Changes a Vehicle Sync setting: vsSet <name> <value>", "consoleCommandSet", VehicleSync)
            VehicleSync.consoleCommandsAdded = true
        end
    else
        VehicleSyncSettings.reset()
    end
end

---Mod event: map unloaded
function VehicleSync:deleteMap()
    if VehicleSync.consoleCommandsAdded then
        removeConsoleCommand("vsSettings")
        removeConsoleCommand("vsSet")
        VehicleSync.consoleCommandsAdded = false
    end
    VehicleSyncSettings.reset()
end

---Saves the settings together with the savegame (server)
function VehicleSync.onSaveCareerMissionInfo(missionInfo)
    if g_server ~= nil and missionInfo ~= nil then
        VehicleSyncSettings.saveToSavegame(missionInfo.savegameDirectory)
    end
end

function VehicleSync:consoleCommandSettings()
    return VehicleSyncSettings.describe()
end

function VehicleSync:consoleCommandSet(name, value)
    if name == nil or value == nil then
        return "Usage: vsSet <name> <value>\n" .. VehicleSyncSettings.describe()
    end
    local ok, errorText = VehicleSyncSettings.set(name, value)
    if not ok then
        return "Error: " .. errorText
    end
    return string.format("Vehicle Sync: '%s' set to %s (saved with the next savegame)", name, tostring(VehicleSyncSettings.values[name]))
end

VehicleSync.init()
addModEventListener(VehicleSync)
