local engine = dofile("tests/mocks/engine.lua")
engine.loadCore()
dofile("src/VehicleSyncSettings.lua")

local S = VehicleSyncSettings

describe("VehicleSyncSettings", function()
    before_each(function()
        engine.reset()
        S.reset()
    end)

    it("starts with the controller defaults for every definition", function()
        for _, def in ipairs(S.DEFINITIONS) do
            assert.equals(VehicleSyncController.DEFAULTS[def.name], S.values[def.name], def.name)
            assert.not_equals(nil, VehicleSyncController.DEFAULTS[def.name], def.name)
        end
    end)

    it("finds definitions", function()
        assert.equals("number", S.getDefinition("maxSyncSpeed").type)
        assert.is_nil(S.getDefinition("nope"))
    end)

    it("merges values into a cached controller settings table", function()
        local a = S.get()
        assert.equals(16, a.maxSyncSpeed)
        assert.equals(a, S.get())
        S.set("maxSyncSpeed", "20")
        local b = S.get()
        assert.not_equals(a, b)
        assert.equals(20, b.maxSyncSpeed)
        -- non user facing tuning stays available
        assert.equals(VehicleSyncController.DEFAULTS.lookAheadMin, b.lookAheadMin)
    end)

    describe("set", function()
        it("parses numbers within range", function()
            assert.is_true((S.set("radioRange", "750")))
            assert.equals(750, S.values.radioRange)
            assert.is_true((S.set("radioRange", 800)))
            assert.equals(800, S.values.radioRange)
        end)
        it("rejects out of range and invalid numbers", function()
            local ok, err = S.set("radioRange", "10")
            assert.is_false(ok)
            assert.contains(err, "between")
            ok, err = S.set("radioRange", "abc")
            assert.is_false(ok)
            assert.contains(err, "number")
            assert.equals(500, S.values.radioRange)
        end)
        it("parses booleans in several spellings", function()
            for _, v in ipairs({ "false", "0", "off", false }) do
                assert.is_true((S.set("disengageOnCartFull", v)))
                assert.is_false(S.values.disengageOnCartFull)
            end
            for _, v in ipairs({ "true", "1", "on", true }) do
                assert.is_true((S.set("disengageOnCartFull", v)))
                assert.is_true(S.values.disengageOnCartFull)
            end
            local ok, err = S.set("disengageOnCartFull", "maybe")
            assert.is_false(ok)
            assert.contains(err, "true/false")
        end)
        it("rejects unknown settings", function()
            local ok, err = S.set("foo", "1")
            assert.is_false(ok)
            assert.contains(err, "Unknown")
        end)
    end)

    describe("persistence", function()
        it("has no path without a mission or savegame directory", function()
            assert.is_nil(S.getXMLPath())
            local mission = g_currentMission
            g_currentMission = nil
            assert.is_nil(S.getXMLPath())
            assert.equals("dir/vehicleSync.xml", S.getXMLPath("dir"))
            g_currentMission = mission
        end)
        it("does nothing without a savegame directory", function()
            S.saveToSavegame()
            S.loadFromSavegame()
            assert.equals(0, table.size(engine.files))
        end)
        it("round trips all settings through the savegame xml", function()
            S.set("maxSyncSpeed", "22")
            S.set("keepSpeedOnSteering", "false")
            S.saveToSavegame("savegame1")
            assert.not_equals(nil, engine.files["savegame1/vehicleSync.xml"])

            S.reset()
            g_currentMission.missionInfo.savegameDirectory = "savegame1"
            S.loadFromSavegame()
            assert.equals(22, S.values.maxSyncSpeed)
            assert.is_false(S.values.keepSpeedOnSteering)
        end)
        it("uses defaults when the file does not exist", function()
            g_currentMission.missionInfo.savegameDirectory = "missing"
            S.set("maxSyncSpeed", "22")
            S.loadFromSavegame()
            assert.equals(16, S.values.maxSyncSpeed)
        end)
        it("warns about invalid values and keeps the default", function()
            engine.files["sg/vehicleSync.xml"] = { ["vehicleSync.settings#maxSyncSpeed"] = 999 }
            g_currentMission.missionInfo.savegameDirectory = "sg"
            S.loadFromSavegame()
            assert.equals(16, S.values.maxSyncSpeed)
            assert.equals(1, #Logging.calls.warning)
        end)
        it("skips saving when the xml cannot be created", function()
            local create = XMLFile.create
            XMLFile.create = function() return nil end
            S.saveToSavegame("sg")
            XMLFile.create = create
            assert.is_nil(engine.files["sg/vehicleSync.xml"])
        end)
    end)

    it("describes all settings", function()
        local text = S.describe()
        for _, def in ipairs(S.DEFINITIONS) do
            assert.contains(text, def.name)
        end
        assert.contains(text, "vsSet")
    end)
end)
